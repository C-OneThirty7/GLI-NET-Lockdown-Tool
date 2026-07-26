#!/bin/sh
set -eu

MODE="${1:-apply}"
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
BACKUP_DIR="/root/lockdown-backup-$STAMP"
IGNORE_IPS="${IGNORE_IPS:-192.168.8.0/24}"
STATE_DIR="${STATE_DIR:-/etc/glinet-lockdown}"
BOOT_GUARD_LOG="$STATE_DIR/boot-guard.log"
BOOT_GUARD_SUMMARY="$STATE_DIR/boot-guard.summary"
OPTIONAL_BUNDLES_FILE="$STATE_DIR/optional-bundles"
CORE_APPLIED_FILE="$STATE_DIR/core-applied"
LATEST_BACKUP_FILE="$STATE_DIR/latest-backup"
DNS_ENFORCE_FILE="$STATE_DIR/dns-enforcement-enabled"
CLOUD_IP_BLOCK_FILE="$STATE_DIR/cloud-ip-block-enabled"
CLOUD_HOSTS_FILE="$STATE_DIR/cloud-hosts"
CLOUD_IPS_FILE="$STATE_DIR/cloud-ip-blocklist"
SSH_TEMP_UNTIL_FILE="$STATE_DIR/ssh-temp-until"
SSH_TEMP_EXPIRES_FILE="$STATE_DIR/ssh-temp-expires"
UPDATE_REPO_FILE="$STATE_DIR/github-repo"
FAN_MODE_FILE="$STATE_DIR/fan-mode"
FAN_PWM_FILE="$STATE_DIR/fan-pwm"
VERIFY_FAILURES=0
OPKG_UPDATED=0
OPTIONAL_BUNDLE_LIST="tailscale zerotier tor vpn-servers file-sharing upnp-mdns adguard-parental astrorelay"
STRICT_BUNDLE_LIST="tailscale zerotier tor file-sharing upnp-mdns adguard-parental astrorelay"
CLOUD_HOST_LIST="dl.gl-inet.com www.gl-inet.com link.gl-inet.com goodcloud.xyz gslb-us.goodcloud.xyz gslb-jp.goodcloud.xyz eu.goodcloud.xyz us.goodcloud.xyz jp.goodcloud.xyz glddns.com arlab1.cc"
SEEDED_CLOUD_IP_LIST="52.41.190.83 3.114.177.237"
DEFAULT_GITHUB_REPO="${DEFAULT_GITHUB_REPO:-}"

log() {
  echo "[lockdown] $*"
  logger -t glinet-lockdown "$*" 2>/dev/null || true
}

verify_check() {
  check_name="$1"
  check_cmd="$2"
  if sh -c "$check_cmd" >/dev/null 2>&1; then
    echo "[verify] PASS: $check_name"
  else
    echo "[verify] FAIL: $check_name"
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
  fi
}

have_init() {
  [ -x "/etc/init.d/$1" ]
}

svc_disable() {
  if have_init "$1"; then
    "/etc/init.d/$1" stop >/dev/null 2>&1 || true
    "/etc/init.d/$1" disable >/dev/null 2>&1 || true
    log "disabled service: $1"
  fi
}

remove_pkgs_if_installed() {
  remove_list=""

  for pkg in "$@"; do
    if opkg list-installed | grep -q "^$pkg "; then
      remove_list="$remove_list $pkg"
    fi
  done

  [ -n "$remove_list" ] || return 0

  if opkg remove $remove_list >/tmp/glinet-lockdown-remove.log 2>&1; then
    for pkg in $remove_list; do
      log "removed package: $pkg"
    done
  else
    log "normal package removal failed for bundle:$remove_list; retrying with forced dependent removal"
    if opkg remove --force-removal-of-dependent-packages $remove_list >/tmp/glinet-lockdown-remove.log 2>&1; then
      for pkg in $remove_list; do
        log "force-removed package: $pkg"
      done
    else
      log "failed to remove package bundle:$remove_list; see /tmp/glinet-lockdown-remove.log"
    fi
  fi
}

uci_delete_if_exists() {
  uci -q get "$1" >/dev/null 2>&1 && uci -q delete "$1" || true
}

restart_firewall() {
  /etc/init.d/firewall restart >/dev/null 2>&1 || service firewall restart >/dev/null 2>&1 || true
}

restart_dnsmasq() {
  /etc/init.d/dnsmasq restart >/dev/null 2>&1 || service dnsmasq restart >/dev/null 2>&1 || true
}

seed_cloud_lists() {
  mkdir -p "$STATE_DIR"

  if [ ! -s "$CLOUD_HOSTS_FILE" ]; then
    for host in $CLOUD_HOST_LIST; do
      echo "$host"
    done >"$CLOUD_HOSTS_FILE"
  fi

  if [ ! -s "$CLOUD_IPS_FILE" ]; then
    for ip in $SEEDED_CLOUD_IP_LIST; do
      echo "$ip"
    done >"$CLOUD_IPS_FILE"
  fi
}

create_backup() {
  reason="${1:-manual}"

  mkdir -p "$STATE_DIR"
  mkdir -p "$BACKUP_DIR"
  cp -a /etc/config "$BACKUP_DIR/" 2>/dev/null || true
  cp -a /etc/hosts "$BACKUP_DIR/hosts" 2>/dev/null || true
  cp -a /etc/dropbear "$BACKUP_DIR/dropbear" 2>/dev/null || true
  cp -a /etc/rc.local "$BACKUP_DIR/rc.local" 2>/dev/null || true
  cp -a /etc/crontabs "$BACKUP_DIR/crontabs" 2>/dev/null || true
  cp -a /etc/openvpn "$BACKUP_DIR/openvpn" 2>/dev/null || true
  cp -a /etc/wireguard "$BACKUP_DIR/wireguard" 2>/dev/null || true
  cp -a /etc/tailscale "$BACKUP_DIR/tailscale" 2>/dev/null || true
  cp -a /etc/zerotier-one "$BACKUP_DIR/zerotier-one" 2>/dev/null || true
  {
    echo "created=$(date)"
    echo "reason=$reason"
    echo "path=$BACKUP_DIR"
  } >"$BACKUP_DIR/manifest"
  printf '%s\n' "$BACKUP_DIR" >"$LATEST_BACKUP_FILE"
  log "backup saved to $BACKUP_DIR"
}

