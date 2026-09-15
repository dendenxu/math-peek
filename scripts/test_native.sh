#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
live=false
occlusion=false
regression=false
full_formulas=false
for argument in "$@"; do
    case "$argument" in
        --live) live=true ;;
        --occlusion) occlusion=true ;;
        --regression) regression=true ;;
        --full-formulas) full_formulas=true ;;
        *) echo "Usage: scripts/test_native.sh [--live] [--regression|--full-formulas] [--occlusion]" >&2; exit 2 ;;
    esac
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
math_objects=("$bin_dir"/SwiftMath.build/*.o)
module_dir="$bin_dir/Modules"
# Swift 6.3's default build engine emits one combined dependency object.
if [[ ! -f "${math_objects[0]}" && -f "$bin_dir/SwiftMath.o" ]]; then
    math_objects=("$bin_dir/SwiftMath.o")
    module_dir="$bin_dir"
fi
if [[ ! -f "${math_objects[0]}" ]]; then
    echo "SwiftMath object files not found in $bin_dir" >&2
    exit 1
fi

# Keep the executables beside SwiftPM's font bundle so Bundle.module can find it.
xcrun swiftc -O -I "$module_dir" \
    native/HoverMath.swift native/FormulaView.swift tests/native_rendering/main.swift \
    "${math_objects[@]}" -o "$bin_dir/native-rendering-tests"
xcrun swiftc -O -I "$module_dir" \
    native/HoverMath.swift native/FormulaView.swift native/HoverController.swift \
    tests/hover_transitions/main.swift "${math_objects[@]}" \
    -o "$bin_dir/hover-transition-tests"
xcrun swiftc -O -I "$module_dir" \
    native/HoverMath.swift native/FormulaView.swift native/HoverController.swift \
    tests/panel_layout/main.swift "${math_objects[@]}" \
    -o "$bin_dir/panel-layout-tests"

"$bin_dir/native-rendering-tests"
"$bin_dir/panel-layout-tests"
if $live; then
    live_arguments=(--run)
    if $occlusion; then live_arguments+=(--occlusion); fi
    if $regression; then live_arguments+=(--regression); fi
    if $full_formulas; then live_arguments+=(--full-formulas); fi
    "$bin_dir/hover-transition-tests" "${live_arguments[@]}"
else
    echo "Live hover checks skipped. To run: raise the isolated demo in iTerm2, pause installed Math Peek hover, then scripts/test_native.sh --live."
fi
