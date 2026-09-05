import importlib.util
from pathlib import Path

import annotation_data
from annotation_data.paths import repository_root


ROOT = Path(__file__).resolve().parents[2]


def test_package_exposes_the_project_version() -> None:
    assert annotation_data.__version__ == "0.1.0"


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


def test_python_support_package_has_unambiguous_name() -> None:
    assert importlib.util.find_spec("annotation_data") is not None
    assert not (ROOT / "python/annotool").exists()
    metadata = (ROOT / "pyproject.toml").read_text(encoding="utf-8")
    assert '\nname = "annotation-data-tools"\n' in metadata
