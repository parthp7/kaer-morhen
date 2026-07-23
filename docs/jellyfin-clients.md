# Jellyfin Client Compatibility — Household Devices

Client-side research for the upcoming Jellyfin stack on ciri (server side:
NVENC via the GTX 1060 passthrough, see [gpu-passthrough.md](gpu-passthrough.md)).
Covers the four device types that will consume it: iPhone, MacBook, Windows PC,
and the living-room Samsung TV (primary client, evaluated in depth).

Researched 2026-07-17; TV app store checked on-device 2026-07-18; Tizen client
sideloaded onto the TV 2026-07-20.

Addresses are written as `<LAN_PREFIX>.NN` per `CLAUDE.md` — resolved in the
git-ignored `secrets.local.yaml`, see [network.md](network.md).

## Summary

| Device | Client | Status |
|---|---|---|
| iPhone | **Swiftfin** (official, App Store) | Excellent — actively developed, 4K HEVC/HDR10/DV Direct Play |
| MacBook | Web UI, or Jellyfin Media Player | Good — browser is sufficient for a laptop screen |
| Windows PC | **Jellyfin Media Player** (official) | Good — install the app over the browser for HEVC/HDR Direct Play |
| Samsung TV | **Jellyfin for Tizen** (official) | Sideloaded 2026-07-20; playback verified 2026-07-22 (Direct Play + NVENC transcode) — **connect by IP, not hostname** ([why](#known-tizen-client-rough-edges)) |

## Samsung TV (primary client)

- **Model**: Samsung UA55AUE70AKLXL — AU7000 series, 55" Crystal UHD, 2021,
  India variant
- **Firmware**: `T-KSU2EUABC-2301.1,BT-S` — `KSU2E` = KantSU2e platform =
  **Tizen 6.0** (2021 line)
- **Panel/HDR**: 4K 60 Hz edge-lit, HDR10 / HDR10+ / HLG. No Dolby Vision
  (no Samsung TV has it)

### Official app availability

Jellyfin's Tizen client launched in the Samsung app store **2026-02** for
Tizen 6.0+ (≈2021 models and newer) — this TV is squarely in the supported
window. However the rollout is staged by model/region, and **as of 2026-07-18
the app does not appear in this TV's app store (India)**.

**Resolved 2026-07-20 by sideloading** — see the runbook below. The store
rollout is still worth re-checking periodically ([State of the Fin
2026-05-24](https://jellyfin.org/posts/state-of-the-fin-2026-05-24/)): a store
install would supersede the sideload and bring auto-updates with it.

## Runbook — sideloading jellyfin-tizen (done 2026-07-20)

Installed with [`georift/install-jellyfin-tizen`](https://github.com/georift/install-jellyfin-tizen),
a Docker one-liner that wraps the Tizen SDK — it downloads a
[jellyfin-tizen](https://github.com/jellyfin/jellyfin-tizen) build, packages,
signs, and deploys it over the network. No Tizen Studio install needed.

### 1. TV: developer mode + fixed address

- Enable developer mode: **Apps → app settings → press `1 2 3 4 5` in order**.
  **The AU7000 remote has no number pad** — pair a USB/Bluetooth keyboard to
  the TV and type the digits there. This is the one genuinely fiddly step.
- In the developer-mode dialog, set **Host IP = ciri** (`<LAN_PREFIX>.150`) —
  this is the machine that will *run the installer*, not the Jellyfin server
  address. The TV only accepts pushes from this host.
- Give the TV a stable address: `<LAN_PREFIX>.70` (router-side DHCP
  reservation — `.70` sits in the `.31–.99` pool per
  [network.md](network.md)), DNS pointed at Pi-hole #1 (`<LAN_PREFIX>.101`).
- Reboot the TV so developer mode takes effect.

### 2. Verify the TV is listening

The Tizen debug port is `26101`. From ciri:

```bash
nc -vz <LAN_PREFIX>.70 26101
```

Must succeed before the installer will work — a refused connection means
developer mode is off, the reboot was skipped, or the Host IP doesn't match
the machine you're running from.

### 3. Install

```bash
docker run --rm ghcr.io/georift/install-jellyfin-tizen <LAN_PREFIX>.70
```

The image takes up to three more optional args (build variant e.g.
`Jellyfin-TrueHD`, a release-tag URL to pin a version, and a custom
certificate password); the bare form installs the current default build.

### 4. Verify

- App appears in the TV's Apps row.
- **Survives a cold restart** — verified by unplugging at the wall, not just a
  menu reboot. Sideloaded apps can vanish on a full power cycle if developer
  mode was misconfigured, so this is the check that matters.
- Launching it shows the "Add Server" prompt. **Add the server by IP
  (`http://<LAN_PREFIX>.150:8096`), not the `jellyfin.kaermorhen.internal`
  hostname** — see the DNS gotcha under rough edges below.

### Maintenance caveats

- **No auto-updates** — re-run the same `docker run` to pull a newer client.
- **Signing certificate expires**, after which the app stops launching and
  must be re-installed. Same command; keep developer mode enabled on the TV.
- Re-installing requires ciri to still be the TV's registered Host IP.

### Direct Play matrix (AU7000, per Samsung 2021 media specs)

| Media | TV support | Jellyfin behavior |
|---|---|---|
| H.264 up to 4K (L5.1) | yes | Direct Play |
| HEVC up to 4K (L5.1) | yes | Direct Play — covers most 4K rips |
| AV1 up to 4K60 | yes | Direct Play (note: the 1060 has no AV1 *encode*, so never transcode *to* AV1) |
| HDR10 / HDR10+ / HLG | yes | Direct Play |
| Dolby Vision | no | Plays HDR10 base layer; DV profile 5 files transcode/tone-map (NVENC + CUDA tone mapping) |
| AAC / AC3 / DD+ audio | yes | Direct Play |
| DTS / TrueHD / FLAC audio | **no** (Samsung dropped DTS in 2018+) | Audio-only transcode to DD+/AAC — cheap, video untouched |
| SRT subtitles | yes | Direct Play |
| ASS/SSA subtitles | partial | Burn-in transcode is the reliable path |

Expected transcode triggers in practice: DTS/TrueHD audio tracks (common in
remuxes) and styled subtitles — both cheap with NVENC, so no buffering risk.

### Known Tizen client rough edges

- **Add the server by IP, not the internal DNS hostname** (hit 2026-07-22).
  With the server added as `jellyfin.kaermorhen.internal`, the app *browsed*
  fine but every playback failed — spinner, then "media not supported by this
  client" — on a file that Direct Plays on every other client. Cause: the Tizen
  app browses through its Chromium **web-view** (which resolves Pi-hole DNS) but
  plays through Samsung's native **AVPlay** player, which uses a separate
  network stack that does *not* resolve the internal name. The server logs the
  giveaway: PlaybackInfo negotiated, but **no `/Videos/.../stream` request ever
  arrives** — the TV can't reach the stream URL. Fix: set the app's server entry
  to `http://<LAN_PREFIX>.150:8096`. The IP is reachable remotely too (the
  Tailscale subnet router advertises the whole LAN), so IP is the universal
  choice. Root cause was `JELLYFIN_PublishedServerUrl` (a hostname): fine for
  web/Swiftfin, a trap for native-player clients. It was removed from the server
  compose 2026-07-22, so connecting by IP is now the complete fix.
- UI (embedded web client) is sluggish on the AU7000's budget SoC —
  navigation only, playback is fine.
- Mid-playback audio/subtitle track switching is flaky
  ([jellyfin-web#6608](https://github.com/jellyfin/jellyfin-web/issues/6608)) —
  pick tracks before pressing play.
- Occasional in-spec HEVC files error out
  ([jellyfin-tizen#286](https://github.com/jellyfin/jellyfin-tizen/issues/286));
  fix is a one-off forced transcode.

## Other clients

- **iPhone — [Swiftfin](https://apps.apple.com/us/app/swiftfin/id1604098728)**:
  the official iOS client (the older "Jellyfin Mobile" app is legacy).
  v1.4.x as of early 2026, active development. Direct-plays 4K HEVC with
  HDR10/Dolby Vision on supported iPhones. Third-party Infuse exists but
  isn't needed.
- **MacBook**: web UI in any browser is full-featured and enough for a
  laptop. Jellyfin Media Player (official desktop app, mpv-based) available
  if codec issues ever show up. The desktop app is mid-rewrite
  ("Jellyfin Desktop" v3, Qt → CEF) — current stable works fine.
- **Windows PC**: same two options; prefer Jellyfin Media Player since
  browser HEVC support outside Edge forces transcodes the app avoids.

## Sources

- [Jellyfin official clients](https://jellyfin.org/downloads/clients/)
- [State of the Fin 2026-05-24](https://jellyfin.org/posts/state-of-the-fin-2026-05-24/) — Tizen store release (Tizen 6+), client roadmaps
- [XDA: Jellyfin launches on Samsung TVs](https://www.xda-developers.com/jellyfin-finally-launches-on-samsung-tizen-tvs/) (2026-02-03)
- [Samsung 2021 TV video specifications](https://developer.samsung.com/smarttv/develop/specifications/media-specifications/2021-tv-video-specifications.html) — codec/audio matrix incl. the DTS drop
- [Jellyfin codec support docs](https://jellyfin.org/docs/general/clients/codec-support/)
- [georift/install-jellyfin-tizen](https://github.com/georift/install-jellyfin-tizen) — the installer actually used · [sideload guide](https://jellywatch.app/blog/jellyfin-samsung-tv-tizen-install-sideload-guide-2026)
