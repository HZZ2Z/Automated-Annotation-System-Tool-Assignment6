from __future__ import annotations

from pathlib import Path
import shlex
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]


def _write_executable(path: Path, output: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"#!/bin/sh\nprintf '%s\\n' '{output}'\n", encoding="utf-8")
    path.chmod(0o755)


def _fake_project(
    tmp_path: Path, *, python_version: str = "3.14.7", media_version: str = "6.1.2"
) -> tuple[Path, Path]:
    root = tmp_path / "fake project with spaces"
    script = root / "scripts" / "project_env.sh"
    script.parent.mkdir(parents=True)
    shutil.copy2(ROOT / "scripts" / "project_env.sh", script)
    _write_executable(root / ".venv" / "bin" / "python", f"Python {python_version}")
    _write_executable(
        root / ".tools" / "ffmpeg" / "bin" / "ffmpeg",
        f"ffmpeg version {media_version}",
    )
    _write_executable(
        root / ".tools" / "ffmpeg" / "bin" / "ffprobe",
        f"ffprobe version {media_version}",
    )
    godot = tmp_path / "godot"
    _write_executable(godot, "4.7.2.stable.test")
    return script, godot


def test_project_environment_exports_verified_local_tools(tmp_path: Path) -> None:
    """A sourced project environment must expose the repo tools, not shell luck."""
    fake_godot = tmp_path / "godot"
    fake_godot.write_text("#!/bin/sh\necho 4.7.2.stable.test\n", encoding="utf-8")
    fake_godot.chmod(0o755)
    script = ROOT / "scripts" / "project_env.sh"
    command = "\n".join(
        (
            f"export GODOT_BIN={shlex.quote(str(fake_godot))}",
            "export PROJECT6_ENV_QUIET=1",
            f"source {shlex.quote(str(script))}",
            "printf '%s\\n' \"$PROJECT6_ROOT\" \"$PROJECT6_PYTHON\" \"$GODOT_BIN\" \"${PATH%%:*}\"",
        )
    )

    result = subprocess.run(
        ["/bin/bash", "-c", command],
        cwd=ROOT,
        env={"HOME": str(tmp_path), "PATH": "/usr/bin:/bin"},
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == [
        str(ROOT),
        str(ROOT / ".venv" / "bin" / "python"),
        str(fake_godot),
        str(ROOT / ".tools" / "ffmpeg" / "bin"),
    ]


def test_project_environment_is_idempotent(tmp_path: Path) -> None:
    """Sourcing twice must not grow PATH with duplicate project entries."""
    fake_godot = tmp_path / "godot"
    fake_godot.write_text("#!/bin/sh\necho 4.7.2.stable.test\n", encoding="utf-8")
    fake_godot.chmod(0o755)
    script = ROOT / "scripts" / "project_env.sh"
    command = "\n".join(
        (
            f"export GODOT_BIN={shlex.quote(str(fake_godot))}",
            "export PROJECT6_ENV_QUIET=1",
            f"source {shlex.quote(str(script))}",
            f"source {shlex.quote(str(script))}",
            "printf '%s' \"$PATH\"",
        )
    )

    result = subprocess.run(
        ["/bin/bash", "-c", command],
        cwd=ROOT,
        env={"HOME": str(tmp_path), "PATH": "/usr/bin:/bin"},
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    media_bin = str(ROOT / ".tools" / "ffmpeg" / "bin")
    assert result.stdout.split(":").count(media_bin) == 1


def test_project_environment_reports_missing_godot(tmp_path: Path) -> None:
    """A fresh machine must receive an actionable Godot prerequisite error."""
    script = ROOT / "scripts" / "project_env.sh"
    result = subprocess.run(
        ["/bin/bash", "-c", f"source {shlex.quote(str(script))}"],
        cwd=ROOT,
        env={"HOME": str(tmp_path), "PATH": "/usr/bin:/bin", "PROJECT6_ENV_QUIET": "1"},
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0
    assert "Godot 4.7.2-stable" in result.stderr
    assert "GODOT_BIN" in result.stderr


def test_project_environment_failure_does_not_partially_mutate_shell(
    tmp_path: Path,
) -> None:
    """A failed preflight must leave the caller's PATH and variables untouched."""
    script = ROOT / "scripts" / "project_env.sh"
    command = "\n".join(
        (
            "original_path=$PATH",
            f"source {shlex.quote(str(script))}",
            "status=$?",
            "printf '%s\\n' \"$status\" \"$PATH\" \"${GODOT_BIN-unset}\" \"${PROJECT6_ROOT-unset}\"",
        )
    )
    original_path = "/usr/bin:/bin"

    result = subprocess.run(
        ["/bin/bash", "-c", command],
        cwd=ROOT,
        env={"HOME": str(tmp_path), "PATH": original_path, "PROJECT6_ENV_QUIET": "1"},
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0
    assert result.stdout.splitlines() == ["1", original_path, "unset", "unset"]


def test_project_environment_rejects_shell_functions_as_media_tools(
    tmp_path: Path,
) -> None:
    """Preflight must find executable files, not aliases or shell functions."""
    fake_root = tmp_path / "fake project with spaces"
    fake_script = fake_root / "scripts" / "project_env.sh"
    fake_python = fake_root / ".venv" / "bin" / "python"
    fake_script.parent.mkdir(parents=True)
    fake_python.parent.mkdir(parents=True)
    shutil.copy2(ROOT / "scripts" / "project_env.sh", fake_script)
    _write_executable(fake_python, "Python 3.14.7")

    tool_path = tmp_path / "minimal-path"
    tool_path.mkdir()
    dirname = shutil.which("dirname")
    assert dirname is not None
    (tool_path / "dirname").symlink_to(dirname)
    command = "\n".join(
        (
            "ffmpeg() { :; }",
            "ffprobe() { :; }",
            f"source {shlex.quote(str(fake_script))}",
        )
    )

    result = subprocess.run(
        ["/bin/bash", "-c", command],
        cwd=fake_root,
        env={
            "HOME": str(tmp_path / "empty-home"),
            "PATH": str(tool_path),
            "PROJECT6_ENV_QUIET": "1",
        },
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0
    assert "FFmpeg 6.1+ and FFprobe are unavailable" in result.stderr


@pytest.mark.parametrize(
    ("python_version", "media_version", "expected_error"),
    (
        ("3.9.18", "6.1.2", "Python >=3.10,<3.15"),
        ("3.14.7", "5.1.2", "FFmpeg and FFprobe must be version 6.1+"),
    ),
)
def test_project_environment_rejects_unsupported_dependency_versions(
    tmp_path: Path,
    python_version: str,
    media_version: str,
    expected_error: str,
) -> None:
    """Executable files with incompatible versions must not pass preflight."""
    script, godot = _fake_project(
        tmp_path, python_version=python_version, media_version=media_version
    )

    result = subprocess.run(
        ["/bin/bash", "-c", f"source {shlex.quote(str(script))}"],
        cwd=script.parents[1],
        env={
            "GODOT_BIN": str(godot),
            "HOME": str(tmp_path),
            "PATH": "/usr/bin:/bin",
            "PROJECT6_ENV_QUIET": "1",
        },
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0
    assert expected_error in result.stderr


def test_project_environment_skips_wrong_auto_detected_godot_version(
    tmp_path: Path,
) -> None:
    """Automatic discovery must continue until it finds the required Godot."""
    old_bin = tmp_path / "old-bin"
    old_godot = old_bin / "godot4"
    _write_executable(old_godot, "4.6.1.stable.test")
    expected_godot = tmp_path / "下载" / "Godot_v4.7.2-stable_linux.x86_64"
    _write_executable(expected_godot, "4.7.2.stable.test")
    script = ROOT / "scripts" / "project_env.sh"
    command = "\n".join(
        (
            f"source {shlex.quote(str(script))}",
            "printf '%s' \"$GODOT_BIN\"",
        )
    )

    result = subprocess.run(
        ["/bin/bash", "-c", command],
        cwd=ROOT,
        env={
            "HOME": str(tmp_path),
            "PATH": f"{old_bin}:/usr/bin:/bin",
            "PROJECT6_ENV_QUIET": "1",
        },
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout == str(expected_godot)
