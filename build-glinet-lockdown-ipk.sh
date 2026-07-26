#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SRC_SCRIPT="$SCRIPT_DIR/glinet-lockdown.sh"
MODEL_TARGET="${MODEL_TARGET:-be3600}"
case "$MODEL_TARGET" in
  be3600)
    PKG_NAME="${PKG_NAME:-glinet-lockdown-be3600}"
    PKG_VERSION="${PKG_VERSION:-1.5.5}"
    PKG_DESCRIPTION="GL.iNet lockdown installer for GL-BE3600 local-only router hardening."
    MENU_JSON_SRC="$SCRIPT_DIR/luci/menu.d/glinet-lockdown-be3600.json"
    ACL_JSON_SRC="$SCRIPT_DIR/luci/acl.d/glinet-lockdown-be3600.json"
    JS_VIEW_SRC="$SCRIPT_DIR/luci/view_js/glinet_lockdown_overview.js"
    PKG_DEPENDS="luci-base, rpcd-mod-file"
    PKG_CONFLICTS="glinet-lockdown, glinet-lockdown-axt1800, glinet-lockdown-mudi7"
    USE_LUA_UI=0
    POSTINST_CACHE_REFRESH=1
    ;;
  axt1800)
    PKG_NAME="${PKG_NAME:-glinet-lockdown-axt1800}"
    PKG_VERSION="${PKG_VERSION:-1.5.5}"
    PKG_DESCRIPTION="GL.iNet lockdown installer for GL-AXT1800 local-only router hardening."
    MENU_JSON_SRC="$SCRIPT_DIR/luci/menu.d/glinet-lockdown-axt1800.json"
    ACL_JSON_SRC="$SCRIPT_DIR/luci/acl.d/glinet-lockdown-axt1800.json"
    JS_VIEW_SRC="$SCRIPT_DIR/luci/view_js/glinet_lockdown_overview.js"
    PKG_DEPENDS="luci-base, rpcd-mod-file"
    PKG_CONFLICTS="glinet-lockdown, glinet-lockdown-be3600, glinet-lockdown-mudi7"
    USE_LUA_UI=0
    POSTINST_CACHE_REFRESH=1
    ;;
  mudi7|gl-e5800|gle5800)
    PKG_NAME="${PKG_NAME:-glinet-lockdown-mudi7}"
    PKG_VERSION="${PKG_VERSION:-1.6.5}"
    PKG_DESCRIPTION="GL.iNet lockdown installer for Mudi 7 / GL-E5800 cellular travel router hardening."
    MENU_JSON_SRC="$SCRIPT_DIR/luci/menu.d/glinet-lockdown-mudi7.json"
    ACL_JSON_SRC="$SCRIPT_DIR/luci/acl.d/glinet-lockdown-mudi7.json"
    JS_VIEW_SRC="$SCRIPT_DIR/luci/view_js/glinet_lockdown_overview.js"
    PKG_DEPENDS="luci-base, rpcd-mod-file"
    PKG_CONFLICTS="glinet-lockdown, glinet-lockdown-be3600, glinet-lockdown-axt1800"
    USE_LUA_UI=0
    POSTINST_CACHE_REFRESH=1
    ;;
  *)
    echo "unsupported MODEL_TARGET: $MODEL_TARGET (use be3600, axt1800, or mudi7)" >&2
    exit 1
    ;;
esac
PKG_ARCH="all"
OUT_DIR="$SCRIPT_DIR/dist"
WORK_DIR="${TMPDIR:-/tmp}/${PKG_NAME}-build.$$"
PKG_FILE="$OUT_DIR/${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}.ipk"
VIEW_VERSION="$(printf '%s' "$PKG_VERSION" | tr '.-' '__')"
JS_VIEW_NAME="overview_${VIEW_VERSION}"
JS_VIEW_PATH="glinet_lockdown/$JS_VIEW_NAME"
UPDATE_REPO="${UPDATE_REPO:-}"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

if [ ! -f "$SRC_SCRIPT" ]; then
  echo "missing source script: $SRC_SCRIPT" >&2
  exit 1
fi

mkdir -p "$OUT_DIR" \
  "$WORK_DIR/control" \
  "$WORK_DIR/data/etc/init.d" \
  "$WORK_DIR/data/etc/glinet-lockdown" \
  "$WORK_DIR/data/usr/share/rpcd/acl.d" \
  "$WORK_DIR/data/usr/share/luci/menu.d" \
  "$WORK_DIR/data/usr/sbin" \
  "$WORK_DIR/data/www/luci-static/resources/view/glinet_lockdown" \
  "$WORK_DIR/data/usr/lib/lua/luci/controller" \
  "$WORK_DIR/data/usr/lib/lua/luci/view/glinet_lockdown"

