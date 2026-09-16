#!/bin/bash
# Shared bundle builder for local installation and release archives.
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
output=""
universal=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            if [[ $# -lt 2 ]]; then echo "--output requires an app path" >&2; exit 2; fi
            output="$2"; shift 2 ;;
        --universal) universal=true; shift ;;
        -h|--help)
            echo "Usage: scripts/build_app.sh --output '/path/Math Peek.app' [--universal]"
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
if [[ -z "$output" || "$output" != *.app ]]; then
    echo "--output must name a new .app bundle" >&2
    exit 2
fi
if [[ -e "$output" || -L "$output" ]]; then
    echo "Refusing to overwrite existing output: $output" >&2
    exit 1
fi
version=$(/usr/bin/tr -d '[:space:]' < "$root/VERSION")
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must contain a three-part numeric version, such as 1.1.0" >&2
    exit 1
fi
# These engines generate an app-aware SwiftPM resource accessor. The native
# engine only searches beside the executable or in its build directory.
build_engine=xcode
if /usr/bin/xcrun swift build --help | /usr/bin/grep 'swiftbuild' >/dev/null; then
    build_engine=swiftbuild
elif ! /usr/bin/xcrun xcodebuild -version >/dev/null 2>&1; then
    echo "This Swift toolchain needs full Xcode to package app resources correctly." >&2
    echo "Install the prebuilt Math Peek release, use newer Command Line Tools, or select a full Xcode installation." >&2
    exit 1
fi
if $universal; then
    architecture_products=()
    for architecture in arm64 x86_64; do
        scratch="$root/.build/release-universal/$architecture"
        /usr/bin/xcrun swift package --package-path "$root" --scratch-path "$scratch" resolve
        # Raise only this private build checkout's deployment metadata. The app
        # already requires macOS 13; targeting 12 pulls unavailable Intel shims
        # from recent SDKs even though those shims are unnecessary on macOS 13.
        dependency_manifest="$scratch/checkouts/SwiftMath/Package.swift"
        if /usr/bin/grep -F '.macOS("12.0")' "$dependency_manifest" >/dev/null; then
            /bin/chmod u+w "$dependency_manifest"
            /usr/bin/sed -i '' 's/\.macOS("12\.0")/.macOS("13.0")/' "$dependency_manifest"
        fi
        if ! /usr/bin/grep -F '.macOS("13.0")' "$dependency_manifest" >/dev/null; then
            echo "Unexpected SwiftMath deployment metadata; review the pinned dependency before releasing." >&2
            exit 1
        fi
        build_args=(--package-path "$root" -c release --build-system "$build_engine"
            --scratch-path "$scratch" --arch "$architecture")
        /usr/bin/xcrun swift build "${build_args[@]}"
        architecture_products+=("$(/usr/bin/xcrun swift build "${build_args[@]}" --show-bin-path)")
    done
    build="${architecture_products[0]}"
else
    build_args=(--package-path "$root" -c release --build-system "$build_engine")
    /usr/bin/xcrun swift build "${build_args[@]}"
    build=$(/usr/bin/xcrun swift build "${build_args[@]}" --show-bin-path)
fi

contents="$output/Contents"
resources="$contents/Resources"
/bin/mkdir -p "$contents/MacOS" "$resources"
if $universal; then
    for executable in MathPeek MathPeekCLI; do
        /usr/bin/lipo -create "${architecture_products[0]}/$executable" "${architecture_products[1]}/$executable" \
            -output "$contents/MacOS/$executable"
    done
else
    /bin/cp "$build/MathPeek" "$build/MathPeekCLI" "$contents/MacOS/"
fi
/bin/cp "$root/assets/Info.plist" "$contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$version" "$contents/Info.plist"
/bin/cp "$root/assets/MathPeek.icns" "$resources/MathPeek.icns"
/bin/cp "$root/licenses/SwiftMath-LICENSE" "$resources/SwiftMath-LICENSE"
/usr/bin/rsync -a --exclude='*.py' --exclude='*.pyc' --exclude='__pycache__' --exclude='.DS_Store' \
    "$build/SwiftMath_SwiftMath.bundle/" "$resources/SwiftMath_SwiftMath.bundle/"
/usr/bin/rsync -a --exclude='*.test.js' --exclude='*.test.cjs' --exclude='hover.*' \
    "$root/web/" "$resources/web/"

sign_args=(--force --sign "${DEVELOPER_ID_APPLICATION:--}")
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" && "$DEVELOPER_ID_APPLICATION" != "-" ]]; then
    sign_args+=(--options runtime --timestamp)
fi
/usr/bin/codesign "${sign_args[@]}" "$contents/MacOS/MathPeekCLI"
/usr/bin/codesign "${sign_args[@]}" --deep "$output"
/usr/bin/codesign --verify --deep --strict "$output"
if $universal; then
    for architecture in arm64 x86_64; do
        /usr/bin/lipo "$contents/MacOS/MathPeek" -verify_arch "$architecture"
        /usr/bin/lipo "$contents/MacOS/MathPeekCLI" -verify_arch "$architecture"
    done
fi
echo "Built Math Peek $version: $output"
