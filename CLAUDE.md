# CLAUDE.md

Homelab configurations and helper scripts for personal infrastructure. Private repository.

## Repository layout
- `scripts/` — helper/automation scripts (grouped by purpose, e.g. `scripts/backup/`)
- `configs/` — service & app configs (grouped per host or service)
- `docs/` — notes, runbooks, and host inventory
- Keep each service/host self-contained in its own subdirectory with a local README.

## Secrets & sensitive data
- NEVER commit secrets, tokens, passwords, or keys. Commit `*.example` templates instead.
- Replace sensitive values (IPs, hostnames, MACs, credentials) with named placeholders, e.g. `<NAS_IP>`.
- Real values live only in a local, git-ignored `secrets.local.*` mapping file — never reference real values in tracked files.
- Keep placeholder names stable and documented so mappings stay resolvable.

## Shell scripts
- Bash scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Scripts must be idempotent and safe to re-run; validate inputs and fail loudly.
- Quote variables; pass `shellcheck` before committing.
- Add a header comment describing purpose, usage, and required env/args.

## Conventions
- Never install/upgrade/remove system packages or dependencies without explicit permission.
- Confirm before any destructive or irreversible action (rm, wipe, prune, disk ops).
- Document every non-trivial script or config in its directory README.
- Prefer relative paths and env vars over hardcoded machine-specific values.
