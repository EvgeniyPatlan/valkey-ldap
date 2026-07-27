#!/usr/bin/env bash
#
# build_package.sh — Build script for valkey-ldap packages (RPM, DEB, source tarballs)
#
# Mirrors the flag interface of valkey-audit's build_package.sh so the
# CI pipeline can drive both modules through the same stages:
#   --install_deps, --get_sources, --build_src_rpm, --build_rpm,
#   --build_src_deb, --build_deb, --use_local_packaging_script,
#   --repo, --branch, --version, --release, --builddir.
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly PRODUCT="valkey-ldap"
readonly PACKAGE_NAME="percona-valkey-ldap"
readonly DEFAULT_VERSION="1.1.0"
readonly DEFAULT_RELEASE="1"
readonly DEFAULT_BRANCH="percona-packaging"
readonly DEFAULT_REPO="https://github.com/EvgeniyPatlan/valkey-ldap.git"
# Pinned to the toolchain version embedded in the spec's %prep rustup install.
readonly RUST_TOOLCHAIN="1.87.0"

BUILDER_SCRIPT_DIR="$(dirname "$(readlink -e "${0}")")"
readonly BUILDER_SCRIPT_DIR

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_info()  { printf '\033[1;32m[INFO]\033[0m  %s\n' "$*"; }
log_warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
log_error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die()       { log_error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# apt resilience — a transient mirror/CDN failure (e.g. "Connection reset by
# peer" from deb.debian.org) must never fail a build. harden_apt drops in a
# config with retries, generous timeouts and no HTTP pipelining (flaky Fastly
# nodes reset pipelined connections). apt_get wraps the WHOLE command in an
# outer retry loop: apt's own Acquire::Retries handles per-file blips, and when
# those exhaust, the loop refreshes indexes and retries (a fresh attempt may
# route to a healthy node; already-fetched .debs stay cached). Use apt_get for
# every apt-get update/install.
# ---------------------------------------------------------------------------
harden_apt() {
    [[ -d /etc/apt ]] || return 0
    mkdir -p /etc/apt/apt.conf.d
    cat > /etc/apt/apt.conf.d/80-retries <<'EOF'
Acquire::Retries "5";
Acquire::Retries::Delay "true";
Acquire::http::Timeout "120";
Acquire::https::Timeout "120";
Acquire::http::Pipeline-Depth "0";
EOF
}

apt_get() {
    harden_apt
    local attempt rc
    for attempt in 1 2 3 4 5; do
        if DEBIAN_FRONTEND=noninteractive command apt-get "$@"; then
            return 0
        fi
        rc=$?
        log_warn "apt-get $* failed (attempt ${attempt}/5, rc=${rc}); refreshing indexes before retry"
        DEBIAN_FRONTEND=noninteractive command apt-get update -y >/dev/null 2>&1 || true
        sleep $(( attempt * 10 ))
    done
    log_error "apt-get $* failed after 5 attempts"
    return 1
}

cleanup() {
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        log_error "Script exited with code $rc"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]
    The following options may be given:
        --builddir=DIR                  Absolute path to the dir where all actions will be performed
        --get_sources                   Source will be cloned + tarballed
        --build_src_rpm                 Build source RPM
        --build_src_deb                 Build source DEB
        --build_rpm                     Build binary RPMs
        --build_deb                     Build binary DEBs
        --install_deps                  Install build dependencies (root required)
        --branch=BRANCH                 Branch/tag for build (default: ${DEFAULT_BRANCH})
        --repo=URL                      Git repo URL (default: ${DEFAULT_REPO})
        --version=VER                   Version string (default: from Cargo.toml or ${DEFAULT_VERSION})
        --release=REL                   Release number (default: ${DEFAULT_RELEASE})
        --use_local_packaging_script    Use local packaging/ (in ${BUILDER_SCRIPT_DIR}) instead of the cloned tree
        --help                          Print usage
Example: $0 --builddir=/tmp/BUILD --get_sources --build_src_rpm --build_rpm
Example: $0 --builddir=/tmp/BUILD --get_sources --build_src_deb --build_deb
Example: $0 --builddir=/tmp/BUILD --install_deps --get_sources --build_deb
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_arguments() {
    for arg in "$@"; do
        case "$arg" in
            --builddir=*)                WORKDIR="${arg#*=}" ;;
            --build_src_rpm=*|--build_src_rpm) SRPM=1 ;;
            --build_src_deb=*|--build_src_deb) SDEB=1 ;;
            --build_rpm=*|--build_rpm)   RPM=1 ;;
            --build_deb=*|--build_deb)   DEB=1 ;;
            --get_sources=*|--get_sources) SOURCE=1 ;;
            --branch=*)                  BRANCH="${arg#*=}" ;;
            --repo=*)                    REPO="${arg#*=}" ;;
            --version=*)                 VERSION="${arg#*=}" ;;
            --release=*)                 RELEASE="${arg#*=}" ;;
            --install_deps=*|--install_deps) INSTALL=1 ;;
            --use_local_packaging_script=*|--use_local_packaging_script) LOCAL_BUILD=1 ;;
            --help)                      usage ;;
            *)                           die "Unknown option: $arg" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
