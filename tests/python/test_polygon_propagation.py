"""Behavior and real-process tests for the CPU polygon propagation baseline."""

from importlib import import_module
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

import cv2
import numpy as np
import pytest

from polygon_fixtures import SHAPE, boundary_offset_scene, complex_mask, deformed_scene, iou, polygon_mask, refresh_frame_digest, scene_layers, translated_scene
from annotation_data.polygon_edge_refinement import EdgeRefinement


ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / "python/propagate_polygons.py"


def propagate(request, **kwargs):
    try:
        engine = import_module("annotation_data.polygon_propagation")
    except ModuleNotFoundError:
        pytest.fail("The polygon propagation engine is not implemented", pytrace=False)
    return engine.propagate(request, **kwargs)


@pytest.mark.parametrize("direction", [1, -1])
def test_textured_concave_translation_beats_copy_in_both_directions(tmp_path, direction):
    offsets = [(direction * 5 * t, direction * 3 * t) for t in range(-3, 4)]
    request, truths = translated_scene(tmp_path, offsets, key=3)

    result = propagate(request)

    assert result["success"], result
    assert (result["start_index"], result["end_index"]) == (0, 6), result
    assert [p["index"] for p in result["proposals"]] == [0, 1, 2, 4, 5, 6]
    copy = polygon_mask(request["regions"][0]["polygon"])
    for proposal in result["proposals"]:
        candidate = polygon_mask(proposal["regions"][0]["polygon"])
        motion_iou = iou(candidate, truths[proposal["index"]])
        copy_iou = iou(copy, truths[proposal["index"]])
        assert motion_iou > 0.90, (proposal, motion_iou, copy_iou)
        assert motion_iou > copy_iou + 0.08
        contour = np.asarray(proposal["regions"][0]["polygon"], np.float32)
        assert cv2.contourArea(contour) / cv2.contourArea(cv2.convexHull(contour)) < 0.85


@pytest.mark.parametrize("mode", ["rotation", "deformation"])
def test_real_image_motion_tracks_rotation_and_local_deformation(tmp_path, mode):
    request, truths = deformed_scene(tmp_path, mode)

    result = propagate(request)

    assert result["success"] and result["end_index"] == 3, result
    copy = truths[0]
    measured, baseline = [], []
    for proposal in result["proposals"]:
        truth = truths[proposal["index"]]
        measured.append(iou(polygon_mask(proposal["regions"][0]["polygon"]), truth))
        baseline.append(iou(copy, truth))
    assert min(measured) > 0.90, measured
    assert np.mean(measured) > np.mean(baseline) + 0.06, (measured, baseline)


def test_static_textured_frame_preserves_shape_and_original_request(tmp_path):
    request, truths = translated_scene(tmp_path, [(0, 0), (0, 0), (0, 0)], key=1)
    request["regions"][0]["box"] = [62, 48, 70, 72]
    before = deepcopy(request)
    progress = []

    result = propagate(request, progress=progress.append)

    assert result["success"] and not result["cancelled"], result
    assert result["metric_id"] == "poly-sim-flow-edge-v1"
    assert result["threshold"] == 1.0
    assert request == before
    assert [p["index"] for p in result["proposals"]] == [0, 2]
    for proposal in result["proposals"]:
        assert proposal["frame_id"] == 100 + proposal["index"]
        region = proposal["regions"][0]
        assert iou(polygon_mask(region["polygon"]), truths[1]) > 0.99
        assert {k: v for k, v in region.items() if k not in {"polygon", "box"}} == {k: v for k, v in before["regions"][0].items() if k not in {"polygon", "box"}}
        points = np.asarray(region["polygon"])
        assert region["box"] == [*points.min(axis=0).tolist(), *np.ptp(points, axis=0).tolist()]
        assert proposal["quality"]
        json.dumps(proposal["quality"], allow_nan=False)
    assert progress and progress[-1]["completed"] == progress[-1]["total"] == 2
    assert all(0 <= p["completed"] <= p["total"] and p["message"] for p in progress)
    result["proposals"][0]["regions"][0]["polygon"][0][0] += 1
    assert request == before


