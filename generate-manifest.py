"""Generate lanes.json - the ONE source of provider/GUID truth in this tree.

Extracts the provider table from the INSTALLED Linux reference core (read-only)
and derives every GUID with the original generator's uuid5 scheme, so values
are stable across regenerations and identical to the ones already living in
the guest's Windows Terminal settings. Consumers (Patch-WtSettings.py,
Launch-Timi.ps1, TimiLane.exe) read this file; nobody hand-copies a GUID.

Run:  python3 generate-manifest.py [--core /path/to/timi.py]

The core is never modified. astra/glmflash were never minted on the guest
(measured 2026-09-10); their guids carry guid_source "minted" - the first
install that consumes this manifest creates those two profiles.
"""
import ast
import json
import os
import sys
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CORE = "/home/zeino/.local/share/timi/timi.py"
SNAPSHOT_SETTINGS = os.path.expanduser(
    "~/.claude/briefs/timi-windows-refactor/source-readonly/wt-settings.json")
# The original generator's fixed namespace ("timi" ns) - documented in the
# Aug-19 generate_settings.py and reproduced byte-identically by this script.
GUID_NS = uuid.UUID("6c6d6931-0000-4a11-8a11-74696d692e77")
SHORTCUTS = {"t": "opus", "s": "sonnet", "d": "deepseek", "f": "fable",
             "g": "glmflash", "1": "luna", "2": "terra", "3": "sol", "4": "astra"}
INHERITED = ("opus", "sonnet", "fable", "deepseek", "luna", "terra", "sol", "codex", "glm")


def profile_guid(key):
    return str(uuid.uuid5(GUID_NS, "timi-provider-%s" % key))


def extract_providers(core_path):
    """Read PROVIDERS out of the installed core via AST - no code execution."""
    tree = ast.parse(open(core_path, encoding="utf-8", errors="replace").read())
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id == "PROVIDERS" for t in node.targets):
            out = {}
            for k, v in zip(node.value.keys, node.value.values):
                out[k.value] = ast.literal_eval(v)
            return out
    raise SystemExit("generate-manifest: PROVIDERS not found in %s" % core_path)


def main():
    core = DEFAULT_CORE
    args = sys.argv[1:]
    if "--core" in args:
        core = args[args.index("--core") + 1]
    providers = extract_providers(core)
    try:
        snap = open(SNAPSHOT_SETTINGS, encoding="utf-8", errors="replace").read()
    except OSError:
        snap = ""
    out = {"schema_version": 1,
           "source": "installed Linux core (%s) + uuid5 namespace "
                     "6c6d6931-0000-4a11-8a11-74696d692e77; guid_source records "
                     "which values the guest's live wt-settings already carries"
                     % os.path.realpath(core),
           "providers": {}, "shortcuts": dict(SHORTCUTS),
           "new_tab_effort": {}, "default_provider_role": "timi"}
    for key, meta in providers.items():
        guid = profile_guid(key)
        out["providers"][key] = {
            "label": meta["label"], "effort": meta["effort"], "mark": meta["mark"],
            "tint": meta["tint"], "tint_light": meta["tint_light"], "guid": guid,
            "guid_source": "inherited" if ("{%s}" % guid) in snap else "minted",
        }
    dest = os.path.join(HERE, "lanes.json")
    with open(dest, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=1, ensure_ascii=False, sort_keys=True)
        fh.write("\n")
    minted = sorted(k for k, v in out["providers"].items() if v["guid_source"] == "minted")
    print("generate-manifest: wrote %s (%d lanes; minted: %s)"
          % (dest, len(out["providers"]), ", ".join(minted) or "none"))


if __name__ == "__main__":
    main()
