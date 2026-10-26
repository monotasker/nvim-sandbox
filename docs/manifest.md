# Manifest schema

The seed reads a JSON manifest that describes config clones and the optional
personal addon. Resolution order (first existing file wins):

1. `$EDITOR_MANIFEST`
2. `~/.config/nvim-sandbox/manifest.json`
3. `/usr/local/share/nvim-sandbox/manifest.default.json` (baked into the image)

The default file in this repo is [`manifest.default.json`](../manifest.default.json).
Query helpers live in [`manifest-get.py`](../manifest-get.py).

## Top-level fields

| Field | Type | Description |
|-------|------|-------------|
| `pull_on_start` | bool | If true, seed fast-forward pulls config repos (and addon) unless overridden by env |
| `addon` | object | Optional personal addon (see below) |
| `configs` | object | Map of named config entries (keys are free-form, e.g. `nvim`, `tmux`) |

Env overrides that interact with the manifest:

| Env | Effect |
|-----|--------|
| `EDITOR_CONFIG_PULL=1` | Force ff-only pull of configs (+ addon) |
| `EDITOR_TOOLS_UPDATE=1` | Refresh mutable CLIs regardless of stamps |
| `EDITOR_ADDON_REPO` / `DIR` / `SCRIPT` / `REF` | Override `addon.*` fields |

## `configs.<name>`

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | Skip when false |
| `repo` | string | Git remote URL |
| `path` | string | Clone destination (supports `~`) |
| `depth` | number | `git clone --depth` (0 = full history) |
| `ref` | string | Optional branch/tag/commit after clone |

## `addon`

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | Ignored if `repo` / `EDITOR_ADDON_REPO` is empty; treat empty repo as off |
| `repo` | string | Git remote (required to enable) |
| `path` | string | Clone dir (default `~/.local/share/nvim-sandbox/addon`) |
| `script` | string | Script inside the clone (default `seed-addon.sh`) |
| `depth` | number | Clone depth |
| `ref` | string | Optional pin |

The addon script runs **only** as uid 1000. Seed aborts addon execution if it
detects root.

## Minimal example

```json
{
  "pull_on_start": false,
  "addon": {
    "enabled": false,
    "repo": "",
    "path": "~/.local/share/nvim-sandbox/addon",
    "script": "seed-addon.sh",
    "depth": 0,
    "ref": ""
  },
  "configs": {
    "nvim": {
      "enabled": true,
      "repo": "https://github.com/monotasker/nvconfig.git",
      "path": "~/.config/nvim/lua",
      "depth": 1
    }
  }
}
```
