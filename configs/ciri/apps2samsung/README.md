# apps2samsung — Jellyfin client for the Samsung TV (Tizen)

**Not a compose stack.** Nothing runs here: `/data/stacks/apps2samsung/` on ciri
holds a single readme with a run-once command, and it lives under `stacks/`
only because that is where the ciri work happens. Mirrored into the repo per
the `CLAUDE.md` rule so a rebuild-from-backup doesn't lose it.

Installs the [jellyfin-tizen](https://github.com/georift/install-jellyfin-tizen)
client onto the Samsung smart TV — Samsung's store has no Jellyfin app, so it is
side-loaded over the network in developer mode.

## The command

Run on ciri (needs docker and the TV reachable on the LAN):

```bash
docker run --rm ghcr.io/georift/install-jellyfin-tizen <LAN_PREFIX>.70
```

`<LAN_PREFIX>.70` is the Samsung TV, sitting in the DHCP range
(`.31–.99`, see [network.md](../../../docs/network.md)). If the TV's lease
moves, the address in the command moves with it — check the router or Pi-hole
before re-running.

## Prerequisites

- **Developer mode on the TV**: Apps → press `12345` on the remote → toggle
  Developer mode on → enter ciri's IP as the host → restart the TV.
- The TV and ciri must be on the same LAN segment (they are — single flat /24).

## Notes

- **Re-run after a TV factory reset** or a Jellyfin major upgrade; side-loaded
  Tizen apps do not auto-update.
- Tizen side-loads carry a **certificate that expires**, so the app can stop
  launching after a few months. Re-running the installer re-signs it.
- The TV client points at Jellyfin directly. Once
  [proposal 003](../../../docs/proposals/003-reverse-proxy.md) is fully wired it
  can use `https://jellyfin.kaermorhen.fyi` instead — but see that proposal's
  note on Jellyfin's published server URI, which must be set correctly or
  clients receive an unroutable container address.