record_optional_bundle() {
  bundle="$1"
  mkdir -p "$STATE_DIR"
  touch "$OPTIONAL_BUNDLES_FILE"
  grep -qx "$bundle" "$OPTIONAL_BUNDLES_FILE" 2>/dev/null || echo "$bundle" >>"$OPTIONAL_BUNDLES_FILE"
}

optional_bundle_enabled() {
  bundle="$1"
  grep -qx "$bundle" "$OPTIONAL_BUNDLES_FILE" 2>/dev/null
}

clear_optional_bundle() {
  bundle="$1"
  tmp_file="/tmp/glinet-lockdown-bundles.$$"

  [ -f "$OPTIONAL_BUNDLES_FILE" ] || return 0
  grep -vx "$bundle" "$OPTIONAL_BUNDLES_FILE" >"$tmp_file" 2>/dev/null || true
  mv "$tmp_file" "$OPTIONAL_BUNDLES_FILE"
}

install_pkgs_if_available() {
  install_list=""

  if [ "$OPKG_UPDATED" -eq 0 ]; then
    opkg update >/tmp/glinet-lockdown-opkg-update.log 2>&1 || log "opkg update failed; install may use cached package lists"
    OPKG_UPDATED=1
  fi

  for pkg in "$@"; do
    if opkg list-installed | grep -q "^$pkg "; then
      log "package already installed: $pkg"
    elif opkg list "$pkg" 2>/dev/null | grep -q "^$pkg "; then
      install_list="$install_list $pkg"
    else
      log "package not found in feeds: $pkg"
    fi
  done

  [ -n "$install_list" ] || return 0

  if opkg install $install_list >/tmp/glinet-lockdown-install.log 2>&1; then
    for pkg in $install_list; do
      log "installed package: $pkg"
    done
  else
    log "failed to install package bundle:$install_list; see /tmp/glinet-lockdown-install.log"
    return 1
  fi
}

svc_enable() {
  if have_init "$1"; then
    "/etc/init.d/$1" enable >/dev/null 2>&1 || true
    "/etc/init.d/$1" start >/dev/null 2>&1 || true
    log "enabled service: $1"
  fi
}

apply_optional_bundle() {
  bundle="$1"

  case "$bundle" in
    tailscale)
      svc_disable tailscale
      remove_pkgs_if_installed tailscale gl-sdk4-tailscale gl-sdk4-ui-tailscaleview
      ;;
    zerotier)
      svc_disable zerotier
      remove_pkgs_if_installed zerotier gl-sdk4-zerotier gl-sdk4-ui-zerotierview
      ;;
    tor)
      svc_disable tor
      remove_pkgs_if_installed tor tor-geoip gl-sdk4-tor gl-sdk4-ui-torview
      ;;
    vpn-servers)
      svc_disable openvpn
      svc_disable openvpn_init_tap_s2s
      svc_disable gl_s2s
      remove_pkgs_if_installed gl-sdk4-ovpn-server gl-sdk4-wg-server gl-sdk4-ui-ovpnserver gl-sdk4-ui-wgserver gl-sdk4-s2s
      ;;
    file-sharing)
      for service_name in minidlna rpcbind nfsd samba4 vsftpd webdav_ser \
        gl_nas_diskmanager gl_nas_sys gl_nas_sys_dl gl_nas_sys_up
      do
        svc_disable "$service_name"
      done
      remove_pkgs_if_installed minidlna samba4-server samba4-utils vsftpd-tls gl-sdk4-webdav gl-sdk4-nas-web gl-sdk4-nas-utils gl-sdk4-nas-exfat
      ;;
    upnp-mdns)
      svc_disable miniupnpd
      svc_disable avahi-daemon
      remove_pkgs_if_installed miniupnpd-nftables luci-app-upnp avahi-dbus-daemon
      ;;
    adguard-parental)
      svc_disable adguardhome
      svc_disable adguard-home
      svc_disable parental_control
      remove_pkgs_if_installed gl-sdk4-adguardhome adguardhome-conntrack kmod-gl-sdk4-parental-control gl-sdk4-ui-parentalcontrol
      ;;
    astrorelay)
      svc_disable astrowarp
      svc_disable gl-astrowarp
      svc_disable astrorelay
      svc_disable gl-astrorelay
      remove_pkgs_if_installed gl-sdk4-ui-astrowarp
      ;;
    all)
      for optional_bundle in tailscale zerotier tor vpn-servers file-sharing upnp-mdns adguard-parental astrorelay
      do
        apply_optional_bundle "$optional_bundle"
        record_optional_bundle "$optional_bundle"
      done
      record_optional_bundle full
      echo "[optional] FULL OPTIONAL LOCKDOWN APPLIED"
      ;;
    *)
      echo "unsupported optional bundle: $bundle" >&2
      return 1
      ;;
  esac

  [ "$bundle" = "all" ] || record_optional_bundle "$bundle"
  log "applied optional bundle: $bundle"
}

install_optional_bundle() {
  bundle="$1"

  case "$bundle" in
    tailscale)
      install_pkgs_if_available tailscale gl-sdk4-tailscale gl-sdk4-ui-tailscaleview
      svc_enable tailscale
      ;;
    zerotier)
      install_pkgs_if_available zerotier gl-sdk4-zerotier gl-sdk4-ui-zerotierview
      svc_enable zerotier
      ;;
    tor)
      install_pkgs_if_available tor tor-geoip gl-sdk4-tor gl-sdk4-ui-torview
      svc_enable tor
      ;;
    vpn-servers)
      install_pkgs_if_available gl-sdk4-ovpn-server gl-sdk4-wg-server gl-sdk4-ui-ovpnserver gl-sdk4-ui-wgserver gl-sdk4-s2s
      svc_enable openvpn
      svc_enable gl_s2s
      ;;
    file-sharing)
      install_pkgs_if_available minidlna samba4-server samba4-utils vsftpd-tls gl-sdk4-webdav gl-sdk4-nas-web gl-sdk4-nas-utils gl-sdk4-nas-exfat
      for service_name in minidlna samba4 vsftpd webdav_ser gl_nas_diskmanager gl_nas_sys gl_nas_sys_dl gl_nas_sys_up
      do
        svc_enable "$service_name"
      done
      ;;
    upnp-mdns)
      install_pkgs_if_available miniupnpd-nftables luci-app-upnp avahi-dbus-daemon
      svc_enable miniupnpd
      svc_enable avahi-daemon
      ;;
    adguard-parental)
      install_pkgs_if_available gl-sdk4-adguardhome adguardhome-conntrack kmod-gl-sdk4-parental-control gl-sdk4-ui-parentalcontrol
      svc_enable adguardhome
      svc_enable adguard-home
      svc_enable parental_control
      ;;
    astrorelay)
      install_pkgs_if_available gl-sdk4-ui-astrowarp
      svc_enable astrowarp
      svc_enable gl-astrowarp
      svc_enable astrorelay
      svc_enable gl-astrorelay
      ;;
    all)
      for optional_bundle in tailscale zerotier tor vpn-servers file-sharing upnp-mdns adguard-parental astrorelay
      do
        install_optional_bundle "$optional_bundle"
      done
      clear_optional_bundle full
      echo "[optional] FULL OPTIONAL LOCKDOWN RESTORE REQUESTED"
      ;;
    *)
      echo "unsupported optional install bundle: $bundle" >&2
      return 1
      ;;
  esac

  if [ "$bundle" != "all" ]; then
    clear_optional_bundle "$bundle"
    clear_optional_bundle full
  fi

  log "install/restore requested for optional bundle: $bundle"
}

