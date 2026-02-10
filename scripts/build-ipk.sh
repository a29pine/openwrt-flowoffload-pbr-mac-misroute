#!/usr/bin/env bash
set -euo pipefail

# Builds an OpenWrt .ipk that installs the flow-offload PBR/NAT guard include
# plus helper wrappers for apply/rollback.

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
PKG=openwrt-flowoffload-pbr-mitigation
# Use latest tag if present; allow override via VERSION=... (strip leading v)
VERSION=${VERSION:-$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null || echo 0.1.0)}
PKG_VERSION=${VERSION#v}
BUILD_DIR="${ROOT_DIR}/dist/ipk"
WORK_DIR="${BUILD_DIR}/${PKG}_${PKG_VERSION}"
CONTROL_DIR="${WORK_DIR}/CONTROL"
DATA_DIR="${WORK_DIR}/data"

command -v ar >/dev/null 2>&1 || { echo "ar is required to build ipk" >&2; exit 1; }

rm -rf "$WORK_DIR"
mkdir -p "$CONTROL_DIR" "$DATA_DIR"

# Payload files
install -Dm644 "${ROOT_DIR}/mitigation/firewall4-offload-mitigation.nft" \
  "${DATA_DIR}/etc/nftables.d/99-flowoffload-pbr.nft"
install -Dm755 "${ROOT_DIR}/mitigation/apply.sh" \
  "${DATA_DIR}/usr/lib/${PKG}/apply.sh"
install -Dm755 "${ROOT_DIR}/mitigation/rollback.sh" \
  "${DATA_DIR}/usr/lib/${PKG}/rollback.sh"
mkdir -p "${DATA_DIR}/usr/sbin"
ln -sf "../lib/${PKG}/apply.sh" "${DATA_DIR}/usr/sbin/flowoffload-pbr-apply"
ln -sf "../lib/${PKG}/rollback.sh" "${DATA_DIR}/usr/sbin/flowoffload-pbr-rollback"

# Control metadata
cat >"${CONTROL_DIR}/control" <<EOF
Package: ${PKG}
Version: ${PKG_VERSION}
Architecture: all
Maintainer: openwrt-flowoffload-pbr maintainers
Section: net
Priority: optional
Description: OpenWrt firewall4 flow offload guard for PBR/NAT traffic
EOF

echo "/etc/nftables.d/99-flowoffload-pbr.nft" >"${CONTROL_DIR}/conffiles"

cat >"${CONTROL_DIR}/postinst" <<'EOF'
#!/bin/sh
[ "$1" = "configure" ] || exit 0
if [ -x /etc/init.d/firewall ]; then
  /etc/init.d/firewall reload || /etc/init.d/firewall restart || true
fi
exit 0
EOF
chmod +x "${CONTROL_DIR}/postinst"

cat >"${CONTROL_DIR}/postrm" <<'EOF'
#!/bin/sh
case "$1" in
  remove|purge)
    if [ -x /etc/init.d/firewall ]; then
      /etc/init.d/firewall reload || /etc/init.d/firewall restart || true
    fi
    ;;
esac
exit 0
EOF
chmod +x "${CONTROL_DIR}/postrm"

# Build control.tar.gz
(
  cd "$CONTROL_DIR"
  tar -czf "${WORK_DIR}/control.tar.gz" ./*
)

# Build data.tar.gz
(
  cd "$DATA_DIR"
  tar -czf "${WORK_DIR}/data.tar.gz" ./*
)

echo "2.0" >"${WORK_DIR}/debian-binary"

(
  cd "$WORK_DIR"
  ar rcs "${PKG}_${PKG_VERSION}_all.ipk" debian-binary control.tar.gz data.tar.gz
  mv "${PKG}_${PKG_VERSION}_all.ipk" "$BUILD_DIR/"
)

rm -rf "$WORK_DIR"
echo "Built $BUILD_DIR/${PKG}_${PKG_VERSION}_all.ipk"
