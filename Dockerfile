# nvim-sandbox: opinionated Neovim editor image (stable floor only).
# Mutable CLIs install into the persistent home volume on first boot
# (see seed-home.sh).
#
# Image (rebuild rarely):
#   - OS + zsh/tmux/git/rg/fd/fzf + build tools (gcc, cmake, cargo/rust)
#   - Node (official tarball) + Corepack/pnpm
#   - Neovim (pinned), zoxide
#   - util-linux runuser + socat (entrypoint → seed-home as uid 1000)
#
# Home volume (update anytime via seed-home):
#   - ~/editor-tools — local pnpm project for allowlisted CLI installs
#   - pi, pi-acp, tree-sitter-cli via pnpm → ~/.local/share/pnpm
#   - go, gh, lazygit, yazi → ~/.local
#   - Config repos from manifest (default: monotasker nvconfig/tmux/zsh)
#   - Optional EDITOR_ADDON for personal/private seed
#
# Ownership model:
#   1. Root installs everything that lives under /usr or /opt — never /home/dev.
#   2. Root creates uid/gid 1000 with useradd --create-home → /home/dev.
#   3. USER dev sets HOME and creates the home layout (only uid 1000 writes home).
#   4. USER root for ENTRYPOINT only (socat → runuser seed-home). Do not set compose `user:`.
#
# Base: Fedora (pinned major + digest) for a current glibc so modern prebuilt
# CLIs work (e.g. tree-sitter 0.27 needs GLIBC_2.39). We intentionally do not
# FROM node — that image already has a uid-1000 user and HOME layout that
# fights useradd.
#
# Digest is the multi-arch *index* for fedora:44 (amd64 + arm64). Refresh with:
#   docker buildx imagetools inspect fedora:44 --format '{{.Manifest.Digest}}'
#
# Build::
#
#   docker build -t nvim-sandbox:latest .
#   # or: docker compose build

FROM fedora:44@sha256:43b29f65a41eb9c35e1cd5323e3bdf3b655c2357a9f4f1ff2f9c2798e5045d80

ARG TARGETARCH
ARG NODE_VERSION=24.9.0
ARG NVIM_VERSION=v0.12.5
ARG PNPM_VERSION=12.9.1

# No HOME=/home/dev here. Root layers must not inherit that — it creates a
# root-owned /home/dev before useradd and breaks USER dev.
# Lifecycle scripts: blocked by ~/.npmrc (ignore-scripts=true) on the home
# volume; pnpm allowlist lives under $PNPM_HOME (see seed-home.sh). Yarn Berry
# does not honor that npmrc key — keep YARN_ENABLE_SCRIPTS=false here.
ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    EDITOR=nvim \
    VISUAL=nvim \
    SHELL=/bin/zsh \
    TERM=xterm-256color \
    PNPM_VERSION=${PNPM_VERSION} \
    LMS_HOST=host.docker.internal \
    LMS_PORT=1234 \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    YARN_ENABLE_SCRIPTS=false

# ── 1. Root: OS packages ──────────────────────────────────────────────────
# Drop-privs: util-linux `runuser` (Fedora-native).
RUN dnf -y install --setopt=install_weak_deps=False \
        bash \
        ca-certificates \
        cargo \
        cmake \
        curl \
        fd-find \
        findutils \
        fzf \
        gcc \
        gcc-c++ \
        git \
        glibc-langpack-en \
        gnupg2 \
        gzip \
        jq \
        less \
        libsqlite3x \
        make \
        openssh-clients \
        openssl \
        openssl-libs \
        pkgconf-pkg-config \
        procps-ng \
        python3 \
        python3-pip \
        python3-virtualenv \
        ripgrep \
        rust \
        shadow-utils \
        socat \
        sqlite \
        tar \
        tmux \
        unzip \
        util-linux \
        which \
        xz \
        zsh \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# ── Node (official linux tarball → /usr/local) + Corepack ─────────────────
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) node_arch=x64 ;; \
      arm64) node_arch=arm64 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL \
      "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" \
      | tar -xJ -C /usr/local --strip-components=1; \
    node --version; \
    # Node 24.9 ships Corepack 0.34.0, which hardcodes bin/pnpm.cjs; pnpm 11+
    # uses bin/pnpm.mjs (fixed in Corepack >= 0.34.5). Pin a known-good release.
    npm install -g corepack@0.36.0; \
    corepack enable; \
    corepack --version

