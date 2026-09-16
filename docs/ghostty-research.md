# Ghostty 原生悬停研究

2026-09-16，实测官方 Ghostty **1.3.1 (15212)**，源码以
[`v1.3.1`](https://github.com/ghostty-org/ghostty/tree/v1.3.1) 为准。
这是研究记录，**不表示 Math Peek 已启用 Ghostty 悬停**。
研究工具不进入应用构建，不改变 iTerm2、Terminal 或 cmux 的现有实现。

## 已经验证的进展

不修改 Ghostty，也不使用 OCR，可以从以下原生接口获得部分定位信息：

| 来源 | 可获得的数据 | 限制 |
| --- | --- | --- |
| `AXValue` | 缓冲区原文 | 包含历史，合并软换行，省略尾部空白行，缓存 500 ms |
| `AXScrollArea.AXContentSize` | 整个滚动文档的高度 | 后台或被遮挡时可能尚未更新 |
| `AXVerticalScrollBar.AXValue` | 归一化滚动位置 | 需要结合文档高度；滚动过程中可能不是整行 |
| 本窗格内 `TIOCGWINSZ` | 行列数、终端区域像素尺寸 | 像素尺寸可能包含不足一个单元格的余量 |
| 本窗格内 `CSI 16 t` | 真实单元格高、宽，回复 `CSI 6;height;width t` | 是终端内协议查询，不能在外部任意发送并吞掉用户输入 |

在已知零边距、尺寸稳定的追加式 ASCII 输出中，设行高为 `h`，可见行数为 `r`：

```text
historyRows = (documentHeight - viewportHeight) / h
totalRows = r + historyRows
firstVisibleRow = scrollbarValue * historyRows
```

行数和偏移必须接近整数。原文按真实列数重建物理行后，才能把鼠标位置映射回
`HoverMath` 所需的原文下标。未知边距、Unicode 宽度或不一致的尺寸不能直接猜测。

隔离窗口实测为 80 列、24 行、2 倍缩放，真实单元格为 **17 × 37 px**，
即 **8.5 × 18.5 pt**。文本区域为 680 × 444 pt：

| 测试内容 | AX 逻辑行数 | 文档高度 | 推导结果 |
| --- | ---: | ---: | --- |
| 普通输出 | 6 | 444 pt | 可见 24 行，尾部空行未在原文中出现 |
| 前置 160 行历史 | 166 | 3089.5 pt | 共 167 物理行，底部视口从第 143 行开始 |
| 包含一个长软换行 | 7 | 444 pt | 可重建该 ASCII 软换行 |
| 160 行历史加软换行 | 167 | 3145 pt | 共 170 物理行，底部视口从第 146 行开始 |

索引均从 0 开始。滚动到第 80 行时，滚动条值为 `0.5594405594`，乘以 143
恰好还原偏移 80。研究模型在这些实测输入中可定位 Euler、裸的
`\boxed{K = \frac{P}{P+R}}` 及软换行公式，且不会把
`"$HOME/Applications/Ghostty.app" "$HOME/Applications/cmux.app"` 当成公式。

改变窗口大小并重新输出后，TTY 报告 82 × 25 格、1406 × 926 px，单元格仍然是
17 × 37 px。这说明 `width / columns` 和 `height / rows` **不等于真实格子尺寸**。
此测试验证缩放窗口后的余量，不代表验证了已有历史内容的 resize reflow。

## 更新延迟与读取耗时不同

先读取公式 A，随后原地写入等长公式 B，位置和窗口尺寸保持不变。
一次实测结果如下；另两次重复也在约 525 ms 的采样中首次看到 B：

| 距写入完成时间 | `AXValue` 返回 |
| ---: | --- |
| 7.8 ms | A |
| 22.6 ms | A |
| 104.4 ms | A |
| 304.6 ms | A |
| 525.2 ms | B |
| 655.6 ms | B |

这与 `SurfaceView_AppKit.swift` 的 `CachedValue(duration: .milliseconds(500))` 一致。
上述时间以 fixture 完成写入为起点，不是 GPU 呈现时间；采样也没有测出精确失效时刻。
连续两次读到同样文字不能证明内容新鲜，增加轮询频率也不能跳过这个缓存。

最初的小探针单次读取原文和滚动几何约为 0.55–0.77 ms。加入屏幕缩放查询后的探针，
热读取约为 0.7–4 ms，首个样本在不同运行中曾达到约 20–93 ms。这些都不是鼠标到浮窗的端到端延迟，
也不能与 SwiftMath 的单独渲染耗时直接比较。

## 稳定文本也存在无法还原的位置

除了缓存，还复现了一个纯 ASCII 的位置反例。两种终端输出的公式在不同的物理位置：

1. `erased-wrap`：在标记行下输出 160 个 `A`，接公式。用 `CUP` 和 `EL2` 擦除并改写
   前两行，保留它们的软换行状态。公式仍从 **第 3 行、第 0 列** 开始。
2. `plain-wrap`：直接输出 20 个 `A`、换行、60 个空格，再接相同公式。
   公式从 **第 2 行、第 60 列** 开始。

等待缓存失效后，两者的 `AXValue` **完全相同**，均为 143 个 UTF-16 code units；
文本区域、文档高度、单元格尺寸、滚动条值也相同：

```text
MATH PEEK OWNED GHOSTTY RESEARCH
AAAAAAAAAAAAAAAAAAAA
<60 spaces>\boxed{K = \frac{P}{P+R}}
END
```

简单按列数重新折行会在 `erased-wrap` 的空白处命中公式。总行数校验或两次读取相同
不能区分这两种状态。追加式输出模型必须明确限制使用场景，不能因为数据看起来一致，
就宣称它也支持会擦除、重绘屏幕的终端程序。外部接口也无法证明一个窗格此前从未重绘。

另一个实测反例是 `SGR 8` 隐藏文字：相同公式在可见和隐藏状态下，原生文字完全相同。
当前 `AXAttributedStringForRange` 只补充字体，没有隐藏样式。
源码还显示同步输出模式 `DECSET 2026` 下，渲染可以暂缓，而 AX 读取的是终端模型。
这一项来自源码核对，尚未做独立的画面时序实测。

这些结论不要求所有 AX 终端提供逐帧原子性；现有 iTerm2/Terminal 路径也没有这样的保证。
这里的关键差别是：Ghostty 1.3.1 缺少真实字符位置，外部重建存在已经复现的歧义。

## 可继续实现的方向

### 外部实验适配

可考虑用户显式运行 `math-peek connect ghostty` 的追加式普通文本模式，但此命令
**目前没有实现**。上线前至少还需要：

- 将随机配对标记绑定到准确的 `AXTextArea` 和 Ghostty 进程生命周期，不能按标题或窗格顺序猜。
- 持有同一个 TTY 文件描述符，防止 `/dev/ttysNNN` 被复用；验证控制会话属于本地 Ghostty。
  仅检查环境变量或尺寸相等不足以排除 tmux、screen、SSH 等内层 PTY。
- 字号、屏幕缩放、窗口或 split 改变时重新校验几何；不能永久使用连接时的格子尺寸。
- 对有歧义的定位停用预览，对全文历史处理设置上限，并测量闲置和悬停时的 CPU。
- 单独验证标签页、分屏、关闭再开窗格、非零边距、Unicode 和动态输出。

这条路径不应被描述成 Ghostty 已经提供原生字符坐标，也不应自动替换现有终端后端。

### 按请求导出可见网格

更完整的方向是在 Ghostty 中增加一个很小的只读 viewport snapshot API：

| 文件 | 作用 |
| --- | --- |
| `include/ghostty.h` | 定义版本化 snapshot 及释放函数，保留现有 ABI |
| `src/apprt/embedded.zig` | 导出 C 包装层 |
| `src/Surface.zig` | 在现有 renderer mutex 内一次复制可见 cells 和几何 |
| `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` | AX 请求时读取，转换为屏幕坐标 |

数据需要包含物理空行、wrap 标记、宽字符/组合字符、隐藏标记、实际 cell 尺寸和 padding。
同步输出尚未结束、resize 状态不一致时返回暂不可用。只在请求时工作，复杂度与可见格子数
有关，不扫描全部历史，不新增 timer，也不在每帧发送通知。

现有 `ghostty_surface_read_text` 可以按行读取，但 `offset_start` 是网格索引、
`tl_px_y` 是 baseline，不能直接当作 UTF-16 下标或字符上边界；它还会丢失部分 wrap/style
信息。仅在 Swift 层拼接这些结果不足以实现完整的位置接口。

上游 [#10992](https://github.com/ghostty-org/ghostty/pull/10992) 涉及标准 AX 字符位置映射，
本次核对时仍为 draft 且有冲突；其持续更新缓存/通知的设计还存在性能讨论，未直接移植。
上述按需 snapshot 是设计建议，**尚未编译、压测或合入 Ghostty**，不能承诺实际毫秒数。

## 复现

不需要 Python、OCR 或屏幕录制。纯模型可以独立运行：

```sh
mkdir -p build
xcrun swiftc -O native/HoverMath.swift tests/ghostty_geometry/main.swift \
  -o build/ghostty-geometry-research
build/ghostty-geometry-research
```

GUI 探针仅用于隔离测试环境。它要求同 bundle ID 的 Ghostty 没有运行，使用自己的配置、
新窗口和已知文本，测试期间会聚焦、滚动和调整该窗口。调用方需已有辅助功能权限；滚动
测试还使用 Ghostty AppleScript。配置禁用窗口恢复，不要用它保留日常终端会话状态。
测试结束会关闭自己的 fixture、退出测试进程并恢复之前的前台应用。

```sh
xcrun swiftc tests/ghostty_live/main.swift -o build/ghostty-live-research
ghostty_report_dir="$PWD/build/ghostty-research-$(date +%Y%m%d-%H%M%S)"
build/ghostty-live-research /path/to/isolated/Ghostty.app "$ghostty_report_dir"
build/ghostty-geometry-research --report "$ghostty_report_dir/report.json"
```

输出目录必须尚不存在。报告只包含 fixture 自己生成的文字和测量数据。运行中的探针
同时也是终端内的 fixture，不要原地重新编译覆盖它。GUI 探针没有加入默认 CI。
