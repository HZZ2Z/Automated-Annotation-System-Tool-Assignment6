"""Repository-layout safeguards for the Assignment submission."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]


CONTRACT_FIXTURES = {
    "model_output_v1": (
        "valid/assignment-model-output-v1.json",
        "invalid/model-output-v1-bad-box.json",
    ),
    "dataset_manifest_v1": (
        "valid/dataset-manifest.json",
        "invalid/manifest-frame-gap.json",
    ),
    "media_label_v1": (
        "valid/media-label.json",
        "invalid/media-label-frame-mismatch.json",
    ),
}

TEST_TOOL_PATHS = [
    "tests/run_tests.sh",
    "tests/benchmarks/make_part3_sources.py",
    "tests/benchmarks/godot/display_benchmark.gd",
    "tests/benchmarks/godot/display_benchmark.gd.uid",
    "tests/benchmarks/godot/playback_benchmark.gd",
    "tests/benchmarks/godot/playback_benchmark.gd.uid",
    "tests/benchmarks/godot/long_source_benchmark.gd",
    "tests/benchmarks/godot/long_source_benchmark.gd.uid",
    "tests/benchmarks/godot/video_import_benchmark.gd",
    "tests/benchmarks/godot/video_import_benchmark.gd.uid",
    "tests/benchmarks/results/part2_1_display.json",
    "tests/benchmarks/results/part3_1_import.json",
    "tests/benchmarks/results/part3_1_long_source.json",
    "tests/benchmarks/results/part3_1_playback.json",
]

FORCE_ADDED_FORBIDDEN_CASES = [
    ".godot/imported/icon.ctex",
    "android/build.gradle",
    ".venv/bin/python",
    ".tools/ffmpeg/bin/ffmpeg",
    ".cache/state.json",
    ".pytest_cache/state.json",
    "client/.mypy_cache/state.json",
    "tests/.ruff_cache/state.json",
    "python/__pycache__/module.cpython-312.pyc",
    "python/module.pyc",
    "python/module.pyo",
    "generated_sample/frame_000001.png",
    "scratch/generated_frames/frame_000001.png",
    "frames/frame_000001.png",
    "exports/project.zip",
    "autosave/session.json",
    "build/package.whl",
    "dist/package.whl",
    "secrets/token.txt",
    "config/.env.production",
    "config.env",
    "id_ed25519",
    "certificate.p12",
    "certificate.pfx",
    "debug.log",
    "scratch.tmp",
    "scratch.temp",
    "asset.png.import",
    "docs/images.jpeg",
    "docs/0001.png",
]


@pytest.mark.parametrize(
    ("relative_path", "expected_kind"),
    [
        ("README.md", "file"),
        ("RESULTS.md", "file"),
        ("pyproject.toml", "file"),
        ("requirements.lock", "file"),
        ("project.godot", "file"),
        ("python/make_sample_input.py", "file"),
        ("python/frame_source.py", "file"),
        ("scripts/project_env.sh", "file"),
        ("docs/architecture.md", "file"),
        ("client", "directory"),
        ("core", "directory"),
        ("tests", "directory"),
    ],
)
def test_assignment_deliverables_keep_their_public_locations(
    relative_path: str,
    expected_kind: str,
) -> None:
    """The cleanup must not relocate an Assignment-facing entry point."""

    path = ROOT / relative_path
    if expected_kind == "file":
        assert path.is_file()
    else:
        assert path.is_dir()


@pytest.mark.parametrize(
    "candidate",
    [
        "Dataset_test/example.png",
        ".codex/config.toml",
        ".agents/state",
        ".env",
        ".env.local",
        ".cache/state.json",
        ".mypy_cache/state.json",
        ".ruff_cache/state.json",
        "generated_frames/frame_000001.png",
        "frames/frame_000001.png",
        "config.local.toml",
        "credentials.json",
        "secrets/token.txt",
        "id_rsa",
        "secret.key",
        "certificate.pem",
        "certificate.p12",
        "certificate.pfx",
        "docs/images.jpeg",
        "docs/播放.png",
        "docs/laparoscopic_hernia_2d.ogv.uid",
        "plans/local.md",
        "python/example.egg-info/PKG-INFO",
        "tests/output/result.json",
        "tests/video_test/frame.png",
        "tests/laparoscopic_hernia_2d_frames/frame.png",
    ],
)
def test_local_only_paths_are_ignored(candidate: str) -> None:
    """A local dataset or generated artifact must not enter the submission."""

    result = subprocess.run(
        ["git", "check-ignore", "-q", "--", candidate],
        cwd=ROOT,
        check=False,
    )

    assert result.returncode == 0, f"local-only path is not ignored: {candidate}"


@pytest.mark.parametrize(
    "candidate",
    [
        ".env.example",
        ".env.development.example",
        "config.example.env",
        "config.example.toml",
    ],
)
def test_shareable_configuration_examples_are_not_ignored(candidate: str) -> None:
    """Safe templates must remain available as reproducible documentation."""

    result = subprocess.run(
        ["git", "check-ignore", "-q", "--", candidate],
        cwd=ROOT,
        check=False,
    )

    assert result.returncode == 1, f"shareable example is ignored: {candidate}"


@pytest.mark.parametrize("candidate", FORCE_ADDED_FORBIDDEN_CASES)
def test_force_guard_cases_are_normally_ignored(candidate: str) -> None:
    """The first Git safeguard should ignore every force-guarded artifact."""

    result = subprocess.run(
        ["git", "check-ignore", "-q", "--", candidate],
        cwd=ROOT,
        check=False,
    )

    assert result.returncode == 0, f"force-guarded path is not ignored: {candidate}"


@pytest.mark.parametrize("candidate", FORCE_ADDED_FORBIDDEN_CASES)
def test_force_added_private_or_generated_path_fails_submission_gate(
    candidate: str,
) -> None:
    """The layout gate must reject a forbidden path even after ``git add -f``."""

    assert _submission_violations([candidate]) == [candidate]


def test_contract_fixtures_live_under_tests() -> None:
    """Test inputs must not be mixed into the production contract tree."""

    fixture_root = ROOT / "tests/fixtures"
    for contract_name, relative_paths in CONTRACT_FIXTURES.items():
        for relative_path in relative_paths:
            assert (fixture_root / contract_name / relative_path).is_file()

    production_fixture_files = [
        path
        for path in (ROOT / "core").glob("**/fixtures/**/*")
        if path.is_file()
    ]
    assert production_fixture_files == []


def test_test_tools_have_one_canonical_home() -> None:
    """Reviewer and measurement tools must be discoverable below tests/."""

    for relative_path in TEST_TOOL_PATHS:
        assert (ROOT / relative_path).is_file(), f"missing test tool: {relative_path}"

    assert os.access(ROOT / "tests/run_tests.sh", os.X_OK)
    assert not (ROOT / "scripts/run_part2_2_tests.sh").exists()
    assert not (ROOT / "benchmarks").exists()
    assert not list((ROOT / "tests/godot").glob("*_benchmark.gd"))


def test_runner_uses_repository_absolute_godot_script_paths() -> None:
    """Every Godot gate must work when the runner starts outside the repo."""

    runner = (ROOT / "tests/run_tests.sh").read_text(encoding="utf-8")
    scripts = (
        "test_runner.gd",
        "test_polygon_ops.gd",
        "test_image_region_algorithms.gd",
        "test_advanced_edit_tools.gd",
        "test_keyboard_reachability.gd",
    )

    assert "--script tests/" not in runner
    for script in scripts:
        assert f'--script "$PROJECT6_ROOT/tests/godot/{script}"' in runner


def test_benchmark_source_generator_resolves_the_repository_sample() -> None:
    """Relocating the generator must not redirect it to tests/sample/."""

    module = _load_benchmark_source_generator()

    assert module.SAMPLE == ROOT / "sample/assignment_v1"


def test_benchmark_source_generator_runs_from_its_new_home(tmp_path: Path) -> None:
    """The relocated generator must still consume the canonical sample."""

    module = _load_benchmark_source_generator()
    playback_output = tmp_path / "playback"
    stress_output = tmp_path / "stress"

    module.make_playback_source(playback_output, frame_count=2)
    module.make_stress_source(stress_output, frame_count=3)

    playback_manifest = json.loads(
        (playback_output / "manifest.json").read_text(encoding="utf-8")
    )
    stress_manifest = json.loads(
        (stress_output / "manifest.json").read_text(encoding="utf-8")
    )
    assert playback_manifest["frame_count"] == 2
    assert stress_manifest["frame_count"] == 3
    assert (playback_output / "frames/frame_000001.png").is_file()
    assert (stress_output / "frames/frame_000002.png").is_file()


def _load_benchmark_source_generator():
    script_path = ROOT / "tests/benchmarks/make_part3_sources.py"
    spec = importlib.util.spec_from_file_location("make_part3_sources", script_path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _submission_violations(paths: list[str]) -> list[str]:
    """Return paths that must never be part of the submitted Git tree."""

    forbidden_prefixes = (
        ".agents/",
        ".codex/",
        ".superpowers/",
        ".worktrees/",
        "Dataset_test/",
        "android/",
        "benchmarks/",
        "core/fixtures/",
        "core/frame_source/fixtures/",
        "core/workspace/fixtures/",
        "docs/superpowers/",
        "frames/",
        "plans/",
        "sample/",
        "tests/laparoscopic_hernia_2d_frames/",
        "tests/output/",
        "tests/video_test/",
    )
    forbidden_files = {
        "docs/images.jpeg",
        "docs/laparoscopic_hernia_2d.ogv.uid",
        "docs/播放.png",
        "scripts/run_part2_2_tests.sh",
    }
    private_names = {
        ".env",
        "credentials.json",
        "id_dsa",
        "id_ecdsa",
        "id_ed25519",
        "id_rsa",
        "token.txt",
    }
    forbidden_directory_names = {
        ".agents",
        ".cache",
        ".codex",
        ".godot",
        ".mypy_cache",
        ".pytest_cache",
        ".ruff_cache",
        ".superpowers",
        ".tools",
        ".venv",
        ".worktrees",
        "__pycache__",
        "autosave",
        "build",
        "dist",
        "exports",
        "generated_frames",
        "generated_sample",
        "sample",
        "secrets",
    }

    violations = []
    for path in paths:
        path_object = Path(path)
        name = path_object.name
        is_private_env = (
            name.startswith(".env.") and not name.endswith(".example")
        ) or (name.endswith(".env") and not name.endswith(".example.env"))
        if (
            path.startswith(forbidden_prefixes)
            or path in forbidden_files
            or (path.startswith("docs/000") and name.endswith(".png"))
            or name in private_names
            or is_private_env
            or name.endswith(
                (
                    ".local.toml",
                    ".key",
                    ".pem",
                    ".p12",
                    ".pfx",
                    ".pyc",
                    ".pyo",
                    ".pyd",
                    ".tmp",
                    ".temp",
                    ".log",
                    ".import",
                )
            )
            or any(part in forbidden_directory_names for part in path_object.parts)
            or any(part.endswith(".egg-info") for part in path_object.parts)
        ):
            violations.append(path)
    return violations


def test_effective_submission_excludes_local_and_misplaced_test_content() -> None:
    """Ignored paths must still fail the layout gate if force-added to Git."""

    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )
    candidates = [
        path
        for path in result.stdout.decode("utf-8").split("\0")
        if path and (ROOT / path).exists()
    ]
    violations = _submission_violations(candidates)

    assert violations == [], f"forbidden submission paths: {violations}"
