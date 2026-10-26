# Proposal 012 — Self-hosted password manager (Vaultwarden on ciri)

- **Status**: **Built 2026-10-26, verified 2026-10-27.** Stack live on ciri,
  `vault.kaermorhen.fyi` routed and resolving, signups closed, admin panel
  disabled, Argon2id + TOTP on, 112 logins imported from Apple Passwords and
  confirmed encrypted at rest, first encrypted export taken, Kuma monitor
  live. Details in the stack README.
- **Date**: 2026-10-26
- **Scope**: new compose stack `configs/ciri/vaultwarden/`; one route in
  `configs/yennefer/proxy/Caddyfile`; one A record on pihole-1
- **Decisions taken up front**: Vaultwarden; LAN + Tailscale only (no public
  exposure); single user; nothing to import (2026-10-26).

## 1. The need

One place for website logins (the main use) and for the assorted key/values
needed regularly (router admin, API tokens, licence keys). It needs a good UI
showing everything, and the backend must be unreadable without the master
password. Named as a candidate in [001 §4](001-initial-infrastructure-plan.md)
and as "the first service built behind the proxy" in
[003 §8](003-reverse-proxy.md).

## 2. Options compared

| Option | Verdict |
|---|---|
| **Vaultwarden** | **Chosen.** Rust Bitwarden-compatible server: one container, SQLite, ~50 MB RAM. Uses the **official, audited Bitwarden clients** (browser extensions, iOS/macOS autofill, web vault). TOTP codes, attachments, custom fields, secure notes, SSH-key items all free. The server itself isn't formally audited — but it only ever sees ciphertext. |
| Bitwarden official (Lite) | Same clients, audited server. Heavier; needs an installation ID; TOTP and attachments need a paid licence even self-hosted. |
| Passbolt CE | GPG-based, audited, Docker-native. Team-oriented; weaker personal autofill and mobile. |
| KeePassXC + Syncthing | Smallest attack surface, but no server or web UI — doesn't fit a ciri stack. |
| Psono / Padloc / Teampass | Enterprise-shaped, dormant, or weaker. |

## 3. Security model

Zero-knowledge: the client derives a key from the master password (Argon2id)
and encrypts every field before upload; the server stores ciphertext plus a
login hash. Root on ciri, the SQLite file, or a PBS backup reveal nothing.

Not "secure against any attack" — the remaining risks are a weak master
password (offline guessing), a compromised client device, a tampered web vault
(mitigated by using extension/native apps day to day), a lost master password
(unrecoverable — paper emergency kit), and the plain-HTTP Caddy → ciri hop on
the LAN (accepted, as for every service). Admin panel disabled (no
`ADMIN_TOKEN`); signups opened for one start only; password hints off; TOTP 2FA
from an authenticator outside the vault.

## 4. Build

Runbook, client setup, backup/restore and verification live in the stack
README: [configs/ciri/vaultwarden/README.md](../../configs/ciri/vaultwarden/README.md).

Summary: stack on ciri at port 8222 → Caddy `@vault` route →
`vault.kaermorhen.fyi` (wildcard cert already covers it) → A record on pihole-1,
synced to pihole-2 → one signup window → Argon2id KDF + TOTP → clients.

## 5. Backups

PBS nightly covers `data/` (scsi1). Because losing the vault means losing
access to everything, add a monthly **password-protected encrypted export**
stored offline, until the B2 offsite sync in [backups.md](../backups.md) lands.

## 6. Open items

- Make Bitwarden the only autofill source. iCloud Keychain stays on for now,
  since many places still use its logins.
- Homepage tile (optional)
