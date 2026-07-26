#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/glinet-lockdown.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -q 'verify_check "dropbear service disabled"' "$SCRIPT" \
  || fail "verification must require dropbear service to be disabled"

grep -q 'svc_disable "dropbear"' "$SCRIPT" \
  || fail "apply mode must disable and stop dropbear"

grep -q 'apply_optional_bundle()' "$SCRIPT" \
  || fail "optional service bundles must be implemented"

grep -q 'OPTIONAL_BUNDLES_FILE=' "$SCRIPT" \
  || fail "optional service selections must persist for startup guard enforcement"

grep -q 'CORE_APPLIED_FILE=' "$SCRIPT" \
  || fail "startup guard must know whether core lockdown has been run"

grep -q 'LATEST_BACKUP_FILE=' "$SCRIPT" \
  || fail "lockdown must track the latest settings backup"

grep -q 'create_backup()' "$SCRIPT" \
  || fail "lockdown must provide settings backups"

grep -q 'optional-set' "$SCRIPT" \
  || fail "optional service selections must be reconciled as a desired state"

grep -q 'set_optional_selection_state()' "$SCRIPT" \
  || fail "profile application must save optional desired state before core lockdown"

grep -q 'sh "$0" apply' "$SCRIPT" \
  || fail "profile application must run core lockdown"

grep -q 'glinet_optional_bundle' "$ROOT_DIR/luci/view_js/glinet_lockdown_overview.js" \
  || fail "LuCI must expose optional service selection checkboxes"

grep -q 'Full Optional Lockdown' "$ROOT_DIR/luci/view_js/glinet_lockdown_overview.js" \
  || fail "LuCI must expose a full optional lockdown selection"

grep -q 'FULL OPTIONAL LOCKDOWN APPLIED' "$SCRIPT" \
  || fail "full optional lockdown must print an explicit success marker"

grep -q 'Full optional lockdown has been applied' "$ROOT_DIR/luci/view_js/glinet_lockdown_overview.js" \
  || fail "LuCI must display a clear full optional lockdown applied status"

grep -q 'install_optional_bundle()' "$SCRIPT" \
  || fail "optional service bundles must support install/restore actions"

grep -q 'Execute Optional Selections' "$ROOT_DIR/luci/view_js/glinet_lockdown_overview.js" \
  || fail "LuCI must expose a single optional selection execute action"

grep -q 'Create Backup' "$ROOT_DIR/luci/view_js/glinet_lockdown_overview.js" \
  || fail "LuCI must expose manual settings backups"

grep -q 'restore_latest_backup()' "$SCRIPT" \
  || fail "lockdown must support restoring the latest settings backup"

grep -q 'apply_dns_enforcement()' "$SCRIPT" \
  || fail "lockdown must support LAN DNS enforcement"

grep -q 'apply_cloud_ip_block()' "$SCRIPT" \
  || fail "lockdown must support cloud IP blocking"

grep -q 'refresh_cloud_ips' "$SCRIPT" \
  || fail "lockdown must refresh cloud IPs"

grep -q 'awk '\''$0 != "0.0.0.0"' "$SCRIPT" \
  || fail "cloud IP refresh must not add 0.0.0.0 to the runtime nft set"

grep -q 'apply_cloud_ip_block' "$SCRIPT" \
  || fail "core lockdown must apply cloud IP blocking"

grep -q 'verify_check "gl-tertf service disabled"' "$SCRIPT" \
  || fail "verification must check gl-tertf remains disabled"

grep -q 'verify_check "gl_clients service disabled"' "$SCRIPT" \
  || fail "verification must check gl_clients remains disabled"

grep -q 'enable_temp_ssh()' "$SCRIPT" \
  || fail "lockdown must support temporary SSH access"

grep -q 'install_temp_ssh_cron()' "$SCRIPT" \
  || fail "temporary SSH must install an expiry watchdog"

grep -q 'ssh-expire' "$SCRIPT" \
  || fail "temporary SSH must support expiry checks"

grep -q 'glinet_ssh_countdown' "$ROOT_DIR/luci/view_js/glinet_lockdown_overview.js" \
  || fail "LuCI must display a temporary SSH countdown"

grep -q 'wan_exposure_scan()' "$SCRIPT" \
  || fail "lockdown must support WAN exposure scans"

grep -q 'self_update_from_github()' "$SCRIPT" \
  || fail "lockdown must support GitHub release updates"

grep -q 'check_update_from_github()' "$SCRIPT" \
  || fail "lockdown must support update checks before install"

grep -q 'apply_profile()' "$SCRIPT" \
  || fail "lockdown must support Balanced/Strict/Custom profiles"

grep -q 'STRICT_BUNDLE_LIST=' "$SCRIPT" \
  || fail "strict profile must have an explicit bundle list"

