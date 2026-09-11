"""Parser depth failures must not damage Godot's VM stack."""
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def test_checked_depth_limit_without_engine_stack_diagnostics(tmp_path):
    result = subprocess.run(
        [os.environ["GODOT_BIN"], "--headless", "--path", str(ROOT), "--log-file", str(tmp_path / "godot.log"),
         "--script", "tests/godot/test_part4_exact_json_depth.gd"],
        cwd=ROOT, capture_output=True, text=True, timeout=30,
    )
    output = result.stdout + result.stderr + (tmp_path / "godot.log").read_text()
    assert result.returncode == 0, output
    assert "SCRIPT ERROR" not in output and "Stack underflow" not in output and "Stack overflow" not in output, output
