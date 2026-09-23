"""Patch Timi's OWN Windows Terminal settings.json with everything Timi needs.

Timi no longer edits the Windows Terminal the user opens from the Start menu.
It ships its own copy - the unpackaged (ZIP) Terminal under Timi\\wt with a
`.portable` marker beside the exe, which makes that build keep its settings AND
its window layouts in `Timi\\wt\\settings` instead of the Store app's LocalState.
Two installs, two settings files, nothing shared: the user's Terminal opens
PowerShell with its own profile list, and Timi's opens agent lanes, and neither
can restore the other's tabs or change what its "+" button does. `--unpatch`
takes the Timi entries back out of a settings file, which is how the Store
Terminal was handed back after the split.

Idempotent: every change is keyed by name/guid, so re-running after Windows
Terminal has rewritten the file (which it does whenever the settings UI is
touched - it normalises keybindings into `actions` with generated ids) lands
the same result instead of duplicating entries. That rewrite is also why this
patches the LIVE file the Terminal reads and copies the result back to the repo
afterwards, rather than treating Timi/wt-settings.json as the source of truth:
the file in the repo was already three edits behind when this was written.

What it sets, and why each one is not the obvious alternative:

  firstWindowPreference = persistedWindowLayout
      Restore tabs on launch. Per the docs the Terminal saves this layout "of
      all open windows automatically to assist with restoration from crashes",
      plus on quit and on closing the last window. It restores each tab's
      profile and, when the shell reports it, its working directory - but
      explicitly "not any contents of those panes", which is why TimiLane.exe
      exists alongside this.

  theme = system + profiles.defaults.colorScheme = {light, dark}
      Two halves of one feature. `theme` swings the window chrome (tab strip,
      title bar) with the OS, and the colorScheme PAIR swings the text
      palette - a single scheme name would leave a dark terminal sitting in a
      light window. The pair form follows the app theme, which when set to
      `system` follows the OS.

  scrollToZoom, only when it has been turned off
      Ctrl+wheel zoom depends on it. It is already the default, and the
      Terminal deletes settings that equal their default every time it
      rewrites the file - so writing it unconditionally would make this script
      claim a change on every run. It is only corrected when explicitly false.

  adjustFontSize actions on ctrl+alt+shift+F9/F10/F8
      The keys timi-zoom.ahk sends. Function keys because they are unambiguous
      for AutoHotkey to synthesise and are not layout-dependent the way `=`
      and `-` are. The Terminal's own ctrl+= / ctrl+- keep working; these are
      an addition, not a replacement.

  elevate is REMOVED from the Timi profiles
      It looks like the obvious way to guarantee an elevated agent and it is a
      trap. The Terminal does not elevate a tab in place: a tab whose profile
      asks for elevation is handed to elevate-shim.exe, which puts a UAC
      dialog on screen and then opens a SECOND, elevated Terminal window for
      it. Measured on this machine 2026-08-20 from the prefetch trail -
      consent.exe 15:04:16, elevate-shim.exe 15:04:34 - and the window that
      arrived carried `--profile {guid} --startingDirectory ...` on its
      command line. That command line is the third injury: any argument at all
      makes the Terminal skip firstWindowPreference, so the window came up
      with one default tab and restored nothing.

      So the flag cost all three of the things it was supposed to protect: a
      prompt instead of promptless elevation, two windows instead of one, and
      no restore. Elevation belongs to the WINDOW and is the scheduled task's
      job (Launch-Timi.ps1 step 1); TimiLane.exe re-runs that task if it ever
      finds itself unelevated, which fixes the "+" dropdown case this flag was
      added for - without a prompt and without a second window.

  defaultProfile = the Opus lane
      So the "+" button opens an Opus xhigh agent, which is what that button is
      for in an agent shell.

  the three real lanes run through TimiLane.exe
      Crash-resume, per-lane session identity, and the Claude Code theme
      follow. The six explain-only lanes keep their cmd.exe /k echo.

      It is a compiled exe rather than the timi-lane.ps1 it replaces because
      this command line runs on the tab's critical path: powershell.exe 5.1
      cost ~1.0 s to start before the script's first statement, and the
      script's WMI parent-walk another ~0.8 s. Measured end to end, the shell
      version took 2.8-3.5 s to reach claude and the exe takes 0.08-0.09 s.
      The .ps1 is kept alongside as the readable reference for what the exe
      does; the two write the same marker and can be swapped back by hand.
"""

