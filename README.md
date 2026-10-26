# nvim-sandbox

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Docker](https://img.shields.io/badge/Docker-Compose%20v2-2496ED?logo=docker&logoColor=white)](docker-compose.yml)
[![CI](https://github.com/monotasker/nvim-sandbox/actions/workflows/ci.yml/badge.svg)](https://github.com/monotasker/nvim-sandbox/actions/workflows/ci.yml)

Opinionated, reusable **Neovim editor container** — Fedora floor, seed-on-boot
home volume, manifest-driven configs, optional personal addon.

Run standalone, or plug the image into another project’s Compose stack.

**Maintainer:** [Ian W. Scott](mailto:scottianw@gmail.com) ([@monotasker](https://github.com/monotasker))

## Why

- **Stable image, mutable home.** Rebuild the image rarely (OS, Neovim, build
  tools). Seed CLIs and configs into a persistent volume on first boot.
- **Portable defaults.** Manifest clones opinionated configs (nvim / tmux / zsh)
  without baking them into the image.
- **Personal without forking.** Opt-in addon repo clones onto the home volume
  and runs as `dev` (uid 1000) only — never as root.
- **Consumer contract.** Other stacks wait on a ready stamp and exec as `dev`.

## Requirements

- [Docker](https://docs.docker.com/get-docker/) with **Compose v2**
- Optional: host **SSH agent** socket if you want git/SSH from inside the editor
- Optional: [ShellCheck](https://www.shellcheck.net/) for local script lint

## Quick start

```bash
cp .env.example .env   # optional
docker compose build
docker compose up -d
# wait until ready.stamp exists, then:
docker compose exec -it -u dev editor tmux new -A -s dev
```

Ready when this path exists inside the container:

`/home/dev/.local/share/editor-tools/ready.stamp`

## Architecture

Image vs home volume vs seed vs addon:

→ **[docs/architecture.md](docs/architecture.md)** (diagram + boot sequence)

| Layer | Contents |
|-------|----------|
| **Image** (rebuild rarely) | Fedora 44 (digest-pinned), zsh/tmux/git/rg/fd/fzf, gcc/cmake/cargo, Node + Corepack/pnpm, pinned Neovim, zoxide, `runuser` + socat |
| **Home volume** (seed on boot) | `~/editor-tools` pnpm project, pnpm globals, go/gh/lazygit/yazi under `~/.local`, manifest config clones, optional addon |

Ownership:

1. Root installs under `/usr` / `/opt` — never `/home/dev`.
2. User `dev` (uid/gid 1000) owns the home volume.
3. Entrypoint starts as **root** (SSH agent socat), then `runuser -u dev` runs seed.
4. Do **not** set Compose `user:` — that breaks the entrypoint.

## Layout

| Path | Role |
|------|------|
| `Dockerfile` | Stable OS/tool floor (base digest pinned) |
| `entrypoint.sh` | Root: SSH agent socat → `runuser` seed |
| `seed-home.sh` | uid 1000: tools + manifest configs + addon |
| `manifest.default.json` | Opinionated portable defaults |
| `manifest-get.py` | Manifest query helper |
| `docker-compose.yml` | Standalone bring-up |
| `.env.example` | Documented env knobs |
| `docs/` | Architecture, manifest schema, GitHub settings |

## Manifest

Resolution order (first hit wins):

1. `$EDITOR_MANIFEST`
2. `~/.config/nvim-sandbox/manifest.json`
3. `/usr/local/share/nvim-sandbox/manifest.default.json`

Schema and field reference: **[docs/manifest.md](docs/manifest.md)**.

Default configs: monotasker `nvconfig`, `tmux-config`, `zsh-config`.

Useful env:

| Variable | Effect |
|----------|--------|
| `EDITOR_CONFIG_PULL=1` | Fast-forward pull config repos (+ addon) on seed |
| `EDITOR_TOOLS_UPDATE=1` | Reinstall/refresh mutable CLIs |
| `NVIM_VERSION` | Build-arg for Neovim pin (default `v0.12.5`) |

## Personal addon (opt-in)

Seed clones an addon **git repo onto the home volume** and runs its script as
`dev` (uid 1000). Seed **refuses** if `id -u` is 0.

| Variable / manifest | Role |
|---------------------|------|
| `EDITOR_ADDON_REPO` / `addon.repo` | Git remote (required to enable) |
| `EDITOR_ADDON_DIR` / `addon.path` | Clone dir (default `~/.local/share/nvim-sandbox/addon`) |
| `EDITOR_ADDON_SCRIPT` / `addon.script` | Script in clone (default `seed-addon.sh`) |
| `EDITOR_ADDON_REF` / `addon.ref` | Optional pin after clone |

### Security notes

- Treat `EDITOR_ADDON_REPO` as **code execution as your editor user** inside the
  container. Only point it at repos you trust.
- Addon never runs as root; image install and socat stay in the entrypoint.
- Prefer private/SSH remotes and pin `EDITOR_ADDON_REF` when you care about
  supply-chain drift.
- Lifecycle scripts for npm/yarn are disabled (`ignore-scripts`,
  `YARN_ENABLE_SCRIPTS=false`); pnpm builds go through an allowlist in
  `~/editor-tools`.

Full policy: [SECURITY.md](SECURITY.md).

## Published contract (consumers)

| Item | Value |
|------|--------|
| Default image tag | `nvim-sandbox:latest` |
| Runtime user after entrypoint | `dev` (uid/gid 1000) |
| Home | `/home/dev` |
| Ready stamp | `/home/dev/.local/share/editor-tools/ready.stamp` |
| Compose `user:` | Must **not** be set |

Example consumer wiring:

```yaml
services:
  editor:
    image: nvim-sandbox:latest
    # or: ghcr.io/<owner>/nvim-sandbox:<tag> after publish
    volumes:
      - editor_home:/home/dev
    # your project mounts / networks / SSH agent here
```

Wait for the ready stamp before `exec`, then:

```bash
docker compose exec -it -u dev editor tmux new -A -s dev
```

### Example consumer: KCWorks

KCWorks is one consumer: it keeps project wiring (`docker/editor/…`,
`kcworks-project.sh`) and builds from this repo via:

- `KCWORKS_EDITOR_CONTEXT` (path to a checkout of this repo)
- `KCWORKS_EDITOR_IMAGE` (default `nvim-sandbox:latest`)

Any other Compose stack can use the same image/tag and ready-stamp contract.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md). After the GitHub remote exists, apply
About/topics with [docs/github-settings.md](docs/github-settings.md).

```bash
# shellcheck (requires shellcheck installed)
shellcheck entrypoint.sh seed-home.sh

# image build
docker compose build
```

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