apply_recorded_optional_bundles() {
  [ -f "$OPTIONAL_BUNDLES_FILE" ] || return 0

  while IFS= read -r bundle; do
    [ -n "$bundle" ] || continue
    [ "$bundle" = "full" ] && continue
    apply_optional_bundle "$bundle"
  done <"$OPTIONAL_BUNDLES_FILE"
}

optional_selection_contains() {
  bundle="$1"
  selection_csv="$2"

  case ",$selection_csv," in
    *",$bundle,"*) return 0 ;;
    *) return 1 ;;
  esac
}

apply_optional_selection() {
  selection_csv="${1:-}"
  selected_count=0
  total_count=0

  mkdir -p "$STATE_DIR"
  touch "$OPTIONAL_BUNDLES_FILE"
  create_backup "optional-selection"

  for optional_bundle in $OPTIONAL_BUNDLE_LIST; do
    total_count=$((total_count + 1))
    if optional_selection_contains "$optional_bundle" "$selection_csv"; then
      apply_optional_bundle "$optional_bundle"
      selected_count=$((selected_count + 1))
    else
      install_optional_bundle "$optional_bundle" || true
    fi
  done

  clear_optional_bundle full
  if [ "$selected_count" -eq "$total_count" ]; then
    record_optional_bundle full
    echo "[optional] FULL OPTIONAL LOCKDOWN APPLIED"
  else
    echo "[optional] OPTIONAL SELECTIONS APPLIED: $selected_count of $total_count removal bundles selected"
  fi
}

set_optional_selection_state() {
  selection_csv="${1:-}"
  selected_count=0
  total_count=0

  mkdir -p "$STATE_DIR"
  : >"$OPTIONAL_BUNDLES_FILE"

  for optional_bundle in $OPTIONAL_BUNDLE_LIST; do
    total_count=$((total_count + 1))
    if optional_selection_contains "$optional_bundle" "$selection_csv"; then
      record_optional_bundle "$optional_bundle"
      selected_count=$((selected_count + 1))
    fi
  done

  if [ "$selected_count" -eq "$total_count" ]; then
    record_optional_bundle full
  fi

  echo "[optional] OPTIONAL SELECTION STATE SAVED: $selected_count of $total_count removal bundles selected"
}

apply_dns_enforcement() {
  mkdir -p "$STATE_DIR"
  touch "$DNS_ENFORCE_FILE"

  uci_delete_if_exists firewall.glinet_lockdown_dns_lan
  uci set firewall.glinet_lockdown_dns_lan='redirect'
  uci set firewall.glinet_lockdown_dns_lan.name='glinet_lockdown_dns_lan'
  uci set firewall.glinet_lockdown_dns_lan.src='lan'
  uci set firewall.glinet_lockdown_dns_lan.src_dport='53'
  uci set firewall.glinet_lockdown_dns_lan.dest_port='53'
  uci set firewall.glinet_lockdown_dns_lan.proto='tcp udp'
  uci set firewall.glinet_lockdown_dns_lan.target='DNAT'

  uci_delete_if_exists firewall.glinet_lockdown_dot_lan
  uci set firewall.glinet_lockdown_dot_lan='rule'
  uci set firewall.glinet_lockdown_dot_lan.name='glinet_lockdown_dot_lan'
  uci set firewall.glinet_lockdown_dot_lan.src='lan'
  uci set firewall.glinet_lockdown_dot_lan.dest='wan'
  uci set firewall.glinet_lockdown_dot_lan.dest_port='853'
  uci set firewall.glinet_lockdown_dot_lan.proto='tcp udp'
  uci set firewall.glinet_lockdown_dot_lan.target='REJECT'
  uci set firewall.glinet_lockdown_dot_lan.family='any'

  uci commit firewall
  restart_firewall
  restart_dnsmasq
  log "enabled LAN DNS enforcement and blocked outbound DNS-over-TLS/QUIC port 853"
}

clear_dns_enforcement() {
  uci_delete_if_exists firewall.glinet_lockdown_dns_lan
  uci_delete_if_exists firewall.glinet_lockdown_dot_lan
  uci commit firewall
  rm -f "$DNS_ENFORCE_FILE"
  restart_firewall
  log "disabled LAN DNS enforcement"
}

refresh_cloud_ips() {
  seed_cloud_lists
  tmp_file="/tmp/glinet-lockdown-cloud-ips.$$"

  cp "$CLOUD_IPS_FILE" "$tmp_file" 2>/dev/null || true
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    nslookup "$host" 2>/dev/null | awk '
      /^Address[[:space:]]*[0-9]*:/ { print $NF }
      /^Address:[[:space:]]*/ { print $2 }
    ' | grep -E '^[0-9]+(\.[0-9]+){3}$' >>"$tmp_file" 2>/dev/null || true
  done <"$CLOUD_HOSTS_FILE"

  sort -u "$tmp_file" | awk '$0 != "0.0.0.0" { print }' >"$CLOUD_IPS_FILE"
  rm -f "$tmp_file"
  log "refreshed cloud IP blocklist from configured cloud hostnames"
}

