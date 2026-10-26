#!/usr/bin/env bash
# Editor home seed (uid 1000): mutable CLIs + configs into the home volume, then exec.
#
# Invoked by editor-entrypoint.sh via runuser (not as container ENTRYPOINT).
#
# First empty home:
#   - ~/editor-tools pnpm project (allowlisted CLIs; see README.md)
#   - Mutable CLIs into ~/.local (pnpm globals, go, gh, lazygit, yazi)
#   - Clone config repos from manifest (default: monotasker nvconfig/tmux/zsh)
#   - Optional personal addon: clone repo onto the home volume, run seed script
#     as uid 1000 only (never root). See manifest.addon / EDITOR_ADDON_REPO.
#   - github.com in ~/.ssh/known_hosts (non-interactive; for git SSH)
#
# Manifest resolution (first hit):
#   1. $EDITOR_MANIFEST
#   2. ~/.config/nvim-sandbox/manifest.json
#   3. /usr/local/share/nvim-sandbox/manifest.default.json (image)
#
# Updates later:
#   EDITOR_CONFIG_PULL=1   — ff-only pull manifest config repos + addon (overrides pull_on_start)
#   EDITOR_TOOLS_UPDATE=1   — reinstall/refresh mutable CLIs
#   EDITOR_ADDON_REPO=…    — enable/override addon git remote (opt-in)
#
# Tool/config seed failures are logged and non-fatal so the editor still starts.
# Addon execution: only as the seed user (uid 1000). Entrypoint must use runuser.
set -euo pipefail

log() { printf 'editor: %s\n' "$*" >&2; }

if [[ "$(id -u)" -eq 0 ]]; then
  log "error: editor-seed-home must run as uid 1000 (via editor-entrypoint / runuser)"
  exit 1
fi

# Defaults (override via compose/env)
: "${PNPM_HOME:=$HOME/.local/share/pnpm}"
: "${GO_VERSION:=1.24.7}"
: "${GH_VERSION:=2.101.0}"
: "${LAZYGIT_VERSION:=0.64.1}"
: "${YAZI_VERSION:=26.9.1}"

export PNPM_HOME
# Stamps/readiness live under ~/.local/share/editor-tools (not the pnpm project).
EDITOR_TOOLS_DIR="${EDITOR_TOOLS_DIR:-$HOME/.local/share/editor-tools}"
# Pinned CLIs via a local pnpm project (allowBuilds); put bins on PATH.
EDITOR_TOOLS_PROJECT="${EDITOR_TOOLS_PROJECT:-$HOME/editor-tools}"
READY_STAMP="${EDITOR_READY_STAMP:-$EDITOR_TOOLS_DIR/ready.stamp}"
MANIFEST_GET="${MANIFEST_GET:-/usr/local/libexec/nvim-sandbox/manifest-get.py}"
# pnpm 12 global bin dir is $PNPM_HOME/bin (ERR_PNPM_GLOBAL_BIN_DIR_NOT_IN_PATH).
export PATH="$EDITOR_TOOLS_PROJECT/node_modules/.bin:$PNPM_HOME/bin:$PNPM_HOME:$HOME/.local/bin:$PATH"
# Cleared at start so consumers (e.g. kcworks-project.sh) wait for this boot.
mkdir -p "$EDITOR_TOOLS_DIR"
rm -f "$READY_STAMP"

resolve_manifest() {
  if [[ -n "${EDITOR_MANIFEST:-}" && -f "$EDITOR_MANIFEST" ]]; then
    printf '%s\n' "$EDITOR_MANIFEST"
  elif [[ -f "$HOME/.config/nvim-sandbox/manifest.json" ]]; then
    printf '%s\n' "$HOME/.config/nvim-sandbox/manifest.json"
  else
    printf '%s\n' "/usr/local/share/nvim-sandbox/manifest.default.json"
  fi
}

manifest_get() {
  python3 "$MANIFEST_GET" "$EDITOR_SEED_MANIFEST" "$1"
}

