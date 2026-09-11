from __future__ import annotations

import hashlib
import importlib.util
import json
import math
from pathlib import Path
import sys
from types import SimpleNamespace

import cv2
import numpy as np
import pytest

import sam_video_smoke as smoke


WIDTH = 24
HEIGHT = 16
REQUIRED_TAGS = {
    "stable",
    "fast_motion",
    "low_contrast_or_glare",
    "occlusion_or_disappearance",
}
VISIBLE_UI_CHECKS = {
    "preview",
    "early_stop",
    "cancel",
    "prefix_confirm",
    "undo_redo",
    "save_reopen",
    "reanchor",
    "new_batch",
}


def _write_png(path: Path, image: np.ndarray) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    ok, encoded = cv2.imencode(".png", image)
    assert ok
    payload = encoded.tobytes()
    path.write_bytes(payload)
    return hashlib.sha256(payload).hexdigest()


def _make_frames(root: Path, count: int) -> tuple[Path, list[int]]:
    frames = root / "frames"
    frames.mkdir(parents=True)
    frame_ids = [11825 + index * 25 for index in range(count + 1)]
    # Deliberately create them out of order.  Filesystem iteration order is not
    # the Source order contract; numeric frame identity is.
    for index in reversed(range(count + 1)):
        image = np.full((HEIGHT, WIDTH, 3), index * 3, np.uint8)
        _write_png(frames / f"{frame_ids[index]:06d}.png", image)
    return frames, frame_ids


def _environment(root: Path) -> dict[str, str]:
    config = root / "sam2.yaml"
    checkpoint = root / "sam2.pt"
    config.write_text("model: fake\n", encoding="utf-8")
    checkpoint.write_bytes(b"fake-checkpoint")
    return {
        "PROJECT6_MODEL_PYTHON": sys.executable,
        "PROJECT6_SAM2_CONFIG": str(config),
        "PROJECT6_SAM2_CHECKPOINT": str(checkpoint),
        "PROJECT6_SAM2_DEVICE": "cpu",
    }


class FakePredictor:
    sam_video_device = "cpu"

    def __init__(self) -> None:
        self.init_calls: list[str] = []
        self.add_masks: list[np.ndarray] = []
        self.propagate_counts: list[int] = []
        self.reset_count = 0
        self.close_count = 0

    def init_state(self, *, video_path: str):
        names = sorted(
            Path(video_path).iterdir(), key=lambda path: int(path.stem)
        )
        assert [path.name for path in names] == [
            f"{index:06d}.jpg" for index in range(len(names))
        ]
        self.init_calls.append(video_path)
        return {"serial": len(self.init_calls)}

    def add_new_mask(self, *, inference_state, frame_idx: int, obj_id: int, mask):
        assert inference_state["serial"] == 1
        assert frame_idx == 0
        assert obj_id == 1
        self.add_masks.append(np.asarray(mask).copy())
        logits = np.where(mask, 4.0, -4.0).astype(np.float32)[None, None]
        return 0, [1], logits

    def propagate_in_video(self, **kwargs):
        assert kwargs["reverse"] is False
        assert kwargs["start_frame_idx"] == 0
        count = kwargs["max_frame_num_to_track"]
        self.propagate_counts.append(count)
        for local_index in range(count + 1):
            logits = np.full((1, 1, HEIGHT, WIDTH), -4.0, np.float32)
            x0 = min(2 + local_index, WIDTH - 6)
            logits[0, 0, 3:10, x0:x0 + 5] = 4.0
            yield local_index, [1], logits

    def reset_state(self, inference_state) -> None:
        self.reset_count += 1

    def close(self) -> None:
        self.close_count += 1


def _factory(predictor: FakePredictor):
    calls: list[tuple[str, str, str]] = []

    def build(config: str, checkpoint: str, device: str):
        calls.append((config, checkpoint, device))
        return predictor

    return build, calls


