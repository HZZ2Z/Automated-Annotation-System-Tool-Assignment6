import copy
import pytest
from annotation_data.review_session import baseline_digest, validate_review_session


def payload(kind="model"):
    records = [{"schema_version":1,"source":"cam","frame":0,"regions":[]}, {"schema_version":1,"source":"cam","frame":1,"time_s":2.125,"regions":[]}]
    return {"schema_version":3,"frame_digits":6,"session_id":"s","media_id":"clip","media_type":"video","source_relative_path":"clip.mp4","source":"cam","source_sha256":None,"round_id":"r1","model_revision":"m1","taxonomy_version":"t1","revision":0,"baseline_kind":kind,"baseline_records":records if kind=="model" else [],"baseline_digest":baseline_digest(records) if kind=="model" else None,"frame_entries":[{"frame":0,"frame_id":0,"time_s":0.125},{"frame":1,"frame_id":1,"time_s":2.125}],"explicit_frames":[0,1],"frames":{str(r["frame"]):dict(r,source="human_corrected") for r in records},"review_state":{},"batch_operations":[]}


@pytest.mark.parametrize("kind",["model","unknown","empty"])
def test_annotation_absence_with_timed_source_is_valid(kind):
    assert not validate_review_session(payload(kind))


def test_provided_annotation_time_must_match_source():
    p=payload("unknown")
    p["frames"]["0"]["time_s"]=999
    assert validate_review_session(p)


def test_corrected_presence_cannot_change_known_baseline():
    p=payload()
    p["frames"]["0"]["time_s"]=0.125
    assert validate_review_session(p)
    p=payload()
    p["frames"]["1"].pop("time_s")
    assert validate_review_session(p)