arch_triple() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64 | amd64) printf '%s\n' "x86_64" ;;
    aarch64 | arm64) printf '%s\n' "arm64" ;;
    *)
      log "unsupported arch: $arch"
      return 1
      ;;
  esac
}

yazi_arch() {
  case "$(arch_triple)" in
    x86_64) printf '%s\n' "x86_64" ;;
    arm64) printf '%s\n' "aarch64" ;;
  esac
}

go_arch() {
  case "$(arch_triple)" in
    x86_64) printf '%s\n' "amd64" ;;
    arm64) printf '%s\n' "arm64" ;;
  esac
}

# gh release tarballs use amd64/arm64 (same as Go).
gh_arch() { go_arch; }

ensure_dirs() {
  mkdir -p \
    "$HOME/.local/bin" \
    "$HOME/.local/share" \
    "$HOME/.config/pnpm" \
    "$HOME/.config/nvim-sandbox" \
    "$HOME/.pi/agent" \
    "$HOME/.ssh" \
    "$PNPM_HOME/bin" \
    "$PNPM_HOME/global/v11" \
    "$EDITOR_TOOLS_PROJECT"
  chmod 700 "$HOME/.ssh"
}

# Package lifecycle policy for this home volume:
#   ~/.npmrc                          — ignore-scripts=true (npm + default pnpm)
#   ~/.config/pnpm/config.yaml        — ignoreScripts: true (pnpm user config)
#   $PNPM_HOME/global/v11/pnpm-workspace.yaml — allowBuilds whitelist for globals
#
# .npmrc cannot whitelist individual packages. Whitelist = pnpm allowBuilds.
# To run allowed scripts: pnpm … --no-ignore-scripts (see ensure_pnpm_globals).
ensure_package_script_policy() {
  local npmrc="$HOME/.npmrc"
  local pnpm_user_cfg="$HOME/.config/pnpm/config.yaml"
  local pnpm_global_ws="$PNPM_HOME/global/v11/pnpm-workspace.yaml"
  local expected_npmrc expected_pnpm_cfg expected_ws

  expected_npmrc="; Block package lifecycle scripts by default (npm + pnpm).
; Per-package allowlisting is NOT supported in .npmrc — see
; ~/.local/share/pnpm/global/v11/pnpm-workspace.yaml allowBuilds.
ignore-scripts=true"

  expected_pnpm_cfg="ignoreScripts: true"

  expected_ws="# pnpm global build allowlist (scripts still need --no-ignore-scripts).
packages: []

allowBuilds:
  tree-sitter-cli: true
  \"@google/genai\": false
  protobufjs: false"

  write_text_shim "$npmrc" "$expected_npmrc" "~/.npmrc (ignore-scripts)"
  write_text_shim "$pnpm_user_cfg" "$expected_pnpm_cfg" "~/.config/pnpm/config.yaml"
  write_text_shim "$pnpm_global_ws" "$expected_ws" "pnpm global allowBuilds"
}