def test_v3_request_accepts_endoscapes_sampling_step(tmp_path):
    request, _ = translated_scene(tmp_path, [(0, 0), (0, 0)])
    request["schema_version"] = 3
    request["frame_step"] = 25
    request["frames"][0]["frame_id"] = 29375
    request["frames"][1]["frame_id"] = 29400

    result = propagate(request)

    assert result["success"], result
    assert result["schema_version"] == 3
    assert result["frame_step"] == 25
    assert result["end_index"] == 1


def test_bright_instrument_fallback_finds_approximate_translated_region(tmp_path):
    request, truths = translated_scene(tmp_path, [(0, 0), (18, 7)])
    for index, frame in enumerate(request["frames"]):
        image = np.full(SHAPE, 20, np.uint8)
        image[truths[index] > 0] = 225
        cv2.imwrite(frame["image_path"], image)
        refresh_frame_digest(frame)

    result = propagate(request)

    assert result["success"] and result["end_index"] == 1, result
    proposal = result["proposals"][0]
    candidate = polygon_mask(proposal["regions"][0]["polygon"])
    assert iou(candidate, truths[1]) > 0.85
    assert proposal["quality"]["poly-1"]["propagation_mode"] == "bright-template fallback"


def test_uniform_target_uses_explicit_fixed_coordinate_fallback(tmp_path):
    request, _ = translated_scene(tmp_path, [(0, 0), (0, 0)])
    for frame in request["frames"]:
        cv2.imwrite(frame["image_path"], np.full(SHAPE, 128, np.uint8))
        refresh_frame_digest(frame)

    result = propagate(request)

    assert result["success"] and result["end_index"] == 1, result
    proposal = result["proposals"][0]
    assert proposal["quality"]["poly-1"]["propagation_mode"] == "fixed fallback"
    assert np.array_equal(
        polygon_mask(proposal["regions"][0]["polygon"]),
        polygon_mask(request["regions"][0]["polygon"]),
    )


@pytest.mark.parametrize("failure", ["disappearance", "occlusion", "hole", "split", "cut"])
def test_unreliable_frame_remains_an_explicit_approximate_candidate(tmp_path, failure):
    request, _ = translated_scene(tmp_path, [(-5, -3), (0, 0), (5, 3), (10, 6)], key=1)
    image = cv2.imread(request["frames"][2]["image_path"], 0)
    if failure == "disappearance":
        _, image = scene_layers()
    elif failure == "cut":
        image = np.random.default_rng(42).integers(0, 256, SHAPE, np.uint8)
    elif failure == "occlusion":
        image[50:127, 66:84] = 30
    elif failure == "hole":
        image[88:105, 75:87] = 30
    else:
        image[91:104, :] = 30
    cv2.imwrite(request["frames"][2]["image_path"], image)
    refresh_frame_digest(request["frames"][2])

    result = propagate(request)

    assert result["success"], result
    assert (result["start_index"], result["end_index"]) == (0, 3), result
    altered = next(proposal for proposal in result["proposals"] if proposal["index"] == 2)
    mode = altered["quality"]["poly-1"]["propagation_mode"]
    assert mode in {"flow", "bright-template fallback", "fixed fallback"}
    if failure in {"disappearance", "occlusion", "cut"}:
        assert mode != "flow"


def test_single_unreliable_region_uses_per_region_approximate_fallback(tmp_path):
    request, _ = translated_scene(tmp_path, [(0, 0), (5, 3)])
    request["regions"].append({"id": "weak", "class": "other", "kind": "anatomy", "polygon": [[150, 130], [190, 130], [190, 160], [150, 160]]})

    result = propagate(request)

    assert result["success"] and result["end_index"] == 1, result
    assert result["proposals"][0]["quality"]["weak"]["propagation_mode"] in {"bright-template fallback", "fixed fallback"}


