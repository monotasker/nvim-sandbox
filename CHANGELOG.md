# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- README badges, Requirements, maintainer note; `docs/` (architecture, manifest
  schema, GitHub settings helpers).
- `.github/CODEOWNERS`.
- Dockerfile: pin `fedora:44` multi-arch index digest.

## [0.1.0] - 2026-10-16

### Added

- Initial public release: Fedora-based Neovim editor image, seed-on-boot home
  volume, manifest-driven config clones, optional uid-1000 personal addon hook.
- Standalone `docker-compose.yml`, consumer-ready contract (`dev` / ready stamp).
- MIT license, contributing and security docs, CI (build + ShellCheck), optional
  GHCR publish-on-tag workflow.

[Unreleased]: https://github.com/monotasker/nvim-sandbox/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/monotasker/nvim-sandbox/releases/tag/v0.1.0
