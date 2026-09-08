"""Independent Media Label V3 validation; no filesystem or UI dependencies.

Godot's existing content digest normalizes all JSON numbers to doubles. Keep
source identity internal when validating records; persistent corrections project
that identity to human_corrected without changing the immutable baseline.
"""
import hashlib
import json
from typing import Any

from annotation_data.contracts import validate_instance


def _normalized(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: _normalized(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_normalized(item) for item in value]
    if type(value) in (int, float):
        return float(value) if value != 0 else 0.0
    return value


def baseline_digest(records: list[dict]) -> str:
    """V3 full precision canonical digest, with records ordered by original frame ID."""
    text = json.dumps(_normalized(sorted(records, key=lambda r: r["frame"])),
                      sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def validate_review_session(payload: object) -> list[str]:
    """Validate structure first, then cross-record/frame/workflow invariants."""
    errors = validate_instance(payload, "media-label-v3.schema.json")
    if errors:
        return errors
    assert isinstance(payload, dict)
    entries = payload["frame_entries"]
    frame_map = {}
    previous_time = -1.0
    for index, entry in enumerate(entries):
        frame = entry["frame_id"]
        if entry["frame"] != index:
            errors.append(f"frame_entries.{index}.frame: expected playback index {index}")
        if frame in frame_map:
            errors.append(f"frame_entries.{index}.frame_id: duplicate frame")
        if "time_s" in entry:
            if entry["time_s"] < previous_time:
                errors.append(f"frame_entries.{index}.time_s: timestamps must be ordered")
            previous_time = entry["time_s"]
        frame_map[frame] = entry
    explicit = set(payload["explicit_frames"])
    if not explicit <= frame_map.keys():
        errors.append("explicit_frames: unknown original frame")
    if set(map(int, payload["frames"])) != explicit:
        errors.append("frames: must exactly match explicit_frames")
    baseline = payload["baseline_records"]
    known = payload["baseline_kind"] in ("model", "imported_labels")
    baseline_ids = [record["frame"] for record in baseline]
    if known:
        if len(baseline_ids) != len(set(baseline_ids)) or set(baseline_ids) != frame_map.keys():
            errors.append("baseline_records: expected exact complete frame set")
        if baseline_digest(baseline) != payload["baseline_digest"]:
            errors.append("baseline_digest: differs from immutable baseline")
    for record in baseline:
        errors.extend(_record_identity(record, record["frame"], payload["source"], frame_map, "baseline_records"))
    baseline_by_frame = {record["frame"]: record for record in baseline}
    for key, record in payload["frames"].items():
        errors.extend(_record_identity(record, int(key), "human_corrected", frame_map, f"frames.{key}"))
        original = baseline_by_frame.get(int(key))
        if known and original is not None and (
            ("time_s" in record) != ("time_s" in original)
            or record.get("time_s") != original.get("time_s")
        ):
            errors.append(f"frames.{key}.time_s: must preserve baseline timestamp including absence")
    for key in payload["review_state"]:
        if int(key) not in explicit:
            errors.append(f"review_state.{key}: reviewed frame must be explicit")
    for index, operation in enumerate(payload["batch_operations"]):
        prefix = f"batch_operations.{index}"
        keyframe, start, end = (operation[k] for k in ("keyframe", "start_frame", "end_frame"))
        if any(frame not in frame_map for frame in (keyframe, start, end)) or start > end:
            errors.append(f"{prefix}: invalid original frame range")
        affected = operation["affected_frames"]
        if any(frame not in frame_map or not start <= frame <= end or frame == keyframe for frame in affected):
            errors.append(f"{prefix}.affected_frames: invalid target")
        if "metric_id" in operation:
            if not start <= keyframe <= end:
                errors.append(f"{prefix}: range must contain keyframe")
            if (operation["start_index"] > operation["end_index"]
                or operation["covered_count"] != operation["end_index"] - operation["start_index"] + 1
                or operation["covered_count"] > operation["max_frames"]
                or operation["changed_count"] != len(affected)
                or operation["changed_count"] >= operation["covered_count"]):
                errors.append(f"{prefix}: inconsistent covered range or changed count")
    return errors


def _record_identity(record: dict, frame: int, source: str, entries: dict, prefix: str) -> list[str]:
    errors = []
    if record["frame"] != frame or frame not in entries or record["source"] != source:
        errors.append(f"{prefix}: wrong source or original frame identity")
    elif "time_s" in record and (
        "time_s" not in entries[frame] or record["time_s"] != entries[frame]["time_s"]
    ):
        errors.append(f"{prefix}.time_s: provided timestamp must exactly match source")
    ids = [region["id"] for region in record["regions"]]
    if len(ids) != len(set(ids)):
        errors.append(f"{prefix}.regions: duplicate region ID")
    return errors
