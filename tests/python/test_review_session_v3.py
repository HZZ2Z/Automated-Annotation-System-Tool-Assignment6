"""Part 4 V3 structural and semantic contract, independent of Godot."""
import copy
import hashlib
import json
import pytest
from annotation_data.contracts import SCHEMA_PATHS, validate_instance
from annotation_data.review_session import validate_review_session
from annotation_data.workspace import validate_media_label_semantics


def payload():
    return {"schema_version":3,"frame_digits":6,"session_id":"s1","media_id":"clip","media_type":"video","source_relative_path":"clip.mp4","source":"camera_a","source_sha256":None,"round_id":"round1","model_revision":"m1","taxonomy_version":"t1","revision":2,"baseline_kind":"unknown","baseline_digest":None,"baseline_records":[],"frame_entries":[{"frame":0,"frame_id":12},{"frame":1,"frame_id":90,"time_s":3.6}],"explicit_frames":[12],"frames":{"12":{"schema_version":1,"source":"human_corrected","frame":12,"regions":[]}},"review_state":{"12":{"accepted_digest":"a"*64}},"batch_operations":[]}


def test_v3_schema_registered():
    assert "media-label-v3.schema.json" in SCHEMA_PATHS


def test_valid_projection_and_implicit_empty_frame():
    p = payload()
    assert not validate_media_label_semantics(p)
    assert not validate_instance(p, "media-label-v3.schema.json")


def test_sampling_aware_poly_audit_schema():
    p = payload()
    p["batch_operations"] = [{
        "schema_version": 2, "type": "range_propagate", "mode": "merge",
        "keyframe": 5850, "start_frame": 5850, "end_frame": 5875,
        "affected_frames": [5875], "metric_id": "poly-sim-flow-edge-v1",
        "threshold": 0.7, "max_frames": 30, "frame_step": 25,
        "keyframe_digest": "a" * 64, "created_at": "2026-09-10T17:37:23",
        "start_index": 0, "end_index": 1, "left_stop": "source boundary",
        "right_stop": "motion leaves image bounds", "changed_count": 1,
        "covered_count": 2, "edge_refinement": {
            "attempted": 1, "accepted": 0, "fallback": 1, "items": [{
                "frame_id": 5875, "region_id": "poly", "accepted": False,
                "reason": "Hausdorff above 6", "raw_edge_score": 0.04,
                "refined_edge_score": 0.09,
            }],
        },
    }]
    assert not validate_instance(p, "media-label-v3.schema.json")


def _sampled_session(frame_ids=(5850, 5875)):
    p = payload()
    p.update(frame_entries=[{"frame": index, "frame_id": frame}
                            for index, frame in enumerate(frame_ids)],
             explicit_frames=[], frames={}, review_state={})
    operation = {
        "schema_version": 2, "type": "range_propagate", "mode": "merge",
        "keyframe": frame_ids[0], "start_frame": frame_ids[0], "end_frame": frame_ids[-1],
        "affected_frames": list(frame_ids[1:]), "metric_id": "poly-sim-flow-edge-v1",
        "threshold": 0.7, "max_frames": 30, "frame_step": 25,
        "keyframe_digest": "a" * 64, "created_at": "2026-09-10T17:37:23",
        "start_index": 0, "end_index": len(frame_ids) - 1,
        "left_stop": "source boundary", "right_stop": "source boundary",
        "changed_count": len(frame_ids) - 1, "covered_count": len(frame_ids),
        "edge_refinement": {
            "attempted": len(frame_ids) - 1, "accepted": 0,
            "fallback": len(frame_ids) - 1, "items": [{
                "frame_id": frame, "region_id": "poly", "accepted": False,
                "reason": "Hausdorff above 6", "raw_edge_score": 0.04,
                "refined_edge_score": 0.09,
            } for frame in frame_ids[1:]],
        },
    }
    p["batch_operations"] = [operation]
    return p


def test_sampling_aware_poly_audit_semantics_reject_wrong_step_and_off_grid_frame():
    valid = _sampled_session()
    assert not validate_review_session(valid)
    wrong_step = copy.deepcopy(valid)
    wrong_step["batch_operations"][0]["frame_step"] = 24
    assert validate_review_session(wrong_step)
    off_grid = _sampled_session((5850, 5860, 5900))
    assert validate_review_session(off_grid)


def test_sampling_aware_poly_audit_rejects_off_grid_edge_item():
    p = _sampled_session()
    p["batch_operations"][0]["edge_refinement"]["items"][0]["frame_id"] = 5860
    assert validate_review_session(p)


def test_legacy_marker_cannot_claim_v2_only_fields():
    p = payload()
    p["batch_operations"] = [{
        "schema_version": 1, "type": "range_propagate", "mode": "merge",
        "keyframe": 12, "start_frame": 12, "end_frame": 90,
        "affected_frames": [90], "frame_step": 1,
    }]
    assert validate_instance(p, "media-label-v3.schema.json")


@pytest.mark.parametrize("mutation", [
    lambda p: p["frames"]["12"].update(source="clip"),
    lambda p: p["frames"]["12"].update(time_s=0),
    lambda p: p["frames"]["12"].update(frame=90),
    lambda p: p["explicit_frames"].append(90),
    lambda p: p["frame_entries"][1].update(frame_id=12),
    lambda p: p["frame_entries"][1].update(frame=3),
    lambda p: p["review_state"].update({"90":{"accepted_digest":"a"*64}}),
    lambda p: p.update(baseline_kind="model"),
    lambda p: p.update(baseline_records=[{"schema_version":1,"source":"camera_a","frame":12,"regions":[]}]),
    lambda p: p.update(batch_operations=[{"schema_version":1,"type":"range_propagate","mode":"overwrite","keyframe":12,"start_frame":12,"end_frame":90,"affected_frames":[12]}]),
])
def test_invalid_semantics_rejected(mutation):
    p = payload()
    mutation(p)
    assert validate_media_label_semantics(p)


@pytest.mark.parametrize("field,value", [("revision",True),("source_sha256","bad"),("baseline_digest","bad"),("source_relative_path","../clip.mp4"),("frame_entries",[]),("baseline_records",{})])
def test_invalid_structure_rejected(field, value):
    p = payload()
    p[field] = value
    assert validate_instance(p, "media-label-v3.schema.json")


def test_real_godot_payload_and_baseline_corruption():
    from pathlib import Path
    from annotation_data.review_session import baseline_digest
    artifact = Path("/tmp/part4-v3-godot.json")
    assert artifact.exists(), "run Godot behavioral test before cross-language validation"
    p = json.loads(artifact.read_text())
    assert not validate_media_label_semantics(p)
    p["baseline_records"][0]["regions"][0]["box"][0] = 3.600000000000001
    assert validate_media_label_semantics(p)
    p["baseline_digest"] = baseline_digest(p["baseline_records"])
    assert not validate_media_label_semantics(p)
    p["baseline_records"][0]["regions"][0]["box"][0] = 3.6
    assert validate_media_label_semantics(p)
