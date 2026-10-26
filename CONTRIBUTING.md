# Contributing

Thanks for helping improve nvim-sandbox.

## Development setup

- Docker (Compose v2)
- Optional: [ShellCheck](https://www.shellcheck.net/) for `entrypoint.sh` /
  `seed-home.sh`

```bash
cp .env.example .env
docker compose build
docker compose up -d
docker compose exec -it -u dev editor zsh
```

Reset the home volume when testing seed from scratch:

```bash
docker compose down
docker volume rm nvim-sandbox-home   # or your NVIM_SANDBOX_HOME_VOLUME name
docker compose up -d --build
```

## What belongs where

| Change | Put it in |
|--------|-----------|
| OS packages, Neovim pin, Node/pnpm floor | `Dockerfile` |
| SSH agent / drop privileges | `entrypoint.sh` |
| Mutable CLIs, configs, addon | `seed-home.sh` |
| Default config remotes / addon defaults | `manifest.default.json` |
| Standalone ports/volumes/env | `docker-compose.yml`, `.env.example` |

Prefer small, reviewable PRs. Do not commit `.env` or secrets.

## Pull requests

1. Fork / branch from `main`.
2. Keep the consumer contract stable unless you bump the major version and
   document the break (ready stamp path, uid 1000 `dev`, no Compose `user:`).
3. Update `CHANGELOG.md` under `[Unreleased]` for user-visible changes.
4. Open a PR; CI must pass (Docker build + ShellCheck).

## Code style

- Shell: `set -euo pipefail`, log to stderr with a clear prefix (`editor:`).
- Prefer `runuser -u dev` over ad-hoc `su`/`gosu` for the seed drop.
- Python helpers: keep them small and stdlib-only when possible.
