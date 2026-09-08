#!/usr/bin/env bash
# vpn.sh — unprivileged backend for the groot.vpn Omarchy plugin.
#
#   vpn.sh status                 One-line JSON snapshot for the widget.
#   vpn.sh inbox                  JSON list of importable .conf files in the inbox.
#   vpn.sh import <basename>      Import inbox/<basename> as a NetworkManager tunnel.
#   vpn.sh import-file <path>     Copy any .conf into the inbox and import it.
#   vpn.sh pick-import            GUI file chooser (zenity), then import-file.
#   vpn.sh forget  <id>           Delete one of our tunnels (id must be omarchy-vpn-*).
#   vpn.sh connect <id>           Re-pin the endpoint and bring the tunnel up.
#   vpn.sh disconnect [<id>]      Bring one / all of our tunnels down.
#   vpn.sh refresh-ip             Refresh the cached public-IP / geo lookup.
#   vpn.sh killswitch <on|off>    Toggle the kill switch (delegates to pkexec helper).
#   vpn.sh setup                  Install system integration (delegates to pkexec).
#
# Connection management here is deliberately unprivileged: on Omarchy the polkit
# rule org.freedesktop.NetworkManager.rules already lets a local `wheel` user add
# and modify system connections without a prompt. The only privileged action is
# the kill switch, which is a separate root helper invoked through polkit.
#
# Nothing in this script interpolates untrusted data into a shell. Every external
# command is called with an explicit argv. Config values are handled as data.

set -euo pipefail
IFS=$'\n\t'
export LC_ALL=C

# ------------------------------------------------------------------ locations
PLUGIN_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
CONF_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/vpn"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-vpn"
RUN_DIR="${XDG_RUNTIME_DIR:-/tmp}/omarchy-vpn"
INBOX="$CONF_HOME/inbox"
STORE="$STATE_HOME/store"
META_DIR="$STATE_HOME/servers"
PUBIP_CACHE="$STATE_HOME/pubip.json"

HELPER=/usr/local/lib/omarchy-vpn/omarchy-vpn-helper
KS_LIVE=/run/omarchy-vpn/state
KS_FLAG=/var/lib/omarchy-vpn/killswitch.enabled

ID_PREFIX="omarchy-vpn-"
IFACE_PREFIX="ovpn-"

# widget settings arrive as env from the QML side (OMARCHY_VPN_*)
SET_IP_LOOKUP="${OMARCHY_VPN_PUBLICIPLOOKUP:-true}"
SET_IP_URL="${OMARCHY_VPN_PUBLICIPURL:-https://ipinfo.io/json}"
SET_KEEP_CONF="${OMARCHY_VPN_KEEPORIGINALCONFIGS:-true}"

umask 077
mkdir -p "$INBOX" "$STORE" "$META_DIR" "$RUN_DIR"
chmod 700 "$STATE_HOME" "$STORE" "$RUN_DIR" 2>/dev/null || true