find_and_copy_artifact() {
    local search_subdir="$1"
    local glob_pattern="$2"
    local found

    found="$(find "$WORKDIR/$search_subdir" -name "$glob_pattern" 2>/dev/null | sort | tail -n1 || true)"
    if [[ -n "$found" ]]; then
        FOUND_FILE="$(basename "$found")"
        cp "$found" "$WORKDIR/$FOUND_FILE"
        return 0
    fi

    found="$(find "$CURDIR/$search_subdir" -name "$glob_pattern" 2>/dev/null | sort | tail -n1 || true)"
    if [[ -n "$found" ]]; then
        FOUND_FILE="$(basename "$found")"
        cp "$found" "$WORKDIR/$FOUND_FILE"
        return 0
    fi

    log_error "No artifact matching '$glob_pattern' found in $search_subdir"
    return 1
}

copy_artifacts() {
    local dest_subdir="$1"
    shift

    mkdir -p "$WORKDIR/$dest_subdir"
    mkdir -p "$CURDIR/$dest_subdir"
    cp "$@" "$WORKDIR/$dest_subdir/"
    cp "$@" "$CURDIR/$dest_subdir/"
}

check_workdir() {
    if [[ -z "$WORKDIR" ]]; then
        die "--builddir is required"
    fi
    if [[ "$WORKDIR" == "$CURDIR" ]]; then
        die "Current directory cannot be used for building!"
    fi
    if [[ ! -d "$WORKDIR" ]]; then
        log_info "Creating build directory: $WORKDIR"
        mkdir -p "$WORKDIR"
    fi
}

# ---------------------------------------------------------------------------
# extract_version — read version from the cloned tree's Cargo.toml
# ---------------------------------------------------------------------------
extract_version() {
    local source_dir="$1"
    local cargo_toml="$source_dir/Cargo.toml"
    if [[ ! -f "$cargo_toml" ]]; then
        die "Cargo.toml not found: $cargo_toml"
    fi

    local ver
    ver="$(grep -E '^version[[:space:]]*=' "$cargo_toml" | head -1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')"
    if [[ -z "$ver" ]]; then
        die "Failed to extract version from $cargo_toml"
    fi
    VERSION="$ver"
    log_info "Version: ${VERSION}"
}

