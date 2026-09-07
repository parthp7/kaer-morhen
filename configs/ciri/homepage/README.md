# homepage — lab dashboard (ciri stack)

Homepage + OliveTin + Docker socket proxy + a static results server on
**ciri** (VM 150), live at `ciri:/data/stacks/homepage/`. Design, placement
assessment, runbook and gotchas: [proposal 008](../../../docs/proposals/008-lab-dashboard.md).
Read-only by construction — nothing in this stack can restart, write or install
anything (§0, §6 there).

**Status: built and verified** (2026-09-07). All four containers run on ciri;
Caddy serves `home`, `olivetin` and `pulse`; the three collectors write real
JSON on their timers; the forced-command whitelist refuses everything else.
Pulse lives in its own LXC 205 on yennefer, outside this stack. Contract tests
E1–E3 and E5–E9 passed; **E4 (a live qBittorrent move) is still unobserved** —
it needs a large torrent to finish, and is deferred by decision rather than
pending work. That and one privilege-narrowing item are the two things to look
at later: see "Follow-ups" in
[proposal 008](../../../docs/proposals/008-lab-dashboard.md) and
[Open items](../../../docs/maintenance.md#open-items).

| Piece | Port on ciri | Behind Caddy as |
|---|---|---|
| Homepage (`ghcr.io/gethomepage/homepage:v2.2.0`) | **3010** (3000 is Sure's) | `home.kaermorhen.fyi` |
| OliveTin (`jamesread/olivetin:3000.19.0` + ssh/jq, built locally) | 1337 | `olivetin.kaermorhen.fyi` |
| socket-proxy (`lscr.io/linuxserver/socket-proxy:3.4.4`) | none | — |
| results (`joseluisq/static-web-server:2.44.0`) | none | — |

## Files

- `compose.yaml` — verbatim copy of the live file (scp'd back after every change)
- `.env.example` — placeholders for every secret; the real `.env` is VM-only, `chmod 600`
- `homepage/` — `settings.yaml`, `docker.yaml`, `widgets.yaml`, `services.yaml`,
  `bookmarks.yaml`. Secrets enter via `{{HOMEPAGE_VAR_*}}` from `.env`; addresses
  via `{{HOMEPAGE_VAR_LAN_PREFIX}}`, so these files carry no real values.
  Homepage also writes four empty stubs of its own on first run
  (`custom.css`, `custom.js`, `kubernetes.yaml`, `proxmox.yaml` — the last one
  is a commented sample, *not* where our Proxmox tokens live); they are
  deliberately untracked
- the two PVE tiles need **two different tokens**
  (`PVE_HOMEPAGE_TOKEN`, `PVE_HOMEPAGE_TOKEN_YENNEFER`) because geralt and
  yennefer are standalone nodes, not a cluster
- `olivetin/Dockerfile` — base image + `openssh-clients` + `jq`. Bump the `FROM`
  on upgrade, then `docker compose build --pull && docker compose up -d`
- `olivetin/config.yaml` — actions and ACLs. The tracked copy carries
  `<OLIVETIN_PASSWORD_HASH>`; the live one holds the argon2id hash
- `olivetin/scripts/` — `collect.sh`, `collect-updates.sh`: run one whitelisted
  word on one host over ssh, store the JSON in `results/`
- `olivetin/ssh/config.example` — host aliases; the live `config`, `id_ed25519*`
  and `known_hosts` are git-ignored and must never be committed
- host side: the dispatcher and collectors live in [`scripts/ops/`](../../../scripts/ops/)

## Layout & ownership (in the VM)

```
/data/stacks/homepage/          ciri:ciri (1000)
├── compose.yaml  .env (600)
├── homepage/                   Homepage runs as PUID/PGID 1000 → writes logs/ here
├── olivetin/
│   ├── Dockerfile  config.yaml (600)  scripts/
│   └── ssh/  (700)             config, id_ed25519 (600), known_hosts — mounted at /home/olivetin/.ssh
└── results/                    *.json written by OliveTin (uid 1000), served read-only
```

## Upgrades

Weekly pass ([maintenance.md](../../../docs/maintenance.md)): bump the four
pins, `docker compose build --pull` (OliveTin has a `build:`), then
`docker compose pull && docker compose up -d`. Homepage re-reads `.env` only on
restart; YAML edits are live.
