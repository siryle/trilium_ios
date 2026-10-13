#!/usr/bin/env python3
"""Generate the native Xcode project using only the Python standard library.

Run after source checkout: Swift files are discovered on every invocation, so the
committed project never prevents a newly added source or test from entering CI.
"""
from __future__ import annotations

import hashlib
import json
import plistlib
import struct
import zlib
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "TriliumPocket.xcodeproj"
APP = "TriliumPocket"


def identifier(key: str) -> str:
    return hashlib.sha256(key.encode()).hexdigest()[:24].upper()


def quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def png_icon() -> bytes:
    """Draw a crisp, opaque 1024px notebook icon without imaging dependencies."""
    size = 1024
    rows = bytearray()
    for y in range(size):
        rows.append(0)  # PNG scanline filter: none.
        for x in range(size):
            color = (22, 39, 60)
            if 248 <= x < 780 and 176 <= y < 848:
                color = (237, 245, 246)
            if 248 <= x < 318 and 176 <= y < 848:
                color = (60, 185, 166)
            if 366 <= x < 690 and any(a <= y < a + 26 for a in (318, 422, 526)):
                color = (57, 87, 112)
            if 366 <= x < 586 and 630 <= y < 656:
                color = (57, 87, 112)
            rows.extend(color)
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