apply_cloud_ip_block() {
  mkdir -p "$STATE_DIR"
  touch "$CLOUD_IP_BLOCK_FILE"
  seed_cloud_lists

  if ! command -v nft >/dev/null 2>&1; then
    log "nft not found; cloud IP runtime blocklist cannot be applied on this firmware"
    return 0
  fi

  nft delete table inet glinet_lockdown >/dev/null 2>&1 || true
  nft add table inet glinet_lockdown >/dev/null 2>&1 || true
  nft add set inet glinet_lockdown cloud4 '{ type ipv4_addr; flags interval; }' >/dev/null 2>&1 || true
  nft add chain inet glinet_lockdown output '{ type filter hook output priority -1; policy accept; }' >/dev/null 2>&1 || true
  nft add chain inet glinet_lockdown forward '{ type filter hook forward priority -1; policy accept; }' >/dev/null 2>&1 || true

  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    case "$ip" in
      \#*|0.0.0.0) continue ;;
    esac
    nft add element inet glinet_lockdown cloud4 "{ $ip }" >/dev/null 2>&1 || true
  done <"$CLOUD_IPS_FILE"

  nft add rule inet glinet_lockdown output ip daddr @cloud4 counter drop >/dev/null 2>&1 || true
  nft add rule inet glinet_lockdown forward ip daddr @cloud4 counter drop >/dev/null 2>&1 || true
  log "enabled runtime cloud IP blocklist"
}

clear_cloud_ip_block() {
  rm -f "$CLOUD_IP_BLOCK_FILE"
  if command -v nft >/dev/null 2>&1; then
    nft delete table inet glinet_lockdown >/dev/null 2>&1 || true
  fi
  log "disabled runtime cloud IP blocklist"
}

remove_temp_ssh_cron() {
  [ -f /etc/crontabs/root ] || return 0
  sed -i '/# BEGIN glinet-lockdown-temp-ssh/,/# END glinet-lockdown-temp-ssh/d' /etc/crontabs/root 2>/dev/null || true
  /etc/init.d/cron restart >/dev/null 2>&1 || true
}

install_temp_ssh_cron() {
  mkdir -p /etc/crontabs
  touch /etc/crontabs/root
  sed -i '/# BEGIN glinet-lockdown-temp-ssh/,/# END glinet-lockdown-temp-ssh/d' /etc/crontabs/root 2>/dev/null || true
  cat >>/etc/crontabs/root <<'EOF'
# BEGIN glinet-lockdown-temp-ssh
* * * * * /usr/sbin/glinet-lockdown.sh ssh-expire >/dev/null 2>&1
# END glinet-lockdown-temp-ssh
EOF
  /etc/init.d/cron enable >/dev/null 2>&1 || true
  /etc/init.d/cron restart >/dev/null 2>&1 || true
}

temp_ssh_active() {
  now_epoch="$(date +%s 2>/dev/null || echo 0)"
  expires_epoch="$(cat "$SSH_TEMP_EXPIRES_FILE" 2>/dev/null || echo 0)"

  case "$now_epoch:$expires_epoch" in
    *[!0-9:]*|0:*) return 1 ;;
  esac

  [ "$now_epoch" -lt "$expires_epoch" ]
}

disable_temp_ssh() {
  if uci -q get dropbear.@dropbear[0] >/dev/null 2>&1; then
    uci set dropbear.@dropbear[0].IdleTimeout='300'
    uci set dropbear.@dropbear[0].MaxAuthTries='3'
    uci set dropbear.@dropbear[0].PasswordAuth='off'
    uci set dropbear.@dropbear[0].RootPasswordAuth='off'
    uci commit dropbear
  fi
  svc_disable "dropbear"
  rm -f "$SSH_TEMP_UNTIL_FILE" "$SSH_TEMP_EXPIRES_FILE"
  remove_temp_ssh_cron
  log "temporary SSH disabled"
}

expire_temp_ssh_if_needed() {
  [ -s "$SSH_TEMP_EXPIRES_FILE" ] || return 0
  if temp_ssh_active; then
    return 0
  fi
  disable_temp_ssh
}

enable_temp_ssh() {
  minutes="${1:-15}"
  now_epoch="$(date +%s 2>/dev/null || echo 0)"

  case "$minutes" in
    ''|*[!0-9]*) minutes=15 ;;
  esac
  [ "$minutes" -lt 1 ] && minutes=1
  [ "$minutes" -gt 240 ] && minutes=240

  if uci -q get dropbear.@dropbear[0] >/dev/null 2>&1; then
    uci set dropbear.@dropbear[0].IdleTimeout='300'
    uci set dropbear.@dropbear[0].MaxAuthTries='3'
    uci set dropbear.@dropbear[0].PasswordAuth='on'
    uci set dropbear.@dropbear[0].RootPasswordAuth='on'
    uci commit dropbear
  fi
  if have_init dropbear; then
    /etc/init.d/dropbear enable >/dev/null 2>&1 || true
    /etc/init.d/dropbear start >/dev/null 2>&1 || true
  fi

  expires_epoch=$((now_epoch + (minutes * 60)))
  until_text="$(date -d "@$expires_epoch" 2>/dev/null || date -r "$expires_epoch" 2>/dev/null || echo "epoch:$expires_epoch")"
  printf '%s\n' "$until_text" >"$SSH_TEMP_UNTIL_FILE"
  printf '%s\n' "$expires_epoch" >"$SSH_TEMP_EXPIRES_FILE"
  install_temp_ssh_cron
  nohup sh -c "sleep $((minutes * 60)); /usr/sbin/glinet-lockdown.sh ssh-expire >/tmp/glinet-lockdown-ssh-disable.log 2>&1" >/dev/null 2>&1 &
  echo "[ssh] TEMP_SSH_ACTIVE_UNTIL: $until_text"
  echo "[ssh] TEMP_SSH_EXPIRES_EPOCH: $expires_epoch"
  log "temporary SSH enabled for $minutes minutes"
}

wan_exposure_scan() {
  echo "[scan] --- WAN exposure scan ---"
  echo "[scan] WAN interface status:"
  ubus call network.interface.wan status 2>/dev/null || echo "[scan] WAN status unavailable"
  echo "[scan] Listening TCP/UDP sockets:"
  netstat -lntup 2>/dev/null || ss -lntup 2>/dev/null || echo "[scan] socket listing unavailable"
  echo "[scan] Lockdown WAN firewall rules:"
  uci show firewall 2>/dev/null | grep 'glinet_lockdown' || echo "[scan] no lockdown firewall rules found"
  echo "[scan] Summary:"
  if uci show firewall 2>/dev/null | grep -q 'glinet_lockdown_admin_wan'; then
    echo "[scan] PASS: WAN admin drop rule is configured"
  else
    echo "[scan] WARN: WAN admin drop rule is missing"
  fi
  if [ -f "$DNS_ENFORCE_FILE" ]; then
    echo "[scan] PASS: DNS enforcement is enabled"
  else
    echo "[scan] INFO: DNS enforcement is not enabled"
  fi
  if [ -f "$CLOUD_IP_BLOCK_FILE" ]; then
    echo "[scan] PASS: cloud IP blocklist is enabled"
  else
    echo "[scan] INFO: cloud IP blocklist is not enabled"
  fi
}