@pytest.mark.parametrize("points", [
    [[62, 48], [132, 120], [132, 48], [62, 120]],
    [[62, 48], [62, 48], [132, 100]],
    [[10, 10], [20, 20], [30, 30]],
    [[10, 10], [90, 10], [30, 10], [60, 90]],
    [[-1, 20], [30, 20], [30, 60]],
    [[20, 20], [225, 20], [30, 60]],
    [[float("nan"), 20], [30, 20], [30, 60]],
    [[True, 20], [30, 20], [30, 60]],
    [[20, 20], [30, 20]],
])
def test_malformed_source_polygon_never_produces_candidates(tmp_path, points):
    request, _ = translated_scene(tmp_path, [(0, 0), (5, 3)])
    request["regions"][0]["polygon"] = points

    result = propagate(request)

    assert result["success"] is False and result["cancelled"] is False
    assert result["error"]
    assert not result.get("proposals")


@pytest.mark.parametrize("change", [
    {"schema_version": True}, {"schema_version": 2}, {"schema_version": 4}, {"key_index": 99}, {"key_index": False},
    {"frame_step": 0}, {"frame_step": 1.5}, {"frame_step": True},
    {"similarity_threshold": -0.1}, {"similarity_threshold": 0}, {"similarity_threshold": 1.1},
    {"similarity_threshold": float("inf")}, {"similarity_threshold": True},
    {"regions": []}, {"frames": []}, {"unknown_option": 1},
])
def test_malformed_request_returns_explicit_failure(tmp_path, change):
    request, _ = translated_scene(tmp_path, [(0, 0), (5, 3)])
    request.update(change)

    result = propagate(request)

    assert result["success"] is False and result["error"], result


@pytest.mark.parametrize("failure", ["index gap", "frame gap", "unsorted", "too many", "duplicate region", "box only", "extra region attribute", "relative path"])
def test_invalid_sequence_or_region_contract_is_rejected(tmp_path, failure):
    request, _ = translated_scene(tmp_path, [(0, 0), (5, 3)])
    if failure == "index gap":
        request["frames"][1]["index"] = 3
    elif failure == "frame gap":
        request["frames"][1]["frame_id"] += 1
    elif failure == "unsorted":
        request["frames"].reverse()
    elif failure == "too many":
        request["frames"] = [{**request["frames"][0], "index": i, "frame_id": i} for i in range(31)]
    elif failure == "duplicate region":
        request["regions"] *= 2
    elif failure == "box only":
        request["regions"][0].pop("polygon")
        request["regions"][0]["box"] = [62, 48, 70, 72]
    elif failure == "extra region attribute":
        request["regions"][0]["custom"] = "not V1"
    else:
        request["frames"][0]["image_path"] = "relative.png"

    result = propagate(request)

    assert result["success"] is False and result["error"], result


@pytest.mark.parametrize("failure", ["image digest", "entry digest", "record digest", "verified", "extra frame field"])
def test_invalid_v2_snapshot_identity_is_rejected(tmp_path, failure):
    request, _ = translated_scene(tmp_path, [(0, 0), (5, 3)])
    frame = request["frames"][0]
    if failure == "image digest":
        frame["image_sha256"] = "0" * 64
    elif failure == "entry digest":
        frame["entry_digest"] = "BAD"
    elif failure == "record digest":
        frame["record_digest"] = "f" * 63
    elif failure == "verified":
        frame["verified"] = 0
    else:
        frame["unexpected"] = True

    result = propagate(request)

    assert result["schema_version"] == 3
    assert result["success"] is False and result["error"], result


def test_image_loading_failure_invalidates_the_whole_plan(tmp_path):
    request, _ = translated_scene(tmp_path, [(0, 0), (5, 3), (10, 6)])
    Path(request["frames"][2]["image_path"]).write_bytes(b"broken png")

    result = propagate(request)

    assert result["success"] is False and not result.get("proposals"), result
    assert "image" in result["error"].lower() or "png" in result["error"].lower()


def test_dimensions_change_truncates_only_the_affected_direction(tmp_path):
    request, _ = translated_scene(tmp_path, [(-5, -3), (0, 0), (5, 3), (10, 6)], key=1)
    cv2.imwrite(request["frames"][2]["image_path"], np.zeros((200, 220), np.uint8))
    refresh_frame_digest(request["frames"][2])

    result = propagate(request)

    assert result["success"] and (result["start_index"], result["end_index"]) == (0, 1), result
    assert any(word in result["right_stop"] for word in ("dimension", "size"))


