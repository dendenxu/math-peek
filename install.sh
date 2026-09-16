#!/bin/bash
# Build and install the complete native app and command-line launcher.
set -euo pipefail

if [[ $# -gt 0 ]]; then
    if [[ $# -eq 1 && ( "$1" == "--help" || "$1" == "-h" ) ]]; then
        echo "Usage: ./install.sh"
        echo "Installs Math Peek and math-peek with native terminal discovery and capture."
        exit 0
    fi
    echo "Usage: ./install.sh (no Python or separate iTerm integration is needed)" >&2
    exit 2
fi

root=$(cd -- "$(dirname -- "$0")" && pwd -P)
app_parent="$HOME/Applications"
app="$app_parent/Math Peek.app"
command_path="$HOME/.local/bin/math-peek"
identifier="local.mathpeek.preview"

if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then
    echo "Math Peek requires macOS 13 or later." >&2
    exit 1
fi
if ! /usr/bin/xcrun --find swift >/dev/null 2>&1; then
    echo "Install Xcode Command Line Tools first: xcode-select --install" >&2
    exit 1
fi
if [[ -e "$command_path" || -L "$command_path" ]]; then
    if [[ ! "$command_path" -ef "$root/bin/math-peek" &&
          ! "$command_path" -ef "$app/Contents/MacOS/MathPeekCLI" ]]; then
        echo "Another command already occupies $command_path" >&2
        exit 1
    fi
fi
if [[ -e "$app" || -L "$app" ]]; then
    if [[ -L "$app" || ! -f "$app/Contents/Info.plist" ]] ||
       [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)" != "$identifier" ]]; then
        echo "Another app already occupies $app" >&2
        exit 1
    fi
fi
if /usr/bin/pgrep -x MathPeek >/dev/null; then
    echo "Quit Math Peek from its menu-bar menu, then run ./install.sh again." >&2
    exit 1
fi

/bin/mkdir -p "$app_parent" "$(dirname -- "$command_path")"
staging=$(/usr/bin/mktemp -d "$app_parent/.math-peek-install.XXXXXX")
cleanup() {
    if [[ -d "$staging/Previous Math Peek.app" && ! -d "$app" ]]; then
        echo "The previous app is preserved at $staging/Previous Math Peek.app" >&2
    else
        /bin/rm -rf -- "$staging"
    fi
}
trap cleanup EXIT
staged_app="$staging/Math Peek.app"
"$root/scripts/build_app.sh" --output "$staged_app"

# Swap only after the complete replacement has built and signed successfully.
if /usr/bin/pgrep -x MathPeek >/dev/null; then
    echo "Math Peek started during installation. Quit it and run ./install.sh again." >&2
    exit 1
fi
if [[ -d "$app" ]]; then
    /bin/mv "$app" "$staging/Previous Math Peek.app"
fi
if ! /bin/mv "$staged_app" "$app"; then
    if [[ -d "$staging/Previous Math Peek.app" ]]; then
        /bin/mv "$staging/Previous Math Peek.app" "$app"
    fi
    exit 1
fi
if [[ -L "$command_path" && "$command_path" -ef "$root/bin/math-peek" ]]; then
    /bin/ln -s "$app/Contents/MacOS/MathPeekCLI" "$staging/math-peek"
    /bin/mv -f "$staging/math-peek" "$command_path"
elif [[ ! -e "$command_path" && ! -L "$command_path" ]]; then
    /bin/ln -s "$app/Contents/MacOS/MathPeekCLI" "$command_path"
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "Installed: $app"
echo "Command: $command_path"
echo "Open Math Peek to set up Accessibility, hover preview, and launch at login."
echo "Installed terminals are discovered automatically; add custom apps in Terminal Apps."
echo "For cmux, run math-peek connect cmux once inside a local cmux terminal pane."
echo "For experimental Ghostty hover, run math-peek connect ghostty in each local pane; no Ghostty changes are needed."
if [[ -z "${DEVELOPER_ID_APPLICATION:-}" || "$DEVELOPER_ID_APPLICATION" == "-" ]]; then
    echo "This ad-hoc signed build may need Accessibility permission again after an update."
    echo "First try turning Math Peek's Accessibility switch back on in System Settings."
    echo "If the switch is on but Math Peek setup still reports missing permission, remove the old entry,"
    echo "then use + to add $app and enable it. Check the permission status in Math Peek itself."
    echo "No removal is needed if the switch restores access."
fi
