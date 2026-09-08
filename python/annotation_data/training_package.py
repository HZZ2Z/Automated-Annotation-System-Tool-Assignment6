"""Independent validation for worker-produced Part 4 file packages.

No Godot executable or active session is required. Baseline SHA256 is provenance,
not authentication of an unavailable original model dataset. Reports are recounted
and checked against corrected regions; the model team can independently bind the
baseline digest to its original immutable predictions.
"""
from __future__ import annotations

import csv
import hashlib
import io
import json
from pathlib import Path
from typing import Any

from referencing import Registry, Resource
from annotation_data.contracts import ROOT, SCHEMA_PATHS, StrictDraft202012Validator, validate_instance
from annotation_data.review_session import _normalized

PATHS = (
    "data/corrected_annotations.jsonl", "data/frame_map.jsonl", "reports/diff.json",
    "reports/diff.csv", "reports/summary_by_class.csv",
)
CATEGORIES = ("added", "deleted", "label_changed", "geometry_changed", "attributes_changed")
CLASS_COUNTS = ("added", "deleted", "reclassified_in", "reclassified_out", "geometry_changed", "attributes_changed")


def canonical_digest(value: Any) -> str:
    data = json.dumps(_normalized(value), ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(data.encode()).hexdigest()


def package_identity(manifest: dict) -> str:
    return canonical_digest({k: v for k, v in manifest.items() if k not in {"package_id", "revision", "created_at"}})


def _schema_errors(value: Any, name: str) -> list[str]:
    paths = dict(SCHEMA_PATHS)
    paths.update({n: ROOT / "core/feedback" / n for n in ("annotation-diff-v1.schema.json", "training-package-v2.schema.json")})
    schemas = {n: json.loads(p.read_text()) for n, p in paths.items()}
    registry = Registry().with_resources((n, Resource.from_contents(s)) for n, s in schemas.items())
    return [f"{name}:{'.'.join(map(str, e.path))}: {e.message}" for e in StrictDraft202012Validator(schemas[name], registry=registry).iter_errors(value)]


def _json(text: str) -> Any:
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError(f"duplicate JSON key: {key}")
            result[key] = value
        return result
    def constant(value):
        raise ValueError(f"nonfinite JSON number: {value}")
    return json.loads(text, object_pairs_hook=pairs, parse_constant=constant)


def validate_training_package(directory: str | Path) -> list[str]:
    """Return checked errors for either training_update_v2 or review_export_v1."""
    try:
        return _validate(Path(directory))
    except (OSError, ValueError, TypeError, KeyError, AttributeError, OverflowError) as exc:
        return [f"malformed package: {exc}"]


def _validate(root: Path) -> list[str]:
    errors: list[str] = []
    if root.is_symlink() or not root.is_dir():
        return ["package must be a real directory"]
    expected_files = {"manifest.json", *PATHS}
    actual_files = set()
    for item in root.rglob("*"):
        if item.is_symlink():
            return ["package symlinks are forbidden"]
        if item.is_file():
            actual_files.add(item.relative_to(root).as_posix())
        elif item.is_dir():
            if item.relative_to(root).as_posix() not in {"data", "reports"}:
                return ["package contains a foreign directory"]
        else:
            return ["package contains a special filesystem entry"]
    if actual_files != expected_files:
        return ["package files must exactly match the fixed artifact allowlist"]
    manifest = _json((root / "manifest.json").read_text(encoding="utf-8"))
    errors.extend(_schema_errors(manifest, "training-package-v2.schema.json"))
    if errors:
        return errors
    if manifest["package_id"] != package_identity(manifest):
        errors.append("package_id: canonical content identity mismatch")
    training = manifest["package_type"] == "training_update_v2"
    if manifest["schema_version"] != (2 if training else 1):
        errors.append("package type/schema mismatch")
    if training and manifest["baseline"]["kind"] == "unknown":
        errors.append("training package requires known baseline")
    baseline = manifest["baseline"]
    if (baseline["kind"] in {"empty", "unknown"}) != (baseline["digest"] is None):
        errors.append("baseline kind/digest mismatch")
    listed = [a["path"] for a in manifest["artifacts"]]
    if len(set(listed)) != len(PATHS) or set(listed) != set(PATHS):
        return errors + ["artifact names must be unique and complete"]
    texts = {}
    for artifact in manifest["artifacts"]:
        raw = (root / artifact["path"]).read_bytes()
        if len(raw) != artifact["bytes"] or hashlib.sha256(raw).hexdigest() != artifact["sha256"]:
            errors.append(f"{artifact['path']}: bytes/SHA256 mismatch")
        texts[artifact["path"]] = raw.decode("utf-8")
    if errors:
        return errors
    records = [_json(line) for line in texts[PATHS[0]].splitlines()]
    mapping = [_json(line) for line in texts[PATHS[1]].splitlines()]
    diff = _json(texts[PATHS[2]])
    errors.extend(_schema_errors(diff, "annotation-diff-v1.schema.json"))
    for record in records:
        errors.extend(validate_instance(record, "model_output_v1.schema.json"))
    if errors:
        return errors
    coverage = manifest["coverage"]
    entries = manifest["source_frame_entries"]
    entry_map = {int(e["frame_id"]): e for e in entries}
    source_ids = [int(e["frame_id"]) for e in entries]
    included = coverage["included_frame_ids"]
    excluded = coverage["excluded_frame_ids"]
    verified = coverage["verified_frame_ids"]
    explicit = coverage["explicit_frame_ids"]
    if len(entry_map) != len(entries) or [e["frame"] for e in entries] != list(range(len(entries))):
        errors.append("source frame identity/playback indices invalid")
    times = [e["time_s"] for e in entries if "time_s" in e]
    if times != sorted(times):
        errors.append("source timestamps not ordered")
    if coverage["source_frame_ids"] != source_ids:
        errors.append("coverage source frame identity mismatch")
    if (set(included) & set(excluded) or set(included) | set(excluded) != set(source_ids)
            or not set(verified) <= set(explicit) <= set(source_ids)):
        errors.append("invalid coverage partition/verification/explicit sets")
    if included != [f for f in source_ids if f in set(included)] or excluded != [f for f in source_ids if f in set(excluded)]:
        errors.append("coverage order differs from Source")
    for key, values in (("total_frames", source_ids), ("included_frames", included), ("excluded_frames", excluded)):
        if coverage[key] != len(values) or manifest["summary"][key] != len(values) or diff["summary"][key] != len(values):
            errors.append(f"{key}: incorrect count")
    if training:
        if not included or included != verified or coverage["exclusion_reason"] != "not_content_verified":
            errors.append("training coverage must exactly equal nonempty current verified frames")
    elif included != source_ids or excluded or coverage["exclusion_reason"] != "none":
        errors.append("review export must include all source frames")
    if [r["frame"] for r in records] != included or [m.get("frame_id") for m in mapping] != included:
        errors.append("artifact frame order/coverage mismatch")
        return errors
    by_frame = {int(r["frame"]): r for r in records}
    for record, mapped in zip(records, mapping):
        frame = int(record["frame"])
        entry = entry_map[frame]
        if record["source"] != "human_corrected":
            errors.append(f"frame {frame}: corrected source must be human_corrected")
        if len({r["id"] for r in record["regions"]}) != len(record["regions"]):
            errors.append(f"frame {frame}: duplicate region id")
        # Model Output V1 timestamps are optional independently of Source timing.
        # Preserve a record's absence; any supplied timestamp must match Source.
        if "time_s" in record and ("time_s" not in entry or record["time_s"] != entry["time_s"]):
            errors.append(f"frame {frame}: provided annotation timestamp differs from source")
        if ("time_s" in mapped) != ("time_s" in entry) or mapped.get("time_s") != entry.get("time_s"):
            errors.append(f"frame {frame}: frame map source timestamp value/presence mismatch")
        expected = dict(entry, sample_id=f"{manifest['media']['media_id']}_{frame:06d}", explicit=frame in explicit,
                        verified=frame in verified, review_status="verified" if frame in verified else "unverified",
                        annotation_status=("negative" if not record["regions"] else "annotated") if frame in explicit else "unannotated")
        if any(type(mapped.get(k)) is not bool for k in ("verified", "explicit")) or mapped != expected:
            errors.append(f"frame {frame}: frame map/sample ID/status mismatch")
        internal = dict(record, source=manifest["media"]["source"])
        accepted = manifest["review_state"].get(str(frame), {}).get("accepted_digest")
        if (accepted == canonical_digest(internal)) != (frame in verified):
            errors.append(f"frame {frame}: current content verification mismatch")
    if not set(map(int, manifest["review_state"])) <= set(explicit):
        errors.append("review state must refer to explicit source frames")
    for operation in manifest["batch_operations"]:
        if any(operation[k] not in entry_map for k in ("keyframe", "start_frame", "end_frame")):
            errors.append("batch provenance contains unknown source frame")
        if operation["start_frame"] > operation["end_frame"]:
            errors.append("batch provenance has reversed frame range")
        if "metric_id" in operation:
            if not operation["start_frame"] <= operation["keyframe"] <= operation["end_frame"]:
                errors.append("batch metric range must contain keyframe")
            if (operation["start_index"] > operation["end_index"]
                    or operation["covered_count"] != operation["end_index"] - operation["start_index"] + 1
                    or operation["covered_count"] > operation["max_frames"]
                    or operation["changed_count"] != len(operation["affected_frames"])
                    or operation["changed_count"] >= operation["covered_count"]):
                errors.append("batch metric range/coverage/changed counts inconsistent")
        if any(f not in entry_map or f == operation["keyframe"] or not operation["start_frame"] <= f <= operation["end_frame"] for f in operation["affected_frames"]):
            errors.append("batch provenance contains invalid target")
    if manifest["summary"]["verified_frames"] != len(verified):
        errors.append("verified_frames count mismatch")
    errors.extend(_validate_diff(diff, manifest, by_frame, texts))
    return errors


def _validate_diff(diff: dict, manifest: dict, records: dict, texts: dict) -> list[str]:
    errors = []
    available = manifest["baseline"]["kind"] != "unknown"
    if diff["available"] != available or manifest["summary"]["audit_available"] != available:
        errors.append("audit availability inconsistent with baseline kind")
    expected_ids = sorted(manifest["coverage"]["included_frame_ids"]) if available else []
    if [f["frame_id"] for f in diff["frames"]] != expected_ids:
        errors.append("audit frame coverage mismatch")
    counts = dict.fromkeys(CATEGORIES, 0)
    changed_frames = changed_regions = 0
    classes = {}
    csv_events = []
    for frame in diff["frames"]:
        local = dict.fromkeys(CATEGORIES, 0)
        seen = set()
        changed = set()
        grouped = {}
        current = {r["id"]: r for r in records[int(frame["frame_id"] )]["regions"]}
        if manifest["baseline"]["kind"] == "empty":
            expected_events = [{"region_id": rid, "type": "added", "before": None, "after": current[rid]}
                               for rid in sorted(current)]
            if frame["events"] != expected_events:
                errors.append("empty baseline audit must exactly add every current region")
        for event in frame["events"]:
            rid, kind = event["region_id"], event["type"]
            before, after = event["before"], event["after"]
            if (rid, kind) in seen:
                errors.append("duplicate audit event")
            seen.add((rid, kind)); changed.add(rid)
            grouped.setdefault(rid, []).append(event)
            if ((before is not None and before["id"] != rid) or (after is not None and after["id"] != rid)
                    or after != current.get(rid)):
                errors.append("audit event region identity/current after mismatch")
            if kind == "added":
                valid = before is None and after is not None
            elif kind == "deleted":
                valid = before is not None and after is None
            else:
                fields = {"label_changed": ("class",), "geometry_changed": ("box", "polygon"), "attributes_changed": ("kind", "track_id", "conf")}[kind]
                valid = before is not None and after is not None and {k:before[k] for k in fields if k in before} != {k:after[k] for k in fields if k in after}
            if not valid:
                errors.append("audit event does not describe its claimed change")
            local[kind] += 1; counts[kind] += 1
            csv_events.append((int(frame["frame_id"]), rid, kind, before, after))
            assignments = [(before["class"], "reclassified_out"), (after["class"], "reclassified_in")] if kind == "label_changed" and before and after else [((before if kind == "deleted" else after or before or {}).get("class", ""), kind)]
            for label, key in assignments:
                row = classes.setdefault(label, {"class":label, **dict.fromkeys(CLASS_COUNTS,0)})
                if key in row: row[key] += 1
        for events in grouped.values():
            before, after = events[0]["before"], events[0]["after"]
            if any(e["before"] != before or e["after"] != after for e in events):
                errors.append("same-region audit events have inconsistent before/after")
            expected = set()
            if before is None: expected.add("added")
            elif after is None: expected.add("deleted")
            else:
                for kind, keys in (("label_changed",("class",)),("geometry_changed",("box","polygon")),("attributes_changed",("kind","track_id","conf"))):
                    if {k:before[k] for k in keys if k in before} != {k:after[k] for k in keys if k in after}: expected.add(kind)
            if expected != {e["type"] for e in events}: errors.append("audit omits or adds a category for a changed region")
        if frame["counts"] != local or frame["changed_regions"] != len(changed):
            errors.append("audit per-frame counts mismatch")
        changed_regions += len(changed); changed_frames += bool(changed)
    expected_classes = [classes[k] for k in sorted(classes)]
    if diff["by_class"] != expected_classes:
        errors.append("audit per-class counts mismatch")
    for key, count in {**counts, "changed_frames":changed_frames,"changed_regions":changed_regions}.items():
        if diff["summary"][key] != count or manifest["summary"][key] != count:
            errors.append(f"audit {key} total mismatch")
    event_reader = csv.DictReader(io.StringIO(texts[PATHS[3]]))
    if event_reader.fieldnames != ["frame_id","region_id","type","before","after"]:
        errors.append("event CSV header mismatch")
    parsed = [(int(row["frame_id"]),row["region_id"],row["type"],_json(row["before"]),_json(row["after"])) for row in event_reader]
    if parsed != csv_events:
        errors.append("event CSV differs from JSON audit")
    class_reader = csv.DictReader(io.StringIO(texts[PATHS[4]]))
    if class_reader.fieldnames != ["class", *CLASS_COUNTS]:
        errors.append("class CSV header mismatch")
    rows = [{"class":row["class"], **{k:int(row[k]) for k in CLASS_COUNTS}} for row in class_reader]
    if rows != expected_classes:
        errors.append("class CSV differs from JSON audit")
    return errors


def main() -> int:
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    args = parser.parse_args()
    errors = validate_training_package(args.package)
    print(json.dumps({"success": not errors, "errors": errors}, ensure_ascii=False))
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