# ---------------------------------------------------------------------------
# get_system
# ---------------------------------------------------------------------------
get_system() {
    ARCH="$(uname -m)"

    if [[ -f /etc/redhat-release ]]; then
        RHEL="$(rpm --eval %rhel)"
        OS_NAME="el${RHEL}"
        OS="rpm"
        if [[ -f /etc/oracle-release ]]; then
            PLATFORM_FAMILY="oracle"
        elif [[ -f /etc/fedora-release ]]; then
            PLATFORM_FAMILY="fedora"
        else
            PLATFORM_FAMILY="rhel"
        fi
    elif [[ -f /etc/SuSE-release ]] || [[ -f /etc/SUSE-brand ]] || grep -qi suse /etc/os-release 2>/dev/null; then
        OS="rpm"
        OS_NAME="suse"
        RHEL="0"
        PLATFORM_FAMILY="suse"
    elif [[ -f /etc/system-release ]] && grep -qi "amazon" /etc/system-release 2>/dev/null; then
        OS="rpm"
        RHEL="$(rpm --eval %rhel 2>/dev/null || echo 0)"
        OS_NAME="amzn2023"
        PLATFORM_FAMILY="amazon"
    elif command -v rpm &>/dev/null && ! command -v dpkg &>/dev/null; then
        OS="rpm"
        RHEL="$(rpm --eval %rhel 2>/dev/null || echo 0)"
        OS_NAME="rpm"
        PLATFORM_FAMILY="rhel"
    else
        OS_NAME="$(lsb_release -sc 2>/dev/null || echo unknown)"
        OS="deb"
        PLATFORM_FAMILY="deb"
    fi

    log_info "Detected OS: ${OS} (${PLATFORM_FAMILY}/${OS_NAME}), arch: ${ARCH}"
}

# ---------------------------------------------------------------------------
# install_deps
# ---------------------------------------------------------------------------
install_deps() {
    if [[ "$INSTALL" -eq 0 ]]; then
        log_info "Dependencies will not be installed"
        return 0
    fi

    if [[ "$(id -u)" -ne 0 ]]; then
        die "Cannot install dependencies — please run as root"
    fi

    if [[ "$OS" == "rpm" ]]; then
        install_deps_rpm
    else
        install_deps_deb
    fi

    install_rust_toolchain
    ensure_syft_system
}

# ensure_syft_system — install Syft into /usr/local/bin so the spec/rules can
# generate the package's SBOM from the built tree. Idempotent; tries curl/wget.
ensure_syft_system() {
    command -v syft &>/dev/null && return 0
    log_info "Installing Syft (system-wide) for in-package SBOM generation..."
    if command -v curl &>/dev/null; then
        curl -sSfL https://get.anchore.io/syft | sh -s -- -b /usr/local/bin >/dev/null 2>&1 || true
    elif command -v wget &>/dev/null; then
        wget -qO- https://get.anchore.io/syft | sh -s -- -b /usr/local/bin >/dev/null 2>&1 || true
    fi
    command -v syft &>/dev/null || log_warn "Syft not installed; the package SBOM step will fail loudly at build time"
}

install_deps_rpm() {
    local pkg_mgr="yum"
    if command -v dnf &>/dev/null; then
        pkg_mgr="dnf"
    fi

    if [[ "$PLATFORM_FAMILY" == "suse" ]]; then
        log_info "Installing SUSE build dependencies..."
        zypper refresh
        zypper install -y \
            rpm-build rpmdevtools gcc gcc-c++ make git tar gzip wget curl ca-certificates \
            libopenssl-devel openldap2-devel clang-devel pkg-config
    else
        case "$PLATFORM_FAMILY" in
            oracle)
                local epel_pkg="oracle-epel-release-el${RHEL}"
                if ! rpm -q "$epel_pkg" &>/dev/null; then
                    log_info "Installing EPEL for Oracle Linux: $epel_pkg"
                    $pkg_mgr install -y --setopt=retries=10 "$epel_pkg" \
                        || log_warn "EPEL installation failed (non-critical)"
                fi
                ;;
            rhel)
                if ! rpm -q epel-release &>/dev/null; then
                    log_info "Installing EPEL repository..."
                    $pkg_mgr install -y --setopt=retries=10 epel-release \
                        || log_warn "EPEL installation failed (non-critical)"
                fi
                ;;
            fedora|amazon)
                log_info "Skipping EPEL (not needed for $PLATFORM_FAMILY)"
                ;;
        esac

        log_info "Installing RPM build dependencies..."
        # Note: curl is intentionally omitted. EL9+ and Amazon Linux 2023 ship
        # curl-minimal preinstalled (provides /usr/bin/curl), and dnf refuses
        # to install curl alongside it without --allowerasing. The preinstalled
        # curl-minimal is sufficient for install_rust_toolchain's rustup-init
        # download. The upstream spec.in carries the same comment.
        $pkg_mgr install -y --setopt=retries=10 \
            rpm-build rpmdevtools gcc gcc-c++ make git tar gzip wget ca-certificates \
            openssl openssl-devel openldap-devel clang-devel pkg-config

        $pkg_mgr clean all
    fi
}

