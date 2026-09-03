from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def _read(relative_path: str) -> str:
    path = ROOT / relative_path
    assert path.is_file(), f"missing Part 1 document: {relative_path}"
    return path.read_text(encoding="utf-8")


def test_readme_is_a_complete_part1_runbook() -> None:
    readme = _read("README.md")
    lower = readme.lower()

    principles = readme.index("开发原则")
    quick_start = readme.index("快速开始")
    assert principles < quick_start
    for phrase in (
        "mitk",
        "所有权",
        "清晰接口",
        "可维护",
        "part 1 边界",
    ):
        assert phrase in lower

    for version in ("Godot 4.7.2-stable", "Python 3.14.7", "FFmpeg 6.1+"):
        assert version in readme
    for command in (
        ".venv/bin/python python/make_sample_input.py --output sample/assignment_v1 --seed 6006",
        ".venv/bin/python python/validate_model_output.py sample/assignment_v1/model_output_v1.jsonl",
        ".venv/bin/python -m pytest tests/python -q",
        "tests/godot/test_runner.gd",
        "--editor --path .",
        "ffmpeg -version",
    ):
        assert command in readme

    assert "单张图像" in readme
    assert "归一化目录" in readme
    assert "| 操作 | 快捷键 |" in readme
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
        "数据源插件",
        "不可变模型输出 + 修正副本",
        "渲染插件",
        "AnnotationViewport",
        "编辑工具插件",
        "已验证命令历史",
        "导出/回传插件",
        "修正数据/训练交接",
    ):
        assert node in architecture
    for concept in ("所有权", "不可变", "深拷贝", "故障隔离"):
        assert concept in lower


def test_plugin_api_documents_the_stable_version1_contract() -> None:
    api = _read("docs/plugin-api.md")
    lower = api.lower()
    for manifest_field in ("id", "version", "api_version", "stage", "entry"):
        assert f"`{manifest_field}`" in api
    for stage in ("source", "render", "edit", "feedback"):
        assert stage in lower
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
        "生命周期",
        "深拷贝",
        "故障隔离",
        "packedstringarray",
        "新增插件",
        "不修改 registry",
    ):
        assert phrase in lower


def test_traceability_covers_part1_and_blocks_later_scope() -> None:
    ledger = _read("docs/requirements-traceability.md")
    assert (
        "| 要求来源 | 要求 | 实现 | 自动化证据 | "
        "人工证据 | 状态 | 后续任务 |"
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


def test_part1_1_documents_match_the_implemented_contract() -> None:
    documents = "\n".join(
        _read(path)
        for path in (
            "README.md",
            "docs/architecture.md",
            "docs/plugin-api.md",
            "docs/requirements-traceability.md",
            "docs/part1-implementation-report.md",
        )
    )

    for required in (
        "core/schemas/model_output_v1.schema.json",
        "python/validate_model_output.py",
        "client/domain/model_output_validator.gd",
        "model_output_v1.jsonl",
        "sample_v1",
        "SHA-256",
    ):
        assert required in documents

    for obsolete in (
        "core/schemas/annotation-v1.schema.json",
        "python/validate_annotations.py",
        "source = human_corrected",
    ):
        assert obsolete not in documents
