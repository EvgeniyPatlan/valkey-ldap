#!/bin/sh
#
# gen-module-sbom.sh — generate the embedded SBOM set for this Percona Valkey module.
#
# Shipped in the source tarball and invoked from the RPM spec (%install) and the
# Debian rules (override_dh_auto_install), so the SBOM reflects the *built* tree.
#
# Usage: gen-module-sbom.sh PKG_NAME VERSION DEST_DIR [SCAN_DIR]
#
# Produces, in DEST_DIR:
#   PKG.spdx.json      SPDX (JSON)
#   PKG.cdx.json       CycloneDX (JSON)
#   PKG.spdx           SPDX (tag-value, text)
#   PKG.cdx.xml        CycloneDX (XML)
#   PKG.sbom.txt       Human-readable component table (Syft table)
#   PKG.licenses.txt   Condensed "name version license" manifest (derived)
#
set -eu

PKG="${1:?usage: gen-module-sbom.sh PKG VERSION DEST_DIR [SCAN_DIR]}"
VER="${2:?missing VERSION}"
DEST="${3:?missing DEST_DIR}"
SCAN="${4:-.}"

# Syft is installed system-wide by build_package.sh --install_deps. Fail loudly
# rather than ship an empty/placeholder SBOM.
if ! command -v syft >/dev/null 2>&1; then
    echo "ERROR: syft not found; cannot generate SBOM for ${PKG}" >&2
    exit 1
fi

mkdir -p "$DEST"

# One scan, multiple output formats. Exclude non-dependency dirs (packaging
# metadata and CI workflows are not components shipped in the package).
syft scan "dir:${SCAN}" \
    --source-name "$PKG" --source-version "$VER" \
    --exclude './debian' --exclude './rpm' --exclude './packaging' \
    --exclude './.github' --exclude './.git' \
    -o "spdx-json=${DEST}/${PKG}.spdx.json" \
    -o "cyclonedx-json=${DEST}/${PKG}.cdx.json" \
    -o "spdx-tag-value=${DEST}/${PKG}.spdx" \
    -o "cyclonedx-xml=${DEST}/${PKG}.cdx.xml" \
    -o "syft-table=${DEST}/${PKG}.sbom.txt"

# Derive a condensed "name version license" manifest from the SPDX tag-value
# output using awk only (no jq/python dependency in the build container).
awk '
    /^PackageName:/           { n=$2 }
    /^PackageVersion:/        { v=$2 }
    /^PackageLicenseDeclared:/{ l=substr($0, index($0, ": ")+2); if (n!="") printf "%s %s %s\n", n, v, l; n="" }
' "${DEST}/${PKG}.spdx" | sort -u > "${DEST}/${PKG}.licenses.txt"

echo "SBOM (spdx/cdx json+xml, table, licenses) written to ${DEST} for ${PKG} ${VER}"