install_deps_deb() {
    log_info "Installing DEB build dependencies..."
    apt_get update

    apt_get -y --fix-missing install \
        build-essential debhelper devscripts dpkg-dev \
        fakeroot ca-certificates lsb-release \
        git wget curl tar gzip make gcc pkg-config \
        libssl-dev libclang-dev

    apt_get -y --fix-missing install libldap-dev \
        || apt_get -y --fix-missing install libldap2-dev
}

# Install rustup + the pinned toolchain into /usr/local so subsequent stages
# in the same container (e.g. cargo vendor inside get_sources) can find it.
install_rust_toolchain() {
    # Pin install location so subsequent stages (which run in a separate
    # bash invocation but the same container) can find both the cargo
    # binary and the toolchain. ensure_cargo_on_path uses the same values.
    export CARGO_HOME=/usr/local/cargo
    export RUSTUP_HOME=/usr/local/rustup
    export PATH="$CARGO_HOME/bin:$PATH"

    # Treat "rustup proxy with a working toolchain" as already installed;
    # a bare `command -v cargo` check is not enough because the proxy
    # exits non-zero when no default toolchain is configured.
    if cargo --version &>/dev/null; then
        log_info "Rust already available: $(cargo --version)"
        return 0
    fi

    log_info "Installing Rust toolchain ${RUST_TOOLCHAIN}..."
    mkdir -p "$CARGO_HOME" "$RUSTUP_HOME"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- --default-toolchain "${RUST_TOOLCHAIN}" --no-modify-path --profile minimal -y

    log_info "Rust installed: $(cargo --version)"
}

# Make sure cargo + the installed toolchain are usable in the current shell.
# Must set RUSTUP_HOME explicitly — /usr/local/cargo/env only fixes PATH,
# and without RUSTUP_HOME the rustup proxy looks under ~/.rustup (empty)
# and bails with "no default is configured".
ensure_cargo_on_path() {
    export CARGO_HOME="${CARGO_HOME:-/usr/local/cargo}"
    export RUSTUP_HOME="${RUSTUP_HOME:-/usr/local/rustup}"
    if [[ -d "$CARGO_HOME/bin" ]]; then
        case ":$PATH:" in
            *":$CARGO_HOME/bin:"*) ;;
            *) export PATH="$CARGO_HOME/bin:$PATH" ;;
        esac
    fi
    cargo --version &>/dev/null || die "cargo not found / no default toolchain — run --install_deps first"
}