restore_latest_backup() {
  [ -s "$LATEST_BACKUP_FILE" ] || {
    echo "[restore] no latest backup recorded" >&2
    return 1
  }
  restore_dir="$(cat "$LATEST_BACKUP_FILE")"
  [ -d "$restore_dir" ] || {
    echo "[restore] latest backup directory is missing: $restore_dir" >&2
    return 1
  }

  create_backup "pre-restore"
  cp -a "$restore_dir/config/." /etc/config/ 2>/dev/null || true
  cp -a "$restore_dir/hosts" /etc/hosts 2>/dev/null || true
  cp -a "$restore_dir/dropbear/." /etc/dropbear/ 2>/dev/null || true
  cp -a "$restore_dir/rc.local" /etc/rc.local 2>/dev/null || true
  cp -a "$restore_dir/crontabs/." /etc/crontabs/ 2>/dev/null || true
  cp -a "$restore_dir/openvpn/." /etc/openvpn/ 2>/dev/null || true
  cp -a "$restore_dir/wireguard/." /etc/wireguard/ 2>/dev/null || true
  cp -a "$restore_dir/tailscale/." /etc/tailscale/ 2>/dev/null || true
  cp -a "$restore_dir/zerotier-one/." /etc/zerotier-one/ 2>/dev/null || true
  restart_firewall
  restart_dnsmasq
  /etc/init.d/network reload >/dev/null 2>&1 || true
  /etc/init.d/rpcd restart >/dev/null 2>&1 || true
  /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
  log "restored settings from $restore_dir"
}

current_lockdown_pkg() {
  opkg list-installed 2>/dev/null | awk '/^glinet-lockdown-/ { print $1; exit }'
}

current_lockdown_version() {
  pkg_name="$1"
  opkg list-installed 2>/dev/null | awk -v pkg="$pkg_name" '$1 == pkg { print $3; exit }'
}

update_repo() {
  repo="${1:-}"
  [ -n "$repo" ] || repo="$(cat "$UPDATE_REPO_FILE" 2>/dev/null || true)"
  [ -n "$repo" ] || repo="$DEFAULT_GITHUB_REPO"
  [ -n "$repo" ] || {
    echo "[update] update source is not configured" >&2
    return 1
  }
  printf '%s\n' "$repo" >"$UPDATE_REPO_FILE"
  printf '%s\n' "$repo"
}

fetch_latest_release_metadata() {
  repo="$(update_repo "${1:-}")" || return 1
  metadata="$2"
  api_url="https://api.github.com/repos/$repo/releases/latest"

  wget -qO "$metadata" "$api_url"
}

latest_asset_url() {
  metadata="$1"
  pkg_name="$2"

  grep 'browser_download_url' "$metadata" | grep "$pkg_name" | grep '_all.ipk' | head -n 1 | sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"//; s/".*//'
}

asset_version_from_url() {
  pkg_name="$1"
  download_url="$2"

  basename="${download_url##*/}"
  printf '%s\n' "$basename" | sed "s/^${pkg_name}_//; s/_all\\.ipk.*//"
}

update_is_newer() {
  current_version="$1"
  latest_version="$2"

  if command -v opkg >/dev/null 2>&1 && opkg compare-versions "$latest_version" '>' "$current_version" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

check_update_from_github() {
  repo_arg="${1:-}"
  metadata="/tmp/glinet-lockdown-release.json"

  pkg_name="$(current_lockdown_pkg)"
  [ -n "$pkg_name" ] || {
    echo "[update] current glinet-lockdown package name not found" >&2
    return 1
  }
  current_version="$(current_lockdown_version "$pkg_name")"
  [ -n "$current_version" ] || current_version="unknown"

  echo "[update] Current package: $pkg_name"
  echo "[update] Current version: $current_version"
  fetch_latest_release_metadata "$repo_arg" "$metadata" || {
    echo "[update] failed to fetch GitHub release metadata" >&2
    return 1
  }

  download_url="$(latest_asset_url "$metadata" "$pkg_name")"
  [ -n "$download_url" ] || {
    echo "[update] no matching IPK asset found for $pkg_name" >&2
    return 1
  }
  latest_version="$(asset_version_from_url "$pkg_name" "$download_url")"
  echo "[update] Latest version: $latest_version"

  if update_is_newer "$current_version" "$latest_version"; then
    echo "[update] UPDATE_AVAILABLE"
  else
    echo "[update] NO_UPDATE"
  fi
}

self_update_from_github() {
  repo_arg="${1:-}"
  metadata="/tmp/glinet-lockdown-release.json"

  pkg_name="$(current_lockdown_pkg)"
  [ -n "$pkg_name" ] || {
    echo "[update] current glinet-lockdown package name not found" >&2
    return 1
  }
  current_version="$(current_lockdown_version "$pkg_name")"
  [ -n "$current_version" ] || current_version="unknown"

  echo "[update] Current package: $pkg_name"
  echo "[update] Current version: $current_version"
  fetch_latest_release_metadata "$repo_arg" "$metadata" || {
    echo "[update] failed to fetch GitHub release metadata" >&2
    return 1
  }

  download_url="$(latest_asset_url "$metadata" "$pkg_name")"
  [ -n "$download_url" ] || {
    echo "[update] no matching IPK asset found for $pkg_name" >&2
    return 1
  }
  latest_version="$(asset_version_from_url "$pkg_name" "$download_url")"
  echo "[update] Latest version: $latest_version"

  if ! update_is_newer "$current_version" "$latest_version"; then
    echo "[update] NO_UPDATE"
    return 0
  fi

  ipk_file="/tmp/${pkg_name}-update.ipk"
  echo "[update] downloading matching update package"
  wget -qO "$ipk_file" "$download_url" || {
    echo "[update] failed to download IPK" >&2
    return 1
  }
  create_backup "pre-update"
  opkg install "$ipk_file"
}

apply_profile() {
  profile="${1:-custom}"
  selection_csv="${2:-}"
  dns_choice="${3:-0}"

  case "$profile" in
    balanced)
      selection_csv=""
      dns_choice=0
      ;;
    strict)
      selection_csv="$(echo "$STRICT_BUNDLE_LIST" | tr ' ' ',')"
      dns_choice=1
      ;;
    custom)
      ;;
    *)
      echo "unsupported profile: $profile" >&2
      return 1
      ;;
  esac

  create_backup "profile-$profile"
  set_optional_selection_state "$selection_csv"
  sh "$0" apply

  if [ "$dns_choice" = "1" ]; then
    apply_dns_enforcement
  else
    clear_dns_enforcement
  fi

  run_verification || true
}

