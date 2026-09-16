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

- Ghostty 1.3.1 能提供原文和可见范围，但没有实现 `AXRangeForPosition` 或
  `AXBoundsForRange`。该版本的 AppleScript 字典也没有提供字符网格或位置。
- cmux 0.64.9 的文本区域不能提供悬停所需的位置映射；其原文接口也有局限。
- 自动发现只负责识别和启用应用。其他终端和自研应用能否悬停，取决于实际接口。

缺少上述接口时，重新添加应用或重新授权不会补齐位置数据。
需要终端本身完善原生辅助功能接口；在此之前可以使用 Math Peek 的剪贴板或文件预览。
