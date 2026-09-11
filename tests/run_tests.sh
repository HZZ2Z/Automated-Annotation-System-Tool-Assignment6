#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../project_env.sh"

run_godot_checked() {
    local label="$1"
    local profile="$2"
    local log_path
    local godot_status
    shift 2
    log_path="$(mktemp "/tmp/project6-${label}.XXXXXX.log")"
    set +e
    "$GODOT_BIN" --headless --log-file "$log_path" --path "$PROJECT6_ROOT" "$@"
    godot_status=$?
    set -e
    if [[ $godot_status -ne 0 ]]; then
        printf 'Godot command failed; retained log: %s\n' "$log_path" >&2
        return "$godot_status"
    fi
    if ! bash "$PROJECT6_ROOT/tests/check_godot_log.sh" "$log_path" "$profile"; then
        printf 'Godot log audit failed; retained log: %s\n' "$log_path" >&2
        return 1
    fi
}

run_godot_checked editor expected-editor-socket --editor --quit
run_godot_checked review-session none --script "$PROJECT6_ROOT/tests/godot/test_review_session_contract.gd"
"$PROJECT6_PYTHON" -m pytest "$PROJECT6_ROOT/tests/python" -q
run_godot_checked aggregate expected-corrupt-png --script "$PROJECT6_ROOT/tests/godot/test_runner.gd"
run_godot_checked polygon-ops none --script "$PROJECT6_ROOT/tests/godot/test_polygon_ops.gd"
run_godot_checked image-region none --script "$PROJECT6_ROOT/tests/godot/test_image_region_algorithms.gd"
run_godot_checked advanced-edit none --script "$PROJECT6_ROOT/tests/godot/test_advanced_edit_tools.gd"
run_godot_checked keyboard none --script "$PROJECT6_ROOT/tests/godot/test_keyboard_reachability.gd"
run_godot_checked brush none --script "$PROJECT6_ROOT/tests/godot/test_brush_stroke_buffer.gd"
run_godot_checked fill none --script "$PROJECT6_ROOT/tests/godot/test_fill_region_solver.gd"
run_godot_checked checked-history none --script "$PROJECT6_ROOT/tests/godot/test_checked_history.gd"
run_godot_checked assignment-edit none --script "$PROJECT6_ROOT/tests/godot/test_editing_assignment.gd"
run_godot_checked vertex-edit none --script "$PROJECT6_ROOT/tests/godot/test_polygon_vertex_editing.gd"
run_godot_checked delivery-surface none --script "$PROJECT6_ROOT/tests/godot/test_delivery_tool_surface.gd"
run_godot_checked model-assist-service none --script "$PROJECT6_ROOT/tests/godot/test_model_assist_service.gd"
run_godot_checked sam-video-service none --script "$PROJECT6_ROOT/tests/godot/test_sam_video_service.gd"

run_godot_checked batch-workflow none --script "$PROJECT6_ROOT/tests/godot/test_batch_workflow.gd"
run_godot_checked batch-ui none --script "$PROJECT6_ROOT/tests/godot/test_batch_ui.gd"
run_godot_checked sam-video-batch-ui none --script "$PROJECT6_ROOT/tests/godot/test_sam_video_batch_ui.gd"
run_godot_checked batch-range none --script "$PROJECT6_ROOT/tests/godot/test_batch_range_model.gd"
run_godot_checked batch-no-candidate-ui none --script "$PROJECT6_ROOT/tests/godot/test_batch_no_candidate_ui.gd"
run_godot_checked batch-provider none --script "$PROJECT6_ROOT/tests/godot/test_batch_provider_contract.gd"
run_godot_checked sam-video-batch none --script "$PROJECT6_ROOT/tests/godot/test_sam_video_batch.gd"
run_godot_checked sam-video-command none --script "$PROJECT6_ROOT/tests/godot/test_sam_video_batch_command.gd"
run_godot_checked polygon-command none --script "$PROJECT6_ROOT/tests/godot/test_polygon_batch_command.gd"
run_godot_checked polygon-integration none --script "$PROJECT6_ROOT/tests/godot/test_polygon_batch.gd"
run_godot_checked polygon-service none --script "$PROJECT6_ROOT/tests/godot/test_polygon_service.gd"
run_godot_checked polygon-ui none --script "$PROJECT6_ROOT/tests/godot/test_polygon_batch_ui.gd"
run_godot_checked main-boundaries none --script "$PROJECT6_ROOT/tests/godot/run_main_boundaries.gd"
