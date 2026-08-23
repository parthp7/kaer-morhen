# CLAUDE.md

Homelab configurations and helper scripts for personal infrastructure. Private repository.

## Critical restrictions
- Only execute read commands over ssh if required, never execute write commands or commands that change system state over ssh.

## Repository layout
- `scripts/` — helper/automation scripts (grouped by purpose, e.g. `scripts/backup/`)
- `configs/` — service & app configs (grouped per host or service)
  - `configs/ciri/<stack>/` — mirror of the live compose stack at
    `ciri:/data/stacks/<stack>/`: after any change, `scp` the `compose.yaml`
    into the repo verbatim; commit a `.env.example` with placeholders (the
    real `.env` stays in the VM, chmod 600). Applies to every future stack.
- `docs/` — notes, runbooks, and host inventory
- Keep each service/host self-contained in its own subdirectory with a local README.

## Secrets & sensitive data
- NEVER commit secrets, tokens, passwords, or keys. Commit `*.example` templates instead.
- Replace sensitive values (IPs, hostnames, MACs, credentials) with named placeholders, e.g. `<NAS_IP>`.
- Real values live only in a local, git-ignored `secrets.local.*` mapping file — never reference real values in tracked files.
- **Exception — the public domain `kaermorhen.fyi` is written out in full** (decided 2026-08-09). A registered domain is public information by construction and carries no secret; masking it only made the reverse-proxy docs unreadable. Internal names (`*.kaermorhen.internal`) were never masked either. Credentials for it — `<ACME_EMAIL>`, `CF_API_TOKEN` — stay masked as normal.
- Keep placeholder names stable and documented so mappings stay resolvable.

## Shell scripts
- Bash scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Scripts must be idempotent and safe to re-run; validate inputs and fail loudly.
- Quote variables; pass `shellcheck` before committing.
- Add a header comment describing purpose, usage, and required env/args.

## Conventions
- SSH to homelab can be done by using `ssh lab-<name>` in most cases, I update ssh config files after creating VM/nodes (usually not LXCs). 
- Document every non-trivial script or config in its directory README.
- Prefer relative paths and env vars over hardcoded machine-specific values.