# ---------------------------------------------------------------------------
# get_sources — clone, vendor crates, tarball
# ---------------------------------------------------------------------------
get_sources() {
    if [[ "$SOURCE" -eq 0 ]]; then
        log_info "Sources will not be downloaded"
        return 0
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local product_full="${PRODUCT}-${VERSION}"

    cat > ${PRODUCT}.properties <<EOF
PRODUCT=${PRODUCT}
PRODUCT_FULL=${product_full}
VERSION=${VERSION}
BUILD_NUMBER=${BUILD_NUMBER:-}
BUILD_ID=${BUILD_ID:-}
EOF

    log_info "Cloning $REPO ..."
    rm -rf "${product_full}"
    if ! git clone "$REPO" "${product_full}"; then
        die "Failed to clone repo from $REPO. Please retry."
    fi

    cd "${product_full}" || die "Cannot cd to ${product_full}"

    if [[ -n "$BRANCH" ]]; then
        git reset --hard
        git clean -xdf
        git checkout "$BRANCH"
    fi

    local revision
    revision="$(git rev-parse --short HEAD)"
    echo "REVISION=${revision}" >> "${WORKDIR}/${PRODUCT}.properties"

    if [[ "$VERSION_FROM_CLI" -eq 0 ]]; then
        extract_version "$(pwd)"
        product_full="${PRODUCT}-${VERSION}"
        export PRODUCT_FULL="${PRODUCT}-${VERSION}-${RELEASE}"

        cat > "${WORKDIR}/${PRODUCT}.properties" <<PROPS
PRODUCT=${PRODUCT}
PRODUCT_FULL=${product_full}
VERSION=${VERSION}
BUILD_NUMBER=${BUILD_NUMBER:-}
BUILD_ID=${BUILD_ID:-}
REVISION=${revision}
PROPS
    fi

    # Vendor Cargo dependencies so downstream rpmbuild / dpkg-buildpackage can
    # build offline (mirrors what packaging/build_srpm.sh expects).
    ensure_cargo_on_path
    log_info "Running cargo vendor ..."
    cargo vendor

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    # Rename directory if extract_version changed VERSION after clone.
    if [[ ! -d "${product_full}" ]]; then
        local old_dir
        old_dir="$(find . -maxdepth 1 -type d -name "${PRODUCT}-*" | head -1)"
        if [[ -n "$old_dir" && "$old_dir" != "./${product_full}" ]]; then
            mv "$old_dir" "${product_full}"
        fi
    fi

    tar --owner=0 --group=0 --exclude=.git -czf "${product_full}.tar.gz" "${product_full}"

    echo "UPLOAD=UPLOAD/experimental/BUILDS/${PRODUCT}/${product_full}/${BRANCH}/${revision}/${BUILD_ID:-}" >> ${PRODUCT}.properties

    copy_artifacts "source_tarball" "${product_full}.tar.gz"

    cd "$CURDIR" || die "Cannot cd to $CURDIR"
}

# ===========================================================================
# RPM
# ===========================================================================

# Substitute spec.in placeholders the same way packaging/build_srpm.sh does.
render_spec() {
    local spec_in="$1"
    local out_spec="$2"
    local rpm_version="${VERSION//-/~}"
    sed -e "s/#\[RPM_VERSION\]/${rpm_version}/g" \
        -e "s/#\[VERSION\]/${VERSION}/g" \
        -e "s/#\[PKG_NAME\]/${PACKAGE_NAME}/g" \
        "$spec_in" > "$out_spec"
    sed -i "s/^Release:.*$/Release:        ${RELEASE}%{?dist}/" "$out_spec"
    local date
    date="$(LC_TIME=en_US.UTF-8 date "+%a %b %d %Y")"
    {
        echo "* ${date} Evgeniy Patlan <evgeniy.patlan@percona.com> - ${rpm_version}-${RELEASE}"
        echo "- Build for ${PACKAGE_NAME} version ${VERSION}"
    } >> "$out_spec"
}

