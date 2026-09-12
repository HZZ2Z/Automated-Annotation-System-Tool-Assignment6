"""Independent validator and parent descriptor reader for training_coco_v1."""

from __future__ import annotations

from datetime import datetime
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
from typing import Any, Callable

import cv2
import numpy as np

from annotation_data.coco_export import (
    CLASS_DIFF_TYPES,
    DIFF_TYPES,
    MAX_SAFE_INTEGER,
    _native_segmentation,
    _strict_json,
    _valid_box,
    canonical_json_bytes,
    coco_package_identity,
    decode_coco_rle,
    issue,
)
from annotation_data.contracts import validate_instance
from annotation_data.polygon_geometry import mask_to_polygon, validate_polygon
from annotation_data.training_package import _schema_errors


def _safe_relative(value: Any) -> bool:
    if not isinstance(value, str) or not value or "\\" in value:
        return False
    path = PurePosixPath(value)
    return not path.is_absolute() and all(part not in {"", ".", ".."} for part in path.parts)


def _strict_positive_id(value: Any) -> bool:
    return type(value) is int and 1 <= value <= MAX_SAFE_INTEGER


def _finite(value: Any) -> bool:
    return type(value) in (int, float) and math.isfinite(float(value))


def _check_cancel(cancel: Callable[[], bool] | None) -> None:
    if cancel is not None and cancel():
        raise InterruptedError("cancelled")


def _report_progress(
    progress: Callable[[dict[str, Any]], None] | None,
    stage: str,
    completed: int,
    total: int,
    message: str,
) -> None:
    if progress is None:
        return
    progress({
        "stage": stage,
        "completed": completed,
        "total": total,
        "fraction": float(completed / total) if total else 0.0,
        "message": message,
    })


def _hash(path: Path, cancel: Callable[[], bool] | None = None) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            _check_cancel(cancel)
            digest.update(chunk)
    _check_cancel(cancel)
    return digest.hexdigest()


def _decode_image(
    path: Path, cancel: Callable[[], bool] | None = None
) -> tuple[int, int] | None:
    try:
        _check_cancel(cancel)
        raw = path.read_bytes()
        _check_cancel(cancel)
    except OSError:
        return None
    suffix = path.suffix.lower()
    if suffix in {".jpg", ".jpeg"} and not raw.startswith(b"\xff\xd8"):
        return None
    if suffix == ".png" and not raw.startswith(b"\x89PNG\r\n\x1a\n"):
        return None
    flags = cv2.IMREAD_UNCHANGED
    if hasattr(cv2, "IMREAD_IGNORE_ORIENTATION"):
        flags |= cv2.IMREAD_IGNORE_ORIENTATION
    decoded = cv2.imdecode(np.frombuffer(raw, dtype=np.uint8), flags)
    if decoded is None or decoded.size == 0 or len(decoded.shape) < 2:
        return None
    return int(decoded.shape[1]), int(decoded.shape[0])


