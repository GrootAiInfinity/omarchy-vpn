# omarchy-vpn

A WireGuard VPN widget for the [Omarchy](https://omarchy.org/) status bar
(Quickshell). Import a `.conf`, connect from a menu in the bar, and optionally
arm a fail-closed nftables kill switch.

Works with any WireGuard provider (Surfshark, Mullvad, ProtonVPN, self-hosted).

## Features

- **Compact bar readout:** country code + colour for the active tunnel, `KS`
  when the kill switch is armed, `off` otherwise. A pulsing icon warns when the
  kill switch is on but no tunnel is carrying traffic.
- **Left-click** opens the panel: kill-switch toggle, tunnel list, inbox.
- **Right-click** connects / disconnects the last-used tunnel.
- **Import:** click **Import from file…** in the panel for a file chooser, or
  drop WireGuard `.conf` files into `~/.config/omarchy/vpn/inbox/` and import
  them from the panel. Each becomes a NetworkManager tunnel; the endpoint is
  pinned to a resolved IP so the tunnel never needs DNS to connect.
- **Connect with a safety net:** bringing a tunnel up runs a connectivity probe
  first, then re-checks after activation. A full-tunnel peer that activates but
  silently black-holes traffic (dead endpoint, bad key, expired credentials) is
  **rolled back automatically** — the previous tunnel or the physical link is
  restored and an error is shown, instead of leaving the machine offline.
- **Kill switch (optional):** a fail-closed `inet omarchy_vpn` nftables table
  with `policy drop` on output — only the tunnels, the encrypted WireGuard
  handshake, loopback, IPv6 ND, LAN/CGNAT/link-local ranges and DHCP are
  allowed. All plaintext egress (including DNS) on the physical link is dropped
  whenever no tunnel carries it. Survives reboots via a systemd unit; a
  NetworkManager dispatcher hook re-syncs it on link flaps.
- **Public-IP check:** after connecting, optionally queries an external service
  to show your apparent exit IP and city. Off = no third-party request.
- Only one of the plugin's tunnels is up at a time.

## Requirements

- Omarchy shell (Quickshell-based bar)
- `NetworkManager`, `jq`, `curl`, coreutils
- `zenity` for the **Import from file…** chooser (the inbox-folder route works
  without it)
- Kill switch only: `nftables`, `polkit` (`pkexec`)

Connecting to a VPN works without the kill switch and without any system
integration — on Omarchy the NetworkManager polkit rule already lets a local
`wheel` user add and modify system connections without a prompt.

## Install

```sh
omarchy plugin add https://github.com/GrootAiInfinity/omarchy-vpn.git --enable
```

Adds the widget to the right side of the bar. Remove it with
`omarchy plugin remove groot.vpn`, update with `omarchy plugin update groot.vpn`.

### Add a server

```sh
mkdir -p ~/.config/omarchy/vpn/inbox
cp ~/Downloads/nz-akl.prod.conf ~/.config/omarchy/vpn/inbox/
```

Open the panel and click **Import**. The tunnel name is derived from the
filename (`nz-akl.prod.conf` → `NZ AKL`).

### Enable the kill switch

Click **Set up kill switch** in the panel (one polkit prompt — runs
`install-system.sh`, which only copies the four files in `system/` into place).
Then toggle it on. Nothing is armed until you turn it on.

Remove the system integration with:

```sh
pkexec ~/.config/omarchy/plugins/groot.vpn/uninstall-system.sh
```

## Security model

- The unprivileged backend (`vpn.sh`) never interpolates untrusted data into a
  shell; every external command is called with an explicit argv, and config
  values are handled as data. Config files are size- and format-checked before
  import; imported filenames must be simple (`[A-Za-z0-9._-]`, ending `.conf`)
  and cannot escape the inbox.
- The only privileged component is `omarchy-vpn-helper`
  (`/usr/local/lib/omarchy-vpn/`, root:root 0755). It accepts exactly one
  invocation — `killswitch {on|off|sync|status}` — takes no caller-supplied
  paths, names or addresses, and discovers the tunnel endpoints itself by
  querying NetworkManager as root. The generated ruleset is `nft -c`
  syntax-checked before it is applied, atomically, in its own table; `off`
  removes only that table and never touches other firewall rules.

## Notes

- Nothing machine-specific is hard-coded — tunnels, endpoints and the kill
  switch's allow-list are all discovered at runtime.
- `vpn.qml` finds `vpn.sh` via `Qt.resolvedUrl(".")`.
- `omarchy update` / `omarchy refresh shell` rewrites `shell.json` and drops the
  plugin's layout entry (the widget files survive). Re-run
  `omarchy plugin enable groot.vpn` and `omarchy restart shell`.
- The kill switch persists across reboots once armed. Turn it off from the panel
  (or `pkexec omarchy-vpn-helper killswitch off`) before removing the plugin.

## License

MIT