cp "$SRC_SCRIPT" "$WORK_DIR/data/usr/sbin/glinet-lockdown.sh"
chmod 0755 "$WORK_DIR/data/usr/sbin/glinet-lockdown.sh"
cp "$SCRIPT_DIR/init.d/glinet-lockdown-guard" "$WORK_DIR/data/etc/init.d/glinet-lockdown-guard"
chmod 0755 "$WORK_DIR/data/etc/init.d/glinet-lockdown-guard"
if [ "$USE_LUA_UI" -eq 1 ]; then
  cp "$CONTROLLER_SRC" "$WORK_DIR/data/usr/lib/lua/luci/controller/glinet_lockdown.lua"
  cp "$SCRIPT_DIR/luci/view/glinet_lockdown/status.htm" "$WORK_DIR/data/usr/lib/lua/luci/view/glinet_lockdown/status.htm"
fi
if [ -n "${MENU_JSON_SRC:-}" ]; then
  sed "s#glinet_lockdown/overview#$JS_VIEW_PATH#g" "$MENU_JSON_SRC" >"$WORK_DIR/data/usr/share/luci/menu.d/glinet-lockdown.json"
fi
if [ -n "${ACL_JSON_SRC:-}" ]; then
  cp "$ACL_JSON_SRC" "$WORK_DIR/data/usr/share/rpcd/acl.d/glinet-lockdown.json"
fi
if [ -n "${JS_VIEW_SRC:-}" ]; then
  cp "$JS_VIEW_SRC" "$WORK_DIR/data/www/luci-static/resources/view/glinet_lockdown/$JS_VIEW_NAME.js"
  cp "$JS_VIEW_SRC" "$WORK_DIR/data/www/luci-static/resources/view/glinet_lockdown/overview.js"
fi
if [ -n "$UPDATE_REPO" ]; then
  printf '%s\n' "$UPDATE_REPO" >"$WORK_DIR/data/etc/glinet-lockdown/github-repo.default"
fi

cat >"$WORK_DIR/control/control" <<EOF
Package: $PKG_NAME
Version: $PKG_VERSION
Architecture: $PKG_ARCH
Maintainer: Kyle Davis
Section: admin
Priority: optional
Depends: $PKG_DEPENDS
EOF

if [ -n "$PKG_CONFLICTS" ]; then
  printf 'Conflicts: %s\n' "$PKG_CONFLICTS" >>"$WORK_DIR/control/control"
fi

printf 'Description: %s\n' "$PKG_DESCRIPTION" >>"$WORK_DIR/control/control"

cat >"$WORK_DIR/control/postinst" <<'EOF'
#!/bin/sh
set -e

if [ -n "$IPKG_INSTROOT" ]; then
  exit 0
fi

echo "[glinet-lockdown] package installed"
if [ -x /etc/init.d/glinet-lockdown-guard ]; then
  /etc/init.d/glinet-lockdown-guard enable >/dev/null 2>&1 || true
fi
mkdir -p /etc/glinet-lockdown
if [ -s /etc/glinet-lockdown/github-repo.default ] && [ ! -s /etc/glinet-lockdown/github-repo ]; then
  cp /etc/glinet-lockdown/github-repo.default /etc/glinet-lockdown/github-repo
fi
echo "[glinet-lockdown] open LuCI at System -> GL.iNet Lockdown to run or verify"
EOF
chmod 0755 "$WORK_DIR/control/postinst"

if [ "$POSTINST_CACHE_REFRESH" -eq 1 ]; then
  cat >>"$WORK_DIR/control/postinst" <<'EOF'
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* /tmp/luci-*cache* 2>/dev/null || true
find /tmp -maxdepth 1 -type f -name 'luci-*' -delete 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
EOF
fi

printf '2.0\n' >"$WORK_DIR/debian-binary"

COPYFILE_DISABLE=1 bsdtar --format ustar -C "$WORK_DIR/control" -czf "$WORK_DIR/control.tar.gz" .
COPYFILE_DISABLE=1 bsdtar --format ustar -C "$WORK_DIR/data" -czf "$WORK_DIR/data.tar.gz" .

rm -f "$PKG_FILE"
COPYFILE_DISABLE=1 bsdtar --format ustar -C "$WORK_DIR" -czf "$PKG_FILE" debian-binary control.tar.gz data.tar.gz

echo "$PKG_FILE"