def _snapshot_tree(root: Path) -> dict[str, str]:
    return {
        path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


def _run_fake(
    root: Path,
    count: int,
    *,
    mask: np.ndarray | None = None,
    cancel_requested=None,
) -> tuple[dict, FakePredictor, Path, Path]:
    frames, _ = _make_frames(root, count)
    mask_path = root / "key-mask.png"
    if mask is None:
        mask = smoke.rasterize_start_mask(
            (WIDTH, HEIGHT), {"box": [3, 2, 8, 7]}
        )
    _write_png(mask_path, mask)
    output = root / "evidence" / "smoke.json"
    output.parent.mkdir()
    predictor = FakePredictor()
    predictor_factory, _ = _factory(predictor)
    report = smoke.run_smoke(
        frames,
        mask_path,
        count,
        output,
        predictor_factory=predictor_factory,
        environ=_environment(root),
        cancel_requested=cancel_requested,
    )
    return report, predictor, frames, output


def test_start_masks_follow_model_output_box_and_polygon_geometry() -> None:
    box = smoke.rasterize_start_mask((12, 10), {"box": [2, 3, 5, 4]})
    expected_box = np.zeros((10, 12), np.uint8)
    expected_box[3:7, 2:7] = 255
    np.testing.assert_array_equal(box, expected_box)

    polygon = smoke.rasterize_start_mask(
        (12, 10), {"polygon": [[2, 2], [8, 2], [5, 7]]}
    )
    expected_polygon = np.zeros((10, 12), np.uint8)
    contour = np.asarray([[2, 2], [8, 2], [5, 7]], np.float32)
    for y in range(10):
        for x in range(12):
            if cv2.pointPolygonTest(contour, (x + 0.5, y + 0.5), False) >= 0:
                expected_polygon[y, x] = 255
    np.testing.assert_array_equal(polygon, expected_polygon)


def test_start_masks_accept_finite_float_geometry_with_pixel_center_semantics() -> None:
    box = smoke.rasterize_start_mask((9, 8), {"box": [2.25, 1.75, 3.5, 2.5]})
    expected_box = np.zeros((8, 9), np.uint8)
    for y in range(8):
        for x in range(9):
            if 2.25 <= x + 0.5 <= 5.75 and 1.75 <= y + 0.5 <= 4.25:
                expected_box[y, x] = 255
    np.testing.assert_array_equal(box, expected_box)

    points = [[1.25, 1.5], [7.5, 2.25], [6.25, 6.75], [2.0, 6.25]]
    polygon = smoke.rasterize_start_mask((9, 8), {"polygon": points})
    expected_polygon = np.zeros((8, 9), np.uint8)
    contour = np.asarray(points, np.float32)
    for y in range(8):
        for x in range(9):
            if cv2.pointPolygonTest(contour, (x + 0.5, y + 0.5), False) >= 0:
                expected_polygon[y, x] = 255
    np.testing.assert_array_equal(polygon, expected_polygon)


@pytest.mark.parametrize(
    "geometry",
    [
        {"box": [0.0, 0.0, math.nan, 2.0]},
        {"box": [0.0, 0.0, math.inf, 2.0]},
        {"box": [-0.1, 0.0, 2.0, 2.0]},
        {"box": [9.5, 0.0, 1.0, 2.0]},
        {"box": [0.1, 0.1, 0.1, 0.1]},
        {"polygon": [[0.0, 0.0], [math.nan, 2.0], [2.0, 0.0]]},
        {"polygon": [[0.0, 0.0], [10.1, 2.0], [2.0, 2.0]]},
        {"polygon": [[1.0, 1.0], [2.0, 2.0], [3.0, 3.0]]},
        {"polygon": [[0.1, 0.1], [0.2, 0.1], [0.1, 0.2]]},
    ],
)
def test_start_masks_reject_nonfinite_outside_or_degenerate_float_geometry(
    geometry: dict,
) -> None:
    with pytest.raises(ValueError):
        smoke.rasterize_start_mask((10, 8), geometry)


def test_candidate_topology_rejects_diagonal_touch_repeated_vertex_ring() -> None:
    candidate = np.zeros((HEIGHT, WIDTH), np.uint8)
    candidate[2:5, 2:5] = 255
    candidate[5:8, 5:8] = 255
    ok, encoded = cv2.imencode(".png", candidate)
    assert ok

    topology = smoke._topology(
        encoded.tobytes(),
        {"roi": [0, 0, WIDTH, HEIGHT]},
        (WIDTH, HEIGHT),
    )

    assert topology["status"] == "FAIL"
    assert topology["reason"] == "non_simple_polygon"


def test_sam_version_uses_distribution_then_module_and_never_unknown() -> None:
    module = SimpleNamespace(__version__="2.1.7")
    assert smoke.resolve_sam2_version(module, lambda _: "3.0.0") == "3.0.0"
    assert smoke.resolve_sam2_version(module, lambda _: "unknown") == "2.1.7"
    assert smoke.resolve_sam2_version(module, lambda _: "bad/version") == "2.1.7"

    def missing_distribution(_):
        raise importlib.metadata.PackageNotFoundError

    assert smoke.resolve_sam2_version(module, missing_distribution) == "2.1.7"
    for bad in (None, "", "unknown", "2.1/escape", "v" * 65):
        with pytest.raises(smoke.SmokeNotRun):
            smoke.resolve_sam2_version(
                SimpleNamespace(__version__=bad), missing_distribution
            )


@pytest.mark.parametrize("count", [1, 5, 30])
def test_fake_smoke_uses_backend_and_preserves_exact_ordered_mapping(
    tmp_path: Path, count: int
) -> None:
    report, predictor, _, output = _run_fake(tmp_path, count)
    expected_ids = [11825 + index * 25 for index in range(count + 1)]

    assert report["status"] == "PASS"
    assert report["input"]["count"] == count
    assert [item["frame_id"] for item in report["input"]["frames"]] == expected_ids
    assert [item["playback_index"] for item in report["input"]["frames"]] == list(
        range(count + 1)
    )
    assert [item["frame_id"] for item in report["candidates"]] == expected_ids[1:]
    assert [item["local_index"] for item in report["candidates"]] == list(
        range(1, count + 1)
    )
    assert all(item["object_id"] == 1 for item in report["candidates"])
    assert all(item["topology"]["status"] == "PASS" for item in report["candidates"])
    assert predictor.propagate_counts == [count]
    assert predictor.reset_count == 1
    assert predictor.close_count == 1
    assert report["cuda"] == {
        "peak_vram_bytes": None,
        "per_frame_propagate_ms": [],
        "inflight_cancel_latency_ms": None,
    }
    assert json.loads(output.read_text(encoding="utf-8")) == report
    artifacts = output.parent / report["artifacts"]
    assert sorted(path.name for path in artifacts.glob("*.png")) == [
        f"frame-{index:06d}.png" for index in range(1, count + 1)
    ]


@pytest.mark.parametrize(
    ("geometry", "expected"),
    [
        ({"box": [3, 2, 8, 7]}, lambda: smoke.rasterize_start_mask(
            (WIDTH, HEIGHT), {"box": [3, 2, 8, 7]}
        )),
        ({"polygon": [[2, 2], [12, 3], [9, 11], [3, 10]]}, lambda: smoke.rasterize_start_mask(
            (WIDTH, HEIGHT),
            {"polygon": [[2, 2], [12, 3], [9, 11], [3, 10]]},
        )),
    ],
)
def test_fake_backend_receives_box_or_polygon_derived_key_mask(
    tmp_path: Path, geometry: dict, expected
) -> None:
    mask = smoke.rasterize_start_mask((WIDTH, HEIGHT), geometry)
    report, predictor, _, _ = _run_fake(tmp_path, 1, mask=mask)

    assert report["status"] == "PASS"
    np.testing.assert_array_equal(predictor.add_masks, [expected() > 0])


def test_cancel_retires_backend_and_publishes_no_candidates(tmp_path: Path) -> None:
    checks = iter((False, True))
    report, predictor, _, output = _run_fake(
        tmp_path,
        1,
        cancel_requested=lambda: next(checks, True),
    )

    assert report["status"] == "NOT RUN"
    assert report["reason"] == "cancelled"
    assert report["candidates"] == []
    assert predictor.propagate_counts == []
    assert predictor.reset_count == 1
    assert predictor.close_count == 1
    assert not (output.parent / report["artifacts"]).exists()


def test_smoke_cleans_staging_and_never_mutates_frames_or_labels(tmp_path: Path) -> None:
    frames, _ = _make_frames(tmp_path, 1)
    label = frames / "model_output_v1.jsonl"
    label.write_text('{"frame":0,"regions":[]}\n', encoding="utf-8")
    before = _snapshot_tree(frames)
    mask_path = tmp_path / "mask.png"
    _write_png(
        mask_path,
        smoke.rasterize_start_mask((WIDTH, HEIGHT), {"box": [2, 2, 4, 4]}),
    )
    output = tmp_path / "out" / "smoke.json"
    output.parent.mkdir()
    predictor = FakePredictor()

    report = smoke.run_smoke(
        frames,
        mask_path,
        1,
        output,
        predictor_factory=_factory(predictor)[0],
        environ=_environment(tmp_path),
    )

    assert report["status"] == "PASS"
    assert _snapshot_tree(frames) == before
    assert not list(output.parent.glob(".sam-video-smoke-*"))


def test_smoke_refuses_to_publish_evidence_inside_the_source_directory(
    tmp_path: Path,
) -> None:
    frames, _ = _make_frames(tmp_path, 1)
    label = frames / "model_output_v1.jsonl"
    label.write_text('{"frame":0,"regions":[]}\n', encoding="utf-8")
    before = _snapshot_tree(frames)
    mask = tmp_path / "mask.png"
    _write_png(
        mask,
        smoke.rasterize_start_mask((WIDTH, HEIGHT), {"box": [2, 2, 4, 4]}),
    )

    with pytest.raises(ValueError, match="source frame directory"):
        smoke.run_smoke(
            frames,
            mask,
            1,
            frames / "must-not-be-created.json",
            predictor_factory=_factory(FakePredictor())[0],
            environ=_environment(tmp_path),
        )

    assert _snapshot_tree(frames) == before


def test_fake_smoke_json_is_deterministic_for_identical_inputs(tmp_path: Path) -> None:
    first, _, _, first_output = _run_fake(tmp_path / "first", 1)
    second, _, _, second_output = _run_fake(tmp_path / "second", 1)

    assert first == second
    assert first_output.read_bytes() == second_output.read_bytes()


@pytest.mark.parametrize("bad_count", [0, 31, True])
def test_invalid_count_is_a_fail_without_invoking_predictor(
    tmp_path: Path, bad_count
) -> None:
    frames, _ = _make_frames(tmp_path, 1)
    mask = tmp_path / "mask.png"
    _write_png(mask, np.full((HEIGHT, WIDTH), 255, np.uint8))
    output = tmp_path / "out" / "smoke.json"
    output.parent.mkdir()
    predictor = FakePredictor()

    report = smoke.run_smoke(
        frames,
        mask,
        bad_count,
        output,
        predictor_factory=_factory(predictor)[0],
        environ=_environment(tmp_path),
    )

    assert report["status"] == "FAIL"
    assert "count" in report["reason"]
    assert predictor.init_calls == []


def test_nonbinary_key_mask_fails_before_predictor_load(tmp_path: Path) -> None:
    frames, _ = _make_frames(tmp_path, 1)
    mask = np.zeros((HEIGHT, WIDTH), np.uint8)
    mask[3:8, 4:9] = 17
    mask_path = tmp_path / "mask.png"
    _write_png(mask_path, mask)
    output = tmp_path / "out" / "smoke.json"
    output.parent.mkdir()
    predictor = FakePredictor()

    report = smoke.run_smoke(
        frames,
        mask_path,
        1,
        output,
        predictor_factory=_factory(predictor)[0],
        environ=_environment(tmp_path),
    )

    assert report["status"] == "FAIL"
    assert "binary" in report["reason"]
    assert predictor.init_calls == []


def test_missing_real_runtime_is_not_run_and_never_pass(tmp_path: Path) -> None:
    output = tmp_path / "smoke.json"

    report = smoke.run_smoke(
        tmp_path / "unread-frames",
        tmp_path / "unread-mask.png",
        1,
        output,
        environ={},
    )

    assert report["status"] == "NOT RUN"
    assert "PROJECT6_MODEL_PYTHON" in report["reason"]
    assert report["candidates"] == []


def test_real_smoke_refuses_a_different_interpreter_without_reading_media(
    tmp_path: Path,
) -> None:
    configured_python = tmp_path / "different-python"
    configured_python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    configured_python.chmod(0o700)
    environment = _environment(tmp_path)
    environment["PROJECT6_MODEL_PYTHON"] = str(configured_python)

    report = smoke.run_smoke(
        tmp_path / "must-not-be-read",
        tmp_path / "must-not-be-read.png",
        1,
        tmp_path / "mismatch.json",
        environ=environment,
    )

    assert report["status"] == "NOT RUN"
    assert "current interpreter" in report["reason"]
    assert report["input"]["frames"] == []


def _acceptance_module():
    path = Path(__file__).resolve().parents[1] / "acceptance" / "run_sam_video_acceptance.py"
    spec = importlib.util.spec_from_file_location("run_sam_video_acceptance", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _minimal_case(tmp_path: Path, identifier: str = "case-1") -> dict:
    return {
        "id": identifier,
        "tag": "stable",
        "frames": str(tmp_path / "explicit-frames"),
        "box": [1.0, 1.0, 3.0, 3.0],
        "polygon": [[1.0, 1.0], [4.0, 1.0], [2.0, 4.0]],
        "independent_truth": None,
        "human_review": None,
        "paired_timing": None,
    }


def _write_allowlist(path: Path, cases: list[dict]) -> None:
    path.write_text(json.dumps({
        "schema": "project6-sam-video-cases-v1",
        "required_tags": [
            "stable",
            "fast_motion",
            "low_contrast_or_glare",
            "occlusion_or_disappearance",
        ],
        "cases": cases,
    }), encoding="utf-8")


@pytest.mark.parametrize(
    "identifier",
    ["../escape", "nested/escape", "nested\\escape", "/tmp/escape", ".", ".."],
)
def test_case_id_is_a_strict_portable_basename_and_cannot_escape_private_work(
    tmp_path: Path, identifier: str
) -> None:
    module = _acceptance_module()
    allowlist = tmp_path / "cases.json"
    _write_allowlist(allowlist, [_minimal_case(tmp_path, identifier)])
    private_work = tmp_path / "private"
    private_work.mkdir()
    outside = tmp_path / "escape-box-1-mask.png"
    outside.write_bytes(b"sentinel")

    with pytest.raises(ValueError, match="portable basename"):
        module.load_cases(allowlist)

    assert outside.read_bytes() == b"sentinel"
    assert list(private_work.iterdir()) == []


def test_derived_acceptance_paths_stay_direct_children_and_writes_are_exclusive(
    tmp_path: Path,
) -> None:
    module = _acceptance_module()
    private_work = tmp_path / "private"
    private_work.mkdir()
    mask_path = module._private_child(private_work, "case-1-box-1-mask.png")
    report_path = module._private_child(private_work, "case-1-box-1.json")
    assert mask_path.parent == private_work.resolve(strict=True)
    assert report_path.parent == private_work.resolve(strict=True)

    image = np.zeros((4, 4), np.uint8)
    module._write_png(mask_path, image)
    with pytest.raises(FileExistsError):
        module._write_png(mask_path, image)
    module._write_report(report_path, {"status": "sentinel"})
    assert json.loads(report_path.read_text(encoding="utf-8")) == {
        "status": "sentinel"
    }
    with pytest.raises(FileExistsError):
        module._write_report(report_path, {"status": "replacement"})


def test_empty_allowlist_reports_all_evidence_sections_not_run(tmp_path: Path) -> None:
    cases_path = Path(__file__).resolve().parents[1] / "acceptance" / "sam_video_cases.json"
    cases = json.loads(cases_path.read_text(encoding="utf-8"))
    assert set(cases) == {"schema", "required_tags", "cases"}
    assert set(cases["required_tags"]) == REQUIRED_TAGS
    assert cases["cases"] == []

    report = _acceptance_module().generate_acceptance_report(
        cases_path,
        environ={},
    )
    assert set(report) == {
        "schema",
        "environment",
        "functional",
        "quality",
        "efficiency",
        "cuda_performance",
    }
    for section in (
        "environment",
        "functional",
        "quality",
        "efficiency",
        "cuda_performance",
    ):
        assert report[section]["status"] == "NOT RUN"
        assert report[section]["reason"]


def test_acceptance_cli_parser_binds_explicit_machine_inputs(tmp_path: Path) -> None:
    module = _acceptance_module()
    cases = tmp_path / "cases.json"
    visible_ui = tmp_path / "visible-ui.json"
    output = tmp_path / "acceptance.json"

    args = module._parser().parse_args([
        "--cases",
        str(cases),
        "--visible-ui-evidence",
        str(visible_ui),
        "--json-out",
        str(output),
    ])

    assert args.cases == cases
    assert args.visible_ui_evidence == visible_ui
    assert args.json_out == output


def _passing_preflight(device: str = "cpu"):
    def preflight(_):
        return {
            "status": "PASS",
            "reason": "",
            "requested_device": device,
            "checkpoint_sha256": "a" * 64,
            "config_sha256": "b" * 64,
            "python_version": "3.14.7",
            "torch_version": "fake",
            "sam2_version": "2.1.7",
            "cuda_available": device == "cuda",
            "cuda_device": "test GPU" if device == "cuda" else None,
        }

    return preflight


def _configured_acceptance_fixture(
    tmp_path: Path,
) -> tuple[Path, np.ndarray, list[int]]:
    mask = smoke.rasterize_start_mask(
        (WIDTH, HEIGHT), {"box": [3, 2, 8, 7]}
    )
    target_ids = [11850 + index * 25 for index in range(30)]
    cases = []
    for index, tag in enumerate(sorted(REQUIRED_TAGS)):
        frames = tmp_path / f"explicit-frames-{index}"
        frames.mkdir(parents=True)
        for frame_index, frame_id in enumerate([11825, *target_ids]):
            image = np.full((HEIGHT, WIDTH, 3), frame_index * 3, np.uint8)
            _write_png(frames / f"{frame_id:06d}.png", image)
        truth = []
        for target_index, frame_id in enumerate(target_ids):
            path = tmp_path / f"truth-{index}-{target_index}.png"
            _write_png(path, mask)
            truth.append({"frame_id": frame_id, "mask": str(path)})
        cases.append({
            "id": f"case-{index}",
            "tag": tag,
            "frames": str(frames),
            "box": [3, 2, 8, 7],
            "polygon": [[3, 2], [10, 2], [10, 8], [3, 8]],
            "independent_truth": truth,
            "human_review": {
                "direct_accept": 30,
                "minor_correction": 0,
                "redraw": 0,
                "reanchor_count": 0,
                "stop_frame": None,
                "silent_drift": 0,
            },
            "paired_timing": {"manual_seconds": 12.0, "sam_seconds": 5.0},
        })
    cases_path = tmp_path / "cases.json"
    _write_allowlist(cases_path, cases)
    return cases_path, mask, target_ids


def _acceptance_invoker(
    mask: np.ndarray,
    target_ids: list[int],
    *,
    device: str = "cpu",
    fail: bool = False,
    old_cuda_fields: bool = False,
    measured_cuda: bool = False,
):
    def invoke(case, geometry, count, environ, work):
        del environ, work
        frame_paths = sorted(
            Path(case["frames"]).glob("*.png"),
            key=lambda path: int(path.stem),
        )[:count + 1]
        input_frames = []
        for playback_index, path in enumerate(frame_paths):
            image = cv2.imread(str(path), cv2.IMREAD_COLOR)
            assert image is not None
            input_frames.append({
                "name": path.name,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "width": int(image.shape[1]),
                "height": int(image.shape[0]),
                "playback_index": playback_index,
                "frame_id": int(path.stem),
            })
        selected = [item["frame_id"] for item in input_frames[1:]]
        return {
            "status": "FAIL" if fail and case["id"] == "case-0" and geometry == "box" and count == 1 else "PASS",
            "reason": "controlled smoke failure" if fail else "",
            "case_id": case["id"],
            "tag": case["tag"],
            "start": geometry,
            "count": count,
            "frame_ids": [item["frame_id"] for item in input_frames],
            "generated_count": len(selected),
            "timings_ms": {"load": 10.0, "open": 20.0, "propagate": float(count)},
            "stop": None,
            "actual_device": device,
            "checkpoint_sha256": "a" * 64,
            "_environment": {
                "python_version": "3.14.7",
                "torch_version": "fake",
                "sam2_version": "2.1.7",
                "cuda_available": device == "cuda",
                "requested_device": device,
                "actual_device": device,
                "config_sha256": "b" * 64,
                "checkpoint_sha256": "a" * 64,
            },
            "cuda": (
                {"peak_vram_bytes": 1234, "cancel_latency_ms": 0.2}
                if old_cuda_fields
                else ({
                    "peak_vram_bytes": 1234,
                    "per_frame_propagate_ms": [1.0, 2.0, 3.0],
                    "inflight_cancel_latency_ms": 0.4,
                } if measured_cuda else {
                    "peak_vram_bytes": None,
                    "per_frame_propagate_ms": [],
                    "inflight_cancel_latency_ms": None,
                })
            ),
            "_input_frames": input_frames,
            "_candidate_masks": {frame_id: mask.copy() for frame_id in selected},
        }

    return invoke


def test_runtime_binds_frame_identity_to_the_explicit_source_directory(
    tmp_path: Path,
) -> None:
    cases_path, mask, target_ids = _configured_acceptance_fixture(tmp_path)
    base_invoker = _acceptance_invoker(mask, target_ids)

    def foreign_but_internally_consistent(case, geometry, count, environ, work):
        result = base_invoker(case, geometry, count, environ, work)
        foreign_ids = [frame_id + 1000 for frame_id in result["frame_ids"]]
        result["frame_ids"] = foreign_ids
        result["_candidate_masks"] = {
            frame_id: mask.copy() for frame_id in foreign_ids[1:]
        }
        for descriptor, frame_id in zip(result["_input_frames"], foreign_ids):
            descriptor["frame_id"] = frame_id
        return result

    report = _acceptance_module().generate_acceptance_report(
        cases_path,
        environ={"explicit": "test-only"},
        smoke_invoker=foreign_but_internally_consistent,
        environment_probe=_passing_preflight(),
    )

    assert report["functional"]["runtime_smoke"]["status"] == "FAIL"
    assert all(
        run["status"] == "FAIL"
        for run in report["functional"]["runtime_smoke"]["runs"]
    )


@pytest.mark.parametrize("field", ["sha256", "width", "playback_index"])
def test_runtime_binds_input_descriptor_to_locally_discovered_source(
    tmp_path: Path, field: str
) -> None:
    cases_path, mask, target_ids = _configured_acceptance_fixture(tmp_path)
    base_invoker = _acceptance_invoker(mask, target_ids)

    def tampered_input(case, geometry, count, environ, work):
        result = base_invoker(case, geometry, count, environ, work)
        descriptor = result["_input_frames"][0]
        descriptor[field] = (
            "f" * 64 if field == "sha256" else int(descriptor[field]) + 1
        )
        return result

    report = _acceptance_module().generate_acceptance_report(
        cases_path,
        environ={"explicit": "test-only"},
        smoke_invoker=tampered_input,
        environment_probe=_passing_preflight(),
    )

    assert report["functional"]["runtime_smoke"]["status"] == "FAIL"


@pytest.mark.parametrize(
    "mutation",
    [
        "count_float",
        "frame_ids_float",
        "input_playback_bool",
        "status_list",
        "checkpoint_mismatch",
        "device_list",
        "timing_integer",
        "cuda_extra_field",
        "cuda_sample_integer",
    ],
)
def test_runtime_normalizes_wrong_run_identity_types_to_fail(
    tmp_path: Path, mutation: str
) -> None:
    cases_path, mask, target_ids = _configured_acceptance_fixture(tmp_path)
    base_invoker = _acceptance_invoker(mask, target_ids)

    def malformed_run(case, geometry, count, environ, work):
        result = base_invoker(case, geometry, count, environ, work)
        if mutation == "count_float":
            result["count"] = float(count)
        elif mutation == "frame_ids_float":
            result["frame_ids"] = [float(value) for value in result["frame_ids"]]
        elif mutation == "input_playback_bool":
            result["_input_frames"][0]["playback_index"] = False
        elif mutation == "status_list":
            result["status"] = []
        elif mutation == "checkpoint_mismatch":
            result["checkpoint_sha256"] = "f" * 64
        elif mutation == "device_list":
            result["actual_device"] = []
        elif mutation == "timing_integer":
            result["timings_ms"]["load"] = 10
        elif mutation == "cuda_extra_field":
            result["cuda"]["unexpected"] = True
        elif mutation == "cuda_sample_integer":
            result["cuda"] = {
                "peak_vram_bytes": 1234,
                "per_frame_propagate_ms": [1],
                "inflight_cancel_latency_ms": 0.4,
            }
        return result

    report = _acceptance_module().generate_acceptance_report(
        cases_path,
        environ={"explicit": "test-only"},
        smoke_invoker=malformed_run,
        environment_probe=_passing_preflight(),
    )

    assert report["functional"]["runtime_smoke"]["status"] == "FAIL"


def test_environment_probe_pass_requires_exact_typed_provenance(
    tmp_path: Path,
) -> None:
    cases_path, mask, target_ids = _configured_acceptance_fixture(tmp_path)

    report = _acceptance_module().generate_acceptance_report(
        cases_path,
        environ={"explicit": "test-only"},
        smoke_invoker=_acceptance_invoker(mask, target_ids),
        environment_probe=lambda _: {
            "status": "PASS",
            "reason": "",
            "checkpoint_sha256": "a" * 64,
        },
    )

    assert report["environment"]["status"] == "FAIL"
    assert report["functional"]["status"] == "NOT RUN"


def test_exact_truth_and_paired_timing_do_not_upgrade_unrun_visible_ui(
    tmp_path: Path,
) -> None:
    cases_path, mask, target_ids = _configured_acceptance_fixture(tmp_path)
    report = _acceptance_module().generate_acceptance_report(
        cases_path,
        environ={"explicit": "test-only"},
        smoke_invoker=_acceptance_invoker(mask, target_ids),
        environment_probe=_passing_preflight(),
    )

    assert report["environment"]["status"] == "PASS"
    assert report["functional"]["status"] == "NOT RUN"
    assert report["functional"]["runtime_smoke"]["status"] == "PASS"
    assert len(report["functional"]["runtime_smoke"]["runs"]) == 24
    assert all(
        "_candidate_masks" not in run
        for run in report["functional"]["runtime_smoke"]["runs"]
    )
    assert report["functional"]["visible_ui"]["status"] == "NOT RUN"
    assert report["quality"]["status"] == "PASS"
    assert len(report["quality"]["cases"]) == 4
    assert all(
        len(item["frames"]) == 30
        and [frame["frame_id"] for frame in item["frames"]] == target_ids
        and all(frame["iou"] == 1.0 and frame["boundary_error_px"] == 0.0 for frame in item["frames"])
        for item in report["quality"]["cases"]
    )
    assert report["efficiency"]["status"] == "PASS"
    assert report["efficiency"]["cases"][0]["manual_seconds"] == 12.0
    assert report["cuda_performance"]["status"] == "NOT RUN"
    assert "peak_vram_bytes" not in report["cuda_performance"]


@pytest.mark.parametrize(
    ("conflict", "expected_status"),
    [
        ("empty_truth", "NOT RUN"),
        ("missing_truth", "FAIL"),
        ("wrong_review_count", "FAIL"),
        ("silent_drift_too_large", "FAIL"),
        ("stop_mismatch", "FAIL"),
    ],
)
def test_quality_requires_exact_candidate_coverage_and_consistent_human_evidence(
    tmp_path: Path, conflict: str, expected_status: str
) -> None:
    cases_path, mask, target_ids = _configured_acceptance_fixture(tmp_path)
    payload = json.loads(cases_path.read_text(encoding="utf-8"))
    first = payload["cases"][0]
    if conflict == "empty_truth":
        first["independent_truth"] = []
    elif conflict == "missing_truth":
        first["independent_truth"].pop()
    elif conflict == "wrong_review_count":
        first["human_review"]["direct_accept"] = 29
    elif conflict == "silent_drift_too_large":
        first["human_review"]["silent_drift"] = 31
    else:
        first["human_review"]["stop_frame"] = target_ids[-1]
    cases_path.unlink()
    _write_allowlist(cases_path, payload["cases"])

    report = _acceptance_module().generate_acceptance_report(
        cases_path,
        environ={"explicit": "test-only"},
        smoke_invoker=_acceptance_invoker(mask, target_ids),
        environment_probe=_passing_preflight(),
    )

    assert report["quality"]["status"] == expected_status
    assert report["quality"]["reason"]


def test_old_cuda_total_and_posthoc_cancel_fields_invalidate_runtime_evidence(
    tmp_path: Path,
) -> None:
    cases_path, mask, target_ids = _configured_acceptance_fixture(tmp_path)
    report = _acceptance_module().generate_acceptance_report(
        cases_path,
        environ={"explicit": "test-only"},
        smoke_invoker=_acceptance_invoker(
            mask, target_ids, device="cuda", old_cuda_fields=True
        ),
        environment_probe=_passing_preflight("cuda"),
    )

    assert report["functional"]["runtime_smoke"]["status"] == "FAIL"
    assert report["cuda_performance"]["status"] == "NOT RUN"
    assert report["cuda_performance"]["reason"]
    assert "propagate_p50_ms" not in report["cuda_performance"]
    assert "propagate_p95_ms" not in report["cuda_performance"]


def test_cuda_aggregation_uses_only_explicit_per_frame_and_inflight_evidence(
    tmp_path: Path,
) -> None:
    cases_path, mask, target_ids = _configured_acceptance_fixture(tmp_path)
    report = _acceptance_module().generate_acceptance_report(
        cases_path,
        environ={"explicit": "test-only"},
        smoke_invoker=_acceptance_invoker(
            mask, target_ids, device="cuda", measured_cuda=True
        ),
        environment_probe=_passing_preflight("cuda"),
    )

    cuda = report["cuda_performance"]
    assert cuda["status"] == "PASS"
    assert cuda["propagate_p50_ms"] == 2.0
    assert cuda["propagate_p95_ms"] == 3.0
    assert cuda["peak_vram_bytes"] == 1234
    assert cuda["inflight_cancel_latency_ms"] == 0.4


def test_quality_accepts_truth_order_independent_exact_identity_coverage(
    tmp_path: Path,
) -> None:
    cases_path, mask, target_ids = _configured_acceptance_fixture(tmp_path)
    payload = json.loads(cases_path.read_text(encoding="utf-8"))
    for case in payload["cases"]:
        case["independent_truth"].reverse()
    cases_path.unlink()
    _write_allowlist(cases_path, payload["cases"])

    report = _acceptance_module().generate_acceptance_report(
        cases_path,
        environ={"explicit": "test-only"},
        smoke_invoker=_acceptance_invoker(mask, target_ids),
        environment_probe=_passing_preflight(),
    )

    assert report["quality"]["status"] == "PASS"
    assert [
        frame["frame_id"] for frame in report["quality"]["cases"][0]["frames"]
    ] == target_ids


def test_quality_matches_human_stop_to_actual_published_prefix(tmp_path: Path) -> None:
    cases_path, mask, target_ids = _configured_acceptance_fixture(tmp_path)
    payload = json.loads(cases_path.read_text(encoding="utf-8"))
    first = payload["cases"][0]
    first["independent_truth"].pop()
    first["human_review"]["direct_accept"] = 29
    first["human_review"]["stop_frame"] = target_ids[-1]
    cases_path.unlink()
    _write_allowlist(cases_path, payload["cases"])
    base_invoker = _acceptance_invoker(mask, target_ids)

    def stopped_invoker(case, geometry, count, environ, work):
        result = base_invoker(case, geometry, count, environ, work)
        if case["id"] == "case-0" and geometry == "polygon" and count == 30:
            result["generated_count"] = 29
            result["_candidate_masks"].pop(target_ids[-1])
            result["stop"] = {
                "kind": "candidate_topology",
                "frame_id": target_ids[-1],
                "playback_index": 30,
                "topology": {
                    "status": "FAIL",
                    "reason": "non_simple_polygon",
                    "vertex_count": 10,
                },
            }
        return result

    report = _acceptance_module().generate_acceptance_report(
        cases_path,
        environ={"explicit": "test-only"},
        smoke_invoker=stopped_invoker,
        environment_probe=_passing_preflight(),
    )

    assert report["quality"]["status"] == "PASS"
    measured = next(
        case for case in report["quality"]["cases"] if case["case_id"] == "case-0"
    )
    assert len(measured["frames"]) == 29
    assert measured["stop_frame"] == target_ids[-1]


def _write_visible_ui_evidence(
    path: Path,
    *,
    case_id: str = "case-0",
    checkpoint_sha256: str = "a" * 64,
    device: str = "cpu",
    sam2_version: str = "2.1.7",
    failing_check: str | None = None,
) -> None:
    checks = {name: "PASS" for name in VISIBLE_UI_CHECKS}
    if failing_check is not None:
        checks[failing_check] = "FAIL"
    path.write_text(json.dumps({
        "schema": "project6-sam-video-visible-ui-v1",
        "case_id": case_id,
        "runtime": {
            "python_version": "3.14.7",
            "torch_version": "fake",
            "sam2_version": sam2_version,
        },
        "checkpoint_sha256": checkpoint_sha256,
        "device": device,
        "checks": checks,
    }), encoding="utf-8")


def test_functional_pass_requires_bound_visible_ui_evidence(tmp_path: Path) -> None:
    cases_path, mask, target_ids = _configured_acceptance_fixture(tmp_path)
    evidence = tmp_path / "visible-ui.json"
    _write_visible_ui_evidence(evidence)

    report = _acceptance_module().generate_acceptance_report(
        cases_path,
        environ={"explicit": "test-only"},
        smoke_invoker=_acceptance_invoker(mask, target_ids),
        environment_probe=_passing_preflight(),
        visible_ui_evidence=evidence,
    )

    assert report["functional"]["status"] == "PASS"
    assert report["functional"]["runtime_smoke"]["status"] == "PASS"
    assert report["functional"]["visible_ui"]["status"] == "PASS"
    assert report["functional"]["visible_ui"]["case_id"] == "case-0"
    assert report["functional"]["visible_ui"]["checks"] == {
        name: "PASS" for name in VISIBLE_UI_CHECKS
    }


def test_all_real_smokes_with_zero_reviewable_candidates_cannot_pass_functional(
    tmp_path: Path,
) -> None:
    cases_path, mask, target_ids = _configured_acceptance_fixture(tmp_path)
    evidence = tmp_path / "visible-ui.json"
    _write_visible_ui_evidence(evidence)
    base_invoker = _acceptance_invoker(mask, target_ids)

    def zero_candidate_invoker(case, geometry, count, environ, work):
        result = base_invoker(case, geometry, count, environ, work)
        result["generated_count"] = 0
        result["stop"] = {
            "kind": "candidate_topology",
            "frame_id": result["frame_ids"][1],
        }
        result["_candidate_masks"] = {}
        return result

    report = _acceptance_module().generate_acceptance_report(
        cases_path,
        environ={"explicit": "test-only"},
        smoke_invoker=zero_candidate_invoker,
        environment_probe=_passing_preflight(),
        visible_ui_evidence=evidence,
    )

    assert len(report["functional"]["runtime_smoke"]["runs"]) == 24
    assert report["functional"]["runtime_smoke"]["status"] == "FAIL"
    assert report["functional"]["status"] == "FAIL"


def test_runtime_rejects_pass_report_with_incomplete_candidate_artifacts(
    tmp_path: Path,
) -> None:
    cases_path, mask, target_ids = _configured_acceptance_fixture(tmp_path)
    base_invoker = _acceptance_invoker(mask, target_ids)

    def incomplete_invoker(case, geometry, count, environ, work):
        result = base_invoker(case, geometry, count, environ, work)
        if case["id"] == "case-0" and geometry == "box" and count == 5:
            result["_candidate_masks"].pop(target_ids[2])
        return result

    report = _acceptance_module().generate_acceptance_report(
        cases_path,
        environ={"explicit": "test-only"},
        smoke_invoker=incomplete_invoker,
        environment_probe=_passing_preflight(),
    )

    malformed = next(
        run
        for run in report["functional"]["runtime_smoke"]["runs"]
        if run["case_id"] == "case-0"
        and run["start"] == "box"
        and run["count"] == 5
    )
    assert malformed["status"] == "FAIL"
    assert malformed["reason"]
    assert report["functional"]["runtime_smoke"]["status"] == "FAIL"


@pytest.mark.parametrize(
    "mutation",
    [
        "nan_score",
        "wrong_local_index",
        "wrong_playback_index",
        "wrong_frame_id",
        "wrong_object_id",
        "wrong_hash",
        "extra_field",
        "missing_field",
        "nested_path",
        "global_nan",
        "duplicate_key",
        "input_count_float",
        "input_count_bool",
        "frame_width_float",
        "frame_height_float",
        "frame_playback_bool",
        "frame_id_float",
        "topology_component_bool",
        "topology_holes_int",
        "topology_vertex_float",
        "topology_foreground_float",
        "topology_iou_bool",
        "integer_score",
        "topology_iou_int",
        "environment_missing_field",
        "environment_extra_field",
        "environment_wrong_config_hash",
        "environment_wrong_checkpoint_hash",
        "environment_requested_device_mismatch",
        "environment_cuda_available_int",
        "cuda_extra_field",
        "cuda_peak_bool",
        "report_list",
        "candidates_object",
        "candidate_list",
        "environment_list",
        "candidate_path_list",
        "input_list",
    ],
)
def test_real_smoke_invocation_rejects_malformed_candidate_descriptor_before_masking(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, mutation: str
) -> None:
    module = _acceptance_module()
    cases_path, _, _ = _configured_acceptance_fixture(tmp_path)
    case = module.load_cases(cases_path)["cases"][0]
    sources = smoke.ordered_frame_sources(case["frames"], 1)
    candidate = np.zeros((HEIGHT, WIDTH), np.uint8)
    candidate[3:10, 3:11] = 255
    x, y, width, height = 3, 3, 8, 7
    ok, encoded = cv2.imencode(".png", candidate[y:y + height, x:x + width])
    assert ok
    payload = encoded.tobytes()
    descriptor = {
        "local_index": 1,
        "playback_index": sources[1]["playback_index"],
        "frame_id": sources[1]["frame_id"],
        "object_id": 1,
        "path": "frame-000001.png",
        "roi": [x, y, width, height],
        "score": 0.75,
        "sha256": hashlib.sha256(payload).hexdigest(),
        "topology": smoke._topology(
            payload,
            {"roi": [x, y, width, height]},
            (WIDTH, HEIGHT),
        ),
    }
    if mutation == "nan_score":
        descriptor["score"] = math.nan
    elif mutation == "wrong_local_index":
        descriptor["local_index"] = 2
    elif mutation == "wrong_playback_index":
        descriptor["playback_index"] += 1
    elif mutation == "wrong_frame_id":
        descriptor["frame_id"] += 1
    elif mutation == "wrong_object_id":
        descriptor["object_id"] = 2
    elif mutation == "wrong_hash":
        descriptor["sha256"] = "f" * 64
    elif mutation == "extra_field":
        descriptor["unexpected"] = True
    elif mutation == "missing_field":
        descriptor.pop("topology")
    elif mutation == "nested_path":
        descriptor["path"] = "nested/frame-000001.png"
    elif mutation == "topology_component_bool":
        descriptor["topology"]["component_count"] = True
    elif mutation == "topology_holes_int":
        descriptor["topology"]["has_holes"] = 0
    elif mutation == "topology_vertex_float":
        descriptor["topology"]["vertex_count"] = float(
            descriptor["topology"]["vertex_count"]
        )
    elif mutation == "topology_foreground_float":
        descriptor["topology"]["foreground_pixels"] = float(
            descriptor["topology"]["foreground_pixels"]
        )
    elif mutation == "topology_iou_bool":
        descriptor["topology"]["roundtrip_iou"] = True
    elif mutation == "integer_score":
        descriptor["score"] = 1
    elif mutation == "topology_iou_int":
        descriptor["topology"]["roundtrip_iou"] = 1
    elif mutation == "candidate_path_list":
        descriptor["path"] = []

    def fake_run(command, **kwargs):
        del kwargs
        report_path = Path(command[command.index("--json-out") + 1])
        artifacts_name = report_path.stem + ".artifacts"
        artifacts = report_path.parent / artifacts_name
        artifacts.mkdir()
        (artifacts / "frame-000001.png").write_bytes(payload)
        report_payload = {
            "schema": "project6-sam-video-smoke-v1",
            "status": "PASS",
            "reason": "",
            "environment": {
                "python_version": "3.14.7",
                "torch_version": "2.8.0",
                "sam2_version": "2.1.7",
                "cuda_available": False,
                "requested_device": "cpu",
                "actual_device": "cpu",
                "config_sha256": hashlib.sha256(config.read_bytes()).hexdigest(),
                "checkpoint_sha256": hashlib.sha256(checkpoint.read_bytes()).hexdigest(),
            },
            "input": {
                "count": 1,
                "key_mask_sha256": hashlib.sha256(
                    Path(command[command.index("--mask") + 1]).read_bytes()
                ).hexdigest(),
                "frames": [
                    {
                        key: source[key]
                        for key in (
                            "name",
                            "sha256",
                            "width",
                            "height",
                            "playback_index",
                            "frame_id",
                        )
                    }
                    for source in sources
                ],
            },
            "timings_ms": {"load": 1.0, "open": 2.0, "propagate": 3.0},
            "candidates": [descriptor],
            "stop": None,
            "artifacts": artifacts_name,
            "cuda": {
                "peak_vram_bytes": None,
                "per_frame_propagate_ms": [],
                "inflight_cancel_latency_ms": None,
            },
        }
        if mutation == "global_nan":
            report_payload["timings_ms"]["propagate"] = math.nan
        elif mutation == "input_count_float":
            report_payload["input"]["count"] = 1.0
        elif mutation == "input_count_bool":
            report_payload["input"]["count"] = True
        elif mutation == "frame_width_float":
            report_payload["input"]["frames"][0]["width"] = float(WIDTH)
        elif mutation == "frame_height_float":
            report_payload["input"]["frames"][0]["height"] = float(HEIGHT)
        elif mutation == "frame_playback_bool":
            report_payload["input"]["frames"][0]["playback_index"] = False
        elif mutation == "frame_id_float":
            frame = report_payload["input"]["frames"][0]
            frame["frame_id"] = float(frame["frame_id"])
        elif mutation == "report_list":
            report_payload = []
        elif mutation == "candidates_object":
            report_payload["candidates"] = {}
        elif mutation == "candidate_list":
            report_payload["candidates"] = [[]]
        elif mutation == "environment_list":
            report_payload["environment"] = ["invalid"]
        elif mutation == "input_list":
            report_payload["input"] = []
        elif mutation == "environment_missing_field":
            report_payload["environment"].pop("sam2_version")
        elif mutation == "environment_extra_field":
            report_payload["environment"]["unexpected"] = True
        elif mutation == "environment_wrong_config_hash":
            report_payload["environment"]["config_sha256"] = "f" * 64
        elif mutation == "environment_wrong_checkpoint_hash":
            report_payload["environment"]["checkpoint_sha256"] = "f" * 64
        elif mutation == "environment_requested_device_mismatch":
            report_payload["environment"]["requested_device"] = "cuda"
        elif mutation == "environment_cuda_available_int":
            report_payload["environment"]["cuda_available"] = 0
        elif mutation == "cuda_extra_field":
            report_payload["cuda"]["unexpected"] = True
        elif mutation == "cuda_peak_bool":
            report_payload["cuda"]["peak_vram_bytes"] = False
        serialized = json.dumps(report_payload, allow_nan=True)
        if mutation == "duplicate_key":
            serialized = serialized.replace(
                '"schema": "project6-sam-video-smoke-v1"',
                '"schema": "project6-sam-video-smoke-v1", "schema": "project6-sam-video-smoke-v1"',
                1,
            )
        report_path.write_text(serialized, encoding="utf-8")
        return SimpleNamespace(returncode=0, stdout=b"", stderr=b"")

    monkeypatch.setattr(module.subprocess, "run", fake_run)
    work = tmp_path / "work"
    work.mkdir()
    config = tmp_path / "configured-sam2.yaml"
    checkpoint = tmp_path / "configured-sam2.pt"
    config.write_text("model: fake\n", encoding="utf-8")
    checkpoint.write_bytes(b"checkpoint")
    result = module._invoke_real_smoke(
        case,
        "box",
        1,
        {
            "PROJECT6_MODEL_PYTHON": sys.executable,
            "PROJECT6_SAM2_CONFIG": str(config),
            "PROJECT6_SAM2_CHECKPOINT": str(checkpoint),
            "PROJECT6_SAM2_DEVICE": "cpu",
        },
        work,
    )

    assert result["status"] == "FAIL"
    assert result["reason"]
    assert result.get("_candidate_masks", {}) == {}


def test_strict_json_rejects_nested_exponent_overflow() -> None:
    module = _acceptance_module()

    with pytest.raises(ValueError, match="finite"):
        module._load_strict_json('{"outer":[{"value":1e309}]}')


def test_strict_json_rejects_excessive_nesting_as_a_controlled_value_error() -> None:
    module = _acceptance_module()
    payload = "[" * 1000 + "0" + "]" * 1000

    with pytest.raises(ValueError, match="nesting"):
        module._load_strict_json(payload)


def test_non_lossless_stop_requires_a_float_roundtrip_iou() -> None:
    module = _acceptance_module()

    assert not module._valid_stop_topology(
        {
            "status": "FAIL",
            "reason": "non_lossless_polygon",
            "vertex_count": 4,
            "roundtrip_iou": 0,
        },
        WIDTH * HEIGHT,
    )


def test_malformed_failed_run_cannot_crash_visible_ui_binding(tmp_path: Path) -> None:
    cases_path, mask, target_ids = _configured_acceptance_fixture(tmp_path)
    evidence = tmp_path / "visible-ui.json"
    _write_visible_ui_evidence(evidence)
    base_invoker = _acceptance_invoker(mask, target_ids, fail=True)

    def malformed_failure(case, geometry, count, environ, work):
        result = base_invoker(case, geometry, count, environ, work)
        if result["status"] == "FAIL":
            result["actual_device"] = []
        return result

    report = _acceptance_module().generate_acceptance_report(
        cases_path,
        environ={"explicit": "test-only"},
        smoke_invoker=malformed_failure,
        environment_probe=_passing_preflight(),
        visible_ui_evidence=evidence,
    )

    assert report["functional"]["status"] == "FAIL"
    assert report["functional"]["runtime_smoke"]["status"] == "FAIL"


@pytest.mark.parametrize(
    "mutation",
    ["wrong_playback", "extra_field", "topology_pass", "unknown_reason"],
)
def test_partial_candidate_prefix_requires_exact_bounded_stop_evidence(
    tmp_path: Path, mutation: str
) -> None:
    cases_path, mask, target_ids = _configured_acceptance_fixture(tmp_path)
    base_invoker = _acceptance_invoker(mask, target_ids)

    def malformed_stop(case, geometry, count, environ, work):
        result = base_invoker(case, geometry, count, environ, work)
        if case["id"] == "case-0" and geometry == "box" and count == 5:
            result["generated_count"] = 2
            result["_candidate_masks"] = {
                frame_id: result["_candidate_masks"][frame_id]
                for frame_id in result["frame_ids"][1:3]
            }
            result["stop"] = {
                "kind": "candidate_topology",
                "frame_id": result["frame_ids"][3],
                "playback_index": result["_input_frames"][3]["playback_index"],
                "topology": {
                    "status": "FAIL",
                    "reason": "non_simple_polygon",
                    "vertex_count": 10,
                },
            }
            if mutation == "wrong_playback":
                result["stop"]["playback_index"] += 1
            elif mutation == "extra_field":
                result["stop"]["unexpected"] = True
            elif mutation == "topology_pass":
                result["stop"]["topology"]["status"] = "PASS"
            elif mutation == "unknown_reason":
                result["stop"]["topology"]["reason"] = "invented"
        return result

    report = _acceptance_module().generate_acceptance_report(
        cases_path,
        environ={"explicit": "test-only"},
        smoke_invoker=malformed_stop,
        environment_probe=_passing_preflight(),
    )

    malformed = next(
        run
        for run in report["functional"]["runtime_smoke"]["runs"]
        if run["case_id"] == "case-0"
        and run["start"] == "box"
        and run["count"] == 5
    )
    assert malformed["status"] == "FAIL"
    assert report["functional"]["runtime_smoke"]["status"] == "FAIL"


@pytest.mark.parametrize(
    ("override", "value"),
    [
        ("case_id", "not-allowlisted"),
        ("checkpoint_sha256", "b" * 64),
        ("device", "cuda"),
        ("sam2_version", "2.2.0"),
        ("failing_check", "cancel"),
    ],
)
def test_visible_ui_evidence_must_match_case_runtime_checkpoint_and_device(
    tmp_path: Path, override: str, value: str
) -> None:
    cases_path, mask, target_ids = _configured_acceptance_fixture(tmp_path)
    evidence = tmp_path / "visible-ui.json"
    kwargs = {override: value}
    _write_visible_ui_evidence(evidence, **kwargs)

    report = _acceptance_module().generate_acceptance_report(
        cases_path,
        environ={"explicit": "test-only"},
        smoke_invoker=_acceptance_invoker(mask, target_ids),
        environment_probe=_passing_preflight(),
        visible_ui_evidence=evidence,
    )

    assert report["functional"]["status"] == "FAIL"
    assert report["functional"]["runtime_smoke"]["status"] == "PASS"
    assert report["functional"]["visible_ui"]["status"] == "FAIL"
    assert report["functional"]["visible_ui"]["reason"]


def test_runtime_smoke_failure_keeps_functional_fail_with_valid_ui_evidence(
    tmp_path: Path,
) -> None:
    cases_path, mask, target_ids = _configured_acceptance_fixture(tmp_path)
    evidence = tmp_path / "visible-ui.json"
    _write_visible_ui_evidence(evidence)

    report = _acceptance_module().generate_acceptance_report(
        cases_path,
        environ={"explicit": "test-only"},
        smoke_invoker=_acceptance_invoker(mask, target_ids, fail=True),
        environment_probe=_passing_preflight(),
        visible_ui_evidence=evidence,
    )

    assert report["functional"]["status"] == "FAIL"
    assert report["functional"]["runtime_smoke"]["status"] == "FAIL"
    assert report["functional"]["visible_ui"]["status"] == "PASS"


def test_missing_config_and_truth_paths_never_leak_into_persisted_reasons(
    tmp_path: Path,
) -> None:
    missing_config = tmp_path / "private" / "secret-sam2.yaml"
    environment = _environment(tmp_path)
    environment["PROJECT6_SAM2_CONFIG"] = str(missing_config)
    smoke_report = smoke.run_smoke(
        tmp_path / "unread-frames",
        tmp_path / "unread-mask.png",
        1,
        tmp_path / "smoke.json",
        environ=environment,
    )
    assert smoke_report["status"] == "NOT RUN"
    assert str(missing_config) not in smoke_report["reason"]
    assert 0 < len(smoke_report["reason"]) <= 160

    cases_path, mask, target_ids = _configured_acceptance_fixture(tmp_path / "quality")
    payload = json.loads(cases_path.read_text(encoding="utf-8"))
    missing_truth = Path(payload["cases"][0]["independent_truth"][0]["mask"])
    missing_truth.unlink()
    report = _acceptance_module().generate_acceptance_report(
        cases_path,
        environ={"explicit": "test-only"},
        smoke_invoker=_acceptance_invoker(mask, target_ids),
        environment_probe=_passing_preflight(),
    )
    assert report["quality"]["status"] == "FAIL"
    assert str(missing_truth) not in report["quality"]["reason"]
    assert 0 < len(report["quality"]["reason"]) <= 160


def test_preflight_never_persists_external_stderr_or_missing_path(
    tmp_path: Path,
) -> None:
    module = _acceptance_module()
    config = tmp_path / "sam2.yaml"
    checkpoint = tmp_path / "sam2.pt"
    config.write_text("model: fake\n", encoding="utf-8")
    checkpoint.write_bytes(b"checkpoint")
    secret = tmp_path / "do-not-persist-this-path"
    probe = tmp_path / "probe-python"
    probe.write_text(
        "#!/bin/sh\nprintf '%s\\n' '" + str(secret) + "' >&2\nexit 1\n",
        encoding="utf-8",
    )
    probe.chmod(0o700)
    values = {
        "PROJECT6_MODEL_PYTHON": str(probe),
        "PROJECT6_SAM2_CONFIG": str(config),
        "PROJECT6_SAM2_CHECKPOINT": str(checkpoint),
        "PROJECT6_SAM2_DEVICE": "cpu",
    }

    failed_probe = module.preflight_environment(values)
    assert failed_probe["status"] == "NOT RUN"
    assert str(secret) not in failed_probe["reason"]
    assert 0 < len(failed_probe["reason"]) <= 160

    missing_config = tmp_path / "private" / "missing.yaml"
    values["PROJECT6_SAM2_CONFIG"] = str(missing_config)
    missing = module.preflight_environment(values)
    assert missing["status"] == "NOT RUN"
    assert str(missing_config) not in missing["reason"]
    assert 0 < len(missing["reason"]) <= 160


@pytest.mark.parametrize("sam2_version", ["", "unknown", "bad/version", "v" * 65])
def test_preflight_rejects_unverifiable_sam_version(
    tmp_path: Path, sam2_version: str
) -> None:
    module = _acceptance_module()
    config = tmp_path / "sam2.yaml"
    checkpoint = tmp_path / "sam2.pt"
    config.write_text("model: fake\n", encoding="utf-8")
    checkpoint.write_bytes(b"checkpoint")
    runtime = json.dumps({
        "python_version": "3.14.7",
        "torch_version": "2.8.0",
        "sam2_version": sam2_version,
        "cuda_available": False,
        "cuda_device": None,
    }, separators=(",", ":"))
    probe = tmp_path / "probe-python"
    probe.write_text(
        "#!/bin/sh\nprintf '%s\\n' '" + runtime + "'\n",
        encoding="utf-8",
    )
    probe.chmod(0o700)

    report = module.preflight_environment({
        "PROJECT6_MODEL_PYTHON": str(probe),
        "PROJECT6_SAM2_CONFIG": str(config),
        "PROJECT6_SAM2_CHECKPOINT": str(checkpoint),
        "PROJECT6_SAM2_DEVICE": "cpu",
    })

    assert report["status"] == "NOT RUN"
    assert report["reason"] == (
        "SAM runtime did not report a valid installed model version"
    )
