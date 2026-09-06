import ast
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def _read(relative_path: str) -> str:
    path = ROOT / relative_path
    assert path.is_file(), f"missing Part 1 document: {relative_path}"
    return path.read_text(encoding="utf-8")


def test_required_python_entrypoints_document_their_boundaries() -> None:
    required = {
        "python/frame_source.py": ("main", "atomic", "cancel"),
        "python/make_sample_input.py": ("parse_args", "deterministic", "seed"),
        "python/validate_model_output.py": (
            "load_schema",
            "validate_record",
            "validate_model_output",
            "read-only",
        ),
    }
    for relative_path, terms in required.items():
        source = _read(relative_path)
        tree = ast.parse(source)
        module_doc = ast.get_docstring(tree)
        assert module_doc, relative_path
        lowered = source.lower()
        for term in terms:
            assert term in lowered, f"{relative_path} must document {term}"


def test_python_support_package_paths_are_current() -> None:
    documents = "\n".join(
        _read(path)
        for path in (
            "README.md",
            "docs/architecture.md",
            "docs/plugin-api.md",
            "docs/requirements-traceability.md",
        )
    )
    assert "python/annotation_data/contracts.py" in documents
    assert "python/annotation_data/sample.py" in documents
    assert "python/annotation_data/frame_source.py" in documents
    assert "python/annotool/" not in documents


def test_readme_is_a_complete_part1_runbook() -> None:
    readme = _read("README.md")
    lower = readme.lower()

    assert "Part 3.1 整体为 **PASS**" in readme

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
        "tests/run_tests.sh",
        "tests/benchmarks/godot/display_benchmark.gd",
        "tests/benchmarks/godot/playback_benchmark.gd",
        "tests/benchmarks/godot/long_source_benchmark.gd",
        "tests/benchmarks/godot/video_import_benchmark.gd",
        "tests/benchmarks/make_part3_sources.py",
        "ffmpeg -version",
    ):
        assert command in readme

    assert "单张图像" in readme
    assert "归一化目录" in readme
    assert "| 操作 | 快捷键 |" in readme
    for shortcut in (
        "ctrl+z",
        "ctrl+shift+z",
        "alt+arrow",
        "space",
        "escape",
        "`[` / `]`",
    ):
        assert shortcut in lower
    for plugin_id in (
        "image_sequence_source",
        "single_image_source",
        "canvas_region_renderer",
        "basic_edit_tools",
        "file_training_handoff",
    ):
        assert plugin_id in readme
    for display_term in ("Overlay opacity", "Fit", "complex polygon", "RESULTS.md"):
        assert display_term in readme
    for rendering_term in (
        "dirty redraw",
        "image-space primitives",
        "AABB",
        "175.27 fps",
        "9.572 ms",
        "llvmpipe",
    ):
        assert rendering_term in readme
    for stream_term in (
        "Start import",
        "Custom",
        "3 s/frame",
        "1 s/frame",
        "Max",
        "actual FPS",
        "Time HH:MM:SS.mmm",
        "Previous",
        "Play",
        "Pause",
        "Next",
        "10,000",
    ):
        assert stream_term in readme


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
    for concept in (
        "所有权",
        "不可变",
        "深拷贝",
        "故障隔离",
        "VideoImportController",
        "PlaybackController",
        "OS.create_process()",
        "current + 1",
        "PolygonOps",
        "ImageRegionAlgorithms",
        "7 个工具",
        "Model Output V1",
    ):
        assert concept.lower() in lower


def test_part22_documents_are_truthful_during_rebuild() -> None:
    readme = _read("README.md")
    results = _read("RESULTS.md")
    architecture = _read("docs/architecture.md")
    ledger = _read("docs/requirements-traceability.md")
    combined = "\n".join((readme, results, architecture, ledger))
    for stale in (
        "11 个工具", "11-tool", "10 个工具", "9 个工具", "Wipe",
        "点击一个 region to erase", "129×129",
    ):
        assert stale not in combined
    for required in (
        "7 个工具", "Close Gaps", "Region Growing", "Live Wire", "Eraser",
        "Shift+P", "Space", "中键", "实时", "待验证",
    ):
        assert required in combined
    for part in ("Part 2.2", "Part 2.3"):
        assert any(part in row and "| BLOCKED |" in row for row in ledger.splitlines())