@pytest.mark.parametrize("topology", ["hole", "split", "bounds"])
def test_mask_conversion_refuses_unsupported_topology(topology):
    mask = np.zeros((80, 100), np.uint8)
    mask[20:60, 20:80] = 255
    if topology == "hole":
        mask[30:40, 40:50] = 0
    elif topology == "split":
        mask[:, 45:50] = 0
    else:
        mask[20:60, :20] = 255
    try:
        geometry = import_module("annotation_data.polygon_geometry")
    except ModuleNotFoundError:
        pytest.fail("The polygon geometry checks are not implemented", pytrace=False)

    with pytest.raises(ValueError, match="hole|component|bound"):
        geometry.mask_to_polygon(mask, (100, 80))


def test_cancellation_discards_partial_proposals(tmp_path):
    request, _ = translated_scene(tmp_path, [(0, 0), (5, 3), (10, 6)])
    messages = []
    def cancelled():
        return any(p["completed"] >= 1 for p in messages)

    result = propagate(request, cancelled=cancelled, progress=messages.append)

    assert result["success"] is False and result["cancelled"] is True, result
    assert not result.get("proposals")


def _run_cli(tmp_path, request, *, cancel=False):
    paths = {key: tmp_path / f"{key}.json" for key in ("request", "result", "progress", "cancel")}
    paths["request"].write_text(json.dumps(request), encoding="utf-8")
    paths["result"].write_text('{"old":"complete file"}', encoding="utf-8")
    old_inode = paths["result"].stat().st_ino
    if cancel:
        paths["cancel"].write_text("cancel", encoding="utf-8")
    process = subprocess.run([sys.executable, str(CLI), "--request", str(paths["request"]), "--result", str(paths["result"]), "--cancel-file", str(paths["cancel"]), "--progress-file", str(paths["progress"])], cwd=ROOT, capture_output=True, text=True, timeout=30)
    assert paths["result"].stat().st_ino != old_inode, process.stderr
    return process, json.loads(paths["result"].read_text()), paths


def test_cli_writes_atomic_json_and_leaves_input_images_unchanged(tmp_path):
    request, _ = translated_scene(tmp_path, [(0, 0), (5, 3), (10, 6)])
    hashes = {f["image_path"]: hashlib.sha256(Path(f["image_path"]).read_bytes()).hexdigest() for f in request["frames"]}

    process, result, paths = _run_cli(tmp_path, request)

    assert process.returncode == 0 and result["success"], (process.stderr, result)
    assert result["schema_version"] == 3
    assert result["end_index"] == 2
    assert json.loads(paths["request"].read_text()) == request
    assert all(hashlib.sha256(Path(path).read_bytes()).hexdigest() == digest for path, digest in hashes.items())
    status = json.loads(paths["progress"].read_text())
    assert status["completed"] == status["total"] == 2
    assert not list(tmp_path.glob("*.tmp"))


@pytest.mark.parametrize("cancel, payload", [(False, {"schema_version": 8}), (True, {"schema_version": 8})])
def test_cli_failure_and_preexisting_cancellation_have_distinct_exit_codes(tmp_path, cancel, payload):
    process, result, _ = _run_cli(tmp_path, payload, cancel=cancel)

    assert process.returncode == (130 if cancel else 1), (process.stderr, result)
    assert result["success"] is False and result["cancelled"] is cancel
    assert result["error"]