def _calendar_timestamp(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return False
    return True


def _walk_package(
    root: Path, cancel: Callable[[], bool] | None = None
) -> tuple[set[str], set[str], list[dict[str, Any]]]:
    files: set[str] = set()
    directories: set[str] = set()
    problems: list[dict[str, Any]] = []
    try:
        for path in root.rglob("*"):
            _check_cancel(cancel)
            relative = path.relative_to(root).as_posix()
            try:
                if path.is_symlink():
                    problems.append(issue("PACKAGE_INVALID", "Symbolic links are forbidden in a package", path=relative))
                elif path.is_dir():
                    directories.add(relative)
                elif path.is_file():
                    files.add(relative)
                else:
                    problems.append(issue("PACKAGE_INVALID", "Unsupported filesystem entry", path=relative))
            except OSError as exc:
                problems.append(issue("PACKAGE_INVALID", f"Cannot inspect package entry: {exc}", path=relative))
    except InterruptedError:
        raise
    except OSError as exc:
        problems.append(issue("PACKAGE_INVALID", f"Cannot enumerate package: {exc}"))
    return files, directories, problems


def _validate_diff(
    diff: dict[str, Any],
    manifest: dict[str, Any],
    category_names: set[str],
    cancel: Callable[[], bool] | None = None,
) -> list[dict[str, Any]]:
    problems: list[dict[str, Any]] = []
    for error in _schema_errors(diff, "annotation-diff-v1.schema.json"):
        problems.append(issue("PACKAGE_INVALID", f"Diff schema: {error}", path="reports/diff.json"))
    if problems:
        return problems
    included = manifest["coverage"]["included_frame_ids"]
    if [row["frame_id"] for row in diff["frames"]] != sorted(included):
        problems.append(issue("PACKAGE_INVALID", "Diff frames do not exactly cover included frames", path="reports/diff.json"))
    totals = dict.fromkeys(DIFF_TYPES, 0)
    changed_frames = 0
    changed_regions = 0
    class_counts: dict[str, dict[str, Any]] = {}

    def increment(label: str, field: str) -> None:
        if label not in category_names:
            problems.append(issue("PACKAGE_INVALID", f"Diff references unknown category {label}", path="reports/diff.json"))
        row = class_counts.setdefault(label, {"class": label, **dict.fromkeys(CLASS_DIFF_TYPES, 0)})
        row[field] += 1

    for frame in diff["frames"]:
        _check_cancel(cancel)
        local = dict.fromkeys(DIFF_TYPES, 0)
        changed: set[str] = set()
        seen: set[tuple[str, str]] = set()
        grouped: dict[str, list[dict[str, Any]]] = {}
        for event in frame["events"]:
            key = (event["region_id"], event["type"])
            if key in seen:
                problems.append(issue("PACKAGE_INVALID", "Diff repeats an event", frame_id=frame["frame_id"], region_id=event["region_id"]))
            seen.add(key)
            grouped.setdefault(event["region_id"], []).append(event)
            before, after, kind = event["before"], event["after"], event["type"]
            if before is not None and before.get("id") != event["region_id"] or after is not None and after.get("id") != event["region_id"]:
                problems.append(issue("PACKAGE_INVALID", "Diff event region identity is inconsistent", frame_id=frame["frame_id"], region_id=event["region_id"]))
            if kind == "added":
                valid = before is None and after is not None
            elif kind == "deleted":
                valid = before is not None and after is None
            else:
                valid = before is not None and after is not None
                fields = ("class",) if kind == "label_changed" else (("box", "polygon") if kind == "geometry_changed" else ("kind", "track_id", "conf"))
                valid = valid and {key: before[key] for key in fields if key in before} != {key: after[key] for key in fields if key in after}
            if not valid:
                problems.append(issue("PACKAGE_INVALID", "Diff event does not describe its claimed change", frame_id=frame["frame_id"], region_id=event["region_id"]))
            local[kind] += 1
            totals[kind] += 1
            changed.add(event["region_id"])
            if kind == "label_changed" and before is not None and after is not None:
                increment(before["class"], "reclassified_out")
                increment(after["class"], "reclassified_in")
            else:
                target = before if kind == "deleted" else after
                if target is not None:
                    increment(target["class"], kind)
        for events in grouped.values():
            before, after = events[0]["before"], events[0]["after"]
            if any(value["before"] != before or value["after"] != after for value in events):
                problems.append(issue("PACKAGE_INVALID", "Events for one region disagree on before/after values", frame_id=frame["frame_id"], region_id=events[0]["region_id"]))
                continue
            expected: set[str] = set()
            if before is None:
                expected.add("added")
            elif after is None:
                expected.add("deleted")
            else:
                if before["class"] != after["class"]:
                    expected.add("label_changed")
                if {key: before[key] for key in ("box", "polygon") if key in before} != {key: after[key] for key in ("box", "polygon") if key in after}:
                    expected.add("geometry_changed")
                if {key: before[key] for key in ("kind", "track_id", "conf") if key in before} != {key: after[key] for key in ("kind", "track_id", "conf") if key in after}:
                    expected.add("attributes_changed")
            if expected != {value["type"] for value in events}:
                problems.append(issue("PACKAGE_INVALID", "Diff omits or invents a change type", frame_id=frame["frame_id"], region_id=events[0]["region_id"]))
        if frame["counts"] != local or frame["changed_regions"] != len(changed):
            problems.append(issue("PACKAGE_INVALID", "Diff per-frame counts are inconsistent", frame_id=frame["frame_id"]))
        changed_frames += bool(changed)
        changed_regions += len(changed)
    expected_classes = [class_counts[label] for label in sorted(class_counts)]
    if diff["by_class"] != expected_classes:
        problems.append(issue("PACKAGE_INVALID", "Diff per-class counts are inconsistent", path="reports/diff.json"))
    expected_summary = {
        **totals,
        "total_frames": manifest["coverage"]["total_frames"],
        "included_frames": manifest["coverage"]["included_frames"],
        "excluded_frames": manifest["coverage"]["excluded_frames"],
        "changed_frames": changed_frames,
        "changed_regions": changed_regions,
    }
    if diff["summary"] != expected_summary:
        problems.append(issue("PACKAGE_INVALID", "Diff summary is inconsistent", path="reports/diff.json"))
    for key, value in expected_summary.items():
        if manifest["summary"].get(key) != value:
            problems.append(issue("PACKAGE_INVALID", f"Manifest summary {key} differs from diff", path="manifest.json"))
    return problems


def validate_coco_package(
    directory: str | Path,
    *,
    cancel: Callable[[], bool] | None = None,
    progress: Callable[[dict[str, Any]], None] | None = None,
) -> list[dict[str, Any]]:
    """Validate a moved package without consulting its originating workspace."""

    root = Path(directory).absolute()
    problems: list[dict[str, Any]] = []
    if not root.is_dir() or root.is_symlink():
        return [issue("PACKAGE_INVALID", "Package directory is missing or symbolic", path=str(root))]
    _check_cancel(cancel)
    _report_progress(progress, "validate_layout", 0, 1, "Checking package layout")
    files, directories, walk_problems = _walk_package(root, cancel)
    problems.extend(walk_problems)
    _report_progress(progress, "validate_layout", 1, 1, "Package layout checked")
    allowed_directories = {"images", "labels", "reports"}
    if directories != allowed_directories:
        problems.append(issue("PACKAGE_INVALID", "Package directory layout contains missing or foreign directories"))
    manifest_path = root / "manifest.json"
    if "manifest.json" not in files:
        problems.append(issue("PACKAGE_INVALID", "manifest.json is missing"))
        return problems
    try:
        manifest = _strict_json(manifest_path)
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        problems.append(issue("PACKAGE_INVALID", f"Cannot parse manifest.json strictly: {exc}", path="manifest.json"))
        return problems
    if not isinstance(manifest, dict):
        return problems + [issue("PACKAGE_INVALID", "Manifest must be an object", path="manifest.json")]
    _check_cancel(cancel)
    try:
        schema_errors = validate_instance(manifest, "training-coco-v1.schema.json")
    except (OSError, ValueError, TypeError) as exc:
        schema_errors = [f"schema unavailable: {exc}"]
    problems.extend(issue("PACKAGE_INVALID", f"Manifest schema: {error}", path="manifest.json") for error in schema_errors)
    if schema_errors:
        return problems
    if not _calendar_timestamp(manifest["created_at"]):
        problems.append(issue("PACKAGE_INVALID", "created_at is not a real UTC-second timestamp", path="manifest.json"))
    if manifest["package_id"] != coco_package_identity(manifest):
        problems.append(issue("PACKAGE_INVALID", "package_id differs from the canonical content identity", path="manifest.json"))

    artifacts = manifest["artifacts"]
    artifact_by_path: dict[str, dict[str, Any]] = {}
    resolved_root = root.resolve(strict=True)
    for artifact in artifacts:
        _check_cancel(cancel)
        relative = artifact["path"]
        if not _safe_relative(relative) or relative in artifact_by_path:
            problems.append(issue("PACKAGE_INVALID", "Artifact path is unsafe or duplicated", path=str(relative)))
            continue
        artifact_by_path[relative] = artifact
        path = root / PurePosixPath(relative)
        try:
            resolved_path = path.resolve(strict=True)
            if (
                path.is_symlink()
                or not path.is_file()
                or not resolved_path.is_relative_to(resolved_root)
            ):
                problems.append(issue("PACKAGE_INVALID", "Artifact is missing, symbolic, or outside the package", path=relative))
                continue
            raw_size = path.stat().st_size
            digest = _hash(path, cancel)
        except OSError as exc:
            problems.append(issue("PACKAGE_INVALID", f"Cannot read artifact: {exc}", path=relative))
            continue
        if raw_size != artifact["bytes"] or digest != artifact["sha256"]:
            problems.append(issue("PACKAGE_INVALID", "Artifact byte count or SHA-256 differs from manifest", path=relative))
    expected_files = {"manifest.json", *artifact_by_path}
    if files != expected_files:
        problems.append(issue("PACKAGE_INVALID", "Package contains missing or unregistered files"))
    if manifest["annotation_path"] not in artifact_by_path or artifact_by_path.get(manifest["annotation_path"], {}).get("role") != "annotation":
        problems.append(issue("PACKAGE_INVALID", "Primary annotation artifact is not registered"))
    if artifact_by_path.get("reports/diff.json", {}).get("role") != "diff":
        problems.append(issue("PACKAGE_INVALID", "Diff artifact is not registered"))
    if problems:
        return problems

    try:
        coco = _strict_json(root / manifest["annotation_path"])
        diff = _strict_json(root / "reports/diff.json")
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        return problems + [issue("PACKAGE_INVALID", f"Cannot parse package JSON strictly: {exc}")]
    if not isinstance(coco, dict) or set(coco) != {"info", "images", "annotations", "categories"}:
        return problems + [issue("PACKAGE_INVALID", "COCO root must contain only info, images, annotations and categories")]
    _check_cancel(cancel)
    if not isinstance(coco["info"], dict) or set(coco["info"]) != {"description", "version", "task"} or coco["info"].get("task") != manifest["task"]:
        problems.append(issue("PACKAGE_INVALID", "COCO info is inconsistent with the manifest"))
    if any(not isinstance(coco.get(key), list) for key in ("images", "annotations", "categories")):
        return problems + [issue("PACKAGE_INVALID", "COCO images, annotations and categories must be arrays")]

    category_ids: set[int] = set()
    category_names: set[str] = set()
    normalized_categories: list[dict[str, Any]] = []
    for category in coco["categories"]:
        _check_cancel(cancel)
        if (
            not isinstance(category, dict)
            or set(category) - {"id", "name", "supercategory"}
            or not _strict_positive_id(category.get("id"))
            or not isinstance(category.get("name"), str)
            or not category["name"]
            or not isinstance(category.get("supercategory", ""), str)
            or category["id"] in category_ids
            or category["name"] in category_names
        ):
            problems.append(issue("PACKAGE_INVALID", "COCO category is invalid or duplicated"))
            continue
        category_ids.add(category["id"])
        category_names.add(category["name"])
        normalized_categories.append(category)
    if normalized_categories != sorted(normalized_categories, key=lambda value: value["id"]):
        problems.append(issue("PACKAGE_INVALID", "COCO categories are not in stable ID order"))
    expected_category_hash = hashlib.sha256(canonical_json_bytes(normalized_categories).removesuffix(b"\n")).hexdigest()
    if expected_category_hash != manifest["category_table_sha256"] or manifest["summary"]["categories"] != len(normalized_categories):
        problems.append(issue("PACKAGE_INVALID", "Category table digest or count is inconsistent"))

    images: dict[int, dict[str, Any]] = {}
    image_files: set[str] = set()
    image_total = len(coco["images"])
    _report_progress(progress, "validate_images", 0, image_total, "Checking package images")
    for image_index, image in enumerate(coco["images"], start=1):
        _check_cancel(cancel)
        if (
            not isinstance(image, dict)
            or set(image) - {"id", "file_name", "width", "height", "video_id"}
            or not _strict_positive_id(image.get("id"))
            or image["id"] in images
            or type(image.get("width")) is not int
            or image["width"] <= 0
            or type(image.get("height")) is not int
            or image["height"] <= 0
            or ("video_id" in image and not _strict_positive_id(image["video_id"]))
            or not isinstance(image.get("file_name"), str)
            or PurePosixPath(image["file_name"]).name != image["file_name"]
            or Path(image["file_name"]).suffix.lower() not in {".jpg", ".jpeg", ".png"}
        ):
            problems.append(issue("PACKAGE_INVALID", "COCO image is invalid or duplicated"))
            continue
        artifact_path = f"{manifest['image_root']}/{image['file_name']}"
        if artifact_by_path.get(artifact_path, {}).get("role") != "image" or artifact_path in image_files:
            problems.append(issue("PACKAGE_INVALID", "COCO image file is missing, duplicated, or has the wrong artifact role", image_id=image["id"]))
            continue
        decoded_size = _decode_image(root / artifact_path, cancel)
        if decoded_size != (image["width"], image["height"]):
            problems.append(issue("PACKAGE_INVALID", "COCO image dimensions differ from decoded package bytes", image_id=image["id"], path=artifact_path))
        image_files.add(artifact_path)
        images[image["id"]] = image
        if image_index == image_total or image_index % 25 == 0:
            _report_progress(
                progress,
                "validate_images",
                image_index,
                image_total,
                f"Checked {image_index}/{image_total} package images",
            )
    declared_image_artifacts = {path for path, value in artifact_by_path.items() if value["role"] == "image"}
    if image_files != declared_image_artifacts:
        problems.append(issue("PACKAGE_INVALID", "Image artifacts do not exactly equal COCO image file names"))

    annotations: dict[int, dict[str, Any]] = {}
    mask_areas: dict[int, float] = {}
    annotation_total = len(coco["annotations"])
    _report_progress(
        progress, "validate_annotations", 0, annotation_total,
        "Checking COCO annotations",
    )
    for annotation_index, annotation in enumerate(coco["annotations"], start=1):
        _check_cancel(cancel)
        allowed = {"id", "image_id", "category_id", "bbox", "area", "iscrowd", "segmentation"}
        if (
            not isinstance(annotation, dict)
            or set(annotation) - allowed
            or not {"id", "image_id", "category_id", "bbox", "area", "iscrowd"} <= set(annotation)
            or not _strict_positive_id(annotation.get("id"))
            or annotation["id"] in annotations
            or not _strict_positive_id(annotation.get("image_id"))
            or annotation["image_id"] not in images
            or not _strict_positive_id(annotation.get("category_id"))
            or annotation["category_id"] not in category_ids
            or type(annotation.get("iscrowd")) is not int
            or annotation["iscrowd"] not in (0, 1)
            or not _finite(annotation.get("area"))
            or float(annotation["area"]) <= 0
        ):
            problems.append(issue("PACKAGE_INVALID", "COCO annotation identity, reference, area or crowd flag is invalid"))
            continue
        image = images[annotation["image_id"]]
        box = _valid_box(annotation.get("bbox"), image["width"], image["height"])
        if box is None:
            problems.append(issue("PACKAGE_INVALID", "COCO annotation bbox is invalid", image_id=image["id"]))
            continue
        if "segmentation" in annotation:
            try:
                _segmentation, area, _mask_box = _native_segmentation(annotation["segmentation"], image["width"], image["height"])
                mask_areas[annotation["id"]] = area
            except ValueError as exc:
                problems.append(issue("PACKAGE_INVALID", f"COCO segmentation is invalid: {exc}", image_id=image["id"]))
        elif manifest["task"] == "instance_segmentation":
            problems.append(issue("PACKAGE_INVALID", "Instance-segmentation package has a box-only annotation", image_id=image["id"]))
        annotations[annotation["id"]] = annotation
        if annotation_index == annotation_total or annotation_index % 100 == 0:
            _report_progress(
                progress,
                "validate_annotations",
                annotation_index,
                annotation_total,
                f"Checked {annotation_index}/{annotation_total} COCO annotations",
            )
    if manifest["summary"]["annotations"] != len(annotations):
        problems.append(issue("PACKAGE_INVALID", "Manifest annotation count differs from COCO"))

    samples = manifest["samples"]
    sample_ids = [sample["image_id"] for sample in samples]
    included = manifest["coverage"]["included_frame_ids"]
    sample_frames = [sample["source_frame_id"] for sample in samples]
    if len(sample_ids) != len(set(sample_ids)) or set(sample_ids) != set(images) or sample_frames != included:
        problems.append(issue("PACKAGE_INVALID", "Manifest samples and COCO images do not form the same one-to-one set"))
    annotations_per_image = {image_id: 0 for image_id in images}
    for annotation in annotations.values():
        annotations_per_image[annotation["image_id"]] += 1
    for sample in samples:
        _check_cancel(cancel)
        expected = "negative" if annotations_per_image.get(sample["image_id"], -1) == 0 else "annotated"
        if sample["annotation_status"] != expected:
            problems.append(issue("PACKAGE_INVALID", "Sample annotation_status differs from COCO object coverage", frame_id=sample["source_frame_id"], image_id=sample["image_id"]))
    if manifest["coverage"]["negative_frames"] != sum(sample["annotation_status"] == "negative" for sample in samples):
        problems.append(issue("PACKAGE_INVALID", "Negative-frame count is inconsistent"))

    links = manifest["annotation_links"]
    link_ids = [link["exported_annotation_id"] for link in links]
    if len(link_ids) != len(set(link_ids)) or set(link_ids) != set(annotations):
        problems.append(issue("PACKAGE_INVALID", "Annotation links do not exactly cover COCO annotations"))
    sample_by_image = {sample["image_id"]: sample for sample in samples}
    for link in links:
        _check_cancel(cancel)
        annotation = annotations.get(link["exported_annotation_id"])
        sample = sample_by_image.get(link["image_id"])
        if annotation is None or sample is None or annotation["image_id"] != link["image_id"] or sample["source_frame_id"] != link["source_frame_id"]:
            problems.append(issue("PACKAGE_INVALID", "Annotation link image/frame identity is inconsistent", region_id=link["native_region_id"]))
            continue
        if link["binding_method"] == "native_import_projection" and link["original_annotation_id"] != link["exported_annotation_id"]:
            problems.append(issue("PACKAGE_INVALID", "Native annotation ID was not preserved", region_id=link["native_region_id"]))
        if link["binding_method"] == "stable_generated" and link["original_annotation_id"] is not None:
            problems.append(issue("PACKAGE_INVALID", "Generated annotation unexpectedly claims an original ID", region_id=link["native_region_id"]))
        area = float(annotation["area"])
        if link["area_source"] == "bbox_fallback":
            expected_area = float(annotation["bbox"][2]) * float(annotation["bbox"][3])
            if abs(area - expected_area) > 1e-6:
                problems.append(issue("PACKAGE_INVALID", "bbox_fallback area differs from bbox", region_id=link["native_region_id"]))
        elif link["area_source"] == "mask":
            if annotation["id"] not in mask_areas or abs(area - mask_areas[annotation["id"]]) > 1e-6:
                problems.append(issue("PACKAGE_INVALID", "mask area differs from segmentation", region_id=link["native_region_id"]))
        elif "segmentation" in annotation and annotation["id"] in mask_areas and abs(area - mask_areas[annotation["id"]]) > 1e-6:
            problems.append(issue("PACKAGE_INVALID", "Original area differs from the preserved segmentation", region_id=link["native_region_id"]))

    coverage = manifest["coverage"]
    entries = manifest["source_frame_entries"]
    source_ids = [entry["frame_id"] for entry in entries]
    source_set = set(source_ids)
    included_set = set(coverage["included_frame_ids"])
    excluded_set = set(coverage["excluded_frame_ids"])
    verified_set = set(coverage["verified_frame_ids"])
    if [entry["frame"] for entry in entries] != list(range(len(entries))) or len(source_ids) != len(source_set):
        problems.append(issue("PACKAGE_INVALID", "Source frame identity or playback indices are invalid"))
    times = [entry["time_s"] for entry in entries if "time_s" in entry]
    if times != sorted(times):
        problems.append(issue("PACKAGE_INVALID", "Source timestamps are not ordered"))
    coverage_invalid = (
        coverage["source_frame_ids"] != source_ids
        or included_set & excluded_set
        or included_set | excluded_set != source_set
        or not verified_set <= source_set
        or coverage["included_frame_ids"] != [frame for frame in source_ids if frame in included_set]
        or coverage["excluded_frame_ids"] != [frame for frame in source_ids if frame in excluded_set]
    )
    policy = coverage["policy"]
    if policy == "verified_only":
        coverage_invalid = coverage_invalid or not included_set <= verified_set \
            or coverage["exclusion_reason"] != "not_content_verified_or_not_selected"
    elif policy == "all_source_frames":
        coverage_invalid = coverage_invalid or included_set != source_set \
            or bool(excluded_set) or coverage["exclusion_reason"] != "none"
    elif policy == "selected_source_frames":
        coverage_invalid = coverage_invalid or coverage["exclusion_reason"] != "not_selected"
    else:
        coverage_invalid = True
    if coverage_invalid:
        problems.append(issue("PACKAGE_INVALID", "Coverage partition, order or verification set is invalid"))

    extended_samples = policy != "verified_only"
    for sample in samples:
        frame = sample["source_frame_id"]
        if extended_samples and (
            "review_status" not in sample or "label_source" not in sample
        ):
            problems.append(issue("PACKAGE_INVALID", "Full-frame samples must declare review and label provenance", frame_id=frame, image_id=sample["image_id"]))
            continue
        if "review_status" in sample:
            expected_review = "verified_current" if frame in verified_set else "unverified"
            if sample["review_status"] != expected_review:
                problems.append(issue("PACKAGE_INVALID", "Sample review_status differs from verified coverage", frame_id=frame, image_id=sample["image_id"]))
            if expected_review == "verified_current" and not isinstance(sample.get("review_digest"), str):
                problems.append(issue("PACKAGE_INVALID", "Verified sample must retain its review digest", frame_id=frame, image_id=sample["image_id"]))
    unverified_included = included_set - verified_set
    has_unverified_warning = "UNVERIFIED_FRAMES_INCLUDED" in manifest["quality"]["warnings"]
    if extended_samples and bool(unverified_included) != has_unverified_warning:
        problems.append(issue("PACKAGE_INVALID", "Unverified-frame warning differs from included review coverage"))
    for key, values in (
        ("total_frames", source_ids),
        ("included_frames", coverage["included_frame_ids"]),
        ("excluded_frames", coverage["excluded_frame_ids"]),
    ):
        if coverage[key] != len(values) or manifest["summary"][key] != len(values):
            problems.append(issue("PACKAGE_INVALID", f"Coverage count {key} is inconsistent"))

    if not isinstance(diff, dict):
        problems.append(issue("PACKAGE_INVALID", "Diff must be an object"))
    else:
        problems.extend(_validate_diff(diff, manifest, category_names, cancel))
    _check_cancel(cancel)
    _report_progress(progress, "validated", 1, 1, "Training package is valid")
    return problems


_ENDOSCAPES_KINDS = {
    "cystic_plate": "anatomy",
    "calot_triangle": "anatomy",
    "cystic_artery": "anatomy",
    "cystic_duct": "anatomy",
    "gallbladder": "anatomy",
    "tool": "instrument",
}


def _editable_category_kind(category: dict[str, Any], manifest: dict[str, Any]) -> str:
    if manifest["dataset"]["dataset_namespace"] == "endoscapes2023":
        native = _ENDOSCAPES_KINDS.get(category["name"])
        if native is not None:
            return native
    kind = category.get("supercategory", "")
    return kind if isinstance(kind, str) and kind else "object"


def _polygon_from_segmentation(
    segmentation: Any,
    width: int,
    height: int,
) -> tuple[list[list[float]] | None, str]:
    """Return one V1-safe ring, or a reason for retaining only the bbox."""

    if isinstance(segmentation, list) and len(segmentation) == 1:
        flat = segmentation[0]
        points = [
            [float(flat[index]), float(flat[index + 1])]
            for index in range(0, len(flat), 2)
        ]
        try:
            ring = validate_polygon(points, (width, height))
        except ValueError as exc:
            return None, str(exc)
        return ring.tolist(), ""
    try:
        if isinstance(segmentation, dict):
            mask = decode_coco_rle(segmentation)
        else:
            mask = np.zeros((height, width), dtype=np.uint8)
            polygons = [
                np.rint(np.asarray(flat, dtype=np.float64).reshape((-1, 2))).astype(np.int32)
                for flat in segmentation
            ]
            cv2.fillPoly(mask, polygons, 1)
        return mask_to_polygon(mask, (width, height)), ""
    except (TypeError, ValueError) as exc:
        return None, str(exc)


def read_coco_source_projection(
    directory: str | Path,
    *,
    cancel: Callable[[], bool] | None = None,
    progress: Callable[[dict[str, Any]], None] | None = None,
) -> dict[str, Any]:
    """Validate one training package, then project it into SourceStage V1 data."""

    root = Path(directory).absolute()
    problems = validate_coco_package(root, cancel=cancel, progress=progress)
    if problems:
        return {
            "success": False,
            "issues": problems,
            "errors": [f"{item['code']}: {item['message']}" for item in problems],
        }
    _check_cancel(cancel)
    manifest = _strict_json(root / "manifest.json")
    coco = _strict_json(root / manifest["annotation_path"])
    categories = {category["id"]: category for category in coco["categories"]}
    images = {image["id"]: image for image in coco["images"]}
    annotations_by_image: dict[int, list[dict[str, Any]]] = {
        image_id: [] for image_id in images
    }
    for annotation in coco["annotations"]:
        annotations_by_image[annotation["image_id"]].append(annotation)
    for values in annotations_by_image.values():
        values.sort(key=lambda value: value["id"])
    links = {
        link["exported_annotation_id"]: link
        for link in manifest["annotation_links"]
    }
    source_entries = {
        entry["frame_id"]: entry
        for entry in manifest["source_frame_entries"]
    }

    frame_entries: list[dict[str, Any]] = []
    records: list[dict[str, Any]] = []
    polygon_regions = 0
    box_fallbacks = 0
    fallback_reasons: dict[str, int] = {}
    sample_total = len(manifest["samples"])
    _report_progress(progress, "project", 0, sample_total, "Preparing editable annotations")
    record_source = manifest["media"]["source"]
    for playback_index, sample in enumerate(manifest["samples"]):
        _check_cancel(cancel)
        frame_id = sample["source_frame_id"]
        image = images[sample["image_id"]]
        source_entry = source_entries[frame_id]
        frame_entry: dict[str, Any] = {
            "frame": playback_index,
            "frame_id": frame_id,
            "image_path": f"{manifest['image_root']}/{image['file_name']}",
        }
        if "time_s" in source_entry:
            frame_entry["time_s"] = source_entry["time_s"]
        else:
            frame_entry["time_s"] = float(playback_index)
        frame_entries.append(frame_entry)

        record: dict[str, Any] = {
            "schema_version": 1,
            "source": record_source,
            "frame": frame_id,
            "time_s": frame_entry["time_s"],
            "regions": [],
        }
        for annotation in annotations_by_image[sample["image_id"]]:
            link = links[annotation["id"]]
            category = categories[annotation["category_id"]]
            region: dict[str, Any] = {
                "id": link["native_region_id"],
                "class": category["name"],
                "kind": _editable_category_kind(category, manifest),
                "box": [float(value) for value in annotation["bbox"]],
            }
            if "segmentation" in annotation:
                polygon, reason = _polygon_from_segmentation(
                    annotation["segmentation"], image["width"], image["height"]
                )
                if polygon is not None:
                    region["polygon"] = polygon
                    polygon_regions += 1
                else:
                    box_fallbacks += 1
                    fallback_reasons[reason] = fallback_reasons.get(reason, 0) + 1
            record["regions"].append(region)
        errors = validate_instance(record, "model_output_v1.schema.json")
        if errors:
            raise ValueError(
                f"projected frame {frame_id} is not Model Output V1: {errors[0]}"
            )
        records.append(record)
        completed = playback_index + 1
        if completed == sample_total or completed % 25 == 0:
            _report_progress(
                progress,
                "project",
                completed,
                sample_total,
                f"Prepared {completed}/{sample_total} editable frames",
            )

    source_manifest = {
        "schema_version": 1,
        "dataset_id": manifest["media"]["media_id"],
        "source_name": root.name,
        "source_sha256": manifest["package_id"],
        "frame_count": len(frame_entries),
        "nominal_fps": 1.0,
        "frames": frame_entries,
        "model_version": "none",
        "model_revision": manifest["model_revision"],
        "round_id": manifest["round_id"],
        "taxonomy_version": manifest["taxonomy_version"],
        "baseline_kind": "imported_labels",
        "package_type": manifest["package_type"],
        "package_id": manifest["package_id"],
        "task": manifest["task"],
    }
    return {
        "success": True,
        "issues": [],
        "errors": [],
        "projection": {
            "package_id": manifest["package_id"],
            "task": manifest["task"],
            "manifest": source_manifest,
            "frame_entries": frame_entries,
            "records": records,
            "artifacts": [
                {"label": "manifest.json", "path": str(root / "manifest.json")},
                {"label": "annotation_coco.json", "path": str(root / manifest["annotation_path"])},
                {"label": "diff.json", "path": str(root / "reports/diff.json")},
            ],
            "statistics": {
                "imported_regions": len(coco["annotations"]),
                "polygon_regions": polygon_regions,
                "box_fallbacks": box_fallbacks,
                "skipped_regions": 0,
                "negative_frames": manifest["coverage"]["negative_frames"],
                "fallback_reasons": dict(sorted(fallback_reasons.items())),
            },
        },
    }


def read_coco_parent_descriptor(
    directory: str | Path,
    *,
    cancel: Callable[[], bool] | None = None,
) -> dict[str, Any]:
    """Validate the entire package, then return its immutable round-parent view."""

    problems = validate_coco_package(directory, cancel=cancel)
    if problems:
        return {"success": False, "issues": problems, "errors": [f"{item['code']}: {item['message']}" for item in problems]}
    _check_cancel(cancel)
    manifest = _strict_json(Path(directory) / "manifest.json")
    _check_cancel(cancel)
    return {
        "success": True,
        "issues": [],
        "errors": [],
        "descriptor": {
            "package_type": manifest["package_type"],
            "package_id": manifest["package_id"],
            "media": manifest["media"],
            "round_id": manifest["round_id"],
            "model_revision": manifest["model_revision"],
            "taxonomy_version": manifest["taxonomy_version"],
            "baseline": manifest["baseline"],
            "source_frame_entries": manifest["source_frame_entries"],
            "category_table_sha256": manifest["category_table_sha256"],
        },
    }