def test_plugin_api_documents_the_stable_version1_contract() -> None:
    api = _read("docs/plugin-api.md")
    lower = api.lower()
    for manifest_field in (
        "id",
        "version",
        "api_version",
        "stage",
        "entry",
        "priority",
        "capabilities",
    ):
        assert f"`{manifest_field}`" in api
    for stage in ("source", "render", "edit", "feedback"):
        assert stage in lower
    for method in (
        "can_open",
        "open",
        "get_frame_count",
        "get_frame_entry",
        "get_model_records",
        "get_manifest",
        "get_presentation",
        "load_texture",
        "close",
        "set_state",
        "draw",
        "hit_test",
        "activate",
        "get_tool_descriptors",
        "set_active_tool",
        "get_active_tool",
        "handle_pointer",
        "handle_key",
        "invoke",
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


def test_plugin_contracts_and_manifests_ship_in_exported_builds() -> None:
    for relative_path in (
        "client/pipeline/stages/source_stage.gd",
        "client/pipeline/stages/render_stage.gd",
        "client/pipeline/stages/edit_stage.gd",
        "client/pipeline/stages/feedback_stage.gd",
        "client/pipeline/plugin_descriptor.gd",
    ):
        assert (ROOT / relative_path).is_file()

    export_config = _read("export_presets.cfg")
    assert "client/plugins/**/*.json" in export_config


def test_traceability_covers_completed_parts_and_blocks_unfinished_scope() -> None:
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
    assert any("Part 2.1" in row and "| PASS |" in row for row in table_rows)
    assert any("Part 3.1" in row and "| PASS |" in row for row in table_rows)
    assert any(
        "Part 3.1 Frame-accurate stream" in row and "| PASS |" in row
        for row in table_rows
    )
    for part in ("Part 2.2", "Part 2.3"):
        assert any(part in row and "| BLOCKED |" in row for row in table_rows)
    for part in ("Part 3.2", "Part 3.3", "Part 4", "Part 5"):
        assert any(part in row and "| BLOCKED |" in row for row in table_rows)


def test_part21_results_match_the_reproducible_display_benchmark() -> None:
    results = _read("RESULTS.md")
    benchmark_path = ROOT / "tests/benchmarks/results/part2_1_display.json"
    assert benchmark_path.is_file()
    benchmark = json.loads(benchmark_path.read_text(encoding="utf-8"))

    assert benchmark["pass"] is True
    assert benchmark["viewport"] == [1280, 800]
    assert benchmark["region_count"] == 20
    assert benchmark["warmup_seconds"] >= 2.0
    assert benchmark["measured_seconds"] >= 10.0
    assert benchmark["mean_fps"] >= 30.0
    assert benchmark["p95_frame_ms"] <= 40.0
    assert benchmark["coordinate_error_image_px"] <= 1e-5
    for value in (
        str(benchmark["mean_fps"]),
        str(benchmark["p95_frame_ms"]),
        benchmark["video_adapter"],
        benchmark["processor"],
    ):
        assert value in results
    for required in (
        "Transform2D",
        "affine_inverse()",
        "polygon",
        "dirty redraw",
        "single-ring",
        "Part 2.2",
        "Part 2.3",
    ):
        assert required in results


def test_part31_results_match_import_playback_and_long_source_benchmarks() -> None:
    results = _read("RESULTS.md")
    playback = json.loads(
        _read("tests/benchmarks/results/part3_1_playback.json")
    )
    long_source = json.loads(
        _read("tests/benchmarks/results/part3_1_long_source.json")
    )
    video_import = json.loads(
        _read("tests/benchmarks/results/part3_1_import.json")
    )

    assert playback["pass"] is True
    assert playback["source_resolution"] == [640, 360]
    assert playback["region_count"] == 20
    assert playback["requested_clock"] == "review"
    assert playback["requested_fps"] == 30.0
    assert abs(playback["requested_seconds_per_frame"] - (1.0 / 30.0)) < 1e-12
    assert playback["measured_seconds"] >= 10.0
    assert playback["indices_continuous"] is True
    assert playback["skipped_frame_count"] == 0
    assert playback["delivered_indices"] == list(
        range(playback["first_delivered_index"], playback["last_delivered_index"] + 1)
    )
    assert playback["cache_size"] <= 12
    assert playback["cache_limit"] == 12

    assert long_source["pass"] is True
    assert long_source["frame_count"] == 10_000
    assert long_source["accepted_indices"] == long_source["seek_targets"]
    assert long_source["texture_cache_size"] <= 12
    assert long_source["explorer_tree_items"] <= 8
    assert long_source["explorer_materialized_frame_items"] == 1
    assert long_source["timeline_frame_buttons"] == 0

    assert video_import["pass"] is True
    assert video_import["loaded_frame"] == 0
    assert video_import["loaded_frame_count"] == 90
    assert video_import["old_dataset_preserved_during_import"] is True
    assert video_import["progress_monotonic"] is True
    assert set(video_import["observed_progress_stages"]) == {
        "probe", "extract", "validate", "publish"
    }
    assert video_import["ui_process_heartbeats"] > 1

    for value in (
        str(playback["actual_playback_fps"]),
        str(playback["p95_delivery_interval_ms"]),
        str(long_source["p95_seek_ms"]),
        str(video_import["import_and_open_seconds"]),
        playback["video_adapter"],
    ):
        assert value in results
    for required in (
        "OS.create_process()",
        "PlaybackFpsMeter",
        "read-only actual FPS",
        "explicit frame/time",
        "1 s/frame",
        "Max",
        "zero",
        "10,000",
        "Part 3.2",
    ):
        assert required in results


def test_part1_1_documents_match_the_implemented_contract() -> None:
    documents = "\n".join(
        _read(path)
        for path in (
            "README.md",
            "docs/architecture.md",
            "docs/plugin-api.md",
            "docs/requirements-traceability.md",
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