# ------------------------------------------------------------------ helpers
die()  { printf '{"ok":false,"error":%s}\n' "$(jq -Rn --arg s "$*" '$s')"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# "Is the internet actually working right now?" — returns 0 if reachable.
# `connect` uses this to catch a tunnel that activates but silently black-holes
# every packet (a full-tunnel peer whose handshake never completes), so it can
# roll the change back instead of leaving the machine offline. Tests DNS +
# routing + TLS together (one fast request, retried by the caller).
net_probe() {
  have curl || return 0   # no curl -> can't tell; don't roll back blindly
  curl -fsS --max-time 3 --proto '=https' -o /dev/null \
       https://connectivitycheck.gstatic.com/generate_204 2>/dev/null
}

# Second opinion before a rollback: a DNS-independent path (pinned IP, still a
# valid TLS name) so a tunnel that carries traffic but broke only DNS, or one
# whose provider blocks the probe host, is not torn down by mistake.
net_probe_dns_independent() {
  have curl || return 0
  curl -fsS --max-time 4 --proto '=https' -o /dev/null \
       --resolve one.one.one.one:443:1.1.1.1 https://one.one.one.one/ 2>/dev/null
}

# Reduce a string to a safe slug: lowercase, [a-z0-9-] only, collapsed, trimmed.
slugify() {
  local s
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')
  s=$(printf '%s' "$s" | tr -s '-')
  s=${s#-}; s=${s%-}
  printf '%s' "${s:0:40}"
}

# Regional-indicator flag from a 2-letter country code (uk -> gb special case).
cc_flag() {
  local cc=${1,,} a b
  [[ $cc == uk ]] && cc=gb
  a=${cc:0:1}; b=${cc:1:1}
  if [[ $a == [a-z] && $b == [a-z] ]]; then
    printf "\\U$(printf %08x $((0x1F1E6 + $(printf '%d' "'$a") - 97)))\\U$(printf %08x $((0x1F1E6 + $(printf '%d' "'$b") - 97)))"
  else
    printf '\U0001F310'
  fi
}

# Parse a WireGuard .conf. Prints TAB-separated: privkey pubkey endpoint_host endpoint_port address_present allowed_present
# Exits non-zero (with a JSON error) if the file is not a plausible WireGuard config.
parse_conf() {
  local f=$1
  [[ -f $f && -r $f ]] || die "config not readable"
  local sz; sz=$(stat -c%s -- "$f")
  (( sz >= 1 && sz <= 65536 )) || die "config size out of range"

  awk '
    function trim(s){ sub(/^[ \t\r]+/,"",s); sub(/[ \t\r]+$/,"",s); return s }
    /^[ \t]*[#;]/ { next }
    /^[ \t]*\[/   { sect = tolower(trim($0)); next }
    /=/ {
      k = tolower(trim(substr($0, 1, index($0,"=")-1)))
      v = trim(substr($0, index($0,"=")+1))
      if (sect == "[interface]" && k == "privatekey") priv = v
      if (sect == "[interface]" && k == "address")    addr = v
      if (sect == "[peer]"      && k == "publickey")  pub  = v
      if (sect == "[peer]"      && k == "endpoint")   ep   = v
      if (sect == "[peer]"      && k == "allowedips") aip  = v
    }
    END {
      n = split(ep, p, ":")
      host = ""; port = ""
      if (n >= 2) { port = p[n]; host = ep; sub(":" port "$", "", host) }
      gsub(/[\[\]]/, "", host)
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", priv, pub, host, port, (addr!=""), (aip!="")
    }
  ' "$f"
}

# Validate parsed fields; echo "host<TAB>port" on success.
validate_fields() {
  local priv=$1 pub=$2 host=$3 port=$4 hasaddr=$5 hasaip=$6
  [[ $priv =~ ^[A-Za-z0-9+/]{42,43}=$ ]]       || die "config: bad or missing PrivateKey"
  [[ $pub  =~ ^[A-Za-z0-9+/]{42,43}=$ ]]       || die "config: bad or missing peer PublicKey"
  [[ $hasaddr == 1 ]]                          || die "config: missing Interface Address"
  [[ $hasaip  == 1 ]]                          || die "config: missing peer AllowedIPs"
  [[ $port =~ ^[0-9]{1,5}$ && $port -ge 1 && $port -le 65535 ]] || die "config: bad Endpoint port"
  [[ $host =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ \
     || $host =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ \
     || $host =~ ^[0-9a-fA-F:]+$ ]]            || die "config: bad Endpoint host"
  printf '%s\t%s' "$host" "$port"
}

# Resolve a host to a single address. Passes IPs through unchanged.
resolve_addr() {
  local host=$1
  if [[ $host =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || $host =~ ^[0-9a-fA-F:]+$ ]]; then
    printf '%s' "$host"; return 0
  fi
  getent ahosts "$host" 2>/dev/null \
    | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1; exit}
           END {}' \
    | grep . || {
        getent ahosts "$host" 2>/dev/null | awk 'NR==1{print $1}'
      }
}

nm_wg_ids() {
  nmcli -t -f NAME,TYPE connection show 2>/dev/null \
    | awk -F: -v p="$ID_PREFIX" 'index($1,p)==1 && $2=="wireguard" {print $1}'
}

# ------------------------------------------------------------------ commands
cmd_inbox() {
  local out=() f base fields hp
  shopt -s nullglob
  for f in "$INBOX"/*.conf; do
    base=$(basename -- "$f")
    if fields=$(parse_conf "$f" 2>/dev/null) \
       && hp=$(validate_fields $fields 2>/dev/null); then
      out+=("$(jq -Rn --arg b "$base" --arg h "${hp%%$'\t'*}" '{basename:$b,endpoint:$h,valid:true}')")
    else
      out+=("$(jq -Rn --arg b "$base" '{basename:$b,valid:false}')")
    fi
  done
  printf '%s\n' "${out[@]:-}" | jq -sc '.'
}

cmd_import() {
  local base=${1:-}
  [[ -n $base ]]                             || die "usage: import <basename>"
  [[ $base != */* && $base != *..* ]]        || die "invalid filename"
  [[ ${#base} -le 100 ]]                     || die "filename too long"
  [[ $base =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\.conf$ ]] \
    || die "filename must be simple: letters, digits, . _ - and end in .conf"

  local src real inbox_real
  src="$INBOX/$base"
  real=$(realpath -e -- "$src" 2>/dev/null)  || die "file not found in inbox"
  inbox_real=$(realpath -e -- "$INBOX")
  [[ $real == "$inbox_real/"* ]]             || die "file escapes the inbox"
  [[ -f $real && ! -L $src ]]                || die "inbox entry is not a regular file"

  local fields hp host port
  fields=$(parse_conf "$real")
  hp=$(validate_fields $fields)
  host=${hp%%$'\t'*}; port=${hp##*$'\t'}

  local slug id iface epip
  slug=$(slugify "${base%.conf}")
  [[ -n $slug ]]                             || die "could not derive a name from the filename"
  id="${ID_PREFIX}${slug}"

  iface="${IFACE_PREFIX}$(printf '%s' "$slug" | tr -cd 'a-z0-9' | cut -c1-9)"
  local n=2
  while ip link show "$iface" >/dev/null 2>&1 || nmcli -t -f connection.interface-name connection show "$iface" >/dev/null 2>&1; do
    iface="${IFACE_PREFIX}$(printf '%s' "$slug" | tr -cd 'a-z0-9' | cut -c1-7)$n"
    (( n++ < 20 )) || die "could not allocate an interface name"
  done

  epip=$(resolve_addr "$host")
  [[ -n $epip ]]                             || die "cannot resolve endpoint host: $host"

  # Rewrite the endpoint to a pinned IP so NetworkManager never needs DNS to
  # connect (the kill switch blocks DNS on the physical link).
  local tmp="$RUN_DIR/$iface.conf"
  ( umask 077
    awk -v ep="$epip:$port" '
      BEGIN{IGNORECASE=1}
      /^[ \t]*endpoint[ \t]*=/ { print "Endpoint = " ep; next }
      { print }
    ' "$real" > "$tmp"
  )

  if nmcli connection show "$id" >/dev/null 2>&1; then
    nmcli connection delete "$id" >/dev/null 2>&1 || true
  fi
  nmcli connection show "$iface" >/dev/null 2>&1 && nmcli connection delete "$iface" >/dev/null 2>&1 || true

  nmcli connection import type wireguard file "$tmp" >/dev/null \
    || { shred -u -- "$tmp" 2>/dev/null || rm -f -- "$tmp"; die "nmcli import failed"; }
  shred -u -- "$tmp" 2>/dev/null || rm -f -- "$tmp"

  nmcli connection modify "$iface" \
    connection.id "$id" \
    connection.autoconnect no \
    connection.zone "" \
    ipv4.never-default no \
    ipv6.method disabled \
    >/dev/null

  # `nmcli connection import` activates the tunnel before we can set
  # autoconnect=no. Put it back down — a tunnel only ever comes up through
  # `connect`, which has the connectivity fail-safe. Otherwise importing a bad
  # config would black-hole traffic with nothing to roll it back.
  nmcli connection down "$id" >/dev/null 2>&1 || true

  local cc citycode label
  cc=$(printf '%s' "$slug" | grep -oE '^[a-z]{2}' || true)
  citycode=$(printf '%s' "${slug#*-}" | tr -c 'a-z0-9' ' ' | awk '{print toupper($1)}')
  if [[ -n $cc ]]; then
    label="$(cc_flag "$cc")  ${cc^^}${citycode:+ $citycode}"
  else
    label="$(cc_flag xx)  ${slug^^}"
  fi

  jq -n --arg id "$id" --arg iface "$iface" --arg host "$host" \
        --arg port "$port" --arg label "$label" --arg cc "$cc" \
        '{id:$id,iface:$iface,endpoint_host:$host,endpoint_port:($port|tonumber),label:$label,cc:$cc,imported:(now|floor)}' \
    > "$META_DIR/$id.json"

  if [[ $SET_KEEP_CONF == true ]]; then
    install -m600 -- "$real" "$STORE/$id.conf"
  fi
  rm -f -- "$real"

  # The kill switch's endpoint allow-list is refreshed by the NetworkManager
  # dispatcher when the tunnel actually comes up, so there is no need to prompt
  # for a privileged sync here.

  jq -n --arg id "$id" --arg label "$label" '{ok:true,id:$id,label:$label}'
}

cmd_import_all() {
  shopt -s nullglob
  local f base ok=0 fail=0 errs=()
  for f in "$INBOX"/*.conf; do
    base=$(basename -- "$f")
    if out=$(cmd_import "$base" 2>&1); then
      (( ok++ ))
    else
      (( fail++ ))
      errs+=("$(jq -Rn --arg b "$base" --arg e "$out" '{basename:$b,error:$e}')")
    fi
  done
  printf '%s\n' "${errs[@]:-}" | jq -sc --argjson ok "$ok" --argjson fail "$fail" \
    '{ok:($fail==0), imported:$ok, failed:$fail, errors:map(select(.!=null))}'
}

# Copy an arbitrary .conf into the inbox under a sanitised name, then import it.
# Lets the UI accept a file from anywhere without the user hand-copying it into
# ~/.config/omarchy/vpn/inbox/ first.
cmd_import_file() {
  local src=${1:-}
  [[ -n $src ]]                         || die "usage: import-file <path>"
  [[ $src = /* ]]                       || src="$PWD/$src"
  local real; real=$(realpath -e -- "$src" 2>/dev/null) || die "file not found: $src"
  [[ -f $real && -r $real ]]            || die "not a readable file: $src"
  local sz; sz=$(stat -c%s -- "$real" 2>/dev/null || echo 0)
  (( sz >= 1 && sz <= 65536 ))          || die "not a plausible WireGuard config (size)"

  # sanity-check it parses as WireGuard before it lands in the inbox. Run the
  # check in a subshell so parse_conf/validate_fields' own die() (which prints
  # and exits) stays contained and we emit one clean error here.
  ( fields=$(parse_conf "$real" 2>/dev/null) && validate_fields $fields ) >/dev/null 2>&1 \
    || die "that file does not look like a WireGuard config"

  local base safe
  base=$(basename -- "$real"); base=${base%.[Cc][Oo][Nn][Ff]}; base=${base%.conf}
  safe=$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '-' | tr -s '-')
  safe=${safe#-}; safe=${safe#.}; safe=${safe%-}
  [[ $safe =~ ^[A-Za-z0-9] ]]           || safe="tunnel-$safe"
  safe=${safe:0:60}.conf

  install -m600 -- "$real" "$INBOX/$safe" || die "could not copy into the inbox"
  cmd_import "$safe"
}

# Pop a GUI file chooser (zenity), then import what was picked.
cmd_pick_import() {
  have zenity || die "zenity is not installed — drop .conf files into ~/.config/omarchy/vpn/inbox/ instead"
  local path
  path=$(zenity --file-selection \
           --title="Select a WireGuard .conf file" \
           --file-filter="WireGuard config | *.conf *.CONF" \
           --file-filter="All files | *" 2>/dev/null) \
    || { jq -n '{ok:true,cancelled:true}'; return 0; }
  [[ -n $path ]] || { jq -n '{ok:true,cancelled:true}'; return 0; }
  cmd_import_file "$path"
}

cmd_forget() {
  local id=${1:-}
  [[ $id =~ ^omarchy-vpn-[a-z0-9-]{1,40}$ ]] || die "invalid id"
  nmcli -t -f NAME,TYPE connection show 2>/dev/null \
    | grep -qx "$id:wireguard"                || die "not one of our tunnels"
  nmcli connection down "$id" >/dev/null 2>&1 || true
  nmcli connection delete "$id" >/dev/null    || die "delete failed"
  rm -f -- "$META_DIR/$id.json" "$STORE/$id.conf"
  jq -n '{ok:true}'
}

cmd_connect() {
  local id=${1:-}
  [[ $id =~ ^omarchy-vpn-[a-z0-9-]{1,40}$ ]] || die "invalid id"
  local meta="$META_DIR/$id.json"
  [[ -f $meta ]]                              || die "unknown tunnel"
  nmcli -t -f NAME,TYPE connection show 2>/dev/null \
    | grep -qx "$id:wireguard"                || die "tunnel missing from NetworkManager"

  # re-pin the endpoint if DNS now resolves it elsewhere
  local host port newip peers pub
  host=$(jq -r '.endpoint_host' "$meta")
  port=$(jq -r '.endpoint_port' "$meta")
  newip=$(resolve_addr "$host" || true)
  if [[ $newip =~ ^[0-9.]+$ || $newip =~ : ]]; then
    peers=$(nmcli -g wireguard.peers connection show "$id" 2>/dev/null | tr -d '\\')
    pub=${peers%% *}
    if [[ $pub =~ ^[A-Za-z0-9+/]{42,43}=$ && $peers != *"endpoint=$newip:$port"* ]]; then
      nmcli connection modify "$id" \
        wireguard.peers "$pub endpoint=$newip:$port allowed-ips=0.0.0.0/0" >/dev/null 2>&1 || true
    fi
  fi

  # Snapshot connectivity + which of our tunnels (if any) is currently up, so a
  # tunnel that activates but carries no traffic can be undone cleanly.
  local pre_ok=1 prev_active=""
  net_probe || pre_ok=0
  prev_active=$(nmcli -t -f NAME,TYPE,STATE connection show --active 2>/dev/null \
    | awk -F: -v p="$ID_PREFIX" '$2=="wireguard" && index($1,p)==1 && $3=="activated"{print $1; exit}')

  # only one of our tunnels up at a time
  local other
  for other in $(nm_wg_ids); do
    [[ $other == "$id" ]] && continue
    nmcli connection down "$other" >/dev/null 2>&1 || true
  done

  nmcli connection up "$id" >/dev/null 2>&1   || die "failed to bring up the tunnel"

  # Fail-safe: if we had internet before, make sure we still do. A full-tunnel
  # WireGuard peer that never completes a handshake installs a default route and
  # then swallows every packet (DNS included), so give it ~12s to prove itself
  # and otherwise put things back exactly as they were.
  if [[ $pre_ok == 1 ]]; then
    local ok=0 i
    for i in 1 2 3; do
      net_probe && { ok=1; break; }
      sleep 1
    done
    if [[ $ok == 0 ]] && net_probe_dns_independent; then ok=1; fi
    if [[ $ok == 0 ]]; then
      nmcli connection down "$id" >/dev/null 2>&1 || true
      if [[ -n $prev_active && $prev_active != "$id" ]]; then
        nmcli connection up "$prev_active" >/dev/null 2>&1 || true
      fi
      sleep 2   # let NetworkManager reinstate the physical default route
      die "tunnel came up but no traffic passed within ~12s — rolled back so you stay online. Check the server's keys/endpoint or provider credentials."
    fi
  fi

  ( SET_IP_LOOKUP="$SET_IP_LOOKUP" SET_IP_URL="$SET_IP_URL" "$0" refresh-ip >/dev/null 2>&1 & ) || true
  jq -n --arg id "$id" '{ok:true,id:$id}'
}

cmd_disconnect() {
  local id=${1:-}
  if [[ -n $id ]]; then
    [[ $id =~ ^omarchy-vpn-[a-z0-9-]{1,40}$ ]] || die "invalid id"
    nmcli connection down "$id" >/dev/null 2>&1 || true
  else
    local c
    for c in $(nm_wg_ids); do nmcli connection down "$c" >/dev/null 2>&1 || true; done
  fi
  ( SET_IP_LOOKUP="$SET_IP_LOOKUP" SET_IP_URL="$SET_IP_URL" "$0" refresh-ip >/dev/null 2>&1 & ) || true
  jq -n '{ok:true}'
}

cmd_refresh_ip() {
  [[ $SET_IP_LOOKUP == true ]] || { printf '{"disabled":true}\n' > "$PUBIP_CACHE"; exit 0; }
  have curl                    || exit 0
  [[ $SET_IP_URL =~ ^https:// ]] || exit 0
  local body
  body=$(curl -fsS --max-time 6 --proto '=https' --tlsv1.2 \
              -H 'Accept: application/json' -- "$SET_IP_URL" 2>/dev/null || true)
  if [[ -z $body ]] || ! jq -e . >/dev/null 2>&1 <<<"$body"; then
    jq -n '{ok:false,at:(now|floor)}' > "$PUBIP_CACHE"; exit 0
  fi
  jq '{
        ok:true, at:(now|floor),
        ip:    (.ip // .query // .address // null),
        city:  (.city // .region // null),
        country:(.country // .country_name // .countryCode // null),
        org:   (.org // .isp // .asn // .connection.org // null)
      }' <<<"$body" > "$PUBIP_CACHE"
}

cmd_killswitch() {
  local want=${1:-}
  [[ $want == on || $want == off ]] || die "usage: killswitch <on|off>"
  [[ -x $HELPER ]]                  || die "system integration not installed — run Setup first"
  have pkexec                       || die "pkexec not found (install polkit)"
  if pkexec "$HELPER" killswitch "$want" >/dev/null 2>&1; then
    jq -n --arg s "$want" '{ok:true,killswitch:$s}'
  else
    die "kill switch change was cancelled or failed"
  fi
}

cmd_setup() {
  [[ -f "$PLUGIN_DIR/install-system.sh" ]] || die "install-system.sh missing from plugin"
  have pkexec                              || die "pkexec not found (install polkit)"
  if pkexec "$PLUGIN_DIR/install-system.sh" >/dev/null 2>&1; then
    jq -n '{ok:true}'
  else
    die "setup was cancelled or failed"
  fi
}

cmd_status() {
  local integration=false ks_live=unknown ks_persisted=false
  [[ -x $HELPER ]] && integration=true
  [[ -r $KS_LIVE ]] && ks_live=$(<"$KS_LIVE")
  [[ -e $KS_FLAG ]] && ks_persisted=true

  # active connection + per-connection state
  declare -A STATE DEV
  local line name typ dev st
  while IFS=: read -r name typ dev st; do
    [[ $typ == wireguard && $name == ${ID_PREFIX}* ]] || continue
    STATE["$name"]=$st; DEV["$name"]=$dev
  done < <(nmcli -t -f NAME,TYPE,DEVICE,STATE connection show 2>/dev/null)

  local active_id=null servers=() f id meta st2 dev2 js
  shopt -s nullglob
  for f in "$META_DIR"/*.json; do
    id=$(jq -r '.id' "$f" 2>/dev/null) || continue
    [[ $id =~ ^omarchy-vpn-[a-z0-9-]+$ ]] || continue
    nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep -qx "$id:wireguard" || {
      rm -f -- "$f"; continue; }
    st2=${STATE[$id]:-}
    dev2=${DEV[$id]:-}
    local sstate=idle
    case "$st2" in
      activated)  sstate=connected; active_id=$(jq -r '.id' "$f") ;;
      activating) sstate=activating ;;
      deactivating) sstate=deactivating ;;
    esac
    js=$(jq -c --arg s "$sstate" --arg dev "$dev2" '. + {state:$s, device:$dev}' "$f")
    servers+=("$js")
  done

  local pubip='{}'
  [[ -r $PUBIP_CACHE ]] && pubip=$(cat "$PUBIP_CACHE" 2>/dev/null || echo '{}')
  jq -e . >/dev/null 2>&1 <<<"$pubip" || pubip='{}'

  local inbox_count=0
  shopt -s nullglob; local ib=("$INBOX"/*.conf); inbox_count=${#ib[@]}

  printf '%s\n' "${servers[@]:-}" | jq -sc \
    --argjson integration "$integration" \
    --arg ks_live "$ks_live" \
    --argjson ks_persisted "$ks_persisted" \
    --arg active_id "$active_id" \
    --argjson pubip "$pubip" \
    --argjson inbox_count "$inbox_count" \
    --arg iplookup "$SET_IP_LOOKUP" \
    '{
       integration: $integration,
       killswitch: $ks_live,
       killswitch_persisted: $ks_persisted,
       active_id: (if $active_id == "null" then null else $active_id end),
       servers: (map(select(. != null)) | sort_by(.label)),
       public: $pubip,
       ip_lookup: ($iplookup == "true"),
       inbox_count: $inbox_count
     }'
}

# ------------------------------------------------------------------ dispatch
case "${1:-status}" in
  status)      cmd_status ;;
  inbox)       cmd_inbox ;;
  import)      cmd_import "${2:-}" ;;
  import-all)  cmd_import_all ;;
  import-file) cmd_import_file "${2:-}" ;;
  pick-import) cmd_pick_import ;;
  forget)      cmd_forget "${2:-}" ;;
  connect)     cmd_connect "${2:-}" ;;
  disconnect)  cmd_disconnect "${2:-}" ;;
  refresh-ip)  cmd_refresh_ip ;;
  killswitch)  cmd_killswitch "${2:-}" ;;
  setup)       cmd_setup ;;
  *)           die "unknown command: ${1:-}" ;;
esac
