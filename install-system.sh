#!/usr/bin/env bash
# install-system.sh — one-time system integration for the io.github.grootaiinfinity.vpn plugin.
#
# Run as root, once:   pkexec ~/.config/omarchy/plugins/io.github.grootaiinfinity.vpn/install-system.sh
# (the widget's "Set up" button does exactly this).
#
# It only copies the four files in ./system/ to fixed system locations and
# reloads the relevant daemons. No network access, no downloads, no eval.
# Read it before you run it; re-running it is safe (idempotent).

set -euo pipefail
IFS=$'\n\t'
umask 022
export LC_ALL=C

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SRC="$SELF_DIR/system"

LIBDIR=/usr/local/lib/omarchy-vpn
POLKIT_ACTION=/usr/share/polkit-1/actions/com.omarchy.vpn.policy
DISPATCHER=/etc/NetworkManager/dispatcher.d/50-omarchy-vpn
UNIT=/etc/systemd/system/omarchy-vpn-killswitch.service

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "must run as root (use pkexec or sudo)" >&2; exit 1; }

for f in omarchy-vpn-helper com.omarchy.vpn.policy 50-omarchy-vpn omarchy-vpn-killswitch.service; do
  [[ -f "$SRC/$f" ]] || { echo "missing source file: system/$f" >&2; exit 1; }
done

# refuse to install a tampered helper (very small sanity check, not a signature)
head -n1 "$SRC/omarchy-vpn-helper" | grep -q '^#!/usr/bin/env bash' \
  || { echo "system/omarchy-vpn-helper does not look like the shipped script" >&2; exit 1; }

command -v nft   >/dev/null || { echo "nftables is required (pacman -S nftables)" >&2; exit 1; }
command -v nmcli >/dev/null || { echo "NetworkManager is required" >&2; exit 1; }

install -d -m 0755 -o root -g root "$LIBDIR" /var/lib/omarchy-vpn
install -m 0755 -o root -g root "$SRC/omarchy-vpn-helper"             "$LIBDIR/omarchy-vpn-helper"
install -m 0644 -o root -g root "$SRC/com.omarchy.vpn.policy"         "$POLKIT_ACTION"
install -D -m 0755 -o root -g root "$SRC/50-omarchy-vpn"              "$DISPATCHER"
install -m 0644 -o root -g root "$SRC/omarchy-vpn-killswitch.service" "$UNIT"

systemctl daemon-reload
# dispatcher needs the service running to be useful; NM picks the script up live
systemctl try-restart NetworkManager-dispatcher.service >/dev/null 2>&1 || true

# Repair the enablement of an existing install. Versions up to 1.0.0 shipped a
# unit that hooked itself onto network-pre.target, a passive target nothing on
# an Omarchy box ever pulls in — so the unit was "enabled" and yet never ran at
# boot, and the kill switch came back disarmed after every reboot. `reenable`
# rewrites the symlinks from the [Install] section of the unit we just wrote.
UNIT_NAME=omarchy-vpn-killswitch.service
if [[ -e /var/lib/omarchy-vpn/killswitch.enabled ]] \
   || systemctl is-enabled --quiet "$UNIT_NAME" 2>/dev/null; then
  systemctl reenable "$UNIT_NAME" >/dev/null 2>&1 || true
fi

# If the user had the kill switch on, put the rules back now rather than making
# them toggle it off and on again to recover from the boot that missed them.
if [[ -e /var/lib/omarchy-vpn/killswitch.enabled ]]; then
  systemctl start "$UNIT_NAME" >/dev/null 2>&1 \
    || "$LIBDIR/omarchy-vpn-helper" killswitch sync || true
fi

echo "omarchy-vpn: system integration installed."
echo "  helper      $LIBDIR/omarchy-vpn-helper"
echo "  polkit      $POLKIT_ACTION"
echo "  dispatcher  $DISPATCHER"
echo "  unit        $UNIT"
if [[ -e /var/lib/omarchy-vpn/killswitch.enabled ]]; then
  echo "Kill switch is enabled and will be re-armed on every boot."
else
  echo "Nothing is enabled yet — turn the kill switch on from the VPN widget."
fi
