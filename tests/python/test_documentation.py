from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def _read(relative_path: str) -> str:
    path = ROOT / relative_path
    assert path.is_file(), f"missing Part 1 document: {relative_path}"
    return path.read_text(encoding="utf-8")


def test_readme_is_a_complete_part1_runbook() -> None:
    readme = _read("README.md")
    lower = readme.lower()

    principles = lower.index("development principles")
    quick_start = lower.index("quick start")
    assert principles < quick_start
    for phrase in (
        "mitk",
        "structured",
        "clear interfaces",
        "maintainable",
        "part 1 boundary",
    ):
        assert phrase in lower

    for version in ("Godot 4.7.2-stable", "Python 3.14.7", "FFmpeg 6.1+"):
        assert version in readme
    for command in (
        ".venv/bin/python -m pytest tests/python -q",
        "python/make_sample_input.py --output sample/assignment_v1 --seed 6006",
        "python/validate_annotations.py sample/assignment_v1/model_output.jsonl",
        "--schema dataset-manifest-v1.schema.json sample/assignment_v1/manifest.json",
        "tests/godot/test_runner.gd",
        "--editor --path .",
        "ffmpeg -version",
    ):
        assert command in readme

    assert "standalone image" in lower
    assert "normalized directory" in lower
    assert "| action | shortcut |" in lower
    for shortcut in ("ctrl+z", "ctrl+shift+z", "shift+tab", "alt+arrow", "escape"):
        assert shortcut in lower
    for plugin_id in (
        "image_sequence_source",
        "single_image_source",
        "canvas_region_renderer",
        "basic_edit_tools",
        "file_training_handoff",
    ):
        assert plugin_id in readme


def test_architecture_document_contains_required_pipeline_and_ownership() -> None:
    architecture = _read("docs/architecture.md")
    lower = architecture.lower()
    assert "```mermaid" in architecture
    for node in (
        "Source plugin",
        "Immutable model + corrected store",
        "Render plugin",
        "AnnotationViewport",
        "Edit-tools plugin",
        "Validated command history",
        "Export / Feedback plugin",
        "Corrected data / training handoff",
    ):
        assert node in architecture
    for concept in ("ownership", "immutable", "deep copy", "failure isolation"):
        assert concept in lower


def test_plugin_api_documents_the_stable_version1_contract() -> None:
    api = _read("docs/plugin-api.md")
    lower = api.lower()
    for manifest_field in ("id", "version", "api_version", "stage", "entry"):
        assert f"`{manifest_field}`" in api
    for stage in ("source", "render", "edit", "feedback"):
        assert f"## {stage.title()}" in api
    for method in (
        "open",
        "get_frame_count",
        "get_frame_entry",
        "get_model_records",
        "get_manifest",
        "load_texture",
        "close",
        "set_state",
        "draw",
        "hit_test",
        "activate",
        "set_active_tool",
        "get_active_tool",
        "handle_pointer",
        "handle_key",
        "begin_add_box",
        "cancel",
        "relabel_selected",
        "set_selected_track_id",
        "set_selected_fill",
        "set_selected_geometry",
        "delete_selected",
        "deactivate",
        "export",
    ):
        assert f"`{method}" in api
    for phrase in (
        "api version 1",
        "export_finished",
        "lifecycle",
        "deep copy",
        "failure isolation",
        "packedstringarray",
        "add a plugin",
        "without changing the registry",
    ):
        assert phrase in lower


def test_traceability_covers_part1_and_blocks_later_scope() -> None:
    ledger = _read("docs/requirements-traceability.md")
    assert (
        "| Requirement source | Requirement | Implementation | Automated evidence | "
        "Manual evidence | Status | Next task |"
    ) in ledger
    for requirement in (
        "1.1 Data contract",
        "Python validator",
        "Godot validator",
        "1.2 Reproducible sample",
        "Drifted regions",
        "Wrong class labels",
        "Missed region",
        "Hallucinated region",
        "Track-id swap",
        "Near-identical frames",
        "1.3 Frame source",
        "Source stage",
        "Render stage",
        "Edit tools stage",
        "Export / Feedback stage",
        "Plugin registry",
        "Plugin API document",
        "Architecture diagram",
        "README runbook",
        "Zero-error sample validation",
    ):
        assert requirement in ledger

    table_rows = [line for line in ledger.splitlines() if line.startswith("|")][2:]
    assert table_rows
    for row in table_rows:
        columns = [column.strip() for column in row.strip("|").split("|")]
        assert len(columns) == 7
        assert columns[5] in {"PASS", "FAIL", "BLOCKED"}
    for part in ("Part 2", "Part 3", "Part 4", "Part 5"):
        assert any(part in row and "| BLOCKED |" in row for row in table_rows)
