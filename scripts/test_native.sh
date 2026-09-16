#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
live=false
occlusion=false
regression=false
full_formulas=false
bundle_id="com.googlecode.iterm2"
marker=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --live) live=true ;;
        --occlusion) occlusion=true ;;
        --regression) regression=true ;;
        --full-formulas) full_formulas=true ;;
        --bundle-id|--marker)
            [[ $# -ge 2 ]] || { echo "$1 requires a value" >&2; exit 2; }
            if [[ "$1" == --bundle-id ]]; then bundle_id="$2"; else marker="$2"; fi
            shift ;;
        *) echo "Usage: scripts/test_native.sh [--live] [--regression|--full-formulas] [--occlusion] [--bundle-id ID] [--marker TEXT]" >&2; exit 2 ;;
    esac
    shift
done
if $occlusion && ! $live; then
    echo "--occlusion requires --live" >&2
    exit 2
fi
if $regression && ! $live; then
    echo "--regression requires --live" >&2
    exit 2
fi
if $full_formulas && ! $live; then
    echo "--full-formulas requires --live" >&2
    exit 2
fi
if $full_formulas && $regression; then
    echo "Choose either --regression or --full-formulas" >&2
    exit 2
fi

swift build -c release --product MathPeek
bin_dir="$(swift build -c release --show-bin-path)"
xcrun swiftc native/HoverApplications.swift tests/hover_applications/main.swift -o "$bin_dir/hover-applications-tests"
"$bin_dir/hover-applications-tests"
xcrun swiftc native/DiagnosticWriter.swift tests/diagnostic_writer/main.swift -o "$bin_dir/diagnostic-writer-tests"
"$bin_dir/diagnostic-writer-tests"
xcrun swiftc native/TerminalCapture.swift tests/terminal_capture/main.swift -o "$bin_dir/terminal-capture-tests"
"$bin_dir/terminal-capture-tests"
xcrun swiftc native/HoverTextPosition.swift tests/hover_position/main.swift -o "$bin_dir/hover-position-tests"
"$bin_dir/hover-position-tests"
math_objects=("$bin_dir"/SwiftMath.build/*.o)
# Swift 6.3's default build engine emits one combined dependency object.
if [[ ! -f "${math_objects[0]}" && -f "$bin_dir/SwiftMath.o" ]]; then
    math_objects=("$bin_dir/SwiftMath.o")
fi
if [[ ! -f "${math_objects[0]}" ]]; then
    echo "SwiftMath object files not found in $bin_dir" >&2
    exit 1
fi
# Older SwiftPM puts modules beside products even with per-source objects.
if [[ -e "$bin_dir/Modules/SwiftMath.swiftmodule" ]]; then
    module_dir="$bin_dir/Modules"
elif [[ -e "$bin_dir/SwiftMath.swiftmodule" ]]; then
    module_dir="$bin_dir"
else
    echo "SwiftMath.swiftmodule not found in $bin_dir or $bin_dir/Modules" >&2
    exit 1
fi

# Keep the executables beside SwiftPM's font bundle so Bundle.module can find it.
xcrun swiftc -O -I "$module_dir" \
    native/HoverMath.swift native/FormulaView.swift tests/native_rendering/main.swift \
    "${math_objects[@]}" -o "$bin_dir/native-rendering-tests"
xcrun swiftc -O -I "$module_dir" \
    native/HoverMath.swift native/FormulaView.swift native/DiagnosticWriter.swift \
    native/HoverTextPosition.swift native/HoverController.swift \
    tests/hover_transitions/main.swift "${math_objects[@]}" \
    -o "$bin_dir/hover-transition-tests"
xcrun swiftc -O -I "$module_dir" \
    native/HoverMath.swift native/FormulaView.swift native/DiagnosticWriter.swift \
    native/HoverTextPosition.swift native/HoverController.swift \
    tests/panel_layout/main.swift "${math_objects[@]}" \
    -o "$bin_dir/panel-layout-tests"

"$bin_dir/native-rendering-tests"
"$bin_dir/panel-layout-tests"
if $live; then
    live_arguments=(--run --bundle-id "$bundle_id")
    if [[ -n "$marker" ]]; then live_arguments+=(--marker "$marker"); fi
    if $occlusion; then live_arguments+=(--occlusion); fi
    if $regression; then live_arguments+=(--regression); fi
    if $full_formulas; then live_arguments+=(--full-formulas); fi
    "$bin_dir/hover-transition-tests" "${live_arguments[@]}"
else
    echo "Live hover checks skipped. To run: raise the isolated demo in iTerm2, pause installed Math Peek hover, then scripts/test_native.sh --live."
fi
