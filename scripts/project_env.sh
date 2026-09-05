#!/usr/bin/env bash

# Source this file from the repository root (or any subdirectory):
#   source scripts/project_env.sh
# It keeps all dependencies project-scoped and does not modify shell startup files.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf '%s\n' "Source this script so its environment reaches your shell:" >&2
    printf '%s\n' "  source scripts/project_env.sh" >&2
    exit 2
fi

_project6_configure_environment() {
    local root media_bin python_bin python_version python_minor
    local ffmpeg_version ffprobe_version media_version_pattern media_major media_minor
    local godot_version candidate candidate_version
    local configured_path resolved_ffmpeg resolved_ffprobe resolved_godot
    root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
    media_bin="$root/.tools/ffmpeg/bin"
    python_bin="$root/.venv/bin/python"
    configured_path="${PATH:-}"
    resolved_ffmpeg=""
    resolved_ffprobe=""
    resolved_godot=""

    if [[ ! -x "$python_bin" ]]; then
        printf 'Project Python is missing: %s\n' "$python_bin" >&2
        printf '%s\n' "Create .venv and install requirements.lock before launching Godot." >&2
        return 1
    fi
    python_version="$("$python_bin" --version 2>&1 || true)"
    if [[ "$python_version" =~ ^Python[[:space:]]+3\.([0-9]+)(\.|$) ]]; then
        python_minor="${BASH_REMATCH[1]}"
    else
        python_minor=""
    fi
    if [[ -z "$python_minor" || "$python_minor" -lt 10 || "$python_minor" -ge 15 ]]; then
        printf 'Project Python must be Python >=3.10,<3.15; got: %s\n' "${python_version:-unreadable}" >&2
        return 1
    fi

    if [[ -x "$media_bin/ffmpeg" ]]; then
        resolved_ffmpeg="$media_bin/ffmpeg"
    else
        resolved_ffmpeg="$(PATH="$configured_path" type -P ffmpeg 2>/dev/null || true)"
    fi
    if [[ -x "$media_bin/ffprobe" ]]; then
        resolved_ffprobe="$media_bin/ffprobe"
    else
        resolved_ffprobe="$(PATH="$configured_path" type -P ffprobe 2>/dev/null || true)"
    fi
    if [[ -x "$media_bin/ffmpeg" || -x "$media_bin/ffprobe" ]]; then
        case ":$configured_path:" in
            *":$media_bin:"*) ;;
            *) configured_path="$media_bin${configured_path:+:$configured_path}" ;;
        esac
    fi
    if [[ -z "$resolved_ffmpeg" || -z "$resolved_ffprobe" ]]; then
        printf '%s\n' "FFmpeg 6.1+ and FFprobe are unavailable." >&2
        printf 'Expected project tools: %s and %s\n' "$media_bin/ffmpeg" "$media_bin/ffprobe" >&2
        printf '%s\n' "Run the project-local Conda command in README; no administrator access is required." >&2
        return 1
    fi
    ffmpeg_version="$("$resolved_ffmpeg" -version 2>&1 || true)"
    ffprobe_version="$("$resolved_ffprobe" -version 2>&1 || true)"
    media_version_pattern='^ffmpeg[[:space:]]+version[[:space:]]+[^0-9]*([0-9]+)\.([0-9]+)'
    if [[ "$ffmpeg_version" =~ $media_version_pattern ]]; then
        media_major="${BASH_REMATCH[1]}"
        media_minor="${BASH_REMATCH[2]}"
    else
        media_major=""
        media_minor=""
    fi
    if [[ -z "$media_major" || "$media_major" -lt 6 || ( "$media_major" -eq 6 && "$media_minor" -lt 1 ) ]]; then
        printf 'FFmpeg and FFprobe must be version 6.1+; got FFmpeg: %s\n' "${ffmpeg_version%%$'\n'*}" >&2
        return 1
    fi
    media_version_pattern='^ffprobe[[:space:]]+version[[:space:]]+[^0-9]*([0-9]+)\.([0-9]+)'
    if [[ "$ffprobe_version" =~ $media_version_pattern ]]; then
        media_major="${BASH_REMATCH[1]}"
        media_minor="${BASH_REMATCH[2]}"
    else
        media_major=""
        media_minor=""
    fi
    if [[ -z "$media_major" || "$media_major" -lt 6 || ( "$media_major" -eq 6 && "$media_minor" -lt 1 ) ]]; then
        printf 'FFmpeg and FFprobe must be version 6.1+; got FFprobe: %s\n' "${ffprobe_version%%$'\n'*}" >&2
        return 1
    fi

    if [[ -n "${GODOT_BIN:-}" ]]; then
        if [[ -x "$GODOT_BIN" ]]; then
            resolved_godot="$GODOT_BIN"
        else
            resolved_godot="$(PATH="$configured_path" type -P "$GODOT_BIN" 2>/dev/null || true)"
        fi
        if [[ -z "$resolved_godot" || ! -x "$resolved_godot" ]]; then
            printf 'Configured GODOT_BIN is not executable: %s\n' "$GODOT_BIN" >&2
            return 1
        fi
        godot_version="$("$resolved_godot" --version 2>/dev/null || true)"
        case "$godot_version" in
            4.7.2.stable*) ;;
            *)
                printf 'GODOT_BIN must be Godot 4.7.2-stable; got: %s\n' "${godot_version:-unreadable}" >&2
                return 1
                ;;
        esac
    else
        for candidate in \
            "$(PATH="$configured_path" type -P godot4 2>/dev/null || true)" \
            "$(PATH="$configured_path" type -P godot 2>/dev/null || true)" \
            "${HOME:-}/下载/Godot_v4.7.2-stable_linux.x86_64" \
            "${HOME:-}/Downloads/Godot_v4.7.2-stable_linux.x86_64"
        do
            if [[ -n "$candidate" && -x "$candidate" ]]; then
                candidate_version="$("$candidate" --version 2>/dev/null || true)"
                case "$candidate_version" in
                    4.7.2.stable*)
                        resolved_godot="$candidate"
                        godot_version="$candidate_version"
                        break
                        ;;
                esac
            fi
        done
    fi
    if [[ -z "$resolved_godot" || ! -x "$resolved_godot" ]]; then
        printf '%s\n' "Godot 4.7.2-stable was not found." >&2
        printf '%s\n' "Download its user-writable binary and export GODOT_BIN=/absolute/path/to/Godot_v4.7.2-stable_linux.x86_64." >&2
        return 1
    fi

    export PATH="$configured_path"
    export PROJECT6_ROOT="$root"
    export PROJECT6_PYTHON="$python_bin"
    export GODOT_BIN="$resolved_godot"
    if [[ "${PROJECT6_ENV_QUIET:-0}" != "1" ]]; then
        printf 'Project environment ready\n'
        printf '  Python:  %s\n' "$PROJECT6_PYTHON"
        printf '  FFmpeg:  %s\n' "$resolved_ffmpeg"
        printf '  FFprobe: %s\n' "$resolved_ffprobe"
        printf '  Godot:   %s\n' "$GODOT_BIN"
    fi
}

if _project6_configure_environment; then
    _project6_environment_status=0
else
    _project6_environment_status=$?
fi
unset -f _project6_configure_environment
if [[ $_project6_environment_status -ne 0 ]]; then
    unset _project6_environment_status
    return 1
fi
unset _project6_environment_status
return 0