build_srpm() {
    if [[ "$SRPM" -eq 0 ]]; then
        log_info "SRC RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build src rpm on a Debian-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    find_and_copy_artifact "source_tarball" "${PRODUCT}*.tar.gz"
    local tarfile="$FOUND_FILE"

    rm -fr rpmbuild
    mkdir -vp rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}

    # Extract just the packaging/ subdir from the tarball.
    tar vxzf "${WORKDIR}/${tarfile}" --wildcards '*/packaging' --strip=1

    local spec_in="packaging/${PRODUCT}.spec.in"
    [[ -f "$spec_in" ]] || die "Missing spec template: $spec_in"

    render_spec "$spec_in" "rpmbuild/SPECS/${PACKAGE_NAME}.spec"
    mv -fv "$tarfile" "${WORKDIR}/rpmbuild/SOURCES"

    local rpm_version="${VERSION//-/~}"
    rpmbuild -bs --define "_topdir ${WORKDIR}/rpmbuild" --define "dist .generic" \
        --define "version ${rpm_version}" "rpmbuild/SPECS/${PACKAGE_NAME}.spec"

    copy_artifacts "srpm" rpmbuild/SRPMS/*.src.rpm

    cd "$CURDIR" || die "Cannot cd to $CURDIR"
}

build_rpm() {
    if [[ "$RPM" -eq 0 ]]; then
        log_info "RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build rpm on a Debian-based system"
    fi

    find_and_copy_artifact "srpm" "${PACKAGE_NAME}*.src.rpm"
    local src_rpm="$FOUND_FILE"

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    rm -fr rb
    mkdir -vp rb/{SOURCES,SPECS,BUILD,SRPMS,RPMS,BUILDROOT}
    cp "$src_rpm" rb/SRPMS/

    RHEL="$(rpm --eval %rhel)"
    ARCH="$(uname -m)"
    local rpm_version="${VERSION//-/~}"

    rpmbuild --define "_topdir ${WORKDIR}/rb" --define "dist .${OS_NAME}" \
        --define "version ${rpm_version}" --rebuild "rb/SRPMS/${src_rpm}"

    copy_artifacts "rpm" rb/RPMS/*/*.rpm

    cd "$CURDIR" || die "Cannot cd to $CURDIR"
}

# ===========================================================================
# DEB
# ===========================================================================

