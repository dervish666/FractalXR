#!/usr/bin/env python3
"""Check the template override and the manifest dumped from an exported APK."""
import difflib
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET
import zipfile


def template(archive, manifest):
    with zipfile.ZipFile(archive) as source:
        original = source.read("src/main/AndroidManifest.xml").decode()
    tracked = Path(manifest).read_bytes().decode()
    override = '''    <uses-feature
        android:name="android.hardware.vr.headtracking"
        android:required="true"
        android:version="1"
        tools:replace="android:required" />

'''
    if tracked.count(override) != 1:
        raise ValueError("tracked manifest must contain exactly the headtracking override block")
    stripped = tracked.replace(override, "", 1)
    if stripped != original:
        sys.stderr.writelines(difflib.unified_diff(
            original.splitlines(True), stripped.splitlines(True),
            fromfile="installed Godot template", tofile="tracked manifest without headtracking"))
        raise ValueError("AndroidManifest.xml drift beyond headtracking override; reconcile with installed template")
    print("MANIFEST TEMPLATE PASS headtracking-only override")


def apk(dump):
    # aapt2 xmltree prints element nesting through indentation and decoded attribute values.
    stack = []
    root = None
    for line in Path(dump).read_text().splitlines():
        text = line.lstrip()
        indent = len(line) - len(text)
        if text.startswith("E: "):
            node = ET.Element(text.split()[1])
            while stack and stack[-1][0] >= indent:
                stack.pop()
            if stack:
                stack[-1][1].append(node)
            else:
                root = node
            stack.append((indent, node))
        elif text.startswith("A: "):
            # Raw string annotations follow the decoded value.
            attr = re.match(r'A: (?:\S+:)?(\w+)(?:\([^)]*\))?=("[^"]*"|\S+)', text)
            if attr and stack:
                stack[-1][1].set(attr[1], attr[2].strip('"'))
    if root is None or root.tag != "manifest":
        raise ValueError("aapt2 did not dump a manifest")
    features = [n for n in root.findall("uses-feature")
                if n.get("name") == "android.hardware.vr.headtracking"]
    if len(features) != 1 or features[0].get("required") != "true":
        raise ValueError("APK requires android.hardware.vr.headtracking required=true")
    package = root.get("package", "")

    def qualified(name):
        return package + name if name.startswith(".") else (name if "." in name else package + "." + name)

    activities = {qualified(n.get("name", "")): n for n in root.findall("application/activity")}
    launchers = []
    for component in root.findall("application/*"):
        if component.tag not in ("activity", "activity-alias"):
            continue
        if any(f.find("action[@name='android.intent.action.MAIN']") is not None
               for f in component.findall("intent-filter")):
            target = component.get("targetActivity") or component.get("name", "")
            launchers.append(activities.get(qualified(target)))
    if not launchers or any(n is None or n.get("excludeFromRecents") != "true" for n in launchers):
        raise ValueError("APK launch activity requires excludeFromRecents=true")
    print("MANIFEST APK PASS android.hardware.vr.headtracking required=true launch activity excludeFromRecents=true")


if __name__ == "__main__":
    try:
        if len(sys.argv) == 4 and sys.argv[1] == "template":
            template(*sys.argv[2:])
        elif len(sys.argv) == 3 and sys.argv[1] == "apk":
            apk(*sys.argv[2:])
        else:
            raise ValueError("usage: manifest_check.py template android_source.zip AndroidManifest.xml | apk aapt2-dump.txt")
    except (OSError, ValueError, zipfile.BadZipFile, KeyError) as error:
        sys.exit(f"[build] manifest check failed: {error}")
