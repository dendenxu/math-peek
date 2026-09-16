<p align="center"><img src="assets/icon.png" width="112" alt="Math Peek 图标"></p>

# Math Peek

**鼠标移到终端里的 LaTeX 上，直接看公式。**

独立的 macOS 菜单栏应用。不用框选、复制，也不用在 SSH 服务器或 tmux 里安装东西。
安装器、命令行工具、取字和悬停渲染均为原生实现，**不需要 Python**。

[English](README.en.md) · [下载最新版](https://github.com/dendenxu/math-peek/releases/latest)

![Math Peek 实际操作：悬停显示行内公式、带框分式和多行公式，移开后收起](screenshots/hover-demo.gif)

## 安装

### Homebrew

```sh
brew install --cask dendenxu/tap/math-peek
open -a "Math Peek"
```

安装预编译应用及 `math-peek` 命令，不需要 Swift 编译器或 Python。
更新时先从菜单栏退出 Math Peek，再运行：

```sh
brew upgrade --cask dendenxu/tap/math-peek
```

### 直接下载

从 [GitHub Releases](https://github.com/dendenxu/math-peek/releases/latest) 下载
`Math.Peek-1.1.0-universal.zip`，解压后把 `Math Peek.app` 拖到“应用程序”，然后打开。
同一个应用支持 Apple Silicon 和 Intel Mac，要求 macOS 13 或更新版本。

当前发布包已做本地签名，但**尚未经过 Apple 公证**。如果首次打开被 macOS 拦截，
请到“系统设置 → 隐私与安全性”确认该应用并选择“仍要打开”。Release 附带 SHA256 校验文件。

### 从源码安装

需要 Swift 5.9 或更新版本。新版 Xcode Command Line Tools 可直接构建；
较旧的 Swift 工具链需要完整 Xcode 才能正确打包应用资源，安装器会检查并提示。
第一次构建会下载锁定版本的 SwiftMath 依赖。

```sh
git clone https://github.com/dendenxu/math-peek.git
cd math-peek
./install.sh
open "$HOME/Applications/Math Peek.app"
```

默认安装完整功能，并自动发现已安装的终端，**包括 iTerm2**；没有 `--skip-iterm`，
也不需要单独安装终端插件或开启 iTerm2 Python API。
源码安装将应用放在 `~/Applications/Math Peek.app`，命令放在 `~/.local/bin/math-peek`。

## 第一次使用

1. 打开 Math Peek，在设置页允许“辅助功能”访问。
2. 确认“悬停预览”已开启。设置页会显示当前启用的终端，常见应用会自动发现。
3. 切回终端，让它处于前台，把鼠标停在完整公式的字符上；不用点击或选中。
4. 鼠标移开公式，浮窗自动收起。可以按需要开启“登录时自动启动”。

可以在终端输出这两行试一下：

```sh
printf '%s\n' '$e^{i\pi}+1=0$' '$$\boxed{K = \frac{P}{P+R}}$$'
```

应用完成设置后常驻菜单栏 `M∑`，不需要一直打开阅读窗口。
可从 `M∑ → Setup...` 重新打开设置。

### 添加其他终端之后怎么用？

在设置页点击“添加终端”，或使用 `M∑ → Terminal Apps → Add Application...`，
选择对应的 `.app`。**添加成功后立即启用，不需要刷新或重启。**
随后切回这个终端，把鼠标停在公式上即可。

自研应用也可以这样添加。取消勾选会立即暂停该应用的悬停；移除后不会被自动重新加回。
`Automatically Find Terminals` 可以关闭自动发现，`Find Installed Terminals Now` 可以手动扫描。

“已添加”表示允许 Math Peek 从这个应用取字，不等于它提供了完整的辅助功能接口。
若没有弹出公式，先看设置页或菜单栏状态中的具体原因。

## 终端与权限

Math Peek 直接读取 macOS 辅助功能提供的原文和字符坐标，不使用 OCR，
也不需要屏幕录制权限。悬停要求终端提供足够的文字位置接口。

| 终端 | 取字方式 | 使用说明 |
| --- | --- | --- |
| iTerm2、系统 Terminal | 辅助功能文本与字符坐标 | 允许“辅助功能”后直接悬停 |
| Ghostty | 能读取原文，但当前版本缺少字符位置接口 | 自动发现；悬停兼容性仍受该接口限制 |
| cmux | 当前版本的辅助功能文本与位置接口不完整 | 自动发现；悬停兼容性仍受该接口限制 |
| WezTerm、Alacritty、kitty、Warp、Hyper | 读取应用提供的辅助功能文本与坐标 | 默认自动发现，兼容性取决于其接口实现 |
| 自研或其他 `.app` | 手动添加后读取辅助功能文本与坐标 | 需要公开可访问的文字和位置接口 |

自动发现名单不是对每个应用、版本和全部功能的兼容性保证。
无法可靠定位字符时会提示接口限制；仍可使用剪贴板和文件预览。
自研终端开发者可参考[原生接口要求与已核对的限制](docs/terminal-compatibility.md)。

## 公式与阅读窗口

支持 `$...$`、`$$...$$`、`\(...\)`、`\[...\]`，以及包含已知数学命令的独立裸 TeX。
支持多行 `aligned`、常见矩阵和完整外层 `\boxed{...}`。
浮窗按公式大小调整，过大时等比缩放；同一个公式内移动鼠标不会反复跳动。
没有人为悬停等待或窗口动画。

代码块、行内代码和容易与金额混淆的文本会保守处理。
超出 SwiftMath 支持范围的语法显示原始文本；长篇 Markdown 可用菜单栏的 `Open Reader` 阅读。

| 操作 | 作用 |
| --- | --- |
| `Hover Formula Preview` | 开关悬停预览 |
| `Preview Clipboard` | 阅读剪贴板中的 Markdown / LaTeX |
| `Control-Command-M` | 在已启用终端中读取选区或可见文本；其他应用中预览剪贴板 |
| 阅读窗口“读取终端 / 跟随终端” | 原生读取选区或可见文本；跟随模式每两秒更新 |
| “纯 LaTeX 公式”模式 | 渲染没有外层分隔符的公式 |

整屏读取和跟随需要终端提供可访问的选区或可见文本，不会为了取字自动全选或修改剪贴板。
无法安全读取时会提示使用选区或剪贴板预览。整屏读取可用不代表终端同时提供悬停所需的字符坐标。

## 命令行

```sh
math-peek --clipboard
math-peek answer.md
cat answer.md | math-peek
math-peek --capture
math-peek --follow
```

文件和管道输入要求 UTF-8，最大 2 MB。Homebrew 安装会提供 `math-peek` 命令；
源码安装请把 `~/.local/bin` 加入 `PATH`。旧的 Python RPC `--serve` 已移除。

## 没有弹出公式？

- **刚添加应用**：无需刷新。确认它在 `Terminal Apps` 中已勾选，悬停总开关已开启，再切回终端。
- **提示辅助功能权限**：在“系统设置 → 隐私与安全性 → 辅助功能”允许 Math Peek。
- **提示无法定位字符**：终端缺少悬停所需的原生接口；允许辅助功能或重新添加应用不能补齐该接口，可先用剪贴板预览。
- **升级后失效**：本地签名变化可能使旧授权失效，在系统设置中移除旧条目，重新添加并允许当前 Math Peek。
- **公式未识别**：先用上面的两个完整示例验证；不完整分隔符、代码块或无法读取的终端区域不会强行弹窗。
- **文字能读但语法不支持**：尝试复制到阅读窗口，或改写为 SwiftMath 支持的形式。

诊断位于 `~/Library/Caches/Math Peek/`，只记录状态、权限和耗时，不包含终端文字。
状态日志和登录启动状态查询均在后台执行，避免磁盘或系统服务阻塞悬停。

## 开发与发布

```sh
scripts/test_native.sh
node --test web/core.test.cjs
./scripts/build_release.sh
```

`VERSION` 控制版本号；发布脚本生成双架构 ZIP 与 SHA256 文件。
推送 `v<版本>` tag 可触发 GitHub Actions 构建发布。默认使用本地签名；
只有提供真实的 `DEVELOPER_ID_APPLICATION` 和 `NOTARY_PROFILE` 才进行开发者签名与 Apple 公证。

原生渲染使用 SwiftMath；阅读窗口使用本地打包的 KaTeX、marked 和 DOMPurify。
第三方字体与库的许可证随应用一起分发。
