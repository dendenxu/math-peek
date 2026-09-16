# 原生终端接口

Math Peek 是独立 macOS 应用。终端通过系统辅助功能接口公开原文和位置后，
用户在 Math Peek 中添加对应的 `.app` 即可启用，不需要集成 Math Peek SDK。
应用不使用 OCR，也不通过模拟选择或修改剪贴板取字。

## 悬停需要什么

终端的辅助功能树应包含可命中的 `AXTextArea`，并提供：

| 接口 | 用途 |
| --- | --- |
| `AXValue` | 终端原文，字符下标使用 UTF-16 |
| `AXRangeForPosition` | 把屏幕坐标转换为字符范围 |
| `AXBoundsForRange` | 返回字符的真实屏幕范围，验证鼠标确实位于字符上 |
| `AXVisibleCharacterRange` | 限定当前可见内容，避免误用滚动历史 |
| `AXPosition` / `AXSize` | 描述终端文本区域 |

如果没有 `AXRangeForPosition`，但提供真实的 `AXBoundsForRange`，
Math Peek 可以通过有界查找定位字符。仅提供字体名称和字号不足以可靠推算位置：
终端可能调整单元格宽高、内边距、缩放和换行方式。

整屏读取和跟随只需要可访问的原文与可见范围；读取选区使用 `AXSelectedText`。
因此，能读取终端原文不代表能实现鼠标悬停。

## 已核对的限制

以下结论针对列出的版本；后续版本是否支持，应重新核对其原生接口。

- Ghostty 1.3.1 能提供原文，但可见范围包含滚动历史，且没有实现 `AXRangeForPosition` 或
  `AXBoundsForRange`。该版本的 AppleScript 字典也没有提供字符网格或位置。
  参见 [Ghostty v1.3.1 辅助功能实现](https://github.com/ghostty-org/ghostty/blob/v1.3.1/macos/Sources/Ghostty/Surface%20View/SurfaceView_AppKit.swift#L2219)。
  上游 [#10992](https://github.com/ghostty-org/ghostty/pull/10992) 正在补充鼠标与字符范围映射；
  当前发布版不能仅靠读取字体或推算行高实现可靠悬停。
- cmux 0.64.24 的 `AXValue` 仅返回当前选区文字，未选中时返回空字符串；
  可以通过 `AXSelectedText` 读取选区，但这不是完整的可见终端原文。
  该版本没有提供悬停所需的 `AXRangeForPosition` / `AXBoundsForRange` 映射，
  `characterIndex(for:)` 也只返回当前选区位置，并未按鼠标坐标定位字符。
  参见 [cmux v0.64.24 辅助功能实现](https://github.com/manaflow-ai/cmux/blob/v0.64.24/Sources/GhosttyTerminalView.swift#L6085)。
  Math Peek 因此使用该版本的原生 socket 网格通道，见下节。
- 自动发现只负责识别和启用应用。其他终端和自研应用能否悬停，取决于实际接口。

缺少上述接口时，重新添加应用或重新授权不会补齐位置数据。
需要终端本身完善原生辅助功能接口；在此之前可以使用 Math Peek 的剪贴板或文件预览。

## cmux 网格通道

`math-peek connect cmux` 只读取自身继承的 `CMUX_SOCKET_CAPABILITY` 和本地 socket 路径，
将一次性请求交给应用验证后存入钥匙串，不读取其他进程的环境，不放宽 socket 权限。
CLI 使用 0700 目录和 0600 文件；URL 只包含随机文件名，不包含 capability。
应用验证当前 cmux 进程身份后才发送授权信息。

`debug.terminals` 用于匹配可见窗格，`pane.list` 提供实际单元格尺寸，
`mobile.terminal.replay` 使用 `anchor: viewport` 返回当前可见字符网格。
请求不包含 `client_id` 或 viewport 尺寸，因此不会更改终端大小；viewport anchor
也不会触发 cmux 的手机镜像 baseline 重置。文字仅在内存中处理。

cmux 未返回文字内边距，因此不能把剩余空隙直接假设成居中 padding。
Math Peek 对所有可能的单元格位置做校验；只允许同一完整公式，并可将命中区域
延伸到紧邻的整行空白。不能跨入另一条公式、普通文字或路径所在行。
命中后再次验证窗格、尺寸和网格内容，滚动或输入时立即收起旧浮窗。
隐藏文字、无法确定宽度的 Unicode 区域、过大网格和定位歧义均不强行预览。
