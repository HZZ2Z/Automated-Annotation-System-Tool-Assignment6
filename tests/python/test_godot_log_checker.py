"""Contract tests for the authoritative Godot log audit."""
from __future__ import annotations

from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "tests" / "check_godot_log.sh"


def _check(tmp_path: Path, text: str, profile: str = "none") -> subprocess.CompletedProcess:
    log = tmp_path / "godot.log"
    log.write_text(text, encoding="utf-8")
    return subprocess.run(
        ["bash", str(CHECKER), str(log), profile],
        capture_output=True,
        text=True,
        check=False,
    )


def test_clean_log_passes_and_unexpected_engine_or_script_errors_fail(tmp_path):
    assert _check(tmp_path, "Godot Engine\nPASS suite\n").returncode == 0
    for line in (
        "SCRIPT ERROR: Invalid access\n",
        "ERROR: unrelated runtime failure\n",
        "Unhandled exception in worker\n",
    ):
        result = _check(tmp_path, line)
        assert result.returncode == 1
        assert "Unexpected Godot error output" in result.stderr


def test_corrupt_png_profile_allows_only_the_four_exact_fixture_pairs(tmp_path):
    error_lines = [
        'ERROR: Condition "!success" is true. Returning: ERR_FILE_CORRUPT',
        "ERROR: Error loading image: '/tmp/annotool-task6-corrupt-frame-2-1/frames/frame_000000.png'.",
        'ERROR: Condition "!success" is true. Returning: ERR_FILE_CORRUPT',
        "ERROR: Error loading image: '/tmp/annotool-part1-single-image-invalid-2-2/corrupt.png'.",
        'ERROR: Condition "!success" is true. Returning: ERR_FILE_CORRUPT',
        "ERROR: Error loading image: '/tmp/annotool-task9-corrupt-replacement-2-3/frames/frame_000000.png'.",
        'ERROR: Condition "!success" is true. Returning: ERR_FILE_CORRUPT',
        "ERROR: Error loading image: '/tmp/annotool-workspace-sequence-2-4/VID68/000023.png'.",
    ]
    valid = "\n".join(error_lines) + "\nPASS: complete Godot test suite\n"
    assert _check(tmp_path, valid, "expected-corrupt-png").returncode == 0

    missing = "\n".join(error_lines[:-2]) + "\n"
    assert _check(tmp_path, missing, "expected-corrupt-png").returncode == 1
    unexpected = valid + "ERROR: unrelated runtime failure\n"
    assert _check(tmp_path, unexpected, "expected-corrupt-png").returncode == 1


def test_editor_socket_profile_allows_only_two_exact_environment_pairs(tmp_path):
    pair = (
        'ERROR: Condition "_sock == -1" is true. Returning: FAILED\n'
        'ERROR: Condition "err != OK" is true. Returning: ERR_CANT_CREATE\n'
    )
    valid = pair + "editor scan\n" + pair
    assert _check(tmp_path, valid, "expected-editor-socket").returncode == 0
    assert _check(tmp_path, pair, "expected-editor-socket").returncode == 1
    assert (
        _check(tmp_path, valid + "ERROR: unrelated runtime failure\n", "expected-editor-socket").returncode
        == 1
    )