if grep -q 'STRICT_BUNDLE_LIST=.*vpn-servers' "$SCRIPT"; then
  fail "strict profile must preserve VPN server capability unless the user explicitly selects VPN server removal"
fi

grep -q 'Apply Profile' "$ROOT_DIR/luci/view_js/glinet_lockdown_overview.js" \
  || fail "LuCI must expose profile application"

grep -q 'Custom - use selections below' "$ROOT_DIR/luci/view_js/glinet_lockdown_overview.js" \
  || fail "LuCI must make Custom profile selections obvious"

grep -q 'Custom Optional Services' "$ROOT_DIR/luci/view_js/glinet_lockdown_overview.js" \
  || fail "LuCI must label optional service checkboxes as custom profile controls"

grep -q 'Custom Network Controls' "$ROOT_DIR/luci/view_js/glinet_lockdown_overview.js" \
  || fail "LuCI must label network checkboxes as custom profile controls"

grep -q 'Apply Network Controls' "$ROOT_DIR/luci/view_js/glinet_lockdown_overview.js" \
  || fail "LuCI must expose DNS network controls"

grep -q 'Known blocked GL.iNet/GoodCloud IP denylist' "$ROOT_DIR/luci/view_js/glinet_lockdown_overview.js" \
  || fail "LuCI must clarify that cloud IP entries are denylist entries, not observed callouts"

grep -q 'cloudIpVerified' "$ROOT_DIR/luci/view_js/glinet_lockdown_overview.js" \
  || fail "LuCI must use verification output as a fallback for cloud IP status"

if grep -q 'glinet_cloud_ip_block' "$ROOT_DIR/luci/view_js/glinet_lockdown_overview.js"; then
  fail "cloud IP blocking must be core/default, not a LuCI selection checkbox"
fi

grep -q 'Restore Latest Backup' "$ROOT_DIR/luci/view_js/glinet_lockdown_overview.js" \
  || fail "LuCI must expose one-click latest-backup restore"

grep -q 'Enable SSH Temporarily' "$ROOT_DIR/luci/view_js/glinet_lockdown_overview.js" \
  || fail "LuCI must expose temporary SSH access"

grep -q 'WAN Exposure Scan' "$ROOT_DIR/luci/view_js/glinet_lockdown_overview.js" \
  || fail "LuCI must expose WAN exposure scans"

grep -q 'Check for Update' "$ROOT_DIR/luci/view_js/glinet_lockdown_overview.js" \
  || fail "LuCI must expose update checks"

grep -q 'Installed:' "$ROOT_DIR/luci/view_js/glinet_lockdown_overview.js" \
  || fail "LuCI must display the installed package version near update controls"

if grep -q 'glinet_update_repo' "$ROOT_DIR/luci/view_js/glinet_lockdown_overview.js"; then
  fail "LuCI update control must not expose the GitHub repository URL"
fi

if grep -q 'Check and Install Update' "$ROOT_DIR/luci/view_js/glinet_lockdown_overview.js"; then
  fail "LuCI update control must check before prompting for install"
fi

grep -q 'github-repo.default' "$ROOT_DIR/build-glinet-lockdown-ipk.sh" \
  || fail "build must support a hidden update source without exposing it in LuCI"

grep -q 'apply_fan_mode()' "$SCRIPT" \
  || fail "lockdown must support fan mode control"

grep -q 'fan_pwm_max()' "$SCRIPT" \
  || fail "fan control must detect the platform maximum PWM where available"

grep -q 'Apply Fan Mode' "$ROOT_DIR/luci/view_js/glinet_lockdown_overview.js" \
  || fail "LuCI must expose fan mode control"

grep -q 'overview_${VIEW_VERSION}' "$ROOT_DIR/build-glinet-lockdown-ipk.sh" \
  || fail "build must package LuCI view with a versioned path to avoid stale browser cache"

for acl in "$ROOT_DIR"/luci/acl.d/*.json; do
  grep -q '/etc/glinet-lockdown/core-applied' "$acl" \
    || fail "ACL must allow LuCI to read core-applied state: $acl"
  grep -q '/etc/glinet-lockdown/ssh-temp-expires' "$acl" \
    || fail "ACL must allow LuCI to read temporary SSH expiry state: $acl"
  grep -q '/etc/glinet-lockdown/fan-mode' "$acl" \
    || fail "ACL must allow LuCI to read fan mode state: $acl"
  grep -q '/etc/glinet-lockdown/fan-pwm' "$acl" \
    || fail "ACL must allow LuCI to read fan PWM state: $acl"
done

if grep -q 'dropbear password auth retained because no SSH authorized_keys file exists' "$SCRIPT"; then
  fail "password auth fallback is not allowed when SSH must be disabled by default"
fi

echo "PASS: lockdown script disables SSH by default"
