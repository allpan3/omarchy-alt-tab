#!/usr/bin/env bash
# Optional one-time xremap setup. Edit the installed bindings directly afterward.
set -euo pipefail
exec python3 - "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" "$@" <<'PY'
import argparse
import difflib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:
    sys.exit("Requires Python with PyYAML (python-yaml on Arch).")

root = Path(sys.argv.pop(1))
parser = argparse.ArgumentParser(prog="apply-binds.sh", description="Preview optional xremap bindings; edit them directly after installation.")
parser.add_argument("--apply", action="store_true", help="back up and write the previewed change")
parser.add_argument("--remove", action="store_true", help="remove only this installer's marked block")
parser.add_argument("--modifier", choices=("Alt", "Control_R"), default="Alt")
parser.add_argument("--config", type=Path, default=Path.home() / ".config/xremap/config.yml")
args = parser.parse_args()

try:
    plugin_id = json.loads((root / "manifest.json").read_text())["id"]
    if not isinstance(plugin_id, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", plugin_id):
        raise ValueError("Invalid plugin ID in manifest.json")
    path = args.config.expanduser().resolve(strict=True)
    original = path.read_text()
    data = yaml.safe_load(original)
    if not isinstance(data, dict) or not isinstance(data.get("keymap"), list):
        raise ValueError("Expected an existing xremap keymap list")
    begin, end = f"  # BEGIN {plugin_id}\n", f"  # END {plugin_id}\n"
    if original.count(begin) != original.count(end) or original.count(begin) > 1:
        raise ValueError("Malformed installer markers; refusing to edit")
    if begin in original:
        start = original.index(begin)
        stop = original.index(end) + len(end)
        if stop <= start:
            raise ValueError("Installer markers are out of order")
        if not args.remove:
            print("Already installed. Edit the xremap block directly; it will not be overwritten.")
            sys.exit(0)
        updated = original[:start] + original[stop:]
    elif args.remove:
        print("No installer block found; nothing to remove.")
        sys.exit(0)
    else:
        rules = {}
        for key, mode in (("Tab", "all"), ("Grave", "sameclass")):
            for reverse in (False, True):
                combo = args.modifier + ("-Shift-" if reverse else "-") + key
                payload = {"modifier": "alt" if args.modifier == "Alt" else "ctrl",
                           "mode": mode, "dir": "prev" if reverse else "next"}
                rules[combo] = {"launch": ["omarchy-shell", "shell", "summon", plugin_id,
                                            json.dumps(payload, separators=(",", ":"))]}
        # Be conservative about generic/sided modifiers and common aliases.
        def chord(key):
            return frozenset(re.sub(r"_[lr]$", "", part.lower()).replace("control", "ctrl")
                             for part in str(key).split("-"))
        existing = {chord(key) for item in data["keymap"] for key in item.get("remap", {})}
        if existing.intersection(map(chord, rules)):
            raise ValueError("A requested chord already has an xremap mapping; edit it manually")
        block = begin + "  - name: Window switcher\n    exact_match: true\n    remap:\n"
        block += "".join(f"      {key}: {json.dumps(value)}\n" for key, value in rules.items()) + end
        updated, count = re.subn(r"^keymap:[ \t]*(?:#[^\n]*)?\n", lambda m: m[0] + block,
                                 original, flags=re.MULTILINE)
        if count != 1:
            raise ValueError("Expected one block-style keymap: section")
    candidate = yaml.safe_load(updated)
    if not isinstance(candidate.get("keymap"), list):
        raise ValueError("Removing this block would leave no keymap list; retain keymap: [] manually")
    # Ask xremap to parse without selecting a real input device.
    with tempfile.TemporaryDirectory(prefix="alt-tab-check-") as temp:
        check = Path(temp) / "config.yml"
        check.write_text(updated)
        result = subprocess.run(["xremap", "--device", "/dev/input/alt-tab-validation-does-not-exist", str(check)],
                                capture_output=True, text=True, timeout=5)
        output = result.stdout + result.stderr
        if "Failed to load config" in output or not any(message in output for message in
                ("No device was selected!", "Failed to read /dev/input")):
            raise ValueError("xremap validation failed: " + output[-1000:])
    print("".join(difflib.unified_diff(original.splitlines(True), updated.splitlines(True),
                                    fromfile=str(path), tofile="proposed")), end="")
    if not args.apply:
        print("Preview only. Add --apply to write this change.")
        sys.exit(0)
    if path.read_text() != original:
        raise ValueError("Configuration changed during validation; retry")
    fd, backup = tempfile.mkstemp(prefix=path.name + ".before-alt-tab.", dir=path.parent)
    os.close(fd)
    shutil.copy2(path, backup)
    fd, temporary = tempfile.mkstemp(prefix=".alt-tab-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(updated)
        shutil.copymode(path, temporary)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"Applied. Backup: {backup}\nReload xremap if it does not watch its configuration.")
except (OSError, ValueError, KeyError, AttributeError, yaml.YAMLError, subprocess.SubprocessError) as error:
    sys.exit(str(error))
PY