def ensure_resources() -> None:
    """Create initial assets only; preserve hand-edited resources thereafter."""
    resources = ROOT / APP / "Resources"
    resources.mkdir(parents=True, exist_ok=True)
    info = resources / "Info.plist"
    if not info.exists():
        info.write_bytes(plistlib.dumps({
            "CFBundleDevelopmentRegion": "$(DEVELOPMENT_LANGUAGE)",
            "CFBundleDisplayName": APP,
            "CFBundleExecutable": "$(EXECUTABLE_NAME)",
            "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "$(PRODUCT_NAME)",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "$(MARKETING_VERSION)",
            "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
            "LSRequiresIPhoneOS": True,
            "NSLocalNetworkUsageDescription": "连接你配置的局域网 Trilium 或 AI 服务，读取和保存笔记。",
            "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
            "UILaunchScreen": {},
            "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
            # App-layer URL validation requires explicit HTTP opt-in. Do not add
            # granular ATS keys: iOS ignores NSAllowsArbitraryLoads if present.
            "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
        }, sort_keys=False))
    catalog = resources / "Assets.xcassets"
    icon = catalog / "AppIcon.appiconset"
    icon.mkdir(parents=True, exist_ok=True)
    defaults = {
        catalog / "Contents.json": {"info": {"author": "xcode", "version": 1}},
        icon / "Contents.json": {"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}},
    }
    for path, data in defaults.items():
        if not path.exists():
            path.write_text(json.dumps(data, indent=2) + "\n")
    if not (icon / "AppIcon.png").exists():
        (icon / "AppIcon.png").write_bytes(png_icon())


class Project:
    def __init__(self) -> None:
        self.objects: dict[str, tuple[str, str]] = {}

    def add(self, key: str, isa: str, fields: str) -> str:
        ident = identifier(key)
        if ident in self.objects:
            raise ValueError(f"Duplicate project object: {key}")
        self.objects[ident] = (isa, fields)
        return ident

    @staticmethod
    def refs(items: list[str]) -> str:
        return "(" + ", ".join(items) + ("," if items else "") + ")"

    def file(self, path: Path) -> str:
        relative = path.relative_to(ROOT).as_posix()
        types = {".swift": "sourcecode.swift", ".plist": "text.plist.xml", ".xcassets": "folder.assetcatalog", ".json": "text.json", ".md": "net.daringfireball.markdown", ".strings": "text.plist.strings", ".xcstrings": "text.json.xcstrings"}
        return self.add(f"file:{relative}", "PBXFileReference", f"lastKnownFileType = {quote(types.get(path.suffix, 'file'))}; name = {quote(path.name)}; path = {quote(relative)}; sourceTree = SOURCE_ROOT;")

    def group(self, path: Path, sources: list[str], resources: list[str], *, test: bool = False) -> str:
        children = []
        if path.exists():
            for child in sorted(path.iterdir(), key=lambda item: item.name):
                if child.name.startswith("."):
                    continue
                if child.is_dir() and child.suffix != ".xcassets":
                    children.append(self.group(child, sources, resources, test=test))
                    continue
                ref = self.file(child)
                children.append(ref)
                relative = child.relative_to(ROOT).as_posix()
                if child.suffix == ".swift":
                    sources.append(self.add(f"source:{relative}", "PBXBuildFile", f"fileRef = {ref};"))
                elif not test and child.name != "Info.plist":
                    resources.append(self.add(f"resource:{relative}", "PBXBuildFile", f"fileRef = {ref};"))
        return self.add(f"group:{path.relative_to(ROOT).as_posix()}", "PBXGroup", f"children = {self.refs(children)}; name = {quote(path.name)}; sourceTree = \"<group>\";")

    def phase(self, key: str, isa: str, files: list[str]) -> str:
        return self.add(key, isa, f"buildActionMask = 2147483647; files = {self.refs(files)}; runOnlyForDeploymentPostprocessing = 0;")

    def configs(self, key: str, base: dict[str, str], *, project: bool = False) -> str:
        refs = []
        for mode in ("Debug", "Release"):
            settings = dict(base)
            if project:
                settings.update({"SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O", "DEBUG_INFORMATION_FORMAT": "dwarf" if mode == "Debug" else "dwarf-with-dsym", "SWIFT_COMPILATION_MODE": "singlefile" if mode == "Debug" else "wholemodule", "ENABLE_TESTABILITY": "YES" if mode == "Debug" else "NO"})
                if mode == "Debug":
                    settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG $(inherited)"
            fields = " ".join(f"{name} = {quote(value)};" for name, value in sorted(settings.items()))
            refs.append(self.add(f"config:{key}:{mode}", "XCBuildConfiguration", f"buildSettings = {{ {fields} }}; name = {mode};"))
        return self.add(f"configs:{key}", "XCConfigurationList", f"buildConfigurations = {self.refs(refs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")

    def write(self, project_id: str) -> None:
        lines = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {};", "\tobjectVersion = 56;", "\tobjects = {"]
        for ident, (isa, fields) in sorted(self.objects.items(), key=lambda item: (item[1][0], item[0])):
            lines.append(f"\t\t{ident} = {{ isa = {isa}; {fields} }};")
        lines.extend(["\t};", f"\trootObject = {project_id};", "}", ""])
        PROJECT.mkdir(parents=True, exist_ok=True)
        (PROJECT / "project.pbxproj").write_text("\n".join(lines))


def generate() -> None:
    ensure_resources()
    p = Project()
    app_sources: list[str] = []
    test_sources: list[str] = []
    resources: list[str] = []
    app_group = p.group(ROOT / APP, app_sources, resources)
    tests_group = p.group(ROOT / "tests" / "TriliumPocketTests", test_sources, [], test=True)
    app_product = p.add("product:app", "PBXFileReference", 'explicitFileType = wrapper.application; includeInIndex = 0; path = TriliumPocket.app; sourceTree = BUILT_PRODUCTS_DIR;')
    test_product = p.add("product:test", "PBXFileReference", 'explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = TriliumPocketTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
    products = p.add("group:products", "PBXGroup", f"children = {p.refs([app_product, test_product])}; name = Products; sourceTree = \"<group>\";")
    main_group = p.add("group:root", "PBXGroup", f"children = {p.refs([app_group, tests_group, products])}; sourceTree = \"<group>\";")
    project_config = p.configs("project", {"CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "SWIFT_VERSION": "5.0", "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "TARGETED_DEVICE_FAMILY": "1", "ENABLE_USER_SCRIPT_SANDBOXING": "YES"}, project=True)
    app_config = p.configs("app", {"ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "1.0.0", "GENERATE_INFOPLIST_FILE": "NO", "INFOPLIST_FILE": "TriliumPocket/Resources/Info.plist", "PRODUCT_BUNDLE_IDENTIFIER": "app.trilium.pocket", "PRODUCT_NAME": "$(TARGET_NAME)", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks", "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO", "ENABLE_PREVIEWS": "YES"})
    test_config = p.configs("test", {"GENERATE_INFOPLIST_FILE": "YES", "PRODUCT_BUNDLE_IDENTIFIER": "app.trilium.pocket.tests", "PRODUCT_NAME": "$(TARGET_NAME)", "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/TriliumPocket.app/TriliumPocket", "BUNDLE_LOADER": "$(TEST_HOST)", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @loader_path/Frameworks", "SKIP_INSTALL": "YES"})
    app_phases = [p.phase("phase:app:sources", "PBXSourcesBuildPhase", app_sources), p.phase("phase:app:frameworks", "PBXFrameworksBuildPhase", []), p.phase("phase:app:resources", "PBXResourcesBuildPhase", resources)]
    test_phases = [p.phase("phase:test:sources", "PBXSourcesBuildPhase", test_sources), p.phase("phase:test:frameworks", "PBXFrameworksBuildPhase", [])]
    app_target = p.add("target:app", "PBXNativeTarget", f"buildConfigurationList = {app_config}; buildPhases = {p.refs(app_phases)}; buildRules = (); dependencies = (); name = {APP}; productName = {APP}; productReference = {app_product}; productType = \"com.apple.product-type.application\";")
    project_id = identifier("project")
    proxy = p.add("proxy:app", "PBXContainerItemProxy", f"containerPortal = {project_id}; proxyType = 1; remoteGlobalIDString = {app_target}; remoteInfo = {APP};")
    dependency = p.add("dependency:app", "PBXTargetDependency", f"target = {app_target}; targetProxy = {proxy};")
    test_target = p.add("target:test", "PBXNativeTarget", f"buildConfigurationList = {test_config}; buildPhases = {p.refs(test_phases)}; buildRules = (); dependencies = {p.refs([dependency])}; name = TriliumPocketTests; productName = TriliumPocketTests; productReference = {test_product}; productType = \"com.apple.product-type.bundle.unit-test\";")
    p.add("project", "PBXProject", f"attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; TargetAttributes = {{ {app_target} = {{ CreatedOnToolsVersion = 16.0; }}; {test_target} = {{ CreatedOnToolsVersion = 16.0; TestTargetID = {app_target}; }}; }}; }}; buildConfigurationList = {project_config}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, \"zh-Hans\"); mainGroup = {main_group}; productRefGroup = {products}; projectDirPath = \"\"; projectRoot = \"\"; targets = {p.refs([app_target, test_target])};")
    p.write(project_id)
    scheme_dir = PROJECT / "xcshareddata" / "xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    def reference(target: str, product: str, name: str) -> str:
        return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{escape(product)}" BlueprintName="{escape(name)}" ReferencedContainer="container:TriliumPocket.xcodeproj"/>'
    app_ref = reference(app_target, "TriliumPocket.app", APP)
    test_ref = reference(test_target, "TriliumPocketTests.xctest", "TriliumPocketTests")
    (scheme_dir / "TriliumPocket.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry>
      <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{test_ref}</BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables><TestableReference skipped="NO">{test_ref}</TestableReference></Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
    print(f"Generated {PROJECT.name}: {len(app_sources)} app sources, {len(test_sources)} test sources, {len(resources)} resources")


if __name__ == "__main__":
    generate()
