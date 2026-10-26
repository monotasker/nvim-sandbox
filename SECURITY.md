# Security Policy

## Supported versions

Security fixes target the latest release on `main` and the newest `v*` tag.

## Reporting a vulnerability

Please **do not** open a public issue for security-sensitive reports.

Email **scottianw@gmail.com** with:

- Affected version / commit (if known)
- Description and impact
- Reproduction steps or a minimal PoC when safe to share

You should receive an acknowledgment within a few days. We will coordinate a fix
and disclosure timeline.

## Threat model (summary)

nvim-sandbox is a **development** editor container, not a multi-tenant
isolation boundary.

- The entrypoint runs as root only to set up an SSH agent proxy, then drops to
  uid 1000 (`dev`) for seed and the main process.
- `EDITOR_ADDON_REPO` (and the addon script) is **arbitrary code as the editor
  user**. Only enable remotes you trust; pin `EDITOR_ADDON_REF` when practical.
- npm/yarn lifecycle scripts are disabled; pnpm native builds use an allowlist
  under `~/editor-tools`. That reduces accidental supply-chain execution; it is
  not a sandbox escape guarantee.
- Mounting host credentials (SSH agent, cloud tokens, project secrets) into the
  container is a deliberate tradeoff for day-to-day work. Treat the container
  like a trusted workstation session.
