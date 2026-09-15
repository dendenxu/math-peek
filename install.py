#!/usr/bin/env python3
"""Build and install Math Peek on this Mac. Requires Xcode Command Line Tools."""

import argparse
from pathlib import Path
import plistlib
import platform
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parent
APP = Path.home() / "Applications/Math Peek.app"
RUNTIME = Path.home() / "Library/Application Support/Math Peek/runtime"
IDENTIFIER = "local.mathpeek.preview"


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-iterm", action="store_true", help="install native hover and reader without optional Python capture")
    args = parser.parse_args()
    cli = Path.home() / ".local/bin/math-peek"
    if (cli.exists() or cli.is_symlink()) and cli.resolve() != (ROOT / "bin/math-peek").resolve():
        parser.error("another command already occupies " + str(cli))
    if APP.exists():
        info = APP / "Contents/Info.plist"
        if not info.exists() or plistlib.loads(info.read_bytes()).get("CFBundleIdentifier") != IDENTIFIER:
            parser.error("another app already occupies " + str(APP))
    build = ROOT / "build"
    build.mkdir(exist_ok=True)
    run("xcrun", "swiftc", "-O", "-target", platform.machine() + "-apple-macos13.0",
        *sorted((ROOT / "native").glob("*.swift")), "-o", build / "MathPeek",
        "-framework", "AppKit", "-framework", "WebKit", "-framework", "Carbon", "-framework", "ServiceManagement")
    if not args.skip_iterm:
        if not (RUNTIME / "bin/python3").exists():
            run(sys.executable, "-m", "venv", RUNTIME)
        run(RUNTIME / "bin/python3", "-m", "pip", "install", "iterm2==2.23", "protobuf==7.36.1", "websockets==17.1")
    contents = APP / "Contents"
    (contents / "MacOS").mkdir(parents=True, exist_ok=True)
    resources = contents / "Resources"
    resources.mkdir(exist_ok=True)
    shutil.copy2(build / "MathPeek", contents / "MacOS/MathPeek")
    shutil.copy2(ROOT / "assets/MathPeek.icns", resources / "MathPeek.icns")
    for name in ["web", "integration"]:
        shutil.copytree(ROOT / name, resources / name, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns("__pycache__", "*.test.js", "*.test.cjs"))
    metadata = {
        "CFBundleIdentifier": IDENTIFIER,
        "CFBundleExecutable": "MathPeek",
        "CFBundleName": "Math Peek",
        "CFBundleDisplayName": "Math Peek",
        "CFBundlePackageType": "APPL",
        "CFBundleIconFile": "MathPeek.icns",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "1.0",
        "LSMinimumSystemVersion": "13.0",
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
        "NSAppleEventsUsageDescription": "Read selected or visible iTerm2 text for local formula preview.",
        "CFBundleURLTypes": [{"CFBundleURLName": "Math Peek Actions", "CFBundleURLSchemes": ["mathpeek"]}],
        "CFBundleDocumentTypes": [{
            "CFBundleTypeName": "Math Peek Text",
            "CFBundleTypeRole": "Viewer",
            "LSHandlerRank": "Alternate",
            "LSItemContentTypes": ["public.plain-text", "net.daringfireball.markdown", "public.tex"],
            "CFBundleTypeExtensions": ["txt", "md", "markdown", "tex"],
        }],
        "NSServices": [{
            "NSMenuItem": {"default": "Preview with Math Peek"},
            "NSMessage": "previewSelection",
            "NSPortName": "Math Peek",
            "NSSendTypes": ["public.utf8-plain-text", "NSStringPboardType"],
        }],
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(metadata))
    run("codesign", "--force", "--deep", "--sign", "-", APP)
    cli.parent.mkdir(exist_ok=True, parents=True)
    if not cli.exists() and not cli.is_symlink():
        cli.symlink_to(ROOT / "bin/math-peek")
    (ROOT / "bin/math-peek").chmod(0o755)
    run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-f", APP)
    print("Installed:", APP)
    print("Command:", cli)
    print("Open Math Peek to set up Accessibility, hover preview, and launch at login.")
    print("After setup it stays in the menu bar; the reading window is optional.")


if __name__ == "__main__":
    main()