import io
import json
import os
import shutil
import sys
import time

TIMI_DIR = os.path.dirname(os.path.abspath(__file__))

# Timi's own Terminal. Portable mode is only supported by the unpackaged
# distribution - the Store build ignores a `.portable` marker - so this path is
# also the reason Timi ships a second copy of Windows Terminal at all.
PORTABLE_DIR = os.path.join(TIMI_DIR, "wt")
LOCAL_STATE = os.path.join(PORTABLE_DIR, "settings")
SETTINGS = os.path.join(LOCAL_STATE, "settings.json")

# The Terminal the user opens themselves. Timi does not patch this any more; it
# is here so `--unpatch` has a default target and so the split is written down
# in one place.
STORE_STATE = os.path.join(
    os.environ.get("LOCALAPPDATA", r"C:\Users\Ahmad\AppData\Local"),
    r"Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState",
)
STORE_SETTINGS = os.path.join(STORE_STATE, "settings.json")

REPO_COPY = os.path.join(TIMI_DIR, "wt-settings.json")
LANE_EXE = os.path.join(TIMI_DIR, "TimiLane.exe")

# The generated manifest is the one source of provider/GUID truth. It is built
# from the installed Linux reference and carried with this controlled tree;
# consumers never hand-copy a GUID table.
MANIFEST = os.path.join(TIMI_DIR, "lanes.json")
try:
    with io.open(MANIFEST, encoding="utf-8") as _fh:
        _LANE_DATA = json.load(_fh)
    _LANE_PROVIDERS = _LANE_DATA["providers"]
    # Windows Terminal stores profile references with braces, unlike lanes.json.
    OPUS_GUID = "{" + _LANE_PROVIDERS["opus"]["guid"] + "}"
    LANES = {str(meta["guid"]): key for key, meta in _LANE_PROVIDERS.items()
             if key in ("opus", "sonnet", "fable", "gemini")}
except (OSError, ValueError, KeyError, TypeError) as exc:
    raise SystemExit("Timi: lanes.json is missing or invalid: %s" % exc)

# Palette notes for Timi Light: `white`/`brightWhite` are deliberately DARK.
# Most light schemes keep ANSI white near-white, which is correct in theory and
# invisible in practice - anything printing bright white lands as pale text on
# a pale background. This terminal exists to read agent output, so legibility
# wins over palette purity.
SCHEMES = [
    {
        "name": "Timi Dark",
        "background": "#1B1A19",
        "foreground": "#E8E6E3",
        "cursorColor": "#D97757",
        "selectionBackground": "#3D3A36",
        "black": "#2A2724",
        "red": "#E06C75",
        "green": "#98C379",
        "yellow": "#E5C07B",
        "blue": "#61AFEF",
        "purple": "#8C6FD6",
        "cyan": "#56B6C2",
        "white": "#D5D2CD",
        "brightBlack": "#6E6A64",
        "brightRed": "#F2807A",
        "brightGreen": "#B5D99C",
        "brightYellow": "#F0D399",
        "brightBlue": "#85C1F5",
        "brightPurple": "#A98BE8",
        "brightCyan": "#7BCBD4",
        "brightWhite": "#F7F5F1",
    },
    {
        "name": "Timi Light",
        "background": "#FAF9F7",
        "foreground": "#2B2A28",
        "cursorColor": "#C25E3F",
        "selectionBackground": "#E4DED4",
        "black": "#3A3835",
        "red": "#C2402F",
        "green": "#4B8B34",
        "yellow": "#9A6A00",
        "blue": "#2A6DB5",
        "purple": "#7A4FB0",
        "cyan": "#0E7C7C",
        "white": "#5E5B56",
        "brightBlack": "#8A8680",
        "brightRed": "#D4553F",
        "brightGreen": "#5A9E40",
        "brightYellow": "#B07C10",
        "brightBlue": "#3A82CE",
        "brightPurple": "#9160C4",
        "brightCyan": "#188C8C",
        "brightWhite": "#2B2A28",
    },
]

