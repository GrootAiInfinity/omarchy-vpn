#!/usr/bin/env bash
# uninstall-system.sh — remove the groot.vpn system integration.
#
# Run as root:   pkexec ~/.config/omarchy/plugins/groot.vpn/uninstall-system.sh
#
# Removes the kill switch, the helper, the polkit action, the dispatcher hook
# and the systemd unit. It does NOT delete your NetworkManager tunnels — remove
# those with `nmcli connection delete omarchy-vpn-<name>` or the widget.

set -euo pipefail
IFS=$'\n\t'
export LC_ALL=C

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "must run as root (use pkexec or sudo)" >&2; exit 1; }

# tear the kill switch down first
systemctl disable --now omarchy-vpn-killswitch.service >/dev/null 2>&1 || true
nft list table inet omarchy_vpn >/dev/null 2>&1 && nft delete table inet omarchy_vpn || true

rm -f /usr/local/lib/omarchy-vpn/omarchy-vpn-helper
rmdir /usr/local/lib/omarchy-vpn 2>/dev/null || true
rm -f /usr/share/polkit-1/actions/com.omarchy.vpn.policy
rm -f /etc/NetworkManager/dispatcher.d/50-omarchy-vpn
rm -f /etc/systemd/system/omarchy-vpn-killswitch.service
rm -rf /var/lib/omarchy-vpn /run/omarchy-vpn

systemctl daemon-reload
systemctl try-restart NetworkManager-dispatcher.service >/dev/null 2>&1 || true

echo "omarchy-vpn: system integration removed."
echo "Your tunnels are still in NetworkManager; delete them with the widget or nmcli."
