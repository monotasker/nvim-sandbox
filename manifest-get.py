#!/usr/bin/env python3
"""Query the editor seed manifest (JSON) for shell-friendly values.

Usage:
  manifest-get.py <manifest.json> pull_on_start
  manifest-get.py <manifest.json> addon.enabled|repo|path|script|depth|ref
  manifest-get.py <manifest.json> config.<name>.enabled|repo|path|depth
"""

from __future__ import annotations

import json
import os
import sys


def expand(path: str) -> str:
    return os.path.expanduser(path) if path else ""


def addon_block(data: dict) -> dict:
    """Normalize manifest addon to a dict (null / string path → empty/disabled)."""
    raw = data.get("addon")
    if raw is None:
        return {}
    if isinstance(raw, str):
        # Legacy: addon was a script path string.
        return {
            "enabled": bool(raw),
            "repo": "",
            "path": "",
            "script": expand(raw) if raw else "",
            "depth": 0,
            "ref": "",
        }
    if isinstance(raw, dict):
        return raw
    return {}


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "usage: manifest-get.py <manifest.json> <query>",
            file=sys.stderr,
        )
        return 2

    manifest_path, query = sys.argv[1], sys.argv[2]
    with open(manifest_path, encoding="utf-8") as fh:
        data = json.load(fh)

    if query == "pull_on_start":
        print("1" if data.get("pull_on_start") else "0")
        return 0

    if query.startswith("addon."):
        field = query.split(".", 1)[1]
        addon = addon_block(data)
        if field == "enabled":
            # Explicit enabled, or enabled implicitly when repo is set.
            if "enabled" in addon:
                print("1" if addon.get("enabled") else "0")
            else:
                print("1" if addon.get("repo") else "0")
            return 0
        if field == "repo":
            print(addon.get("repo") or "")
            return 0
        if field == "path":
            default = "~/.local/share/nvim-sandbox/addon"
            print(expand(str(addon.get("path") or default)))
            return 0
        if field == "script":
            # Relative to path, or absolute legacy script path.
            print(addon.get("script") or "seed-addon.sh")
            return 0
        if field == "depth":
            print(str(int(addon.get("depth", 0))))
            return 0
        if field == "ref":
            print(addon.get("ref") or "")
            return 0
        print(f"bad addon field: {field}", file=sys.stderr)
        return 2

    # Legacy query "addon" → script path only (unused by new seed).
    if query == "addon":
        addon = addon_block(data)
        script = addon.get("script") or ""
        path = expand(str(addon.get("path") or ""))
        if script.startswith("/"):
            print(script)
        elif path and script:
            print(os.path.join(path, script))
        else:
            print("")
        return 0

    if query.startswith("config."):
        parts = query.split(".", 2)
        if len(parts) != 3:
            print(f"bad query: {query}", file=sys.stderr)
            return 2
        _prefix, name, field = parts
        cfg = (data.get("configs") or {}).get(name) or {}
        if field == "enabled":
            if name not in (data.get("configs") or {}):
                print("0")
            else:
                print("1" if cfg.get("enabled", True) else "0")
            return 0
        if field == "repo":
            print(cfg.get("repo") or "")
            return 0
        if field == "path":
            print(expand(str(cfg.get("path") or "")))
            return 0
        if field == "depth":
            depth = cfg.get("depth", 1)
            print(str(int(depth)))
            return 0
        print(f"bad field: {field}", file=sys.stderr)
        return 2

    print(f"bad query: {query}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