FONT_ACTIONS = [
    ({"action": "adjustFontSize", "delta": 1}, "ctrl+alt+shift+f9", "Timi.FontUp"),
    ({"action": "adjustFontSize", "delta": -1}, "ctrl+alt+shift+f10", "Timi.FontDown"),
    ({"action": "resetFontSize"}, "ctrl+alt+shift+f8", "Timi.FontReset"),
]


def load(path):
    # Windows Terminal writes UTF-8; it has shipped both with and without a BOM.
    with io.open(path, encoding="utf-8-sig") as fh:
        return json.load(fh)


def save(path, data, label):
    backup = "%s.bak-timi-%s" % (path, time.strftime("%Y%m%d-%H%M%S"))
    if os.path.exists(path):
        shutil.copy2(path, backup)

    body = json.dumps(data, indent=4, ensure_ascii=True)
    # Written whole rather than in place: a partial write here shows up as a
    # settings-error dialog on the user's screen, and the Terminal hot-reloads
    # this file the moment it changes.
    tmp = path + ".timi-tmp"
    with io.open(tmp, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(body + "\n")
    json.load(io.open(tmp, encoding="utf-8"))  # parse-check before it goes live
    os.replace(tmp, path)

    print("Timi: %s %s" % (label, path))
    print("      backup %s" % os.path.basename(backup))


def is_timi_profile(profile):
    return profile.get("name", "").startswith("Timi - ")


def seed_lanes(data):
    """Give a fresh settings file the lane profiles and schemes.

    Timi's own Terminal writes a default settings.json the first time it runs,
    and a default settings.json has no agent lanes in it - so without this the
    private instance opens PowerShell and nothing else. The lanes are taken
    from the repo mirror, which is what this script writes back on every run.
    """
    if any(is_timi_profile(p) for p in data.get("profiles", {}).get("list", [])):
        return []
    if not os.path.exists(REPO_COPY):
        sys.exit("Timi: no lanes in %s and no mirror at %s" % (SETTINGS, REPO_COPY))

    mirror = load(REPO_COPY)
    lanes = [p for p in mirror.get("profiles", {}).get("list", []) if is_timi_profile(p)]
    if not lanes:
        sys.exit("Timi: the mirror %s has no lane profiles either" % REPO_COPY)

    data.setdefault("profiles", {}).setdefault("list", []).extend(lanes)
    return ["seeded %d lane profiles from the mirror" % len(lanes)]


def unpatch(path):
    """Take Timi back out of a settings file the user's Terminal reads."""
    if not os.path.exists(path):
        sys.exit("Timi: %s not found" % path)

    data = load(path)
    removed = []

    profiles = data.get("profiles", {}).get("list", [])
    lanes = [p for p in profiles if is_timi_profile(p)]
    if lanes:
        data["profiles"]["list"] = [p for p in profiles if not is_timi_profile(p)]
        removed.append("%d Timi profiles" % len(lanes))

    # defaultProfile has to move off a profile that is about to stop existing,
    # or the Terminal opens with a settings error instead of a shell. The first
    # surviving profile is the same one a fresh install would pick.
    survivors = data.get("profiles", {}).get("list", [])
    guids = {p.get("guid") for p in survivors}
    if data.get("defaultProfile") not in guids and survivors:
        data["defaultProfile"] = survivors[0].get("guid")
        removed.append("defaultProfile -> %s" % survivors[0].get("name"))

    names = {s["name"] for s in SCHEMES}
    schemes = data.get("schemes", [])
    if any(s.get("name") in names for s in schemes):
        data["schemes"] = [s for s in schemes if s.get("name") not in names]
        removed.append("%d Timi schemes" % len(names))

    ids = {i for _, _, i in FONT_ACTIONS}
    for key in ("actions", "keybindings"):
        entries = data.get(key, [])
        keep = [e for e in entries if e.get("id") not in ids]
        if len(keep) != len(entries):
            data[key] = keep
            removed.append("%d Timi %s" % (len(entries) - len(keep), key))

    defaults = data.get("profiles", {}).get("defaults", {})
    if isinstance(defaults.get("colorScheme"), dict) and set(
        defaults["colorScheme"].values()
    ) & names:
        del defaults["colorScheme"]
        removed.append("profiles.defaults.colorScheme")

    # Tab restore was Timi's requirement, not the user's: it is the reason a
    # plain `wt` reopened yesterday's tabs instead of a clean window.
    for key in ("firstWindowPreference", "theme"):
        if key in data:
            del data[key]
            removed.append(key)

    if not removed:
        print("Timi: no Timi entries left in %s" % path)
        return

    save(path, data, "unpatched")
    for item in removed:
        print("      - removed %s" % item)


def main():
    args = sys.argv[1:]
    if args and args[0] == "--unpatch":
        return unpatch(args[1] if len(args) > 1 else STORE_SETTINGS)

    settings = SETTINGS
    if args and args[0] == "--settings":
        settings = args[1]
    globals()["SETTINGS"] = settings

    if not os.path.exists(settings):
        # Timi's Terminal writes this itself the first time it runs, but the
        # installer patches before anything has been launched - so start from
        # the mirror rather than making the install order load-bearing.
        if not os.path.exists(REPO_COPY):
            sys.exit("Timi: %s not found and no mirror at %s" % (settings, REPO_COPY))
        parent = os.path.dirname(settings)
        if parent and not os.path.isdir(parent):
            os.makedirs(parent)
        shutil.copy2(REPO_COPY, settings)
        print("Timi: seeded %s from the mirror" % settings)

    data = load(settings)
    changed = seed_lanes(data)

    # --- globals ---------------------------------------------------------
    # defaultProfile is what the "+" button, Ctrl+Shift+T and a bare `wt` open.
    # Leaving it on Windows PowerShell meant the most-used button in the window
    # handed back a shell instead of an agent.
    for key, value in (
        ("firstWindowPreference", "persistedWindowLayout"),
        ("theme", "system"),
        ("defaultProfile", OPUS_GUID),
    ):
        if data.get(key) != value:
            data[key] = value
            changed.append("%s=%s" % (key, value))

    # scrollToZoom is already Windows Terminal's default, and the Terminal
    # prunes settings that match their default every time it rewrites the file.
    # Writing it unconditionally would make this script report a change on
    # every single run. Only an explicit false is worth correcting.
    if data.get("scrollToZoom") is False:
        data["scrollToZoom"] = True
        changed.append("scrollToZoom=True")

    # --- colour schemes --------------------------------------------------
    schemes = data.setdefault("schemes", [])
    for scheme in SCHEMES:
        for i, existing in enumerate(schemes):
            if existing.get("name") == scheme["name"]:
                if existing != scheme:
                    schemes[i] = scheme
                    changed.append("scheme %s updated" % scheme["name"])
                break
        else:
            schemes.append(scheme)
            changed.append("scheme %s added" % scheme["name"])

    defaults = data.setdefault("profiles", {}).setdefault("defaults", {})
    pair = {"light": "Timi Light", "dark": "Timi Dark"}
    if defaults.get("colorScheme") != pair:
        defaults["colorScheme"] = pair
        changed.append("profiles.defaults.colorScheme=light/dark pair")

    # --- font-size actions for the Ctrl+wheel bridge ----------------------
    # The Terminal normalises user bindings after it next saves: the command
    # stays in `actions` and the `keys` move out into a `keybindings` entry
    # keyed by id. Both shapes are valid input, so an action counts as current
    # when its command matches AND the keys are attached in either place -
    # otherwise this rewrites the same three entries on every run.
    actions = data.setdefault("actions", [])
    bound = {b.get("id"): b.get("keys") for b in data.get("keybindings", [])}
    for command, keys, ident in FONT_ACTIONS:
        entry = {"command": command, "keys": keys, "id": ident}
        for i, existing in enumerate(actions):
            if existing.get("id") != ident:
                continue
            # A command with no arguments round-trips through the Terminal as
            # the bare action string ({"command": "resetFontSize"}), so the
            # dict form and the string form are the same binding and comparing
            # only the dict rewrites this entry forever.
            existing_command = existing.get("command")
            if isinstance(existing_command, str):
                existing_command = {"action": existing_command}
            same_command = existing_command == command
            same_keys = existing.get("keys") == keys or bound.get(ident) == keys
            if not (same_command and same_keys):
                actions[i] = entry
                changed.append("action %s updated" % ident)
            break
        else:
            actions.append(entry)
            changed.append("action %s added" % ident)

    # Windows Terminal splits user bindings between `actions` (command + id)
    # and `keybindings` (id + keys) after it rewrites the file. Either shape is
    # accepted on read, so writing the combined form above is enough - but if a
    # keybindings list is present, make sure nothing in it steals these keys.
    for binding in data.get("keybindings", []):
        if binding.get("keys") in {k for _, k, _ in FONT_ACTIONS} and binding.get(
            "id"
        ) not in {i for _, _, i in FONT_ACTIONS}:
            sys.exit("Timi: %s is already bound elsewhere" % binding["keys"])

    # --- shortcut actions & keybindings (ctrl+f -> Fable; Gemini unbound) ---
    gemini_guid = "{" + _LANE_PROVIDERS["gemini"]["guid"] + "}"
    fable_guid = "{" + _LANE_PROVIDERS["fable"]["guid"] + "}"
    fable_action_id = "User.newTab.7ECDF7E8"

    for action_id, profile_guid in [(fable_action_id, fable_guid)]:
        for entry in actions:
            if entry.get("id") == action_id:
                break
        else:
            actions.append({
                "command": {"action": "newTab", "profile": profile_guid},
                "id": action_id
            })
            changed.append("action %s added" % action_id)

    keybindings = data.setdefault("keybindings", [])
    for b in list(keybindings):
        if b.get("keys") == "ctrl+f" and b.get("id") != fable_action_id:
            keybindings.remove(b)
            changed.append("rebound ctrl+f away from %s" % b.get("id"))
        elif b.get("keys") == "ctrl+7":
            keybindings.remove(b)
            changed.append("removed stale ctrl+7 binding %s" % b.get("id"))

    bound_ids = {b.get("id"): b.get("keys") for b in keybindings}
    if bound_ids.get(fable_action_id) != "ctrl+f":
        keybindings.append({"id": fable_action_id, "keys": "ctrl+f"})
        changed.append("keybinding ctrl+f -> %s added" % fable_action_id)

    # --- profiles --------------------------------------------------------
    # No shell in front of it: Windows Terminal hands the command line straight
    # to CreateProcess, so the exe is the tab's first and only process until it
    # starts the agent. The -NoExit the shell version needed lives inside the
    # exe now - it opens a plain shell only after the agent has finished.
    lane_cmd = '"%s" %s'
    existing_guids = {p.get("guid", "").lower() for p in data["profiles"].get("list", [])}
    if gemini_guid.lower() not in existing_guids:
        gemini_profile = {
            "commandline": lane_cmd % (LANE_EXE, "gemini"),
            "guid": gemini_guid,
            "hidden": False,
            "icon": "\u264a",
            "name": "Timi - Gemini",
            "startingDirectory": "%USERPROFILE%",
            "tabColor": "#388BFD",
            "tabTitle": "\u264a Gemini"
        }
        data["profiles"].setdefault("list", []).append(gemini_profile)
        changed.append("profile Timi - Gemini added")

    for profile in data["profiles"].get("list", []):
        name = profile.get("name", "")
        if not name.startswith("Timi - "):
            continue
        # Not "leave it alone if absent": an older Timi wrote elevate=true into
        # this file, and a settings file that still carries it keeps forking the
        # second window forever. See the note at the top of this file.
        if profile.pop("elevate", None) is not None:
            changed.append("elevate removed from %s" % name)
        lane = LANES.get(profile.get("guid"))
        if lane:
            want = lane_cmd % (LANE_EXE, lane)
            if profile.get("commandline") != want:
                profile["commandline"] = want
                changed.append("commandline on %s" % name)

    if not changed:
        print("Timi: Windows Terminal settings already current")
        return

    save(settings, data, "patched")
    for item in changed:
        print("      - %s" % item)

    if os.path.abspath(settings) != os.path.abspath(REPO_COPY):
        shutil.copy2(settings, REPO_COPY)
        print("      mirrored to %s" % os.path.basename(REPO_COPY))


if __name__ == "__main__":
    main()
