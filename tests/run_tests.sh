#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../scripts/project_env.sh"

"$GODOT_BIN" --headless --editor --quit --path "$PROJECT6_ROOT"
"$PROJECT6_PYTHON" -m pytest "$PROJECT6_ROOT/tests/python" -q
"$GODOT_BIN" --headless --path "$PROJECT6_ROOT" --script "$PROJECT6_ROOT/tests/godot/test_runner.gd"
"$GODOT_BIN" --headless --path "$PROJECT6_ROOT" --script "$PROJECT6_ROOT/tests/godot/test_polygon_ops.gd"
"$GODOT_BIN" --headless --path "$PROJECT6_ROOT" --script "$PROJECT6_ROOT/tests/godot/test_image_region_algorithms.gd"
"$GODOT_BIN" --headless --path "$PROJECT6_ROOT" --script "$PROJECT6_ROOT/tests/godot/test_advanced_edit_tools.gd"
"$GODOT_BIN" --headless --path "$PROJECT6_ROOT" --script "$PROJECT6_ROOT/tests/godot/test_keyboard_reachability.gd"
"$GODOT_BIN" --headless --path "$PROJECT6_ROOT" --script "$PROJECT6_ROOT/tests/godot/test_brush_stroke_buffer.gd"
"$GODOT_BIN" --headless --path "$PROJECT6_ROOT" --script "$PROJECT6_ROOT/tests/godot/test_fill_region_solver.gd"
"$GODOT_BIN" --headless --path "$PROJECT6_ROOT" --script "$PROJECT6_ROOT/tests/godot/test_checked_history.gd"
"$GODOT_BIN" --headless --path "$PROJECT6_ROOT" --script "$PROJECT6_ROOT/tests/godot/test_editing_assignment.gd"
"$GODOT_BIN" --headless --path "$PROJECT6_ROOT" --script "$PROJECT6_ROOT/tests/godot/test_polygon_vertex_editing.gd"
