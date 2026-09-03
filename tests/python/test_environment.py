from pathlib import Path

import annotool
from annotool.paths import repository_root


def test_package_exposes_the_project_version() -> None:
    assert annotool.__version__ == "0.1.0"


def test_repository_root_is_derived_from_the_package_location(
    monkeypatch, tmp_path: Path
) -> None:
    monkeypatch.chdir(tmp_path)

    assert repository_root() == Path(__file__).resolve().parents[2]


def test_repository_root_contains_required_project_files() -> None:
    root = repository_root()

    assert (root / "project.godot").is_file()
    assert (root / "client" / "app" / "main.tscn").is_file()
    assert (root / "docs" / "architecture.md").is_file()
    assert (root / "docs" / "plugin-api.md").is_file()
