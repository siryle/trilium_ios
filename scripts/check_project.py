#!/usr/bin/env python3
"""Check project references and embedded JavaScript without building or a browser."""
from __future__ import annotations

import json
import plistlib
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
project = (ROOT / "TriliumPocket.xcodeproj/project.pbxproj").read_text()
objects = set(re.findall(r"^\s*([0-9A-F]{24}) = \{ isa =", project, re.MULTILINE))
references = set(re.findall(r"\b[0-9A-F]{24}\b", project))
assert references <= objects, f"Missing PBX objects: {references - objects}"
for folder in ("TriliumPocket", "tests/TriliumPocketTests"):
    for source in (ROOT / folder).rglob("*.swift"):
        relative = source.relative_to(ROOT).as_posix()
        assert f'path = "{relative}";' in project, f"Source missing from project: {relative}"
        assert source.stat().st_size > 0, f"Empty source: {relative}"

scheme = ET.parse(ROOT / "TriliumPocket.xcodeproj/xcshareddata/xcschemes/TriliumPocket.xcscheme")
for reference in scheme.findall(".//BuildableReference"):
    assert reference.attrib["BlueprintIdentifier"] in objects
assert scheme.findall(".//TestableReference"), "No test target in shared scheme"

with (ROOT / "TriliumPocket/Resources/Info.plist").open("rb") as file:
    info = plistlib.load(file)
assert info["LSRequiresIPhoneOS"] is True
for asset in (ROOT / "TriliumPocket/Resources/Assets.xcassets").rglob("Contents.json"):
    contents = json.loads(asset.read_text())
    for image in contents.get("images", []):
        if "filename" in image:
            assert (asset.parent / image["filename"]).is_file()

plutil = shutil.which("plutil")
if plutil:
    subprocess.run([plutil, "-lint", str(ROOT / "TriliumPocket.xcodeproj/project.pbxproj"),
                    str(ROOT / "TriliumPocket/Resources/Info.plist")], check=True)

swift = (ROOT / "TriliumPocket/Features/NoteWebView.swift").read_text()
script = re.search(r"<script>\n(.*?)</script>", swift, re.DOTALL).group(1)
# Swift multiline string escapes used by the editor, decoded once for JavaScript.
script = re.sub(r'\\([\\"nrt])', lambda match: {"\\": "\\", '"': '"', "n": "\n", "r": "\r", "t": "\t"}[match[1]], script)
node = shutil.which("node")
if node:
    subprocess.run([node, "--check"], input=script, text=True, check=True)
    subprocess.run([node, str(ROOT / "scripts/check_editor_history.cjs")], check=True)
    subprocess.run([node, str(ROOT / "scripts/check_markdown_tables.cjs")], check=True)
    subprocess.run([node, str(ROOT / "scripts/check_markdown_layout.cjs")], check=True)
else:
    print("Node unavailable: embedded JavaScript syntax check skipped")

print(f"Static checks passed: {len(objects)} PBX objects, shared test scheme, plist, assets and editor JavaScript")
print("Swift compilation and XCTest must run in GitHub Actions; these checks do not replace them.")