build_source_deb() {
    if [[ "$SDEB" -eq 0 ]]; then
        log_info "Source deb package will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build source deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    rm -rf "${PRODUCT}-"* "${PACKAGE_NAME}-"* "${PACKAGE_NAME}_"*
    rm -f ./*.dsc ./*.orig.tar.gz ./*.changes ./*.debian.tar.* ./*.diff.*

    find_and_copy_artifact "source_tarball" "${PRODUCT}*.tar.gz"
    local tarfile="$FOUND_FILE"

    local debian_codename
    debian_codename="$(lsb_release -sc 2>/dev/null || echo unstable)"
    ARCH="$(uname -m)"

    tar zxf "$tarfile"
    mv "${PRODUCT}-${VERSION}" "${PACKAGE_NAME}-${VERSION}"
    local builddir="${PACKAGE_NAME}-${VERSION}"

    # dpkg-source requires the orig tarball top-level dir to match the source
    # package name; the upstream-style tarball uses PRODUCT, so repack.
    tar czf "${PACKAGE_NAME}_${VERSION}.orig.tar.gz" "$builddir"
    rm -f "$tarfile"

    cd "$builddir" || die "Cannot cd to $builddir"

    # debian/ lives under packaging/debian/ in this repo (no packaging/deb/).
    if [[ ! -d debian ]]; then
        cp -a packaging/debian ./debian
    fi

    cd debian || die "Cannot cd to debian"
    rm -rf changelog
    {
        echo "${PACKAGE_NAME} (${VERSION}-${RELEASE}) unstable; urgency=low"
        echo "  * Initial Release."
        echo " -- Evgeniy Patlan <evgeniy.patlan@percona.com>  $(date -R)"
    } > changelog
    cd ..

    dch -D unstable --force-distribution -v "${VERSION}-${RELEASE}" \
        "Update to new ${PACKAGE_NAME} version ${VERSION}"
    dpkg-buildpackage -S

    cd ..

    copy_artifacts "source_deb" ./*_source.changes
    copy_artifacts "source_deb" ./*.dsc
    copy_artifacts "source_deb" ./*.orig.tar.gz
    copy_artifacts "source_deb" ./*.debian.tar.* 2>/dev/null \
        || copy_artifacts "source_deb" ./*diff* 2>/dev/null \
        || true

    cd "$CURDIR" || die "Cannot cd to $CURDIR"
}

build_deb() {
    if [[ "$DEB" -eq 0 ]]; then
        log_info "Deb package will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build deb on an RPM-based system"
    fi

    for file in 'dsc' 'orig.tar.gz' 'changes'; do
        find_and_copy_artifact "source_deb" "${PACKAGE_NAME}*.${file}"
    done
    find_and_copy_artifact "source_deb" "${PACKAGE_NAME}*.debian.tar.*" \
        || find_and_copy_artifact "source_deb" "${PACKAGE_NAME}*diff*" \
        || true

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"
    rm -fv ./*.deb
    rm -rf "${PACKAGE_NAME}-${VERSION}"

    local debian_codename
    debian_codename="$(lsb_release -sc 2>/dev/null || echo unstable)"
    ARCH="$(uname -m)"

    echo "DEBIAN=${debian_codename}" >> ${PRODUCT}.properties
    echo "ARCH=${ARCH}" >> ${PRODUCT}.properties

    local dsc
    dsc="$(basename "$(find . -name '*.dsc' | sort | tail -n1)")"
    dpkg-source -x "$dsc"

    cd "${PACKAGE_NAME}-${VERSION}" || die "Cannot cd to ${PACKAGE_NAME}-${VERSION}"

    dch -m -D "$debian_codename" --force-distribution \
        -v "${VERSION}-${RELEASE}.${debian_codename}" 'Update distribution'

    # Cargo needs PATH + RUSTUP_HOME inside the dpkg-buildpackage child shell.
    ensure_cargo_on_path

    # shellcheck disable=SC2046
    unset $(locale | cut -d= -f1) 2>/dev/null || true

    dpkg-buildpackage -rfakeroot -us -uc -b

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    copy_artifacts "deb" "$WORKDIR"/*.*deb

    cd "$CURDIR" || die "Cannot cd to $CURDIR"
}

# ===========================================================================
# Main
# ===========================================================================
CURDIR="$(pwd)"
WORKDIR=""
SRPM=0
SDEB=0
RPM=0
DEB=0
SOURCE=0
OS_NAME=""
ARCH=""
OS=""
PLATFORM_FAMILY=""
RHEL="0"
INSTALL=0
BRANCH="$DEFAULT_BRANCH"
REPO="$DEFAULT_REPO"
VERSION=""
VERSION_FROM_CLI=0
RELEASE="$DEFAULT_RELEASE"
LOCAL_BUILD=0

parse_arguments "$@"

if [[ -n "$VERSION" ]]; then
    VERSION_FROM_CLI=1
fi
export PRODUCT_FULL="${PRODUCT}-${VERSION:-$DEFAULT_VERSION}-${RELEASE}"

if [[ $# -eq 0 ]]; then
    usage
fi

check_workdir
get_system

if [[ -z "$VERSION" ]]; then
    if [[ -f "$WORKDIR/${PRODUCT}.properties" ]]; then
        VERSION="$(grep '^VERSION=' "$WORKDIR/${PRODUCT}.properties" | cut -d= -f2)"
        [[ -n "$VERSION" ]] && log_info "Read version from ${PRODUCT}.properties: ${VERSION}"
    fi
    if [[ -z "$VERSION" && -f "$CURDIR/${PRODUCT}.properties" ]]; then
        VERSION="$(grep '^VERSION=' "$CURDIR/${PRODUCT}.properties" | cut -d= -f2)"
        [[ -n "$VERSION" ]] && log_info "Read version from ${PRODUCT}.properties: ${VERSION}"
    fi
    if [[ -z "$VERSION" ]]; then
        VERSION="$DEFAULT_VERSION"
        log_info "Using default version: ${VERSION}"
    fi
    export PRODUCT_FULL="${PRODUCT}-${VERSION}-${RELEASE}"
fi

install_deps
get_sources
build_srpm
build_source_deb
build_rpm
build_deb
