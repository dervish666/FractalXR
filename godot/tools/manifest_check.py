#!/usr/bin/env python3
"""Check the template override and the manifest dumped from an exported APK."""
import difflib
from pathlib import Path
import re
import struct
import sys
import tempfile
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


def apk(dump, archive):
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
    splash = root.findall("application/meta-data[@name='com.oculus.ossplash']")
    if len(splash) != 1 or splash[0].get("value") != "true":
        raise ValueError("APK requires application com.oculus.ossplash=true")
    splash_type = root.findall("application/meta-data[@name='com.oculus.ossplash.type']")
    if len(splash_type) != 1 or splash_type[0].get("value") != "mono":
        raise ValueError("APK requires mono system splash")
    splash_color = root.findall("application/meta-data[@name='com.oculus.ossplash.colorspace']")
    if len(splash_color) != 1 or splash_color[0].get("value") != "Rec.709":
        raise ValueError("APK requires Rec.709 system splash")
    with zipfile.ZipFile(archive) as source:
        png = source.read("assets/vr_splash.png")
    expected = Path(__file__).resolve().parents[1] / "art/icon_512.png"
    if png != expected.read_bytes():
        raise ValueError("APK splash must match art/icon_512.png")
    if png[:8] != b"\x89PNG\r\n\x1a\n" or png[12:16] != b"IHDR":
        raise ValueError("APK splash must be PNG")
    width, height = struct.unpack(">II", png[16:24])
    if (width, height) != (512, 512):
        raise ValueError("APK splash must be 512x512")
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
    print("MANIFEST APK PASS android.hardware.vr.headtracking required=true launch activity excludeFromRecents=true ossplash=true mono colorspace=Rec.709 PNG=512x512")


def controls(dump, archive):
    apk(dump, archive)
    original = Path(dump).read_text()
    with tempfile.TemporaryDirectory() as directory:
        bad = Path(directory) / "manifest.txt"
        for label, old, new in [
            ("wrong-colorspace", "Rec.709", "P3"),
            ("missing-colorspace", "com.oculus.ossplash.colorspace", "com.oculus.unused.colorspace"),
        ]:
            if old not in original:
                raise ValueError(f"cannot construct {label} control")
            bad.write_text(original.replace(old, new))
            try:
                apk(bad, archive)
            except ValueError as error:
                if "requires Rec.709 system splash" not in str(error):
                    raise
            else:
                raise ValueError(f"accepted {label} control")
    print("MANIFEST CONTROLS PASS rejected=2 wrong-colorspace=FAIL missing-colorspace=FAIL")


if __name__ == "__main__":
    try:
        if len(sys.argv) == 4 and sys.argv[1] == "template":
            template(*sys.argv[2:])
        elif len(sys.argv) == 4 and sys.argv[1] == "apk":
            apk(*sys.argv[2:])
        elif len(sys.argv) == 4 and sys.argv[1] == "controls":
            controls(*sys.argv[2:])
        else:
            raise ValueError("usage: manifest_check.py template android_source.zip AndroidManifest.xml | apk|controls aapt2-dump.txt app.apk")
    except (OSError, ValueError, zipfile.BadZipFile, KeyError) as error:
        sys.exit(f"[build] manifest check failed: {error}")
