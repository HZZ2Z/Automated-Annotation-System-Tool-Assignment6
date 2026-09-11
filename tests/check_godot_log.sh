#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ! -f "$1" ]]; then
    printf '%s\n' "usage: check_godot_log.sh LOG_PATH [none|expected-corrupt-png|expected-editor-socket]" >&2
    exit 2
fi

profile="${2:-none}"
if [[ "$profile" != "none" && "$profile" != "expected-corrupt-png" && "$profile" != "expected-editor-socket" ]]; then
    printf 'Unknown Godot log profile: %s\n' "$profile" >&2
    exit 2
fi

error_lines="$(rg -n 'SCRIPT ERROR|Unhandled exception|ERROR:' "$1" || true)"
if [[ "$profile" == "expected-corrupt-png" ]]; then
    condition_pattern='ERROR: Condition "!success" is true\. Returning: ERR_FILE_CORRUPT$'
    source_pattern="ERROR: Error loading image: '/tmp/annotool-task6-corrupt-frame-[^']+/frames/frame_000000\\.png'\\.$"
    single_pattern="ERROR: Error loading image: '/tmp/annotool-part1-single-image-invalid-[^']+/corrupt\\.png'\\.$"
    playback_pattern="ERROR: Error loading image: '/tmp/annotool-task9-corrupt-replacement-[^']+/frames/frame_000000\\.png'\\.$"
    workspace_pattern="ERROR: Error loading image: '/tmp/annotool-workspace-sequence-[^']+/VID68/000023\\.png'\\.$"
    unexpected="$(printf '%s\n' "$error_lines" | rg -v "$condition_pattern|$source_pattern|$single_pattern|$playback_pattern|$workspace_pattern" || true)"
    condition_count="$(printf '%s\n' "$error_lines" | rg -c "$condition_pattern" || true)"
    source_count="$(printf '%s\n' "$error_lines" | rg -c "$source_pattern" || true)"
    single_count="$(printf '%s\n' "$error_lines" | rg -c "$single_pattern" || true)"
    playback_count="$(printf '%s\n' "$error_lines" | rg -c "$playback_pattern" || true)"
    workspace_count="$(printf '%s\n' "$error_lines" | rg -c "$workspace_pattern" || true)"
    if [[ -z "$unexpected" && "$condition_count" == 4 && "$source_count" == 1 && "$single_count" == 1 && "$playback_count" == 1 && "$workspace_count" == 1 ]]; then
        exit 0
    fi
fi

if [[ "$profile" == "expected-editor-socket" ]]; then
    socket_pattern='ERROR: Condition "_sock == -1" is true\. Returning: FAILED$'
    listen_pattern='ERROR: Condition "err != OK" is true\. Returning: ERR_CANT_CREATE$'
    unexpected="$(printf '%s\n' "$error_lines" | rg -v "$socket_pattern|$listen_pattern" || true)"
    socket_count="$(printf '%s\n' "$error_lines" | rg -c "$socket_pattern" || true)"
    listen_count="$(printf '%s\n' "$error_lines" | rg -c "$listen_pattern" || true)"
    if [[ -z "$unexpected" && "$socket_count" == 2 && "$listen_count" == 2 ]]; then
        exit 0
    fi
fi

if [[ -n "$error_lines" ]]; then
    printf '%s\n' "$error_lines"
    printf '%s\n' "Unexpected Godot error output" >&2
    exit 1
fi

if [[ "$profile" == "expected-corrupt-png" ]]; then
    printf '%s\n' "Expected corrupt-PNG diagnostics were missing or changed" >&2
    exit 1
fi

if [[ "$profile" == "expected-editor-socket" ]]; then
    printf '%s\n' "Expected headless-editor socket diagnostics were missing or changed" >&2
    exit 1
fi