# ~/editor-tools: empty pnpm project for CLIs that need lifecycle scripts (or
# that we prefer not to install via Mason's npm). Seed creates the skeleton
# only; add packages later with allowBuilds / --allow-build (see docs).
# Does not overwrite an existing package.json (user deps stay intact).
ensure_editor_tools_project() {
  local dir="$EDITOR_TOOLS_PROJECT"
  local pkg="$dir/package.json"
  local gitignore="$dir/.gitignore"
  local readme="$dir/README.md"
  local expected_gitignore expected_readme

  mkdir -p "$dir"

  expected_gitignore="node_modules/
.pnpm-store/
*.log
.DS_Store"

  expected_readme="# editor-tools

Pinned CLIs for the nvim-sandbox editor container, installed with pnpm so
lifecycle scripts can be allowlisted per package.

Home defaults still block scripts (\`~/.npmrc\` / \`ignoreScripts\`). When
adding a package that must build:

\`\`\`bash
cd ~/editor-tools
CI=true pnpm add <pkg> --no-ignore-scripts --allow-build=<pkg>
# also add <pkg> under pnpm.onlyBuiltDependencies in package.json
\`\`\`

Put \`~/editor-tools/node_modules/.bin\` on PATH (seed + image ENV already do).
Omit the same tools from Mason's install list.

See the nvim-sandbox README (manifest + addon)."

  if [[ ! -f "$pkg" ]]; then
    log "initializing pnpm project at $dir"
    cat >"$pkg" <<EOF
{
  "name": "nvim-sandbox-tools",
  "private": true,
  "version": "0.0.0",
  "description": "Pinned editor CLIs via pnpm (lifecycle scripts allowlisted).",
  "packageManager": "pnpm@${PNPM_VERSION:-12.9.1}",
  "dependencies": {},
  "pnpm": {
    "onlyBuiltDependencies": []
  }
}
EOF
  fi

  write_text_shim "$gitignore" "$expected_gitignore" "~/editor-tools/.gitignore"
  write_text_shim "$readme" "$expected_readme" "~/editor-tools/README.md"

  # Lockfile for an empty project (no network packages). Safe to re-run.
  if [[ ! -f "$dir/pnpm-lock.yaml" ]] || [[ "${EDITOR_TOOLS_UPDATE:-0}" == "1" ]]; then
    log "pnpm install in $dir (skeleton)"
    (cd "$dir" && CI=true pnpm install) || {
      log "pnpm install in $dir failed (continuing)"
      return 0
    }
  fi
}

# Non-interactive host keys for git SSH (bootstrap does this interactively
# in the workspace). Safe to re-run; skips when github.com is already present.
ensure_ssh_known_hosts() {
  local kh="$HOME/.ssh/known_hosts"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  if [[ -f "$kh" ]] && grep -qF 'github.com' "$kh" 2>/dev/null; then
    return 0
  fi
  log "seeding github.com into ~/.ssh/known_hosts"
  if ! ssh-keyscan -T 5 -t ed25519,rsa github.com >>"$kh" 2>/dev/null; then
    log "ssh-keyscan github.com failed (continuing; git SSH may prompt/fail)"
    return 0
  fi
  chmod 600 "$kh" || true
}

ensure_pnpm_globals() {
  local stamp="$EDITOR_TOOLS_DIR/pnpm-globals.stamp"
  if [[ -f "$stamp" && "${EDITOR_TOOLS_UPDATE:-0}" != "1" ]] \
    && command -v pi >/dev/null 2>&1 \
    && command -v pi-acp >/dev/null 2>&1; then
    return 0
  fi

  log "installing pnpm globals into $PNPM_HOME (pi, pi-acp, tree-sitter-cli)"
  mkdir -p "$PNPM_HOME/bin" "$(dirname "$stamp")"
  ensure_package_script_policy
  # ~/.npmrc defaults to ignore-scripts=true. Opt in for this install only so
  # allowBuilds can run tree-sitter-cli's install.js; others stay denied.
  # CI=true + explicit --allow-build avoids the TTY approve-builds prompt.
  CI=true pnpm add -g \
    --no-ignore-scripts \
    --allow-build=tree-sitter-cli \
    --allow-build='!@google/genai' \
    --allow-build='!protobufjs' \
    @earendil-works/pi-coding-agent \
    pi-acp \
    tree-sitter-cli
  if ! command -v pi >/dev/null 2>&1 || ! command -v pi-acp >/dev/null 2>&1; then
    rm -f "$stamp"
    log "pnpm globals missing from PATH after install (need $PNPM_HOME/bin)"
    return 1
  fi
  date -u +%Y-%m-%dT%H:%M:%SZ >"$stamp"
  pi --version || true
}

ensure_go() {
  local prefix="$HOME/.local/go"
  local stamp="$HOME/.local/share/editor-tools/go-${GO_VERSION}.stamp"
  if [[ -x "$prefix/bin/go" && -f "$stamp" && "${EDITOR_TOOLS_UPDATE:-0}" != "1" ]]; then
    ln -sfn "$prefix/bin/go" "$HOME/.local/bin/go"
    ln -sfn "$prefix/bin/gofmt" "$HOME/.local/bin/gofmt"
    return 0
  fi

  log "installing go ${GO_VERSION} → $prefix"
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL "https://dl.google.com/go/go${GO_VERSION}.linux-$(go_arch).tar.gz" \
    | tar -xz -C "$tmp"
  rm -rf "$prefix"
  mv "$tmp/go" "$prefix"
  rm -rf "$tmp"
  mkdir -p "$(dirname "$stamp")"
  date -u +%Y-%m-%dT%H:%M:%SZ >"$stamp"
  ln -sfn "$prefix/bin/go" "$HOME/.local/bin/go"
  ln -sfn "$prefix/bin/gofmt" "$HOME/.local/bin/gofmt"
  go version
}

ensure_gh() {
  local bin="$HOME/.local/bin/gh"
  local stamp="$HOME/.local/share/editor-tools/gh-${GH_VERSION}.stamp"
  if [[ -x "$bin" && -f "$stamp" && "${EDITOR_TOOLS_UPDATE:-0}" != "1" ]]; then
    return 0
  fi

  log "installing gh ${GH_VERSION}"
  local tmp arch
  arch="$(gh_arch)"
  tmp="$(mktemp -d)"
  curl -fsSL \
    "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${arch}.tar.gz" \
    | tar -xz -C "$tmp"
  install -m 0755 "$tmp/gh_${GH_VERSION}_linux_${arch}/bin/gh" "$bin"
  rm -rf "$tmp"
  mkdir -p "$(dirname "$stamp")"
  date -u +%Y-%m-%dT%H:%M:%SZ >"$stamp"
  gh --version | head -n 1
}

ensure_lazygit() {
  local bin="$HOME/.local/bin/lazygit"
  local stamp="$HOME/.local/share/editor-tools/lazygit-${LAZYGIT_VERSION}.stamp"
  if [[ -x "$bin" && -f "$stamp" && "${EDITOR_TOOLS_UPDATE:-0}" != "1" ]]; then
    return 0
  fi

  log "installing lazygit ${LAZYGIT_VERSION}"
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL \
    "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_$(arch_triple).tar.gz" \
    | tar -xz -C "$tmp" lazygit
  install -m 0755 "$tmp/lazygit" "$bin"
  rm -rf "$tmp"
  mkdir -p "$(dirname "$stamp")"
  date -u +%Y-%m-%dT%H:%M:%SZ >"$stamp"
  lazygit --version | head -n 1
}

ensure_yazi() {
  local bin="$HOME/.local/bin/yazi"
  local stamp="$HOME/.local/share/editor-tools/yazi-${YAZI_VERSION}.stamp"
  if [[ -x "$bin" && -f "$stamp" && "${EDITOR_TOOLS_UPDATE:-0}" != "1" ]]; then
    return 0
  fi

  log "installing yazi ${YAZI_VERSION}"
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL \
    "https://github.com/sxyazi/yazi/releases/download/v${YAZI_VERSION}/yazi-$(yazi_arch)-unknown-linux-gnu.zip" \
    -o "$tmp/yazi.zip"
  unzip -q "$tmp/yazi.zip" -d "$tmp"
  install -m 0755 "$tmp"/yazi-*/yazi "$bin"
  if [[ -f "$tmp"/yazi-*/ya ]]; then
    install -m 0755 "$tmp"/yazi-*/ya "$HOME/.local/bin/ya"
  fi
  rm -rf "$tmp"
  mkdir -p "$(dirname "$stamp")"
  date -u +%Y-%m-%dT%H:%M:%SZ >"$stamp"
  yazi --version
}

ensure_mutable_tools() {
  # Network blips must not block tmux/nvim — stamp skips keep later starts fast.
  ensure_editor_tools_project || log "editor-tools project failed (continuing)"
  ensure_pnpm_globals || log "pnpm globals failed (continuing)"
  ensure_go || log "go install failed (continuing)"
  ensure_gh || log "gh install failed (continuing)"
  ensure_lazygit || log "lazygit install failed (continuing)"
  ensure_yazi || log "yazi install failed (continuing)"
}

# Write a home-dir shim if missing or drifted. Leaves symlinks alone.
write_text_shim() {
  local target="$1" expected="$2" label="${3:-$1}"

  if [[ -L "$target" ]]; then
    log "skip $target (symlink → $(readlink "$target"))"
    return 0
  fi
  if [[ -f "$target" ]] && [[ "$(cat "$target")" == "$expected" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$target")"
  printf '%s\n' "$expected" >"$target"
  log "wrote shim $label"
}

# Thin home shims → managed configs under ~/.config (or nvconfig lua tree).
# zsh managed zshrc selects linux.zsh vs darwin.zsh via OSTYPE (linux here).
ensure_nvim_shim() {
  local nvim_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
  local expected
  expected="-- import neovim lua configuration

require('nvconfig');"
  write_text_shim "$nvim_cfg/init.lua" "$expected" "~/.config/nvim/init.lua → nvconfig"
}

ensure_tmux_shim() {
  local expected="source-file ~/.config/tmux/tmux.conf"
  write_text_shim "$HOME/.tmux.conf" "$expected" "~/.tmux.conf → ~/.config/tmux/tmux.conf"
}

ensure_zsh_shims() {
  local expected_zshrc expected_p10k
  expected_zshrc="# Managed zsh config lives in ~/.config/zsh.
if [ -z \"\${ZSH_VERSION:-}\" ]; then
  printf '%s\n' \"This config is for zsh. Run: exec zsh\" >&2
  return 0 2>/dev/null || exit 0
fi

source \"\$HOME/.config/zsh/zshrc\""
  expected_p10k="# Managed Powerlevel10k config lives in ~/.config/zsh.
if [ -z \"\${ZSH_VERSION:-}\" ]; then
  printf '%s\n' \"This config is for zsh. Run: exec zsh\" >&2
  return 0 2>/dev/null || exit 0
fi

source \"\$HOME/.config/zsh/p10k.zsh\""
  write_text_shim "$HOME/.zshrc" "$expected_zshrc" "~/.zshrc → ~/.config/zsh/zshrc"
  write_text_shim "$HOME/.p10k.zsh" "$expected_p10k" "~/.p10k.zsh → ~/.config/zsh/p10k.zsh"
}

clone_or_pull_repo() {
  local label="$1" repo="$2" dest="$3" depth="${4:-1}"

  if [[ ! -d "$dest/.git" ]]; then
    log "cloning $label → $dest"
    mkdir -p "$(dirname "$dest")"
    rm -rf "$dest"
    if [[ "$depth" -gt 0 ]]; then
      git clone --depth "$depth" "$repo" "$dest"
    else
      git clone "$repo" "$dest"
    fi
  elif [[ "${EDITOR_CONFIG_PULL:-0}" == "1" ]]; then
    log "pulling $label"
    git -C "$dest" pull --ff-only || log "$label pull failed (continuing)"
  fi
}

ensure_nvim_config() {
  if [[ "$(manifest_get config.nvim.enabled)" != "1" ]]; then
    log "skip nvim config (manifest disabled)"
    return 0
  fi

  local nvim_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
  local lua_dir repo depth
  lua_dir="$(manifest_get config.nvim.path)"
  repo="$(manifest_get config.nvim.repo)"
  depth="$(manifest_get config.nvim.depth)"
  [[ -n "$lua_dir" && -n "$repo" ]] || {
    log "nvim manifest missing path/repo"
    return 0
  }

  mkdir -p "$nvim_cfg/undodir" "$nvim_cfg/after"
  ensure_nvim_shim
  clone_or_pull_repo "nvconfig" "$repo" "$lua_dir" "$depth"
  ensure_nvim_shim
}

ensure_tmux_config() {
  if [[ "$(manifest_get config.tmux.enabled)" != "1" ]]; then
    log "skip tmux config (manifest disabled)"
    return 0
  fi

  local tmux_cfg repo depth
  tmux_cfg="$(manifest_get config.tmux.path)"
  repo="$(manifest_get config.tmux.repo)"
  depth="$(manifest_get config.tmux.depth)"
  [[ -n "$tmux_cfg" && -n "$repo" ]] || {
    log "tmux manifest missing path/repo"
    return 0
  }

  clone_or_pull_repo "tmux-config" "$repo" "$tmux_cfg" "$depth"
  ensure_tmux_shim

  mkdir -p "$tmux_cfg/plugins"
  if [[ ! -f "$tmux_cfg/plugins/nordfox.tmux" ]]; then
    curl -fsSL \
      "https://raw.githubusercontent.com/EdenEast/nightfox.nvim/main/extra/nordfox/nordfox.tmux" \
      -o "$tmux_cfg/plugins/nordfox.tmux"
  fi

  if [[ ! -d "$tmux_cfg/plugins/tpm" ]]; then
    log "cloning tmux plugin manager (tpm)"
    git clone --depth 1 https://github.com/tmux-plugins/tpm.git "$tmux_cfg/plugins/tpm"
  fi

  if [[ -x "$tmux_cfg/plugins/tpm/bin/install_plugins" ]] \
    && [[ ! -d "$tmux_cfg/plugins/tmux-sensible" ]]; then
    log "installing tmux plugins via tpm"
    "$tmux_cfg/plugins/tpm/bin/install_plugins" || log "tpm install failed (continuing)"
  fi

  ensure_tmux_shim
}

ensure_zsh_config() {
  if [[ "$(manifest_get config.zsh.enabled)" != "1" ]]; then
    log "skip zsh config (manifest disabled)"
    return 0
  fi

  local zsh_cfg repo depth
  zsh_cfg="$(manifest_get config.zsh.path)"
  repo="$(manifest_get config.zsh.repo)"
  depth="$(manifest_get config.zsh.depth)"
  [[ -n "$zsh_cfg" && -n "$repo" ]] || {
    log "zsh manifest missing path/repo"
    return 0
  }

  clone_or_pull_repo "zsh-config" "$repo" "$zsh_cfg" "$depth"

  # Write shims before the long oh-my-zsh clone so a mid-seed shell still
  # sources managed config (and so zsh-newuser cannot claim ~/.zshrc first).
  ensure_zsh_shims

  if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    log "installing oh-my-zsh + plugins via zsh-config/install.sh"
    bash "$zsh_cfg/install.sh" --with-omz --with-plugins
  fi

  # Re-assert shims after install.sh / any concurrent zsh-newuser race.
  ensure_zsh_shims
}

ensure_pi_defaults() {
  local settings="$HOME/.pi/agent/settings.json"
  mkdir -p "$HOME/.pi/agent"
  if [[ ! -f "$settings" ]]; then
    log "writing default pi agent settings (lmstudio)"
    cat >"$settings" <<EOF
{
  "defaultProvider": "lmstudio",
  "defaultModel": "qwen/qwen3-coder-next",
  "theme": "dark",
  "defaultThinkingLevel": "medium"
}
EOF
  fi
}

# Clone optional personal addon onto the home volume and run its seed script.
# Security: runs only as this process's uid (must be 1000 / dev — never root).
# Opt-in via EDITOR_ADDON_REPO or manifest.addon.enabled + repo.
ensure_editor_addon() {
  if [[ "$(id -u)" -eq 0 ]]; then
    log "error: refusing to run editor addon as root"
    return 1
  fi

  local enabled repo dest script_rel depth ref script
  enabled="$(manifest_get addon.enabled)"
  repo="$(manifest_get addon.repo)"
  dest="$(manifest_get addon.path)"
  script_rel="$(manifest_get addon.script)"
  depth="$(manifest_get addon.depth)"
  ref="$(manifest_get addon.ref)"

  # Env wins for remote (and implies enable when set).
  if [[ -n "${EDITOR_ADDON_REPO:-}" ]]; then
    repo="$EDITOR_ADDON_REPO"
    enabled=1
  fi
  if [[ -n "${EDITOR_ADDON_DIR:-}" ]]; then
    dest="$EDITOR_ADDON_DIR"
  fi
  if [[ -n "${EDITOR_ADDON_SCRIPT:-}" ]]; then
    script_rel="$EDITOR_ADDON_SCRIPT"
  fi
  if [[ -n "${EDITOR_ADDON_REF:-}" ]]; then
    ref="$EDITOR_ADDON_REF"
  fi

  if [[ "$enabled" != "1" ]] || [[ -z "$repo" ]]; then
    log "no editor addon configured (set EDITOR_ADDON_REPO or manifest.addon)"
    return 0
  fi
  if [[ -z "$dest" ]]; then
    log "addon path empty (continuing)"
    return 0
  fi

  if [[ ! -d "$dest/.git" ]]; then
    log "cloning editor addon → $dest"
    mkdir -p "$(dirname "$dest")"
    rm -rf "$dest"
    if [[ "$depth" -gt 0 ]]; then
      git clone --depth "$depth" "$repo" "$dest" || {
        log "addon clone failed (continuing; check SSH agent / $repo)"
        return 0
      }
    else
      git clone "$repo" "$dest" || {
        log "addon clone failed (continuing; check SSH agent / $repo)"
        return 0
      }
    fi
    if [[ -n "$ref" ]]; then
      git -C "$dest" checkout "$ref" || log "addon checkout $ref failed (continuing)"
    fi
  elif [[ "${EDITOR_CONFIG_PULL:-0}" == "1" ]]; then
    log "pulling editor addon ($dest)"
    git -C "$dest" pull --ff-only || log "addon pull failed (continuing)"
  fi

  if [[ "$script_rel" == /* ]]; then
    script="$script_rel"
  else
    script="$dest/$script_rel"
  fi

  if [[ ! -f "$script" ]]; then
    log "addon script missing: $script (continuing)"
    return 0
  fi
  chmod u+x "$script" 2>/dev/null || true
  if [[ ! -x "$script" ]]; then
    log "addon script not executable: $script (continuing)"
    return 0
  fi

  log "running editor addon as uid $(id -u) ($(id -un)): $script"
  # Explicit non-root guard immediately before exec.
  if [[ "$(id -u)" -eq 0 ]]; then
    log "error: refusing addon exec as root"
    return 1
  fi
  "$script" || log "editor addon failed (continuing)"
}

EDITOR_SEED_MANIFEST="$(resolve_manifest)"
log "manifest: $EDITOR_SEED_MANIFEST"
if [[ ! -f "$EDITOR_SEED_MANIFEST" ]]; then
  log "error: manifest not found: $EDITOR_SEED_MANIFEST"
  exit 1
fi
if [[ ! -f "$MANIFEST_GET" ]]; then
  log "error: manifest helper missing: $MANIFEST_GET"
  exit 1
fi

# Env EDITOR_CONFIG_PULL=1 wins; else manifest pull_on_start.
if [[ "${EDITOR_CONFIG_PULL:-0}" != "1" ]] \
  && [[ "$(manifest_get pull_on_start)" == "1" ]]; then
  EDITOR_CONFIG_PULL=1
fi
export EDITOR_CONFIG_PULL="${EDITOR_CONFIG_PULL:-0}"

log "══ seed [1/7] directories, package-script policy, SSH known_hosts ══"
ensure_dirs
ensure_package_script_policy
ensure_ssh_known_hosts

log "══ seed [2/7] mutable tools (~/editor-tools, pnpm globals, go, gh, lazygit, yazi) ══"
ensure_mutable_tools

log "══ seed [3/7] neovim config (manifest) ══"
ensure_nvim_config || log "nvim config seed failed (continuing)"

log "══ seed [4/7] tmux config + tpm (manifest) ══"
ensure_tmux_config || log "tmux config seed failed (continuing)"

log "══ seed [5/7] zsh config + oh-my-zsh (manifest) ══"
ensure_zsh_config || log "zsh config seed failed (continuing)"

log "══ seed [6/7] pi agent defaults ══"
ensure_pi_defaults

log "══ seed [7/7] optional editor addon (uid 1000 only) ══"
ensure_editor_addon

date -u +%Y-%m-%dT%H:%M:%SZ >"$READY_STAMP"
log "══ seed complete (${READY_STAMP}) ══"

if [[ $# -eq 0 ]]; then
  set -- sleep infinity
fi
exec "$@"
