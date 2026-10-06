# Math Peek architecture

Math Peek 2 uses one immutable pipeline for every hover source:

1. A terminal adapter captures text, geometry, and source-character candidates.
2. TerminalFormulaDocument reconstructs logical tmux panes with source mappings.
3. HoverMath.Index scans each logical document once and records formula blocks.
4. Pointer candidates query that index; they never run independent formula parsers.
5. HoverPresenter renders the chosen block without participating in capture or parsing.

## Formula-block precedence

From strongest to weakest:

1. Complete standard delimiters.
2. Confirmed Markdown/Codex delimiter recovery.
3. A display block clipped by a validated terminal or tmux-pane edge.
4. Standalone raw TeX containing a known command.

Weaker blocks cannot overlap stronger blocks. An unresolved display delimiter disables raw-TeX fallback in that region, so an incomplete large formula cannot turn into a smaller apparently valid fragment. Ambiguous clipped blocks are rejected.

## Determinism

- A snapshot is parsed once and cached by its exact text and edge semantics.
- A logical pane is cached by its stable row span and terminal-column boundaries.
- Every character covered by one formula returns the same block and source ranges.
- Direct accessibility coordinates and the local bounds retry query the same index.
- Changed text creates a new document; concurrent callers retain their local immutable document.

## Components

- TerminalHoverSource: Accessibility capture and routing to iTerm2/Terminal, cmux, or Ghostty.
- TerminalFormulaDocument: pane reconstruction, source mapping, and snapshot cache.
- HoverMath: single Swift formula scanner and precedence rules.
- HoverController: input scheduling, generations, and stale-result rejection.
- HoverPresenter: native panel construction, rendering, sizing, and placement.
- HoverDiagnostics: stage-to-status mapping and metadata-only diagnostics.
- MathPeek modules: application lifecycle, menus/settings, terminal registry, connections, and reader/window behavior.

The application has no Python parser or runtime path. Test fixtures also use the native Swift implementation.

## Safety rules

- Unknown geometry, stale generations, concealed cells, ambiguous Unicode widths, and uncertain formula boundaries fail closed.
- Diagnostics never contain terminal or formula text.
- Terminal adapters do not simulate selection, type input, change the clipboard, or use OCR.
