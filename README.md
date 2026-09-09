# omarchy-vpn

A WireGuard VPN widget for the [Omarchy](https://omarchy.org/) status bar
(Quickshell). Import a `.conf`, connect from a menu in the bar, and optionally
arm a fail-closed nftables kill switch.

Works with any WireGuard provider (Surfshark, Mullvad, ProtonVPN, self-hosted).

## Features

- **Compact bar readout:** country code + colour for the active tunnel, `KS`
  when the kill switch is armed, `off` otherwise. A pulsing icon warns when the
  kill switch is on but no tunnel is carrying traffic.
- **Left-click** opens the panel: kill-switch toggle, the after-a-reboot
  option, tunnel list, inbox.
- **Right-click** connects / disconnects the last-used tunnel.
- **Import, one file or fifty:** click **Import .conf files…** in the panel and
  select as many `.conf` files as you like (ctrl/shift-click, or Ctrl+A) — or
  drop them into `~/.config/omarchy/vpn/inbox/` and import the lot from the
  panel. Each becomes a NetworkManager tunnel; the endpoint is pinned to a
  resolved IP so the tunnel never needs DNS to connect. The panel reports what
  landed and gives a reason for every file it rejected, so one bad config never
  sinks the batch. Two different configs that would take the same name (two
  providers both shipping `wg0.conf`) get separate tunnels; re-importing the
  same peer updates the tunnel in place instead of duplicating it.
- **Pick a tunnel, drop a tunnel:** click any tunnel in the panel to connect it
  (clicking the connected one disconnects), and the trash icon on its row to
  delete it — once to arm, again within three seconds to confirm. The list gains
  a search box past six tunnels, matching name, endpoint host or id.
- **Connect with a safety net:** bringing a tunnel up runs a connectivity probe
  first, then re-checks after activation. A full-tunnel peer that activates but
  silently black-holes traffic (dead endpoint, bad key, expired credentials) is
  **rolled back automatically** — the previous tunnel or the physical link is
  restored and an error is shown, instead of leaving the machine offline.
- **Kill switch (optional):** a fail-closed `inet omarchy_vpn` nftables table
  with `policy drop` on output — only the tunnels, the encrypted WireGuard
  handshake, loopback, IPv6 ND, LAN/CGNAT/link-local ranges and DHCP are
  allowed. All plaintext egress (including DNS) on the physical link is dropped
  whenever no tunnel carries it. Whether the armed state survives a reboot is
  the **Restore the last session after a reboot** option below: with it on a
  systemd unit re-loads the rules before the network comes up; with it off the
  switch is armed for this session only. Either way a NetworkManager dispatcher
  hook re-syncs the rules on link flaps. The endpoint allow-list is cached
  so the boot-time load — which runs before NetworkManager exists — still opens
  the handshake ports for tunnels on non-standard ports.
- **Restore the last session after a reboot (optional):** one switch, in the
  panel's **After a reboot** section and in the widget's settings, that owns
  everything outliving a reboot.
  - **On** — the tunnel you were connected to comes back by itself *and* the
    kill switch stays armed across reboots. The armed tunnel is marked `AUTO`
    in the panel.
  - **Off** (default) — every boot starts clean: no tunnel is connected and the
    kill switch is off, whatever was running when you shut down. Arming the kill
    switch loads the rules for this session only.

  Disconnecting a tunnel by hand clears it as the one to restore, so an explicit
  disconnect is never undone at the next login or reboot. Switching a tunnel
  does not (the tunnel that is taken down to make room keeps auto-start armed).

  `How the tunnel is restored` picks the mechanism, and only matters while the
  option is on. *At boot* (default) — NetworkManager brings the tunnel up before
  anyone logs in and re-establishes it whenever it drops; the only option that
  covers the gap between power-on and login, at the cost of connecting without
  the roll-back safety net (the widget still checks once, at session start, and
  backs the tunnel out if it came up carrying no traffic). *On login* — the
  widget re-connects it when the shell starts, with the same connectivity check
  and roll-back a manual connect gets.

  Changing the option reconciles both halves immediately. The
  NetworkManager side is free; the kill switch's boot flag is root-owned, so it
  costs one polkit prompt — and only when the switch is actually on and its
  retention has to change.
- **Public-IP check:** after connecting, optionally queries an external service
  to show your apparent exit IP and city. Off = no third-party request.
- Only one of the plugin's tunnels is up at a time.

## Requirements

- Omarchy shell (Quickshell-based bar)
- `NetworkManager`, `jq`, `curl`, coreutils
- `zenity` for the **Import .conf files…** chooser (the inbox-folder route works
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

`omarchy plugin update` refreshes the plugin folder but cannot touch the root
helper under `/usr/local/lib` — that needs a polkit prompt. When the two differ
the panel says so and offers **Update system integration**; click it after any
update that changed the kill switch helper.

### Add servers

Open the panel and click **Import .conf files…** — multi-select is on, so a
provider's whole server pack can go in at once. Or stage them by hand:

```sh
mkdir -p ~/.config/omarchy/vpn/inbox
cp ~/Downloads/*.conf ~/.config/omarchy/vpn/inbox/
```

and click **Import N files from inbox**. The tunnel name is derived from the
filename (`se-sto.prod.conf` → 🇸🇪 `SE STO`); a leading two-letter segment is
read as a country code, anything else gets a globe.

### Remove a server

Click the trash icon on the tunnel's row (once to arm, again to confirm). It is
brought down, deleted from NetworkManager, and its stored copy of the config and
its private key are removed. From the CLI:

```sh
~/.config/omarchy/plugins/groot.vpn/vpn.sh forget omarchy-vpn-se-sto
```

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
  invocation — `killswitch {on|on-once|off|persist|unpersist|sync|status}` —
  takes no caller-supplied paths, names or addresses, and discovers the tunnel endpoints itself by
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
- The kill switch persists across reboots only while **Restore the last session
  after a reboot** is on. Turn it off from the panel (or
  `pkexec omarchy-vpn-helper killswitch off`) before removing the plugin.
- **Upgrading to 1.2.0:** the old `Reconnect the last-used tunnel` enum is
  replaced by the `Restore the last session after a reboot` switch plus a
  `How the tunnel is restored` enum. An existing *On login* / *At boot* setting
  is read as the seed for the new one, so nothing changes under you; *Off* maps
  to the new switch being off. The root helper gained the verbs that make the
  kill switch's boot behaviour follow the option, so re-run **Update system
  integration** once — until you do, arming the kill switch still persists it
  across reboots and the panel says so.
- **Upgrading from 1.0.x:** the systemd unit shipped before 1.1.0 hooked itself
  onto `network-pre.target` alone. That target is passive — nothing on an Omarchy
  box pulls it in — so the unit was reported `enabled` yet never ran at boot, and
  an armed kill switch came back **disarmed** after every reboot. 1.1.0 installs
  the unit the way `nftables.service` does. `omarchy plugin update` cannot
  replace root-owned files, so the panel flags the mismatch and you must re-run
  **Update system integration** once (one polkit prompt) for the fix to land.

## License

MIT