apply_network_selection() {
  dns_choice="${1:-0}"

  create_backup "network-selection"

  if [ "$dns_choice" = "1" ]; then
    apply_dns_enforcement
  else
    clear_dns_enforcement
  fi

  refresh_cloud_ips
  apply_cloud_ip_block

  run_verification || true
}

fan_pwm_path() {
  for path in \
    /sys/devices/platform/soc/soc:pwm-fan/hwmon/hwmon0/pwm1 \
    /sys/class/hwmon/hwmon0/pwm1
  do
    [ -w "$path" ] && {
      printf '%s\n' "$path"
      return 0
    }
  done

  return 1
}

fan_cooling_path() {
  [ -w /sys/class/thermal/cooling_device0/cur_state ] && printf '%s\n' /sys/class/thermal/cooling_device0/cur_state
}

fan_pwm_max() {
  max="$(cat /proc/gl-hw-info/fan_pwm_max 2>/dev/null | tr -cd '0-9' || true)"
  [ -n "$max" ] || max="$(tr -cd '0-9' </sys/firmware/devicetree/base/gl-hw/fan_pwm_max 2>/dev/null || true)"
  [ -n "$max" ] || max=255
  printf '%s\n' "$max"
}

apply_fan_mode() {
  mode="${1:-auto}"
  mkdir -p "$STATE_DIR"

  case "$mode" in
    auto|off)
      printf '%s\n' "$mode" >"$FAN_MODE_FILE"
      rm -f "$FAN_PWM_FILE"
      if [ "$mode" = "auto" ]; then
        /etc/init.d/gl_fan enable >/dev/null 2>&1 || true
        /etc/init.d/gl_fan restart >/dev/null 2>&1 || true
        echo "[fan] auto mode enabled"
      else
        /etc/init.d/gl_fan stop >/dev/null 2>&1 || true
        pwm_path="$(fan_pwm_path 2>/dev/null || true)"
        cooling_path="$(fan_cooling_path 2>/dev/null || true)"
        [ -n "$pwm_path" ] && echo 0 >"$pwm_path" 2>/dev/null || true
        [ -n "$cooling_path" ] && echo 0 >"$cooling_path" 2>/dev/null || true
        echo "[fan] fan turned off"
      fi
      ;;
    low|medium|high)
      max="$(fan_pwm_max)"
      case "$mode" in
        low) pwm=$((max * 35 / 100)) ;;
        medium) pwm=$((max * 70 / 100)) ;;
        high) pwm="$max" ;;
      esac
      [ "$pwm" -lt 1 ] && pwm=1
      /etc/init.d/gl_fan stop >/dev/null 2>&1 || true
      pwm_path="$(fan_pwm_path 2>/dev/null || true)"
      cooling_path="$(fan_cooling_path 2>/dev/null || true)"
      [ -n "$pwm_path" ] || {
        echo "[fan] no writable PWM fan control found" >&2
        return 1
      }
      echo "$pwm" >"$pwm_path"
      [ -n "$cooling_path" ] && echo "$pwm" >"$cooling_path" 2>/dev/null || true
      printf '%s\n' "$mode" >"$FAN_MODE_FILE"
      printf '%s\n' "$pwm" >"$FAN_PWM_FILE"
      echo "[fan] constant $mode mode enabled at PWM $pwm/$max"
      ;;
    *)
      echo "[fan] unsupported fan mode: $mode" >&2
      return 1
      ;;
  esac
}

replace_rc_local() {
  if [ -f /etc/rc.local ] && [ ! -f "$STATE_DIR/rc.local.pre-lockdown" ]; then
    cp /etc/rc.local "$STATE_DIR/rc.local.pre-lockdown" 2>/dev/null || true
  fi

  cat >/etc/rc.local <<'EOF'
#!/bin/sh

exit 0
EOF
  chmod 0755 /etc/rc.local
  log "replaced /etc/rc.local with minimal no-op startup script"
}