def test_running_cli_can_be_cancelled_using_marker(tmp_path):
    request, _ = translated_scene(tmp_path, [(0, 0)] * 30, shape=(600, 800))
    request_path, result_path = tmp_path / "request.json", tmp_path / "result.json"
    cancel_path, progress_path = tmp_path / "cancel", tmp_path / "progress.json"
    request_path.write_text(json.dumps(request))
    process = subprocess.Popen([sys.executable, str(CLI), "--request", str(request_path), "--result", str(result_path), "--cancel-file", str(cancel_path), "--progress-file", str(progress_path)], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 20
        while process.poll() is None and time.monotonic() < deadline:
            if progress_path.exists() and json.loads(progress_path.read_text())["completed"] >= 1:
                cancel_path.write_text("cancel")
                break
            time.sleep(0.01)
        _, stderr = process.communicate(timeout=15)
        assert process.returncode == 130, stderr
        result = json.loads(result_path.read_text())
        assert result["cancelled"] is True and not result.get("proposals")
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()


def test_gradual_appearance_drift_is_retained_as_reviewable_candidates(tmp_path):
    request, _ = translated_scene(tmp_path, [(0, 0)] * 12)
    for i, frame in enumerate(request["frames"]):
        image = cv2.imread(frame["image_path"], 0)
        cv2.imwrite(frame["image_path"], np.clip(image.astype(np.int16) + i * 3, 0, 255).astype(np.uint8))
        refresh_frame_digest(frame)

    result = propagate(request)

    assert result["success"] and result["end_index"] == 11, result
    assert any(proposal["quality"]["poly-1"]["propagation_mode"] != "flow" for proposal in result["proposals"])


def test_motion_to_image_boundary_is_refused_without_clipping(tmp_path):
    polygon = [[155, 48], [215, 48], [215, 74], [185, 74], [185, 120], [155, 120]]
    request, _ = translated_scene(tmp_path, [(0, 0), (5, 0), (10, 0)], polygon=polygon)

    result = propagate(request)

    assert result["success"] and result["end_index"] < 2, result
    assert result["right_stop"] != "source boundary"


def test_large_image_candidates_are_returned_in_original_coordinates(tmp_path):
    polygon = [[124, 96], [264, 96], [264, 148], [184, 148], [184, 240], [124, 240]]
    request, truths = translated_scene(tmp_path, [(0, 0), (12, 6)], polygon=polygon, shape=(480, 1280))

    result = propagate(request)

    assert result["success"] and result["end_index"] == 1, result
    candidate = polygon_mask(result["proposals"][0]["regions"][0]["polygon"], (480, 1280))
    assert iou(candidate, truths[1]) > 0.95


def test_valid_thirty_frame_sequence_is_supported(tmp_path):
    request, _ = translated_scene(tmp_path, [(0, 0)] * 30, key=15)

    result = propagate(request)

    assert result["success"] and (result["start_index"], result["end_index"]) == (0, 29), result
    assert len(result["proposals"]) == 29


def test_default_similarity_threshold_uses_relaxed_review_profile(tmp_path):
    request, _ = translated_scene(tmp_path, [(0, 0), (5, 3)])
    request.pop("similarity_threshold")
    result = propagate(request)
    assert result["success"] and result["threshold"] == 0.1, result
    for frame in request["frames"]:
        cv2.imwrite(frame["image_path"], np.full(SHAPE, 128, np.uint8))
        refresh_frame_digest(frame)
    result = propagate(request)
    assert result["success"] and result["end_index"] == 1, result
    assert result["proposals"][0]["quality"]["poly-1"]["propagation_mode"] == "fixed fallback"


def test_similarity_refusal_never_constructs_optical_flow(tmp_path):
    request, _ = translated_scene(tmp_path, [(0, 0), (0, 0)])
    request["similarity_threshold"] = 0.02
    target = cv2.imread(request["frames"][1]["image_path"], cv2.IMREAD_GRAYSCALE)
    cv2.imwrite(request["frames"][1]["image_path"], np.clip(target.astype(np.int16) + 20, 0, 255).astype(np.uint8))
    refresh_frame_digest(request["frames"][1])
    calls = []

    def forbidden_motion(*args, **kwargs):
        calls.append((args, kwargs))
        raise AssertionError("similarity-refused frames must not enter optical flow")

    def forbidden_edge(*args, **kwargs):
        raise AssertionError("similarity-refused frames must not enter edge refinement")

    result = propagate(request, motion_factory=forbidden_motion, edge_refiner=forbidden_edge)

    assert result["success"] and result["proposals"] == [], result
    assert result["end_index"] == 0
    assert "similarity" in result["right_stop"]
    assert calls == []


class _StaticMotion:
    def __init__(self, _source, _target, _check_cancel):
        pass

    def warp_mask(self, mask):
        return mask.copy()

    def evidence(self, _mask):
        return {"appearance": 0.99, "fb_consistency": 0.99, "support": 0.99,
                "texture": 0.99, "texture_std": 12.0,
                "largest_unsupported_fraction": 0.0}


class _HoleMotion(_StaticMotion):
    def warp_mask(self, mask):
        changed = mask.copy()
        ys, xs = np.where(changed >= 128)
        changed[int(np.median(ys)) - 3:int(np.median(ys)) + 3,
                int(np.median(xs)) - 3:int(np.median(xs)) + 3] = 0
        return changed


def test_invalid_flow_topology_is_discarded_before_approximate_fallback(tmp_path):
    request, _ = translated_scene(tmp_path, [(0, 0), (0, 0)])

    result = propagate(request, motion_factory=_HoleMotion)

    assert result["success"] and result["end_index"] == 1, result
    quality = result["proposals"][0]["quality"]["poly-1"]
    assert quality["propagation_mode"] in {"bright-template fallback", "fixed fallback"}
    assert "hole" in quality["fallback_reason"]


def _edge_scores(**changes):
    scores = {"raw_edge_score": 0.1, "refined_edge_score": 0.2,
              "raw_iou": 0.99, "area_ratio": 1.0, "hausdorff": 1.0}
    scores.update(changes)
    return scores


def test_real_edge_refinement_improves_a_boundary_offset_candidate(tmp_path):
    request, truths = boundary_offset_scene(tmp_path)
    raw = polygon_mask(request["regions"][0]["polygon"]) * 255

    result = propagate(request)

    assert result["success"] and result["end_index"] == 1, result
    proposal = result["proposals"][0]
    final = polygon_mask(proposal["regions"][0]["polygon"])
    assert iou(final, truths[1]) > iou(raw, truths[1])
    diagnostics = proposal["quality"]["poly-1"]
    assert diagnostics["edge"]["attempted"] is True
    assert diagnostics["edge"]["accepted"] is True
    assert diagnostics["edge"]["refined_edge_score"] >= diagnostics["edge"]["raw_edge_score"] + 0.01
    json.dumps(diagnostics, allow_nan=False)


def test_expected_edge_refusal_keeps_raw_flow_and_records_fallback(tmp_path):
    request, truths = translated_scene(tmp_path, [(0, 0), (0, 0)])
    calls = []

    def refuse(_image, raw):
        calls.append(raw.copy())
        return EdgeRefinement(False, raw.copy(), "edge gain below 0.01", _edge_scores(refined_edge_score=0.1))

    result = propagate(request, motion_factory=_StaticMotion, edge_refiner=refuse)

    assert result["success"] and result["end_index"] == 1, result
    assert len(calls) == 2  # 相邻候选与固定关键帧直达候选独立精修。
    proposal = result["proposals"][0]
    assert iou(polygon_mask(proposal["regions"][0]["polygon"]), truths[0]) > 0.99
    edge = proposal["quality"]["poly-1"]["edge"]
    assert edge["accepted"] is False and edge["reason"] == "edge gain below 0.01"


def test_accepted_refined_mask_becomes_the_next_adjacent_seed(tmp_path):
    request, _ = translated_scene(tmp_path, [(0, 0), (0, 0), (0, 0)])
    seen = []

    class RecordingMotion(_StaticMotion):
        def warp_mask(self, mask):
            seen.append(mask.copy())
            return mask.copy()

    def add_safe_boundary_pixel(_image, raw):
        refined = raw.copy()
        ys, xs = np.where(refined >= 128)
        refined[ys.min():ys.min() + 4, xs.max() + 1] = 255
        return EdgeRefinement(True, refined, "accepted", _edge_scores())

    result = propagate(request, motion_factory=RecordingMotion, edge_refiner=add_safe_boundary_pixel)

    assert result["success"] and result["end_index"] == 2, result
    first_refined = polygon_mask(result["proposals"][0]["regions"][0]["polygon"]) > 0
    assert len(seen) >= 2
    assert np.count_nonzero(seen[1] >= 128) >= np.count_nonzero(first_refined) - 4
    assert np.any(seen[1] >= 128)


@pytest.mark.parametrize("fault", ["opencv", "nonfinite", "malformed-fallback"])
def test_edge_runtime_or_protocol_fault_discards_the_whole_plan(tmp_path, fault):
    request, _ = translated_scene(tmp_path, [(0, 0), (0, 0)])

    def broken(_image, raw):
        if fault == "opencv":
            raise cv2.error("grabcut failed")
        if fault == "nonfinite":
            return EdgeRefinement(False, raw.copy(), "edge gain below 0.01", _edge_scores(hausdorff=float("nan")))
        changed = raw.copy()
        changed[0, 0] = 255
        return EdgeRefinement(False, changed, "edge gain below 0.01", _edge_scores())

    result = propagate(request, motion_factory=_StaticMotion, edge_refiner=broken)

    assert result["success"] is False and not result.get("proposals"), result
    assert result["error"]


def test_snapshot_change_during_analysis_discards_all_candidates(tmp_path):
    request, _ = translated_scene(tmp_path, [(0, 0)] * 4)
    def mutate_after_one(status):
        if status["completed"] == 1:
            Path(request["frames"][0]["image_path"]).write_bytes(b"snapshot replaced")

    result = propagate(request, progress=mutate_after_one)

    assert result["success"] is False and not result.get("proposals"), result
    assert "snapshot" in result["error"]


@pytest.mark.parametrize("output_kind", ["result", "progress"])
def test_cli_never_overwrites_input_when_output_path_aliases_an_image(tmp_path, output_kind):
    request, _ = translated_scene(tmp_path, [(0, 0), (5, 3)])
    source_path = Path(request["frames"][0]["image_path"])
    before = source_path.read_bytes()
    request_path = tmp_path / "request.json"
    request_path.write_text(json.dumps(request))
    paths = {"result": tmp_path / "result.json", "progress": tmp_path / "progress.json"}
    paths[output_kind] = source_path

    process = subprocess.run([sys.executable, str(CLI), "--request", str(request_path), "--result", str(paths["result"]), "--progress-file", str(paths["progress"]), "--cancel-file", str(tmp_path / "cancel")], cwd=ROOT, capture_output=True, text=True, timeout=15)

    assert process.returncode == 1
    assert source_path.read_bytes() == before


def test_overly_complex_output_ring_is_refused_for_godot_vertex_budget():
    mask = complex_mask()
    geometry = import_module("annotation_data.polygon_geometry")

    with pytest.raises(ValueError, match="2048"):
        geometry.mask_to_polygon(mask, (1024, 1024))


def test_complex_manual_key_is_preserved_when_output_exceeds_vertex_budget(tmp_path):
    contour = cv2.findContours(complex_mask(), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)[0][0]
    polygon = cv2.approxPolyDP(contour, 0.65, True).reshape(-1, 2).tolist()
    request, _ = translated_scene(tmp_path, [(0, 0), (0, 0)], polygon=polygon, shape=(1024, 1024))
    before = deepcopy(request)

    result = propagate(request)

    assert result["success"] and result["proposals"] == [], result
    assert "2048" in result["right_stop"]
    assert request == before


def test_cli_refuses_nonregular_image_paths_without_blocking(tmp_path):
    request, _ = translated_scene(tmp_path, [(0, 0), (5, 3)])
    fifo = tmp_path / "image-pipe.png"
    os.mkfifo(fifo)
    request["frames"][1]["image_path"] = str(fifo)
    request_path, result_path = tmp_path / "request.json", tmp_path / "result.json"
    request_path.write_text(json.dumps(request))

    process = subprocess.run([sys.executable, str(CLI), "--request", str(request_path), "--result", str(result_path), "--cancel-file", str(tmp_path / "cancel"), "--progress-file", str(tmp_path / "progress.json")], cwd=ROOT, capture_output=True, text=True, timeout=2)

    assert process.returncode == 1
    assert not json.loads(result_path.read_text())["success"]


def test_cli_usage_failure_uses_the_protocol_failure_exit_code():
    process = subprocess.run([sys.executable, str(CLI), "--unknown-option"], cwd=ROOT, capture_output=True, text=True, timeout=5)

    assert process.returncode == 1
    assert process.stderr
