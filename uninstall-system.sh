#!/usr/bin/env bash
# uninstall-system.sh — remove the io.github.grootaiinfinity.vpn system integration.
#
# Run as root:   pkexec /usr/local/lib/omarchy-vpn/uninstall-system.sh
#
# Prefer that root-owned copy, which install-system.sh puts there: it is the one
# that still exists after `omarchy plugin remove`, and unlike the copy in the
# plugin folder it is not writable by the user, so root is not executing a file
# an unprivileged process could have rewritten. The copy in the plugin folder
# does the same job if the integration was never installed.
#
# Removes the kill switch, the helper, the polkit action, the dispatcher hook,
# the systemd unit and this script's own installed copy. It does NOT delete your
# NetworkManager tunnels — remove those with
# `nmcli connection delete omarchy-vpn-<name>` or the widget.

set -euo pipefail
IFS=$'\n\t'
export LC_ALL=C

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

# tear the kill switch down first
systemctl disable --now omarchy-vpn-killswitch.service >/dev/null 2>&1 || true
nft list table inet omarchy_vpn >/dev/null 2>&1 && nft delete table inet omarchy_vpn || true

rm -f /usr/local/lib/omarchy-vpn/omarchy-vpn-helper
rm -f /usr/local/lib/omarchy-vpn/uninstall-system.sh
rmdir /usr/local/lib/omarchy-vpn 2>/dev/null || true
rm -f /usr/share/polkit-1/actions/com.omarchy.vpn.policy
rm -f /etc/NetworkManager/dispatcher.d/50-omarchy-vpn
rm -f /etc/systemd/system/omarchy-vpn-killswitch.service
rm -rf /var/lib/omarchy-vpn /run/omarchy-vpn

systemctl daemon-reload
systemctl try-restart NetworkManager-dispatcher.service >/dev/null 2>&1 || true

echo "omarchy-vpn: system integration removed."
echo "Your tunnels are still in NetworkManager; delete them with the widget or nmcli."