# ── Neovim (stable floor; bump NVIM_VERSION + rebuild to upgrade) ─────────
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) nvim_arch=x86_64 ;; \
      arm64) nvim_arch=arm64 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL \
      "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-${nvim_arch}.tar.gz" \
      | tar -xz -C /opt; \
    ln -sf "/opt/nvim-linux-${nvim_arch}/bin/nvim" /usr/local/bin/nvim; \
    nvim --version | head -n 1

# ── zoxide ────────────────────────────────────────────────────────────────
RUN curl -fsSL "https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh" \
      | bash -s -- --bin-dir /usr/local/bin \
    && zoxide --version

# Root entrypoint (0700): socat SSH proxy, then runuser seed-home as uid 1000.
# Seed script (0755, root-owned): readable/executable by dev; runs as uid 1000.
# Default manifest + query helper (personal overrides via EDITOR_MANIFEST / addon).
COPY entrypoint.sh /usr/local/bin/editor-entrypoint.sh
COPY seed-home.sh /usr/local/bin/editor-seed-home.sh
COPY manifest.default.json /usr/local/share/nvim-sandbox/manifest.default.json
COPY manifest-get.py /usr/local/libexec/nvim-sandbox/manifest-get.py
RUN chmod 0700 /usr/local/bin/editor-entrypoint.sh \
    && chmod 0755 /usr/local/bin/editor-seed-home.sh \
    && chmod 0755 /usr/local/libexec/nvim-sandbox/manifest-get.py \
    && chmod 0644 /usr/local/share/nvim-sandbox/manifest.default.json

# ── 2. Root: uid 1000 + home ──────────────────────────────────────────────
RUN groupadd --gid 1000 dev \
    && useradd --uid 1000 --gid 1000 \
        --home-dir /home/dev \
        --create-home \
        --shell /bin/zsh \
        dev

# ── 3. uid 1000: HOME + home layout (only this user writes /home/dev) ─────
# Fresh editor-home named volume copies this tree as uid 1000.
# .gnupg must exist before consumers bind-mount S.gpg-agent
# (otherwise Docker creates a root-owned parent).
USER dev
ENV HOME=/home/dev \
    PNPM_HOME=/home/dev/.local/share/pnpm \
    PATH=/home/dev/editor-tools/node_modules/.bin:/home/dev/.local/share/pnpm/bin:/home/dev/.local/share/pnpm:/home/dev/.local/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /home/dev
RUN corepack prepare "pnpm@${PNPM_VERSION}" --activate \
    && pnpm --version \
    && mkdir -p \
         .local/bin \
         .local/share/pnpm/global/v11 \
         .local/share/editor-tools \
         editor-tools \
         .config/pnpm \
         .config/nvim-sandbox \
         .ssh \
         .pi/agent \
    && mkdir -m 700 -p .gnupg \
    && chmod 700 .ssh \
    && printf '%s\n' \
         '; Block package lifecycle scripts by default (npm + pnpm).' \
         '; Per-package allowlisting is NOT supported in .npmrc — see' \
         '; ~/.local/share/pnpm/global/v11/pnpm-workspace.yaml allowBuilds.' \
         'ignore-scripts=true' \
         > .npmrc \
    && printf '%s\n' \
         'ignoreScripts: true' \
         > .config/pnpm/config.yaml \
    && printf '%s\n' \
         '# pnpm global build allowlist (scripts still need --no-ignore-scripts).' \
         'packages: []' \
         '' \
         'allowBuilds:' \
         '  tree-sitter-cli: true' \
         '  "@google/genai": false' \
         '  protobufjs: false' \
         > .local/share/pnpm/global/v11/pnpm-workspace.yaml \
    && touch .nvim-sandbox-home

# ── 4. Root entrypoint (socat → runuser seed-home); default CMD keeps container up
USER root
WORKDIR /home/dev

ENTRYPOINT ["/usr/local/bin/editor-entrypoint.sh"]
CMD ["sleep", "infinity"]