run_verification() {
  VERIFY_FAILURES=0
  expire_temp_ssh_if_needed
  echo "[verify] --- lockdown verification ---"
  verify_check "cloud blocklist present" "grep -q '^0.0.0.0 goodcloud.xyz$' /etc/hosts"
  verify_check "ddns blocklist present" "grep -q '^0.0.0.0 glddns.com$' /etc/hosts"
  verify_check "update blocklist present" "grep -q '^0.0.0.0 dl.gl-inet.com$' /etc/hosts"
  verify_check "WAN admin firewall rule exists" "uci show firewall | grep -q \"glinet_lockdown_admin_wan\""
  verify_check "WAN ping firewall rule exists" "uci show firewall | grep -q \"glinet_lockdown_ping_wan\""
  verify_check "local logging enabled" "uci get system.@system[0].log_file | grep -q '^/var/log/messages$'"
  verify_check "dropbear idle timeout hardened" "uci get dropbear.@dropbear[0].IdleTimeout | grep -q '^300$'"
  verify_check "dropbear max auth tries hardened" "uci get dropbear.@dropbear[0].MaxAuthTries | grep -q '^3$'"
  if temp_ssh_active; then
    echo "[verify] INFO: temporary SSH active until $(cat "$SSH_TEMP_UNTIL_FILE" 2>/dev/null || echo unknown)"
  else
    verify_check "dropbear password auth disabled" "uci get dropbear.@dropbear[0].PasswordAuth | grep -q '^off$' && uci get dropbear.@dropbear[0].RootPasswordAuth | grep -q '^off$'"
    verify_check "dropbear service disabled" "[ ! -x /etc/init.d/dropbear ] || ! /etc/init.d/dropbear enabled"
  fi
  verify_check "rc.local minimized" "grep -q '^exit 0$' /etc/rc.local && ! grep -q 'gl_util\\|remount_ubifs\\|drop_caches' /etc/rc.local"
  verify_check "gl-sdk4-ddns package removed" "! opkg list-installed | grep -q '^gl-sdk4-ddns '"
  verify_check "gl-sdk4-mqtt package removed" "! opkg list-installed | grep -q '^gl-sdk4-mqtt '"
  verify_check "gl-sdk4-cloud package removed" "! opkg list-installed | grep -q '^gl-sdk4-cloud '"
  verify_check "gl-mqtt package removed" "! opkg list-installed | grep -q '^gl-mqtt '"
  verify_check "gl-ddns package removed" "! opkg list-installed | grep -q '^gl-ddns '"
  verify_check "gl-cloud-gui package removed" "! opkg list-installed | grep -q '^gl-cloud-gui '"
  verify_check "gl-autopkg package removed" "! opkg list-installed | grep -q '^gl-autopkg '"
  verify_check "lua-eco-mqtt package removed" "! opkg list-installed | grep -q '^lua-eco-mqtt '"
  verify_check "rtty package removed" "! opkg list-installed | grep -q '^rtty '"
  verify_check "rtty-openssl package removed" "! opkg list-installed | grep -q '^rtty-openssl '"
  verify_check "gl-sdk4-rtty package removed" "! opkg list-installed | grep -q '^gl-sdk4-rtty '"
  verify_check "gl-tertf service disabled" "[ ! -x /etc/init.d/gl-tertf ] || ! /etc/init.d/gl-tertf enabled"
  verify_check "gl_clients service disabled" "[ ! -x /etc/init.d/gl_clients ] || ! /etc/init.d/gl_clients enabled"

  if optional_bundle_enabled upnp-mdns; then
    verify_check "optional UPnP service disabled" "[ ! -x /etc/init.d/miniupnpd ] || ! /etc/init.d/miniupnpd enabled"
    verify_check "optional mDNS/Avahi service disabled" "[ ! -x /etc/init.d/avahi-daemon ] || ! /etc/init.d/avahi-daemon enabled"
  fi
  if optional_bundle_enabled tailscale; then
    verify_check "optional Tailscale removed" "! opkg list-installed | grep -q '^tailscale ' && ! opkg list-installed | grep -q '^gl-sdk4-tailscale '"
  fi
  if optional_bundle_enabled zerotier; then
    verify_check "optional ZeroTier removed" "! opkg list-installed | grep -q '^zerotier ' && ! opkg list-installed | grep -q '^gl-sdk4-zerotier '"
  fi
  if optional_bundle_enabled tor; then
    verify_check "optional Tor removed" "! opkg list-installed | grep -q '^tor ' && ! opkg list-installed | grep -q '^gl-sdk4-tor '"
  fi
  if [ -f "$DNS_ENFORCE_FILE" ]; then
    verify_check "DNS redirect rule exists" "uci show firewall | grep -q \"glinet_lockdown_dns_lan\""
    verify_check "DNS-over-TLS block rule exists" "uci show firewall | grep -q \"glinet_lockdown_dot_lan\""
  fi
  if [ -f "$CLOUD_IP_BLOCK_FILE" ]; then
    verify_check "cloud IP blocklist file exists" "[ -s '$CLOUD_IPS_FILE' ]"
    verify_check "cloud IP nft table exists" "command -v nft >/dev/null 2>&1 && nft list table inet glinet_lockdown >/dev/null 2>&1"
  fi

  if [ "$VERIFY_FAILURES" -eq 0 ]; then
    echo "[verify] SUMMARY: PASS"
    return 0
  fi

  echo "[verify] SUMMARY: FAIL ($VERIFY_FAILURES checks failed)"
  return 1
}

if [ "$MODE" = "--verify" ] || [ "$MODE" = "verify" ]; then
  run_verification
  exit $?
fi

case "$MODE" in
  backup)
    create_backup "manual"
    echo "[backup] saved to $BACKUP_DIR"
    exit 0
    ;;
  restore-latest-backup)
    restore_latest_backup
    exit $?
    ;;
  dns-enable)
    create_backup "dns-enable"
    apply_dns_enforcement
    run_verification || true
    exit 0
    ;;
  dns-disable)
    create_backup "dns-disable"
    clear_dns_enforcement
    run_verification || true
    exit 0
    ;;
  cloud-ip-enable)
    create_backup "cloud-ip-enable"
    refresh_cloud_ips
    apply_cloud_ip_block
    run_verification || true
    exit 0
    ;;
  cloud-ip-disable)
    create_backup "cloud-ip-disable"
    echo "[cloud-ip] GL.iNet cloud IP blocking is a core lockdown control and cannot be disabled from this tool"
    refresh_cloud_ips
    apply_cloud_ip_block
    run_verification || true
    exit 0
    ;;
  refresh-cloud-ips)
    refresh_cloud_ips
    [ -f "$CLOUD_IP_BLOCK_FILE" ] && apply_cloud_ip_block
    cat "$CLOUD_IPS_FILE"
    exit 0
    ;;
  network-set)
    apply_network_selection "${2:-0}"
    exit 0
    ;;
  ssh-temp)
    enable_temp_ssh "${2:-15}"
    exit 0
    ;;
  ssh-disable)
    disable_temp_ssh
    exit 0
    ;;
  ssh-expire)
    expire_temp_ssh_if_needed
    exit 0
    ;;
  wan-scan)
    wan_exposure_scan
    exit 0
    ;;
  fan)
    apply_fan_mode "${2:-auto}"
    exit $?
    ;;
  update-check)
    check_update_from_github
    exit $?
    ;;
  self-update)
    self_update_from_github
    exit $?
    ;;
  profile)
    apply_profile "${2:-custom}" "${3:-}" "${4:-0}"
    exit 0
    ;;
  optional-set)
    apply_optional_selection "${2:-}"
    if [ -f "$CORE_APPLIED_FILE" ]; then
      run_verification || true
    else
      echo "[optional] core lockdown has not been run yet; selections were applied where possible and saved for later enforcement"
    fi
    exit 0
    ;;
  optional-*|full)
    mkdir -p "$STATE_DIR"
    case "$MODE" in
      optional-tailscale) apply_optional_bundle tailscale ;;
      optional-zerotier) apply_optional_bundle zerotier ;;
      optional-tor) apply_optional_bundle tor ;;
      optional-vpn-servers) apply_optional_bundle vpn-servers ;;
      optional-file-sharing) apply_optional_bundle file-sharing ;;
      optional-upnp-mdns) apply_optional_bundle upnp-mdns ;;
      optional-adguard-parental) apply_optional_bundle adguard-parental ;;
      optional-astrorelay) apply_optional_bundle astrorelay ;;
      full) apply_optional_bundle all ;;
    esac
    run_verification || true
    exit 0
    ;;
  install-*|restore-full)
    mkdir -p "$STATE_DIR"
    case "$MODE" in
      install-tailscale) install_optional_bundle tailscale ;;
      install-zerotier) install_optional_bundle zerotier ;;
      install-tor) install_optional_bundle tor ;;
      install-vpn-servers) install_optional_bundle vpn-servers ;;
      install-file-sharing) install_optional_bundle file-sharing ;;
      install-upnp-mdns) install_optional_bundle upnp-mdns ;;
      install-adguard-parental) install_optional_bundle adguard-parental ;;
      install-astrorelay) install_optional_bundle astrorelay ;;
      restore-full) install_optional_bundle all ;;
    esac
    run_verification || true
    exit 0
    ;;
