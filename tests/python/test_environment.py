import importlib.util
from pathlib import Path
import tomllib

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


def test_pyproject_pins_the_complete_development_environment() -> None:
    """The single editable install must reproduce the former locked environment."""

    with (ROOT / "pyproject.toml").open("rb") as stream:
        metadata = tomllib.load(stream)

    assert metadata["build-system"]["requires"] == ["setuptools==80.9.0"]
    project = metadata["project"]
    assert project["requires-python"] == ">=3.12,<3.15"
    assert project["dependencies"] == [
        "jsonschema==4.26.0",
        "numpy==2.5.2",
        "opencv-python-headless==4.14.0.94",
    ]
    assert project["optional-dependencies"]["dev"] == [
        "attrs==26.1.0",
        "iniconfig==2.3.0",
        "jsonschema-specifications==2025.9.1",
        "packaging==26.3",
        "pluggy==1.6.0",
        "Pygments==2.21.0",
        "pytest==8.4.2",
        "referencing==0.37.0",
        "rpds-py==2026.6.3",
    ]
    all_requirements = project["dependencies"] + project["optional-dependencies"]["dev"]
    assert all("==" in requirement for requirement in all_requirements)


def test_readme_has_one_python_setup_method() -> None:
    readme = (ROOT / "README.md").read_text(encoding="utf-8")

    assert "python3.14 -m venv .venv" in readme
    assert '.venv/bin/python -m pip install -e ".[dev]"' in readme
    assert "source project_env.sh" in readme
    assert "requirements.lock" not in readme
    assert "scripts/project_env.sh" not in readme
