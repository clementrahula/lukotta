#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Keep translations/context/strings.json in step with the catalogue.

    ./scripts/context-skeleton.py            report what is missing
    ./scripts/context-skeleton.py --write    add an entry for every new string

A string with no context is a string a translator has to guess at, so every
catalogue key has an entry here. The screen is derived from the file the string
was found in; the sentence explaining it is written by hand.
"""
import json, pathlib, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONTEXT = ROOT / "translations" / "context" / "strings.json"

# Which screen a file's strings belong to. A file that shows on several screens
# is listed here by the one it belongs to; a string that appears on more than
# one carries the others in its own entry.
SCREEN_OF_FILE = {
    "HelpSheet.swift": "help", "UnlockView.swift": "unlock", "LukottaApp.swift": "menus",
    "DriveListView.swift": "drive-list", "SettingsView.swift": "settings",
    "PermissionView.swift": "welcome", "AppModel.swift": "notices",
    "Diagnosis.swift": "diagnosis", "ReportIssueSheet.swift": "report",
    "OpenDriveSheet.swift": "open-drive", "UninstallView.swift": "uninstall",
    "Uninstall.swift": "uninstall", "ImageOpenSheet.swift": "open-image",
    "WorkingView.swift": "working", "MountStage.swift": "working",
    "DiskImage.swift": "formats", "Qcow2.swift": "formats", "Vhd.swift": "formats",
    "Vhdx.swift": "formats", "Vmdk.swift": "formats", "Vdi.swift": "formats",
    "ContentView.swift": "notices", "MountedView.swift": "mounted",
    "FailureView.swift": "failure", "Diagnostics.swift": "report",
    "Appearance.swift": "settings", "LoginItem.swift": "settings",
    "Drives.swift": "drive-list", "SharedViews.swift": "notices",
    "EngineStatus.swift": "notices", "MountScript.swift": "notices",
    "VolumeSpace.swift": "notices", "Snapshots.swift": "drive-list",
    "Localisation.swift": "notices", "Language.swift": "settings",
}


def placeholders(key):
    out = []
    for token in ("%@", "%lld"):
        for _ in range(key.count(token)):
            out.append({"token": token, "is": ""})
    return out


def main():
    keys = json.loads(
        subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "extract-strings.py")],
            capture_output=True, text=True).stdout)
    catalogue = json.loads((ROOT / "resources" / "Localizable.xcstrings").read_text())["strings"]
    context = json.loads(CONTEXT.read_text()) if CONTEXT.exists() else {"strings": {}}
    entries = context.setdefault("strings", {})

    missing = [k for k in catalogue if k not in entries]
    stale = [k for k in entries if k not in catalogue]
    blank = [k for k, e in entries.items() if not e.get("context")]

    if "--write" in sys.argv:
        for k in missing:
            entries[k] = {
                "screens": [SCREEN_OF_FILE.get(keys.get(k, "").split("/")[-1], "notices")],
                "context": "",
                "placeholders": placeholders(k),
            }
        for k in stale:
            del entries[k]
        context["strings"] = dict(sorted(entries.items()))
        CONTEXT.write_text(json.dumps(context, indent=2, ensure_ascii=False) + "\n")
        print(f"  {len(entries)} entries ({len(missing)} added, {len(stale)} removed)")
    else:
        print(f"  {len(entries)} entries, {len(missing)} missing, {len(stale)} stale, "
              f"{len(blank)} without context")
    return 1 if (missing or stale or blank) else 0


if __name__ == "__main__":
    sys.exit(main())
