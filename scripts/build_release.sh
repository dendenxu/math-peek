#!/bin/bash
# Build a universal, self-contained app archive without installing it.
set -euo pipefail

if [[ $# -gt 0 ]]; then
    if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
        echo "Usage: scripts/build_release.sh"
        echo "Creates build/release/Math.Peek-VERSION-universal.zip and its SHA256 file."
        echo "Optional: DEVELOPER_ID_APPLICATION and NOTARY_PROFILE for signed/notarized releases."
        exit 0
    fi
    echo "Usage: scripts/build_release.sh" >&2
    exit 2
fi
root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
version=$(/usr/bin/tr -d '[:space:]' < "$root/VERSION")
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must contain a three-part numeric version" >&2
    exit 1
fi
if [[ -n "${NOTARY_PROFILE:-}" && ( -z "${DEVELOPER_ID_APPLICATION:-}" || "$DEVELOPER_ID_APPLICATION" == "-" ) ]]; then
    echo "NOTARY_PROFILE requires a real DEVELOPER_ID_APPLICATION signing identity." >&2
    exit 1
fi
release_dir="$root/build/release"
/bin/mkdir -p "$release_dir"
staging=$(/usr/bin/mktemp -d "$release_dir/.staging.XXXXXX")
trap '/bin/rm -rf -- "$staging"' EXIT
app="$staging/Math Peek.app"
archive_name="Math.Peek-$version-universal.zip"
archive="$release_dir/$archive_name"
"$root/scripts/build_app.sh" --output "$app" --universal
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/$archive_name"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    /usr/bin/xcrun notarytool submit "$staging/$archive_name" --keychain-profile "$NOTARY_PROFILE" --wait
    /usr/bin/xcrun stapler staple "$app"
    /usr/bin/xcrun stapler validate "$app"
    /usr/sbin/spctl --assess --type execute "$app"
    /bin/rm "$staging/$archive_name"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/$archive_name"
    signing_note="This build is Developer ID signed and notarized by Apple."
    signing_note_zh="当前发布包已使用 Developer ID 签名，并经过 Apple 公证。"
elif [[ -n "${DEVELOPER_ID_APPLICATION:-}" && "$DEVELOPER_ID_APPLICATION" != "-" ]]; then
    signing_note="This build is Developer ID signed but is not notarized. macOS may require approval in System Settings > Privacy & Security > Open Anyway on first launch."
    signing_note_zh="当前发布包已使用 Developer ID 签名，但未经过 Apple 公证；首次打开如果被拦截，请在“系统设置 → 隐私与安全性”选择“仍要打开”。"
else
    signing_note="This build is ad-hoc signed and is not notarized. macOS may require approval in System Settings > Privacy & Security > Open Anyway on first launch."
    signing_note_zh="当前发布包使用临时签名，未经过 Apple 公证；首次打开如果被拦截，请在“系统设置 → 隐私与安全性”选择“仍要打开”。"
fi
/bin/mv -f "$staging/$archive_name" "$archive"
(
    cd "$release_dir"
    /usr/bin/shasum -a 256 "$archive_name" > "$archive_name.sha256"
)
cat > "$release_dir/RELEASE_NOTES.md" <<NOTES
Math Peek ${version}：独立的 macOS 菜单栏公式预览应用。

- 预编译 universal 应用，同时支持 Apple Silicon 和 Intel，要求 macOS 13 或更新版本。
- 解压 ZIP，把 Math Peek.app 拖到“应用程序”，打开后允许辅助功能权限。
- 安装器、CLI、终端取字和悬停渲染均为原生实现，不需要 Python，不使用 OCR。
- 添加终端后立即启用，无需刷新或重启；设置页展示终端列表与使用说明。
- iTerm2 / Terminal 支持原生悬停；Ghostty 1.3.1 / cmux 0.64.9 缺少所需位置接口，暂不支持悬停。自动发现不代表接口兼容。
- 修复带框公式、显示裁切和圆角背景；诊断写盘及登录状态查询在后台进行。
- 中文主 README、英文说明和实际悬停演示 GIF。

Homebrew 安装：

\`\`\`sh
brew install --cask dendenxu/tap/math-peek
open -a "Math Peek"
\`\`\`

若新版 Homebrew 提示 untrusted tap，先运行
\`brew trust --cask dendenxu/tap/math-peek\`，然后重试安装。

$signing_note_zh
随附 SHA256 校验文件。应用内包含命令行工具 Math Peek.app/Contents/MacOS/MathPeekCLI。

---

Standalone native macOS formula preview, with universal binaries for Apple Silicon and Intel.
No Python or OCR. Native hover requires terminal Accessibility text and character positions;
current Ghostty and cmux releases do not expose enough position data for hover.

$signing_note
NOTES
echo "$signing_note"
echo "Archive: $archive"
echo "SHA256: $archive.sha256"
