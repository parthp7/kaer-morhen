# vaultwarden — password manager (ciri stack)

Vaultwarden on **ciri** (VM 150), live at `ciri:/data/stacks/vaultwarden/`,
port **8222**, served as **`https://vault.kaermorhen.fyi`** through the Caddy
proxy (LXC 202). LAN + Tailscale only — nothing on the public internet.
Decision record: [proposal 012](../../../docs/proposals/012-password-manager.md).

Single user. Holds website logins plus arbitrary key/values (see "Storing
key/values" below). Clients are the official Bitwarden apps and extensions
pointed at the self-hosted URL.

## Files

- `compose.yaml` — verbatim copy of the live file (scp'd from the VM after
  every change, per the mirror convention in `CLAUDE.md`)
- no `.env` — the stack has no secrets. `ADMIN_TOKEN` is deliberately unset,
  which **disables `/admin` entirely**: no admin panel, no admin attack surface.
  If it is ever needed, set an Argon2 PHC hash (`vaultwarden hash`), never a
  plain token, and put it in a chmod-600 `.env` with a `.env.example` here.

## Config choices

| Setting | Value | Why |
|---|---|---|
| image | `1.37.4` | pinned per house policy (no `:latest`) |
| `DOMAIN` | `https://vault.kaermorhen.fyi` | required for WebAuthn/2FA, attachments and correct links; must match the proxied URL |
| `SIGNUPS_ALLOWED` | `false` | opened for one start only to create the account (below) |
| `INVITATIONS_ALLOWED` | `false` | single user, no organizations to invite into |
| `PASSWORD_HINTS_ALLOWED` / `SHOW_PASSWORD_HINT` | `false` | a hint is plaintext stored server-side; it only helps an attacker |
| `IP_HEADER` | `X-Forwarded-For` | Caddy sets XFF; without this every login logs as `.202` |
| `TZ` | `Asia/Kolkata` | IST everywhere |

WebSocket live sync is built in (since 1.29) on the same port; Caddy proxies
it with no extra config.

## Layout & ownership (in the VM)

```
/data/stacks/vaultwarden/      ciri:ciri   — stack dir + compose.yaml
└── data/                      root:root   — bind mount = /data (container runs as root)
    ├── db.sqlite3               vault: users, folders, ENCRYPTED ciphers
    ├── rsa_key.pem              JWT signing key (losing it = all sessions logged out)
    ├── attachments/             encrypted attachment blobs
    ├── sends/                   encrypted Send blobs
    └── icon_cache/              regenerable
```

`data/` is on scsi1 (`/data`), so the nightly PBS backup of VM 150 covers it.

## Security model

Bitwarden's design is zero-knowledge: the **client** derives a key from the
master password (Argon2id) and encrypts every field — name, URL, username,
password, notes, custom fields — before upload. The server, the SQLite file and
every backup of it hold **ciphertext only** (`2.<iv>|<ct>|<mac>` strings). Root
on ciri does not reveal a single site name.

What it does *not* protect against, stated plainly:

- **Weak master password** — offline guessing against stolen ciphertext is the
  only real attack. Use a 5+ random-word passphrase.
- **Compromised client device** — malware on an unlocked Mac/phone reads the
  vault. No server-side measure helps.
- **Tampered web vault** — the web vault's JavaScript is served by this server.
  Use the browser extension / native apps day to day (they ship their own code);
  treat the web vault as the "see everything" console.
- **Lost master password** — unrecoverable by design. Hence the emergency kit.
- **Caddy → ciri hop is plain HTTP** on the LAN, like every other service.
  Content is already encrypted; session tokens cross it in the clear. Accepted:
  the LAN/tailnet is the perimeter.

## Build procedure

```bash
# in the VM, as ciri
mkdir -p /data/stacks/vaultwarden

# from the Mac
scp configs/ciri/vaultwarden/compose.yaml lab-ciri:/data/stacks/vaultwarden/
```

Proxy + DNS, per [proxy README "Adding a service"](../../yennefer/proxy/README.md):
the `@vault` block is already in the repo `Caddyfile`; apply it on LXC 202,
`caddy adapt`, `systemctl reload caddy`; add the A record
`vault.kaermorhen.fyi → <LAN_PREFIX>.202` on pihole-1 (whole `dns.hosts`
array), force nebula-sync `sync-now`; scp the Caddyfile back.

### One signup window

1. In the VM, edit `compose.yaml`: `SIGNUPS_ALLOWED: "true"`, then
   `docker compose up -d`.
2. Open `https://vault.kaermorhen.fyi` → **Create account** with the master
   passphrase. No hint.
3. Set it back to `"false"`, `docker compose up -d` again. A second signup must
   now fail with *"Registration not allowed or user already exists"*.
4. Web vault → **Settings → Security → Keys** → KDF **Argon2id**
   (64 MiB / 3 iterations / 4 parallelism). This logs every session out.
5. **Settings → Security → Two-step login** → **Authenticator app** (TOTP),
   using an authenticator *outside* this vault. Save the **recovery code**.

## Clients

- **Mac browsers**: Bitwarden extension → on the login screen pick
  **Self-hosted** → server URL `https://vault.kaermorhen.fyi`.
- **iPhone**: Bitwarden app, same server URL, then **iOS Settings → General →
  AutoFill & Passwords** → enable Bitwarden. The app keeps an encrypted offline
  copy: autofill works off-tailnet; changes sync on reconnect.
- **Bitwarden desktop (Mac)** optional, same URL. If it errors with
  `ERR_ADDRESS_UNREACHABLE` while `curl` works, toggle it in **Privacy &
  Security → Local Network**.

## Storing key/values

- **Secure Note** item + **custom fields**: each field is *Text* (visible) or
  *Hidden* (masked, click to reveal/copy). E.g. note `Router` with fields
  `admin_user`, `admin_pass` (hidden).
- API tokens/keys: Login item with the token in a hidden custom field, or a
  Secure Note per provider.
- SSH keys: the dedicated **SSH key** item type.
- Group with **Folders**; the vault search covers names, URLs and fields.

## Backup & restore

| Layer | What | Survives |
|---|---|---|
| PBS nightly (VM 150, scsi1) | the whole `data/` dir | ciri/geralt disk loss |
| **Encrypted export** (manual, monthly + after big changes) | web vault → Tools → Export → `.json (Encrypted)`, **password protected** | the whole lab — store offline (USB/Mac), never in git |
| **Emergency kit** (paper) | master passphrase, 2FA recovery code, server URL | you forgetting |

Until the B2 offsite sync in [backups.md](../../../docs/backups.md) exists,
the encrypted export is the only copy outside the house's two laptops.

Restore from PBS: `docker compose down`, file-restore `data/` from the VM 150
snapshot into `/data/stacks/vaultwarden/data`, `docker compose up -d`.
Restore from export: fresh stack, create the account again, Tools → Import →
Bitwarden (json), enter the export password.

## Verify

```bash
ssh lab-ciri 'docker ps --filter name=vaultwarden --format "{{.Status}}"'   # (healthy)
curl -s http://<LAN_PREFIX>.150:8222/alive                                  # timestamp
curl -sI https://vault.kaermorhen.fyi | head -1                             # 200
curl -s https://vault.kaermorhen.fyi/admin            # "The admin panel is disabled…" (200)
curl -s -o /dev/null -w '%{http_code}\n' https://vault.kaermorhen.fyi/admin/users/overview  # 404
# signups closed — this step never creates an account, even if they were open:
curl -s -H 'Content-Type: application/json' \
  -d '{"email":"signup-probe@example.invalid","name":"probe"}' \
  https://vault.kaermorhen.fyi/identity/accounts/register/send-verification-email   # 400 "Registration not allowed"
# ciphertext only — ciri has no sqlite3, so query a copy on the Mac (DB + WAL):
ssh lab-ciri 'sudo cat /data/stacks/vaultwarden/data/db.sqlite3'     > /tmp/vw/db.sqlite3
ssh lab-ciri 'sudo cat /data/stacks/vaultwarden/data/db.sqlite3-wal' > /tmp/vw/db.sqlite3-wal
sqlite3 /tmp/vw/db.sqlite3 "select count(*), sum(name not like '2.%') from ciphers"   # N|0
rm -rf /tmp/vw
```

Verified 2026-10-27, deployed 2026-10-26: container healthy; `/alive` 200 direct
and via proxy; wildcard cert valid; `/admin` shows only the "disabled" notice
(sub-pages 404); a registration probe returns 400 *"Registration not
allowed"*; one user, Argon2id (32 MiB / 6 iterations — kept below 48 MiB so
the iOS autofill extension doesn't hit its memory cap), TOTP 2FA on, no hint.
After importing 112 logins from Apple Passwords, every cipher and folder
name is a `2.…` string, and a raw byte scan of `db.sqlite3` + WAL finds no
plaintext domain except the account email. The first encrypted export
(`encrypted: true, passwordProtected: true`) is stored offline.

## Monitoring

Uptime-Kuma HTTP monitor on `http://<LAN_PREFIX>.150:8222/alive`. It targets
the container directly, so a proxy or DNS fault won't trip it; the existing
`proxy-caddy` / `proxy-tls` monitors cover that path.

## Follow-ups

- Make Bitwarden the only autofill source (iCloud Keychain stays on for now,
  since many places still use its logins)
- Homepage tile (optional)