esac

if [ "$MODE" = "--guard" ] || [ "$MODE" = "guard" ]; then
  mkdir -p "$STATE_DIR"

  {
    echo "[guard] started $(date)"
    if [ ! -f "$CORE_APPLIED_FILE" ]; then
      echo "[guard] core lockdown has not been run yet; guard is armed but not enforcing"
      summary="[guard] SUMMARY: PENDING"
    elif sh "$0" --verify; then
      summary="[guard] SUMMARY: PASS"
    else
      echo "[guard] verification failed; reapplying lockdown"
      sh "$0" apply
      if sh "$0" --verify; then
        summary="[guard] SUMMARY: PASS (remediated)"
      else
        summary="[guard] SUMMARY: FAIL"
      fi
    fi
    echo "$summary"
  } >"$BOOT_GUARD_LOG" 2>&1

  printf '%s\n' "$summary" >"$BOOT_GUARD_SUMMARY"
  cat "$BOOT_GUARD_LOG"

  case "$summary" in
    *"FAIL"*) exit 1 ;;
  esac

  exit 0
fi

mkdir -p "$STATE_DIR"
create_backup "core-lockdown"

# Disable GL.iNet cloud helpers and optional extras that are not needed for a
# local-only router with VPN client capability. User-selectable optional
# services are handled by explicit LuCI buttons and persisted bundle state.
for service_name in \
  gl-cloud ddns \
  gl-tertf gl-update-logo gl_clients rtty
do
  svc_disable "$service_name"
done

# Remove packages that are not needed for a local-only router profile.
remove_pkgs_if_installed \
  gl-sdk4-mqtt \
  gl-sdk4-ddns \
  gl-sdk4-cloud \
  gl-mqtt \
  gl-ddns \
  gl-cloud-gui \
  gl-autopkg \
  lua-eco-mqtt \
  rtty \
  rtty-openssl \
  gl-sdk4-rtty

apply_recorded_optional_bundles

replace_rc_local

# Keep a local hostname blocklist for known GL.iNet cloud and update domains.
MARK_BEGIN="# BEGIN glinet-lockdown"
MARK_END="# END glinet-lockdown"
TMP_HOSTS="/tmp/hosts.lockdown.$$"

awk -v begin="$MARK_BEGIN" -v end="$MARK_END" '
  $0 == begin { skip = 1; next }
  $0 == end { skip = 0; next }
  !skip { print }
' /etc/hosts >"$TMP_HOSTS"

cat >>"$TMP_HOSTS" <<EOF
$MARK_BEGIN
0.0.0.0 dl.gl-inet.com
0.0.0.0 www.gl-inet.com
0.0.0.0 link.gl-inet.com
0.0.0.0 goodcloud.xyz
0.0.0.0 gslb-us.goodcloud.xyz
0.0.0.0 gslb-jp.goodcloud.xyz
0.0.0.0 eu.goodcloud.xyz
0.0.0.0 us.goodcloud.xyz
0.0.0.0 jp.goodcloud.xyz
0.0.0.0 glddns.com
0.0.0.0 arlab1.cc
$MARK_END
EOF

mv "$TMP_HOSTS" /etc/hosts
log "updated /etc/hosts blocklist"

# Drop WAN access to common admin and VPN-server ports. This does not affect
# outbound VPN client connections to a remote server.
uci_delete_if_exists firewall.glinet_lockdown_admin_wan
uci set firewall.glinet_lockdown_admin_wan='rule'
uci set firewall.glinet_lockdown_admin_wan.name='glinet_lockdown_admin_wan'
uci set firewall.glinet_lockdown_admin_wan.src='wan'
uci set firewall.glinet_lockdown_admin_wan.proto='tcp udp'
uci set firewall.glinet_lockdown_admin_wan.dest_port='22 80 443 8080 8443 1194 51820'
uci set firewall.glinet_lockdown_admin_wan.target='DROP'
uci set firewall.glinet_lockdown_admin_wan.family='any'

uci_delete_if_exists firewall.glinet_lockdown_ping_wan
uci set firewall.glinet_lockdown_ping_wan='rule'
uci set firewall.glinet_lockdown_ping_wan.name='glinet_lockdown_ping_wan'
uci set firewall.glinet_lockdown_ping_wan.src='wan'
uci set firewall.glinet_lockdown_ping_wan.proto='icmp'
uci set firewall.glinet_lockdown_ping_wan.icmp_type='echo-request'
uci set firewall.glinet_lockdown_ping_wan.family='ipv4'
uci set firewall.glinet_lockdown_ping_wan.target='DROP'

uci commit firewall
restart_firewall
log "applied firewall WAN drop rules"

[ -f "$DNS_ENFORCE_FILE" ] && apply_dns_enforcement
refresh_cloud_ips
apply_cloud_ip_block

# Persist local logs so login failures and drift events can be audited.
uci set system.@system[0].log_file='/var/log/messages'
uci set system.@system[0].log_remote='0'
uci commit system
/etc/init.d/log restart >/dev/null 2>&1 || service log restart >/dev/null 2>&1 || true
sleep 1
log "enabled local syslog file: /var/log/messages"

# Disable SSH by default while hardening Dropbear settings in case it is
# manually re-enabled later.
if uci -q get dropbear.@dropbear[0] >/dev/null 2>&1; then
  uci set dropbear.@dropbear[0].IdleTimeout='300'
  uci set dropbear.@dropbear[0].MaxAuthTries='3'
  uci set dropbear.@dropbear[0].PasswordAuth='off'
  uci set dropbear.@dropbear[0].RootPasswordAuth='off'
  uci commit dropbear
  log "tightened dropbear auth settings"
fi
svc_disable "dropbear"
log "disabled SSH service: dropbear"

date >"$CORE_APPLIED_FILE" 2>/dev/null || true
log "done"
log "WAN admin is blocked; local and VPN admin remain available"
run_verification || true
