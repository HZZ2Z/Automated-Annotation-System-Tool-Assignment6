"""Deterministic, read-only projection from a saved review session to COCO.

The module owns the business rules shared by the desktop worker and the CLI.  It
does not publish directories.  Source JSON and image bytes are read without
modification, verified frames are selected from content digests, and every
expected failure is returned as a stable structured issue.
"""

from __future__ import annotations

import copy
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import re
import time
from typing import Any, Callable, Iterable

import cv2
import numpy as np

from annotation_data.contracts import validate_instance
from annotation_data.review_session import validate_review_session
from annotation_data.training_package import canonical_digest


PACKAGE_TYPE = "training_coco_v1"
CONTEXT_VERSION = 1
MAX_SAFE_INTEGER = (1 << 53) - 1
ID_HASH_HEX_DIGITS = 13
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png"}
ENDOSCAPES_KINDS = {
    "cystic_plate": "anatomy",
    "calot_triangle": "anatomy",
    "cystic_artery": "anatomy",
    "cystic_duct": "anatomy",
    "gallbladder": "anatomy",
    "tool": "instrument",
}
DIFF_TYPES = (
    "added",
    "deleted",
    "label_changed",
    "geometry_changed",
    "attributes_changed",
)
CLASS_DIFF_TYPES = (
    "added",
    "deleted",
    "reclassified_in",
    "reclassified_out",
    "geometry_changed",
    "attributes_changed",
)
_FRAME_NAME = re.compile(r"^(?P<video>[0-9]+)_(?P<frame>[0-9]+)\.(?:jpe?g|png)$", re.IGNORECASE)


def _is_int(value: Any) -> bool:
    return type(value) is int and 0 <= value <= MAX_SAFE_INTEGER


def _is_positive_id(value: Any) -> bool:
    return type(value) is int and 1 <= value <= MAX_SAFE_INTEGER


def _is_number(value: Any) -> bool:
    return type(value) in (int, float) and math.isfinite(float(value))


def canonical_json_bytes(value: Any) -> bytes:
    """Return stable UTF-8 JSON bytes and reject non-finite values."""

    return (
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
        + "\n"
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path, cancel: Callable[[], bool] | None = None) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            if cancel is not None and cancel():
                raise InterruptedError("cancelled")
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _strict_json(path: Path) -> Any:
    def pairs(items: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in items:
            if key in result:
                raise ValueError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    def constant(value: str) -> None:
        raise ValueError(f"nonfinite JSON number: {value}")

    return json.loads(
        path.read_text(encoding="utf-8"),
        object_pairs_hook=pairs,
        parse_constant=constant,
    )


def issue(
    code: str,
    message: str,
    *,
    frame_id: int | None = None,
    image_id: int | None = None,
    region_id: str | None = None,
    path: str | None = None,
) -> dict[str, Any]:
    value: dict[str, Any] = {"code": code, "message": message}
    if frame_id is not None:
        value["frame_id"] = frame_id
    if image_id is not None:
        value["image_id"] = image_id
    if region_id is not None:
        value["region_id"] = region_id
    if path is not None:
        value["path"] = path
    return value


def _result_base(
    *,
    success: bool,
    issues: list[dict[str, Any]] | None = None,
    warnings: list[dict[str, Any]] | None = None,
    task: str = "detection",
    saved_revision: int = -1,
    timings_ms: dict[str, int] | None = None,
) -> dict[str, Any]:
    problems = issues or []
    notices = warnings or []
    return {
        "success": success,
        "errors": [f"{item['code']}: {item['message']}" for item in problems],
        "issues": problems,
        "warnings": notices,
        "output_path": "",
        "package_id": "",
        "package_type": PACKAGE_TYPE,
        "task": task,
        "saved_revision": saved_revision,
        "package_saved_revision": -1,
        "reused": False,
        "cancelled": False,
        "summary": {},
        "timings_ms": timings_ms or {},
    }


def build_endoscapes_context(
    saved_session: dict[str, Any],
    source_root: str | Path,
    *,
    task: str = "detection",
    selected_frame_ids: Iterable[int] | None = None,
    segmentation_attested: bool = False,
    allow_box_only_fallback: bool = False,
) -> dict[str, Any]:
    """Build the versioned private context used by both UI and CLI workers."""

    root = Path(source_root).absolute()
    relative = PurePosixPath(str(saved_session.get("source_relative_path", "")))
    split = relative.parts[0] if relative.parts else ""
    frame_entries = saved_session.get("frame_entries", [])
    parsed_frames: list[tuple[int, int, str]] = []
    video_ids: set[int] = set()
    for index, entry in enumerate(frame_entries if isinstance(frame_entries, list) else []):
        file_name = str(entry.get("image_path", "")) if isinstance(entry, dict) else ""
        matched = _FRAME_NAME.fullmatch(file_name)
        if matched is None:
            continue
        video_ids.add(int(matched.group("video")))
        parsed_frames.append((int(entry.get("frame_id", -1)), index, file_name))
    video_id = next(iter(video_ids)) if len(video_ids) == 1 else -1
    split_root = root / split
    metadata = [
        {"role": role, "path": str((split_root / name).absolute())}
        for role, name in (
            ("detection", "annotation_coco.json"),
            ("video", "annotation_coco_vid.json"),
            ("ds", "annotation_ds_coco.json"),
        )
        if (split_root / name).is_file()
    ]
    frames = [
        {
            "source_frame_id": frame_id,
            "source_playback_index": playback,
            "file_name": file_name,
            "source_path": str((split_root / file_name).absolute()),
        }
        for frame_id, playback, file_name in parsed_frames
    ]
    options: dict[str, Any] = {
        "task": task,
        "segmentation_attested": bool(segmentation_attested),
        "allow_box_only_fallback": bool(allow_box_only_fallback),
    }
    if selected_frame_ids is not None:
        options["selected_frame_ids"] = list(selected_frame_ids)
    return {
        "schema_version": CONTEXT_VERSION,
        "package_type": PACKAGE_TYPE,
        "saved_snapshot": copy.deepcopy(saved_session),
        "source_descriptor": {
            "schema_version": 1,
            "source_type": "endoscapes_coco",
            "dataset_namespace": "endoscapes2023",
            "dataset_root": str(root),
            "source_split": split,
            "video_id": video_id,
            "frames": frames,
            "metadata_files": metadata,
        },
        "export_options": options,
        "preparation_token": {
            "session_id": str(saved_session.get("session_id", "")),
            "saved_revision": saved_session.get("revision", -1),
        },
    }


def _materialize_records(snapshot: dict[str, Any]) -> tuple[list[dict], list[dict]]:
    baseline = copy.deepcopy(snapshot.get("baseline_records", []))
    baseline_by_frame = {int(record["frame"]): record for record in baseline}
    corrections = {
        int(key): dict(copy.deepcopy(record), source=snapshot["source"])
        for key, record in snapshot.get("frames", {}).items()
    }
    current: list[dict] = []
    for entry in snapshot["frame_entries"]:
        frame = int(entry["frame_id"])
        if frame in corrections:
            record = corrections[frame]
        elif snapshot["baseline_kind"] in {"model", "imported_labels"}:
            record = copy.deepcopy(baseline_by_frame[frame])
        else:
            record = {
                "schema_version": 1,
                "source": snapshot["source"],
                "frame": frame,
                "regions": [],
            }
            if "time_s" in entry:
                record["time_s"] = entry["time_s"]
        current.append(record)
    return baseline, current


def _extend_category_table(
    native_categories: list[dict[str, Any]], current: list[dict[str, Any]]
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Append stable free-text editor classes without renumbering native IDs."""
    categories = copy.deepcopy(native_categories)
    native_names = {str(category["name"]) for category in categories}
    custom_kinds: dict[str, str] = {}
    problems: list[dict[str, Any]] = []
    for record in current:
        for region in record.get("regions", []):
            name = str(region.get("class", ""))
            if name in native_names:
                continue
            kind = str(region.get("kind", ""))
            existing = custom_kinds.get(name)
            if existing is not None and existing != kind:
                problems.append(issue(
                    "CONFLICTING_CATEGORY_DEFINITION",
                    f"Custom category {name} is used with both {existing} and {kind}",
                    frame_id=int(record["frame"]),
                    region_id=str(region.get("id", "")),
                ))
            else:
                custom_kinds[name] = kind
    if problems:
        return categories, problems

    next_id = max((int(category["id"]) for category in categories), default=0) + 1
    for name in sorted(custom_kinds):
        if next_id > MAX_SAFE_INTEGER:
            return categories, [issue(
                "ID_COLLISION", "No safe COCO category ID remains for custom labels"
            )]
        categories.append({
            "id": next_id,
            "name": name,
            "supercategory": custom_kinds[name],
        })
        next_id += 1
    return categories, []


def _verified_frames(snapshot: dict[str, Any], records: list[dict]) -> list[int]:
    reviews = snapshot.get("review_state", {})
    verified: list[int] = []
    for record in records:
        frame = int(record["frame"])
        accepted = reviews.get(str(frame), {}).get("accepted_digest")
        if accepted == canonical_digest(record):
            verified.append(frame)
    return verified


def _safe_source_path(path: Path, root: Path) -> bool:
    try:
        absolute = path.absolute()
        resolved_root = root.resolve(strict=True)
        resolved = absolute.resolve(strict=True)
        if resolved != absolute or not resolved.is_relative_to(resolved_root):
            return False
        cursor = resolved
        while cursor != resolved_root:
            if cursor.is_symlink():
                return False
            cursor = cursor.parent
        return not resolved.is_symlink() and resolved.is_file()
    except (OSError, RuntimeError):
        return False


def _parse_frame_name(value: Any) -> tuple[int, int] | None:
    if not isinstance(value, str) or PurePosixPath(value).name != value:
        return None
    match = _FRAME_NAME.fullmatch(value)
    if match is None:
        return None
    return int(match.group("video")), int(match.group("frame"))


def _same_json(left: Any, right: Any) -> bool:
    return canonical_json_bytes(left) == canonical_json_bytes(right)


def _load_source_metadata(
    descriptor: dict[str, Any],
    selected: set[int],
    *,
    cancel: Callable[[], bool] | None = None,
) -> tuple[dict[str, Any], list[dict[str, Any]], list[dict[str, Any]]]:
    problems: list[dict[str, Any]] = []
    warnings: list[dict[str, Any]] = []
    root = Path(str(descriptor.get("dataset_root", ""))).absolute()
    if not root.is_dir() or root.is_symlink():
        return {}, [issue("SOURCE_METADATA_REQUIRED", "Dataset root is missing or symbolic", path=str(root))], warnings
    split = descriptor.get("source_split")
    video_id = descriptor.get("video_id")
    if split not in {"train", "val", "test"} or not _is_int(video_id):
        return {}, [issue("SOURCE_METADATA_REQUIRED", "Endoscapes split or video identity is invalid")], warnings
    split_root = (root / str(split)).absolute()
    try:
        if (
            not split_root.is_dir()
            or split_root.is_symlink()
            or split_root.resolve(strict=True) != split_root
        ):
            return {}, [issue("SOURCE_METADATA_REQUIRED", "Declared source split directory is missing or symbolic", path=str(split_root))], warnings
    except (OSError, RuntimeError):
        return {}, [issue("SOURCE_METADATA_REQUIRED", "Declared source split directory cannot be resolved", path=str(split_root))], warnings
    if split != "train":
        warnings.append(issue("NON_TRAIN_SPLIT", f"Source split is {split}; it is preserved and not renamed to train"))

    metadata_files = descriptor.get("metadata_files")
    if not isinstance(metadata_files, list):
        return {}, [issue("SOURCE_METADATA_REQUIRED", "Source metadata file list is missing")], warnings
    documents: dict[str, dict[str, Any]] = {}
    source_files: list[dict[str, Any]] = []
    expected_metadata_names = {
        "detection": "annotation_coco.json",
        "video": "annotation_coco_vid.json",
        "ds": "annotation_ds_coco.json",
    }
    for item in metadata_files:
        if cancel is not None and cancel():
            raise InterruptedError("cancelled")
        if not isinstance(item, dict) or item.get("role") not in {"detection", "video", "ds"}:
            problems.append(issue("SOURCE_METADATA_REQUIRED", "Source metadata descriptor is invalid"))
            continue
        role = str(item["role"])
        if role in documents:
            problems.append(issue("CONFLICTING_SOURCE_METADATA", f"Duplicate metadata role: {role}"))
            continue
        path = Path(str(item.get("path", ""))).absolute()
        expected_path = (split_root / expected_metadata_names[role]).absolute()
        if path != expected_path or not _safe_source_path(path, root):
            problems.append(issue("SOURCE_METADATA_REQUIRED", "Metadata path is missing, unsafe, or does not belong to the declared split and role", path=str(path)))
            continue
        try:
            value = _strict_json(path)
        except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
            problems.append(issue("SOURCE_METADATA_REQUIRED", f"Cannot parse source metadata: {exc}", path=str(path)))
            continue
        if not isinstance(value, dict) or any(not isinstance(value.get(key), list) for key in ("images", "annotations", "categories")):
            problems.append(issue("SOURCE_METADATA_REQUIRED", "COCO metadata requires images, annotations and categories arrays", path=str(path)))
            continue
        documents[role] = value
        source_files.append(
            {
                "role": role,
                "relative_path": path.relative_to(root).as_posix(),
                "bytes": path.stat().st_size,
                "sha256": sha256_file(path, cancel),
                "source_path": str(path),
            }
        )
    if "detection" not in documents:
        problems.append(issue("SOURCE_METADATA_REQUIRED", "annotation_coco.json is required for Endoscapes export"))
    if problems:
        return {}, problems, warnings

    category_sets: list[list[dict[str, Any]]] = []
    for role in ("detection", "video", "ds"):
        if role not in documents:
            continue
        categories: list[dict[str, Any]] = []
        seen_ids: set[int] = set()
        seen_names: set[str] = set()
        for value in documents[role]["categories"]:
            if (
                not isinstance(value, dict)
                or set(value) - {"id", "name", "supercategory"}
                or not _is_positive_id(value.get("id"))
                or not isinstance(value.get("name"), str)
                or not value["name"]
                or not isinstance(value.get("supercategory", ""), str)
            ):
                problems.append(issue("CONFLICTING_SOURCE_METADATA", f"Invalid category in {role} metadata"))
                continue
            category_id = int(value["id"])
            name = value["name"]
            if category_id in seen_ids or name in seen_names:
                problems.append(issue("CONFLICTING_SOURCE_METADATA", f"Duplicate category in {role} metadata"))
                continue
            seen_ids.add(category_id)
            seen_names.add(name)
            categories.append(copy.deepcopy(value))
        category_sets.append(sorted(categories, key=lambda value: value["id"]))
    categories = category_sets[0] if category_sets else []
    if not categories or any(not _same_json(categories, other) for other in category_sets[1:]):
        problems.append(issue("CONFLICTING_SOURCE_METADATA", "COCO category tables disagree across source views"))
    if problems:
        return {}, problems, warnings

    images_by_id: dict[int, dict[str, Any]] = {}
    images_by_name: dict[str, dict[str, Any]] = {}
    for role in ("detection", "video", "ds"):
        document = documents.get(role)
        if document is None:
            continue
        for value in document["images"]:
            if not isinstance(value, dict):
                problems.append(issue("CONFLICTING_SOURCE_METADATA", f"Invalid image row in {role} metadata"))
                continue
            parsed = _parse_frame_name(value.get("file_name"))
            image_id = value.get("id")
            width, height = value.get("width"), value.get("height")
            declared_video = value.get("video_id")
            declared_frame = value.get("frame_id")
            if (
                parsed is None
                or not _is_positive_id(image_id)
                or not _is_int(width)
                or int(width) <= 0
                or not _is_int(height)
                or int(height) <= 0
                or (declared_video is not None and not _is_int(declared_video))
                or (declared_frame is not None and not _is_int(declared_frame))
            ):
                problems.append(issue("CONFLICTING_SOURCE_METADATA", f"Invalid image identity in {role} metadata"))
                continue
            parsed_video, source_frame = parsed
            actual_video = parsed_video if declared_video is None else int(declared_video)
            if actual_video != parsed_video:
                problems.append(issue("CONFLICTING_SOURCE_METADATA", "Image video_id disagrees with file name", image_id=int(image_id)))
                continue
            if role != "video" and declared_frame is not None and int(declared_frame) != source_frame:
                problems.append(issue("CONFLICTING_SOURCE_METADATA", "Non-video-view frame_id disagrees with source frame", image_id=int(image_id)))
                continue
            normalized = {
                "id": int(image_id),
                "file_name": value["file_name"],
                "width": int(width),
                "height": int(height),
                "video_id": actual_video,
                "source_frame_id": source_frame,
                "dataset_sequence_index": int(declared_frame) if role == "video" and declared_frame is not None else None,
                "roles": [role],
            }
            existing = images_by_id.get(int(image_id)) or images_by_name.get(value["file_name"])
            if existing is not None:
                shared = ("id", "file_name", "width", "height", "video_id", "source_frame_id")
                if any(existing[key] != normalized[key] for key in shared):
                    problems.append(issue("CONFLICTING_SOURCE_METADATA", "Image identity or dimensions disagree across source views", image_id=int(image_id)))
                    continue
                if normalized["dataset_sequence_index"] is not None:
                    old_index = existing.get("dataset_sequence_index")
                    if old_index is not None and old_index != normalized["dataset_sequence_index"]:
                        problems.append(issue("CONFLICTING_SOURCE_METADATA", "Dataset sequence indices disagree", image_id=int(image_id)))
                        continue
                    existing["dataset_sequence_index"] = normalized["dataset_sequence_index"]
                if role not in existing["roles"]:
                    existing["roles"].append(role)
            else:
                images_by_id[int(image_id)] = normalized
                images_by_name[value["file_name"]] = normalized

    # annotation_coco.json is the only annotation authority.  The video and DS
    # views may corroborate shared native IDs, but auxiliary-only rows must not
    # silently enlarge the training truth set.
    annotations_by_id: dict[int, dict[str, Any]] = {}
    annotations_by_image: dict[int, list[dict[str, Any]]] = {}
    for role in ("detection", "video", "ds"):
        document = documents.get(role)
        if document is None:
            continue
        for value in document["annotations"]:
            if not isinstance(value, dict):
                problems.append(issue("CONFLICTING_SOURCE_METADATA", f"Invalid annotation row in {role} metadata"))
                continue
            annotation_id = value.get("id")
            image_id = value.get("image_id")
            category_id = value.get("category_id")
            if (
                not _is_positive_id(annotation_id)
                or not _is_positive_id(image_id)
                or not _is_positive_id(category_id)
            ):
                frame = (
                    images_by_id.get(image_id, {}).get("source_frame_id")
                    if _is_positive_id(image_id)
                    else None
                )
                problems.append(issue("INCOMPLETE_FRAME_ANNOTATION", "Source annotation identity is invalid", frame_id=frame))
                continue
            normalized = copy.deepcopy(value)
            existing = annotations_by_id.get(int(annotation_id))
            if role == "detection":
                if existing is not None:
                    problems.append(
                        issue(
                            "CONFLICTING_SOURCE_METADATA",
                            f"Detection metadata repeats annotation {annotation_id}",
                            image_id=int(image_id),
                        )
                    )
                    continue
                annotations_by_id[int(annotation_id)] = normalized
            elif existing is not None:
                for field in ("image_id", "category_id", "bbox", "area", "segmentation", "iscrowd"):
                    if field in existing and field in normalized and not _same_json(existing[field], normalized[field]):
                        problems.append(issue("CONFLICTING_SOURCE_METADATA", f"Annotation {annotation_id} field {field} disagrees across views", image_id=int(image_id)))
    for annotation in annotations_by_id.values():
        annotations_by_image.setdefault(int(annotation["image_id"]), []).append(annotation)
    for values in annotations_by_image.values():
        values.sort(key=lambda value: int(value["id"]))

    descriptor_frames: dict[int, dict[str, Any]] = {}
    for value in descriptor.get("frames", []):
        if not isinstance(value, dict):
            problems.append(issue("SOURCE_METADATA_REQUIRED", "Source frame descriptor is invalid"))
            continue
        frame = value.get("source_frame_id")
        playback = value.get("source_playback_index")
        file_name = value.get("file_name")
        source_path = Path(str(value.get("source_path", ""))).absolute()
        expected_source_path = (split_root / str(file_name)).absolute()
        parsed = _parse_frame_name(file_name)
        if (
            not _is_int(frame)
            or not _is_int(playback)
            or parsed is None
            or parsed != (int(video_id), int(frame))
            or str(source_path.name) != file_name
            or source_path != expected_source_path
        ):
            problems.append(issue("SOURCE_METADATA_REQUIRED", "Source frame identity is invalid", frame_id=int(frame) if _is_int(frame) else None))
            continue
        if int(frame) in descriptor_frames:
            problems.append(issue("CONFLICTING_SOURCE_METADATA", "Source frame descriptor is duplicated", frame_id=int(frame)))
            continue
        native = images_by_name.get(file_name)
        if native is None and int(frame) in selected:
            problems.append(issue("SOURCE_METADATA_REQUIRED", "Selected frame has no native COCO image identity", frame_id=int(frame)))
            continue
        descriptor_frames[int(frame)] = {
            "source_frame_id": int(frame),
            "source_playback_index": int(playback),
            "file_name": file_name,
            "source_path": str(source_path),
            "native": copy.deepcopy(native),
        }

    provided_import_bindings = "import_bindings" in descriptor
    import_bindings: dict[int, dict[str, Any]] = {}
    seen_binding_regions: set[tuple[int, str]] = set()
    for value in descriptor.get("import_bindings", []):
        frame = int(value["source_frame_id"])
        image_id = int(value["image_id"])
        annotation_id = int(value["original_annotation_id"])
        region_id = str(value["native_region_id"])
        descriptor_frame = descriptor_frames.get(frame)
        native_annotation = annotations_by_id.get(annotation_id)
        key = (frame, region_id)
        if (
            descriptor_frame is None
            or descriptor_frame.get("native", {}).get("id") != image_id
            or native_annotation is None
            or int(native_annotation.get("image_id", -1)) != image_id
            or value["imported_region"].get("id") != region_id
            or annotation_id in import_bindings
            or key in seen_binding_regions
        ):
            problems.append(
                issue(
                    "CONFLICTING_SOURCE_METADATA",
                    "Import binding does not match one unique native source object",
                    frame_id=frame,
                    image_id=image_id,
                    region_id=region_id,
                )
            )
            continue
        import_bindings[annotation_id] = copy.deepcopy(value)
        seen_binding_regions.add(key)

    for value in descriptor.get("import_issues", []):
        frame = int(value["source_frame_id"])
        if frame not in selected:
            continue
        image_id = int(value["image_id"])
        descriptor_frame = descriptor_frames.get(frame)
        if (
            descriptor_frame is None
            or descriptor_frame.get("native", {}).get("id") != image_id
        ):
            problems.append(
                issue(
                    "CONFLICTING_SOURCE_METADATA",
                    "Import issue evidence does not match the selected source frame",
                    frame_id=frame,
                    image_id=image_id,
                    region_id=str(value["native_region_id"]),
                )
            )
            continue
        evidence = issue(
            "INCOMPLETE_FRAME_ANNOTATION"
            if value["blocking"]
            else "SOURCE_IMPORT_FALLBACK",
            f"Source import evidence: {value['code']}",
            frame_id=frame,
            image_id=image_id,
            region_id=str(value["native_region_id"]) or None,
        )
        if value["blocking"]:
            problems.append(evidence)
        else:
            warnings.append(evidence)

    category_by_id = {int(value["id"]): value for value in categories}
    skipped_by_frame: dict[int, list[str]] = {}
    for annotation in annotations_by_id.values():
        image = images_by_id.get(int(annotation["image_id"]))
        if image is None:
            continue
        frame = int(image["source_frame_id"])
        if int(annotation["category_id"]) not in category_by_id:
            skipped_by_frame.setdefault(frame, []).append(f"annotation {annotation['id']}: unknown category")
        if not isinstance(annotation.get("bbox"), list) and "segmentation" not in annotation:
            skipped_by_frame.setdefault(frame, []).append(f"annotation {annotation['id']}: missing geometry")

    return {
        "dataset_namespace": descriptor["dataset_namespace"],
        "dataset_root": str(root),
        "source_split": split,
        "video_id": int(video_id),
        "categories": categories,
        "category_by_id": category_by_id,
        "frames": descriptor_frames,
        "images_by_id": images_by_id,
        "annotations_by_id": annotations_by_id,
        "annotations_by_image": annotations_by_image,
        "source_files": source_files,
        "skipped_by_frame": skipped_by_frame,
        "provided_import_bindings": provided_import_bindings,
        "import_bindings": import_bindings,
    }, problems, warnings


def _valid_box(value: Any, width: int, height: int) -> list[float] | None:
    if not isinstance(value, list) or len(value) != 4 or any(not _is_number(item) for item in value):
        return None
    box = [float(item) for item in value]
    x, y, box_width, box_height = box
    if x < 0 or y < 0 or box_width <= 0 or box_height <= 0:
        return None
    if x + box_width > width + 1e-7 or y + box_height > height + 1e-7:
        return None
    return box


def _orientation(a: list[float], b: list[float], c: list[float]) -> float:
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def _segments_cross(a: list[float], b: list[float], c: list[float], d: list[float]) -> bool:
    one = _orientation(a, b, c)
    two = _orientation(a, b, d)
    three = _orientation(c, d, a)
    four = _orientation(c, d, b)
    return (one > 1e-9 and two < -1e-9 or one < -1e-9 and two > 1e-9) and (
        three > 1e-9 and four < -1e-9 or three < -1e-9 and four > 1e-9
    )


def _valid_polygon(value: Any, width: int, height: int) -> tuple[list[list[float]], float, list[float]] | None:
    if not isinstance(value, list) or len(value) < 3:
        return None
    points: list[list[float]] = []
    for point in value:
        if not isinstance(point, list) or len(point) != 2 or any(not _is_number(item) for item in point):
            return None
        x, y = float(point[0]), float(point[1])
        if x < 0 or y < 0 or x > width or y > height:
            return None
        if points and points[-1] == [x, y]:
            return None
        points.append([x, y])
    if points[0] == points[-1]:
        points.pop()
    if len(points) < 3 or len({tuple(point) for point in points}) < 3:
        return None
    count = len(points)
    for left in range(count):
        left_next = (left + 1) % count
        for right in range(left + 1, count):
            right_next = (right + 1) % count
            if left in {right, right_next} or left_next in {right, right_next}:
                continue
            if _segments_cross(points[left], points[left_next], points[right], points[right_next]):
                return None
    signed_twice = sum(
        points[index][0] * points[(index + 1) % count][1]
        - points[(index + 1) % count][0] * points[index][1]
        for index in range(count)
    )
    area = abs(signed_twice) / 2.0
    if area <= 1e-9:
        return None
    xs = [point[0] for point in points]
    ys = [point[1] for point in points]
    box = [min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)]
    if box[2] <= 0 or box[3] <= 0:
        return None
    return points, area, box


def _decode_compressed_counts(value: str) -> list[int]:
    counts: list[int] = []
    position = 0
    while position < len(value):
        number = 0
        shift = 0
        more = True
        last = 0
        while more:
            if position >= len(value):
                raise ValueError("truncated compressed RLE")
            last = ord(value[position]) - 48
            if last < 0 or last > 63:
                raise ValueError("invalid compressed RLE character")
            number |= (last & 0x1F) << (5 * shift)
            more = bool(last & 0x20)
            position += 1
            shift += 1
        if last & 0x10:
            number |= -1 << (5 * shift)
        if len(counts) > 2:
            number += counts[-2]
        if number < 0:
            raise ValueError("negative compressed RLE run")
        counts.append(number)
    return counts


def decode_coco_rle(segmentation: Any) -> np.ndarray:
    if not isinstance(segmentation, dict) or set(segmentation) != {"size", "counts"}:
        raise ValueError("RLE must contain only size and counts")
    size = segmentation["size"]
    if (
        not isinstance(size, list)
        or len(size) != 2
        or any(not _is_int(item) or int(item) <= 0 for item in size)
    ):
        raise ValueError("RLE size must be [positive height, positive width]")
    counts_value = segmentation["counts"]
    if isinstance(counts_value, str):
        counts = _decode_compressed_counts(counts_value)
    elif isinstance(counts_value, list) and all(_is_int(item) for item in counts_value):
        counts = [int(item) for item in counts_value]
    else:
        raise ValueError("RLE counts must be a compressed string or integer array")
    height, width = map(int, size)
    total = height * width
    flat = np.zeros(total, dtype=np.uint8)
    offset = 0
    value = 0
    for run in counts:
        if offset + run > total:
            raise ValueError("RLE runs exceed mask dimensions")
        if value:
            flat[offset : offset + run] = 1
        offset += run
        value = 1 - value
    if offset != total:
        raise ValueError("RLE runs do not cover mask dimensions")
    return flat.reshape((height, width), order="F")


def _native_segmentation(
    value: Any,
    width: int,
    height: int,
) -> tuple[Any, float, list[float]]:
    if isinstance(value, dict):
        mask = decode_coco_rle(value)
        if mask.shape != (height, width):
            raise ValueError("RLE size differs from decoded image dimensions")
        rows, columns = np.nonzero(mask)
        if len(columns) == 0:
            raise ValueError("RLE mask is empty")
        box = [
            float(columns.min()),
            float(rows.min()),
            float(columns.max() - columns.min() + 1),
            float(rows.max() - rows.min() + 1),
        ]
        return copy.deepcopy(value), float(mask.sum()), box
    if isinstance(value, list) and value:
        segments: list[list[float]] = []
        total_area = 0.0
        all_points: list[list[float]] = []
        for flat in value:
            if not isinstance(flat, list) or len(flat) < 6 or len(flat) % 2:
                raise ValueError("COCO polygon segmentation is malformed")
            polygon = [[flat[index], flat[index + 1]] for index in range(0, len(flat), 2)]
            validated = _valid_polygon(polygon, width, height)
            if validated is None:
                raise ValueError("COCO polygon segmentation is invalid")
            points, area, _box = validated
            segments.append([coordinate for point in points for coordinate in point])
            total_area += area
            all_points.extend(points)
        xs = [point[0] for point in all_points]
        ys = [point[1] for point in all_points]
        return segments, total_area, [min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)]
    raise ValueError("segmentation is empty or unsupported")


def _equal_geometry(left: dict[str, Any], right: dict[str, Any]) -> bool:
    return {key: left[key] for key in ("box", "polygon") if key in left} == {
        key: right[key] for key in ("box", "polygon") if key in right
    }


def _stable_id_candidate(domain: str, components: list[Any]) -> int:
    encoded = canonical_json_bytes([domain, *components]).removesuffix(b"\n")
    return int(hashlib.sha256(encoded).hexdigest()[:ID_HASH_HEX_DIGITS], 16) + 1


def _allocate_stable_id(
    domain: str,
    components: list[Any],
    reserved: set[int],
    assigned: set[int],
) -> int | None:
    candidate = _stable_id_candidate(domain, components)
    if candidate in reserved or candidate in assigned or candidate > MAX_SAFE_INTEGER:
        return None
    assigned.add(candidate)
    return candidate


def _region_without_ui_fields(value: dict[str, Any] | None) -> dict[str, Any] | None:
    if value is None:
        return None
    return {key: copy.deepcopy(item) for key, item in value.items() if key != "filled"}


def build_annotation_diff(
    snapshot: dict[str, Any],
    baseline: list[dict],
    current: list[dict],
    selected: list[int],
) -> dict[str, Any]:
    counts = dict.fromkeys(DIFF_TYPES, 0)
    summary: dict[str, Any] = {
        **counts,
        "total_frames": len(snapshot["frame_entries"]),
        "included_frames": len(selected),
        "excluded_frames": len(snapshot["frame_entries"]) - len(selected),
        "changed_frames": 0,
        "changed_regions": 0,
    }
    result = {
        "schema_version": 1,
        "available": snapshot["baseline_kind"] != "unknown",
        "frames": [],
        "summary": summary,
        "by_class": [],
    }
    if not result["available"]:
        return result
    old_records = {int(record["frame"]): record for record in baseline}
    new_records = {int(record["frame"]): record for record in current}
    classes: dict[str, dict[str, Any]] = {}

    def increment(label: str, field: str) -> None:
        if label not in classes:
            classes[label] = {"class": label, **dict.fromkeys(CLASS_DIFF_TYPES, 0)}
        classes[label][field] += 1

    for frame in sorted(set(selected)):
        old = {
            item["id"]: _region_without_ui_fields(item)
            for item in old_records.get(frame, {}).get("regions", [])
        }
        new = {
            item["id"]: _region_without_ui_fields(item)
            for item in new_records.get(frame, {}).get("regions", [])
        }
        row = {
            "frame_id": frame,
            "events": [],
            "counts": dict.fromkeys(DIFF_TYPES, 0),
            "changed_regions": 0,
        }
        for region_id in sorted(old.keys() | new.keys()):
            before, after = old.get(region_id), new.get(region_id)
            kinds: list[str] = []
            if before is None:
                kinds.append("added")
            elif after is None:
                kinds.append("deleted")
            else:
                if before["class"] != after["class"]:
                    kinds.append("label_changed")
                if {key: before[key] for key in ("box", "polygon") if key in before} != {
                    key: after[key] for key in ("box", "polygon") if key in after
                }:
                    kinds.append("geometry_changed")
                if {key: before[key] for key in ("kind", "track_id", "conf") if key in before} != {
                    key: after[key] for key in ("kind", "track_id", "conf") if key in after
                }:
                    kinds.append("attributes_changed")
            if kinds:
                row["changed_regions"] += 1
            for kind in kinds:
                row["events"].append(
                    {
                        "region_id": region_id,
                        "type": kind,
                        "before": before,
                        "after": after,
                    }
                )
                row["counts"][kind] += 1
                summary[kind] += 1
                if kind == "label_changed":
                    increment(before["class"], "reclassified_out")
                    increment(after["class"], "reclassified_in")
                else:
                    target = before if kind == "deleted" else after
                    increment(target["class"], kind)
        if row["changed_regions"]:
            summary["changed_frames"] += 1
        summary["changed_regions"] += row["changed_regions"]
        result["frames"].append(row)
    result["by_class"] = [classes[label] for label in sorted(classes)]
    return result


def coco_package_identity(manifest: dict[str, Any]) -> str:
    projection = {
        key: copy.deepcopy(value)
        for key, value in manifest.items()
        if key not in {"package_id", "created_at", "saved_revision"}
    }
    return sha256_bytes(canonical_json_bytes(projection).removesuffix(b"\n"))


def _inspect_image(
    source: Path,
    root: Path,
    *,
    cancel: Callable[[], bool] | None,
) -> tuple[int, int, int, str]:
    if not _safe_source_path(source, root) or source.suffix.lower() not in IMAGE_EXTENSIONS:
        raise FileNotFoundError("image is missing, symbolic, unsupported, or outside the dataset")
    raw = source.read_bytes()
    if cancel is not None and cancel():
        raise InterruptedError("cancelled")
    flags = cv2.IMREAD_UNCHANGED
    if hasattr(cv2, "IMREAD_IGNORE_ORIENTATION"):
        flags |= cv2.IMREAD_IGNORE_ORIENTATION
    decoded = cv2.imdecode(np.frombuffer(raw, dtype=np.uint8), flags)
    if decoded is None or decoded.size == 0 or len(decoded.shape) < 2:
        raise ValueError("image cannot be fully decoded")
    return int(decoded.shape[1]), int(decoded.shape[0]), len(raw), sha256_bytes(raw)


def prepare_coco_export(
    context: dict[str, Any],
    *,
    cancel: Callable[[], bool] | None = None,
    progress: Callable[[dict[str, Any]], None] | None = None,
) -> dict[str, Any]:
    """Validate, bind, select, inspect and deterministically prepare one package."""

    began = time.perf_counter_ns()
    options = context.get("export_options", {}) if isinstance(context, dict) else {}
    task = options.get("task", "detection") if isinstance(options, dict) else "detection"
    snapshot = context.get("saved_snapshot", {}) if isinstance(context, dict) else {}
    revision = snapshot.get("revision", -1) if isinstance(snapshot, dict) else -1
    problems: list[dict[str, Any]] = []
    warnings: list[dict[str, Any]] = []

    if not isinstance(context, dict):
        problems.append(issue("PACKAGE_INVALID", "Export context must be an object"))
    else:
        try:
            context_errors = validate_instance(
                context, "coco-export-context-v1.schema.json"
            )
        except (OSError, TypeError, ValueError) as exc:
            context_errors = [f"schema unavailable: {exc}"]
        problems.extend(
            issue("PACKAGE_INVALID", f"Export context schema: {message}")
            for message in context_errors
        )
    if problems:
        return _result_base(
            success=False,
            issues=problems,
            warnings=warnings,
            task=task,
            saved_revision=revision,
        )

    try:
        session_errors = validate_review_session(snapshot)
    except (KeyError, TypeError, ValueError) as exc:
        session_errors = [f"cannot inspect saved session: {exc}"]
    problems.extend(
        issue("PACKAGE_INVALID", f"Saved session is invalid: {message}")
        for message in session_errors
    )
    token = context["preparation_token"]
    if (
        token["session_id"] != snapshot["session_id"]
        or token["saved_revision"] != snapshot["revision"]
    ):
        problems.append(
            issue(
                "STALE_CONTEXT",
                "Preparation token does not identify the frozen saved snapshot",
            )
        )
    if snapshot.get("baseline_kind") == "unknown":
        problems.append(issue("SOURCE_METADATA_REQUIRED", "Training export requires a known immutable baseline"))
    if problems:
        return _result_base(success=False, issues=problems, warnings=warnings, task=task, saved_revision=revision)

    baseline, current = _materialize_records(snapshot)
    verified = _verified_frames(snapshot, current)
    verified_set = set(verified)
    source_order = [int(entry["frame_id"]) for entry in snapshot["frame_entries"]]
    source_set = set(source_order)
    requested = options.get("selected_frame_ids")
    if requested is None:
        selected = source_order
        coverage_policy = "all_source_frames"
        exclusion_reason = "none"
    elif (
        not isinstance(requested, list)
        or any(not _is_int(value) for value in requested)
        or len(set(requested)) != len(requested)
    ):
        problems.append(issue("PACKAGE_INVALID", "Selected frame IDs must be unique non-negative integers"))
        selected = []
        coverage_policy = "selected_source_frames"
        exclusion_reason = "not_selected"
    else:
        requested_set = set(map(int, requested))
        rejected = requested_set - source_set
        for frame in sorted(rejected):
            problems.append(issue("SOURCE_METADATA_REQUIRED", "Selected frame is not part of the current Source", frame_id=frame))
        selected = [frame for frame in source_order if frame in requested_set]
        coverage_policy = "selected_source_frames"
        exclusion_reason = "not_selected"
    if not selected and not problems:
        problems.append(issue("PACKAGE_INVALID", "At least one Source frame must be selected for export"))
    unverified_selected = [frame for frame in selected if frame not in verified_set]
    if unverified_selected:
        warnings.append(issue(
            "UNVERIFIED_FRAMES_INCLUDED",
            f"The package includes {len(unverified_selected)} frames whose current content is not verified",
        ))
    if problems:
        return _result_base(success=False, issues=problems, warnings=warnings, task=task, saved_revision=revision)
    if cancel is not None and cancel():
        result = _result_base(success=False, task=task, saved_revision=revision)
        result["cancelled"] = True
        return result

    metadata_started = time.perf_counter_ns()
    metadata, source_problems, source_warnings = _load_source_metadata(
        context.get("source_descriptor", {}), set(selected), cancel=cancel
    )
    problems.extend(source_problems)
    warnings.extend(source_warnings)

    if not problems:
        categories, category_problems = _extend_category_table(
            metadata["categories"], current
        )
        metadata["categories"] = categories
        problems.extend(category_problems)
    timings = {"source_metadata": (time.perf_counter_ns() - metadata_started) // 1_000_000}
    if problems:
        return _result_base(success=False, issues=problems, warnings=warnings, task=task, saved_revision=revision, timings_ms=timings)
    if progress is not None:
        progress({"stage": "metadata", "completed": 1, "total": 1, "fraction": 0.15, "message": "Source metadata validated"})

    root = Path(metadata["dataset_root"])
    inspected: dict[int, dict[str, Any]] = {}
    image_started = time.perf_counter_ns()
    for index, frame in enumerate(selected):
        if cancel is not None and cancel():
            result = _result_base(success=False, task=task, saved_revision=revision, timings_ms=timings)
            result["cancelled"] = True
            return result
        descriptor_frame = metadata["frames"].get(frame)
        if descriptor_frame is None or descriptor_frame.get("native") is None:
            problems.append(issue("SOURCE_METADATA_REQUIRED", "Selected frame has no complete source descriptor", frame_id=frame))
            continue
        source = Path(descriptor_frame["source_path"])
        try:
            width, height, byte_count, digest = _inspect_image(source, root, cancel=cancel)
        except FileNotFoundError as exc:
            problems.append(issue("IMAGE_MISSING", str(exc), frame_id=frame, path=str(source)))
            continue
        except ValueError as exc:
            problems.append(issue("IMAGE_CORRUPT", str(exc), frame_id=frame, path=str(source)))
            continue
        native = descriptor_frame["native"]
        if (width, height) != (native["width"], native["height"]):
            if (width, height) == (native["height"], native["width"]):
                warnings.append(issue("IMAGE_METADATA_DIMENSIONS_SWAPPED", "Native metadata width/height were swapped; exported dimensions use decoded pixels", frame_id=frame, image_id=native["id"]))
            else:
                problems.append(issue("IMAGE_GEOMETRY_SPACE_MISMATCH", "Decoded image dimensions disagree with native metadata", frame_id=frame, image_id=native["id"]))
                continue
        inspected[frame] = {
            **copy.deepcopy(descriptor_frame),
            "width": width,
            "height": height,
            "bytes": byte_count,
            "sha256": digest,
        }
        if progress is not None:
            progress({
                "stage": "images",
                "completed": index + 1,
                "total": len(selected),
                "fraction": 0.15 + 0.35 * (index + 1) / len(selected),
                "message": f"Validated image {index + 1}/{len(selected)}",
            })
    timings["image_preflight"] = (time.perf_counter_ns() - image_started) // 1_000_000
    if problems:
        return _result_base(success=False, issues=problems, warnings=warnings, task=task, saved_revision=revision, timings_ms=timings)

    records_by_frame = {int(record["frame"]): record for record in current}
    baseline_by_frame = {int(record["frame"]): record for record in baseline}
    category_by_name = {category["name"]: category for category in metadata["categories"]}
    allowed_category_names = ", ".join(category_by_name)
    reserved_annotation_ids = set(metadata["annotations_by_id"])
    assigned_annotation_ids: set[int] = set()
    assigned_image_ids: set[int] = set()
    coco_images: list[dict[str, Any]] = []
    coco_annotations: list[dict[str, Any]] = []
    samples: list[dict[str, Any]] = []
    links: list[dict[str, Any]] = []
    native_bindings: dict[tuple[int, str], dict[str, Any]] = {}

    for frame in selected:
        inspected_frame = inspected[frame]
        native_image = inspected_frame["native"]
        native_annotations = metadata["annotations_by_image"].get(native_image["id"], [])
        baseline_regions = {
            region["id"]: region
            for region in baseline_by_frame.get(frame, {}).get("regions", [])
        }
        for native_annotation in native_annotations:
            binding = metadata["import_bindings"].get(int(native_annotation["id"]))
            if metadata["provided_import_bindings"]:
                if binding is None:
                    problems.append(issue("INCOMPLETE_FRAME_ANNOTATION", "A native source object has no explicit import binding", frame_id=frame, image_id=native_image["id"]))
                    continue
                expected_id = str(binding["native_region_id"])
            else:
                # Legacy saved sessions can be explicitly rebound by replaying the
                # deterministic importer projection against their immutable baseline.
                expected_id = f"endoscapes-{metadata['source_split']}-{native_image['id']}-{native_annotation['id']}"
            baseline_region = baseline_regions.get(expected_id)
            category = metadata["category_by_id"].get(int(native_annotation["category_id"]))
            if baseline_region is None or category is None:
                problems.append(issue("INCOMPLETE_FRAME_ANNOTATION", "A native source object was skipped or cannot be bound to the immutable baseline", frame_id=frame, image_id=native_image["id"], region_id=expected_id))
                continue
            if binding is not None:
                geometry_bound = _same_json(
                    _region_without_ui_fields(baseline_region),
                    _region_without_ui_fields(binding["imported_region"]),
                )
            else:
                native_box = _valid_box(native_annotation.get("bbox"), inspected_frame["width"], inspected_frame["height"])
                baseline_box = _valid_box(baseline_region.get("box"), inspected_frame["width"], inspected_frame["height"])
                geometry_bound = native_box is not None and baseline_box == native_box
                if not geometry_bound and "segmentation" in native_annotation and "polygon" in baseline_region:
                    # Legacy rebinding validates both source geometries without
                    # parsing the region ID or guessing with nearest-box IoU.
                    geometry_bound = _valid_polygon(baseline_region["polygon"], inspected_frame["width"], inspected_frame["height"]) is not None
            if baseline_region.get("class") != category["name"] or not geometry_bound:
                problems.append(issue("CONFLICTING_SOURCE_METADATA", "Native annotation does not reproduce the immutable imported baseline", frame_id=frame, image_id=native_image["id"], region_id=expected_id))
                continue
            native_bindings[(frame, expected_id)] = native_annotation
        if metadata["skipped_by_frame"].get(frame):
            problems.append(issue("INCOMPLETE_FRAME_ANNOTATION", "; ".join(metadata["skipped_by_frame"][frame]), frame_id=frame, image_id=native_image["id"]))

    if problems:
        return _result_base(success=False, issues=problems, warnings=warnings, task=task, saved_revision=revision, timings_ms=timings)

    projection_started = time.perf_counter_ns()
    for frame in selected:
        item = inspected[frame]
        native_image = item["native"]
        image_id = int(native_image["id"])
        if image_id in assigned_image_ids:
            problems.append(issue("ID_COLLISION", "Image ID is repeated", frame_id=frame, image_id=image_id))
            continue
        assigned_image_ids.add(image_id)
        image_value: dict[str, Any] = {
            "id": image_id,
            "file_name": item["file_name"],
            "width": item["width"],
            "height": item["height"],
        }
        if native_image.get("video_id") is not None:
            image_value["video_id"] = native_image["video_id"]
        coco_images.append(image_value)
        record = records_by_frame[frame]
        baseline_regions = {
            region["id"]: region
            for region in baseline_by_frame.get(frame, {}).get("regions", [])
        }
        annotation_status = "negative" if not record.get("regions") else "annotated"
        accepted_digest = snapshot.get("review_state", {}).get(
            str(frame), {}
        ).get("accepted_digest")
        if str(frame) in snapshot.get("frames", {}):
            label_source = "current_correction"
        elif snapshot["baseline_kind"] in {"model", "imported_labels"}:
            label_source = "previous_baseline"
        else:
            label_source = "no_annotation"
        samples.append(
            {
                "image_id": image_id,
                "source_frame_id": frame,
                "source_playback_index": item["source_playback_index"],
                "dataset_sequence_index": native_image.get("dataset_sequence_index"),
                "review_digest": accepted_digest,
                "review_status": (
                    "verified_current" if frame in verified_set else "unverified"
                ),
                "label_source": label_source,
                "annotation_status": annotation_status,
            }
        )
        for region in sorted(record.get("regions", []), key=lambda value: value["id"]):
            region_id = str(region.get("id", ""))
            category = category_by_name.get(region.get("class"))
            if category is None:
                problems.append(issue(
                    "UNKNOWN_CATEGORY",
                    f"Unknown category: {region.get('class')}. "
                    f"Allowed source categories: {allowed_category_names}",
                    frame_id=frame,
                    image_id=image_id,
                    region_id=region_id,
                ))
                continue
            native_annotation = native_bindings.get((frame, region_id))
            baseline_region = baseline_regions.get(region_id)
            geometry_unchanged = baseline_region is not None and _equal_geometry(region, baseline_region)
            if native_annotation is not None:
                annotation_id = int(native_annotation["id"])
                if annotation_id in assigned_annotation_ids:
                    problems.append(issue("ID_COLLISION", "Native annotation ID is repeated", frame_id=frame, image_id=image_id, region_id=region_id))
                    continue
                assigned_annotation_ids.add(annotation_id)
            else:
                annotation_id = _allocate_stable_id(
                    "annotation",
                    [metadata["dataset_namespace"], snapshot["media_id"], frame, region_id],
                    reserved_annotation_ids,
                    assigned_annotation_ids,
                )
                if annotation_id is None:
                    problems.append(issue("ID_COLLISION", "Stable generated annotation ID collides with a native or generated ID", frame_id=frame, image_id=image_id, region_id=region_id))
                    continue

            box = _valid_box(region.get("box"), item["width"], item["height"]) if "box" in region else None
            polygon = _valid_polygon(region.get("polygon"), item["width"], item["height"]) if "polygon" in region else None
            if (
                ("box" in region and box is None)
                or ("polygon" in region and polygon is None)
                or (box is None and polygon is None)
            ):
                problems.append(issue("INVALID_GEOMETRY", "Current region geometry is invalid or outside the decoded image", frame_id=frame, image_id=image_id, region_id=region_id))
                continue
            if box is not None and polygon is not None and any(abs(left - right) > 1e-6 for left, right in zip(box, polygon[2])):
                problems.append(issue("INVALID_GEOMETRY", "Current box and polygon describe conflicting geometry", frame_id=frame, image_id=image_id, region_id=region_id))
                continue

            exported: dict[str, Any] = {
                "id": annotation_id,
                "image_id": image_id,
                "category_id": int(category["id"]),
                "iscrowd": int(native_annotation.get("iscrowd", 0)) if native_annotation is not None and native_annotation.get("iscrowd") in (0, 1) else 0,
            }
            geometry_source = ""
            area_source = ""
            segmentation: Any = None
            segmentation_area: float | None = None
            native_mask_error: str | None = None
            if native_annotation is not None and geometry_unchanged and "segmentation" in native_annotation:
                try:
                    segmentation, segmentation_area, native_mask_box = _native_segmentation(
                        native_annotation["segmentation"], item["width"], item["height"]
                    )
                    if box is None:
                        box = native_mask_box
                    geometry_source = "original_rle" if isinstance(segmentation, dict) else "original_polygon"
                except ValueError as exc:
                    native_mask_error = str(exc)
            if native_mask_error is not None:
                if not options.get("allow_box_only_fallback", False):
                    problems.append(issue("INVALID_GEOMETRY", f"Native segmentation is invalid: {native_mask_error}", frame_id=frame, image_id=image_id, region_id=region_id))
                    continue
                warnings.append(issue("SEGMENTATION_OMITTED", f"Native segmentation was omitted: {native_mask_error}", frame_id=frame, image_id=image_id, region_id=region_id))
            if segmentation is None and polygon is not None:
                points, segmentation_area, polygon_box = polygon
                segmentation = [[coordinate for point in points for coordinate in point]]
                box = polygon_box
                geometry_source = "current_polygon"
            if box is None:
                problems.append(issue("INVALID_GEOMETRY", "A detection bounding box cannot be derived", frame_id=frame, image_id=image_id, region_id=region_id))
                continue
            exported["bbox"] = box
            if segmentation is not None:
                exported["segmentation"] = segmentation
                original_area = native_annotation.get("area") if native_annotation is not None else None
                if geometry_source.startswith("original") and _is_number(original_area) and float(original_area) > 0 and abs(float(original_area) - float(segmentation_area)) <= 1e-6:
                    exported["area"] = original_area
                    area_source = "original"
                else:
                    exported["area"] = float(segmentation_area)
                    area_source = "mask"
            elif native_annotation is not None and geometry_unchanged and _is_number(native_annotation.get("area")) and float(native_annotation["area"]) > 0:
                exported["area"] = native_annotation["area"]
                area_source = "original"
                geometry_source = "original_box"
            else:
                exported["area"] = float(box[2] * box[3])
                area_source = "bbox_fallback"
                geometry_source = "current_box"
            if task == "instance_segmentation" and segmentation is None:
                problems.append(issue("SEGMENTATION_REQUIRED", "Every target in an instance-segmentation frame requires a current valid mask", frame_id=frame, image_id=image_id, region_id=region_id))
                continue
            if (
                task == "instance_segmentation"
                and geometry_source.startswith("original")
                and "polygon" not in region
                and not options.get("segmentation_attested", False)
            ):
                problems.append(issue("SEGMENTATION_REQUIRED", "Native mask review must be explicitly attested when the editor only displayed a box", frame_id=frame, image_id=image_id, region_id=region_id))
                continue
            coco_annotations.append(exported)
            links.append(
                {
                    "image_id": image_id,
                    "source_frame_id": frame,
                    "native_region_id": region_id,
                    "exported_annotation_id": annotation_id,
                    "original_annotation_id": int(native_annotation["id"]) if native_annotation is not None else None,
                    "geometry_source": geometry_source,
                    "area_source": area_source,
                    "binding_method": "native_import_projection" if native_annotation is not None else "stable_generated",
                }
            )

    if problems:
        return _result_base(success=False, issues=problems, warnings=warnings, task=task, saved_revision=revision, timings_ms=timings)
    coco_annotations.sort(key=lambda value: (value["image_id"], value["id"]))
    links.sort(key=lambda value: (value["source_frame_id"], value["native_region_id"]))
    coco = {
        "info": {
            "description": "Project6 single-media training export",
            "version": "training_coco_v1",
            "task": task,
        },
        "images": coco_images,
        "annotations": coco_annotations,
        "categories": metadata["categories"],
    }
    diff = build_annotation_diff(snapshot, baseline, current, selected)
    timings["projection"] = (time.perf_counter_ns() - projection_started) // 1_000_000
    label_bytes = canonical_json_bytes(coco)
    diff_bytes = canonical_json_bytes(diff)
    artifacts = [
        {
            "role": "image",
            "path": f"images/{inspected[frame]['file_name']}",
            "bytes": inspected[frame]["bytes"],
            "sha256": inspected[frame]["sha256"],
        }
        for frame in selected
    ]
    artifacts.extend(
        [
            {"role": "annotation", "path": "labels/annotation_coco.json", "bytes": len(label_bytes), "sha256": sha256_bytes(label_bytes)},
            {"role": "diff", "path": "reports/diff.json", "bytes": len(diff_bytes), "sha256": sha256_bytes(diff_bytes)},
        ]
    )
    artifacts.sort(key=lambda value: value["path"])
    all_source_frames = [int(entry["frame_id"]) for entry in snapshot["frame_entries"]]
    selected_set = set(selected)
    coverage = {
        "policy": coverage_policy,
        "total_frames": len(all_source_frames),
        "included_frames": len(selected),
        "excluded_frames": len(all_source_frames) - len(selected),
        "negative_frames": sum(sample["annotation_status"] == "negative" for sample in samples),
        "source_frame_ids": all_source_frames,
        "included_frame_ids": selected,
        "excluded_frame_ids": [frame for frame in all_source_frames if frame not in selected_set],
        "verified_frame_ids": verified,
        "exclusion_reason": exclusion_reason,
    }
    media = {
        "media_id": snapshot["media_id"],
        "media_type": snapshot["media_type"],
        "source": snapshot["source"],
        "source_relative_path": snapshot["source_relative_path"],
        "source_sha256": snapshot["source_sha256"],
    }
    summary = {
        **diff["summary"],
        "negative_frames": coverage["negative_frames"],
        "annotations": len(coco_annotations),
        "categories": len(metadata["categories"]),
    }
    manifest: dict[str, Any] = {
        "schema_version": 1,
        "package_type": PACKAGE_TYPE,
        "package_id": "0" * 64,
        "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "producer": {"name": "Project6", "version": "training-coco-v1"},
        "annotation_format": "coco_instances",
        "task": task,
        "label_origin": "mixed_current_and_baseline",
        "annotation_path": "labels/annotation_coco.json",
        "image_root": "images",
        "dataset": {
            "dataset_namespace": metadata["dataset_namespace"],
            "source_split": metadata["source_split"],
            "original_video_id": metadata["video_id"],
        },
        "media": media,
        "round_id": snapshot["round_id"],
        "model_revision": snapshot["model_revision"],
        "taxonomy_version": snapshot["taxonomy_version"],
        "baseline": {"kind": snapshot["baseline_kind"], "digest": snapshot["baseline_digest"]},
        "saved_revision": int(snapshot["revision"]),
        "category_table_sha256": sha256_bytes(canonical_json_bytes(metadata["categories"]).removesuffix(b"\n")),
        "source_frame_entries": copy.deepcopy(snapshot["frame_entries"]),
        "coverage": coverage,
        "samples": samples,
        "annotation_links": links,
        "provenance": {
            "binding_method": "endoscapes_multi_view_v1",
            "source_files": [
                {key: value for key, value in source_file.items() if key != "source_path"}
                for source_file in sorted(metadata["source_files"], key=lambda value: value["role"])
            ],
            "batch_operations": copy.deepcopy(snapshot.get("batch_operations", [])),
        },
        "quality": {
            "image_integrity_scope": "export_time_only",
            "time_semantics": "source_frame_number_not_certified_seconds",
            # The detailed result keeps one warning per affected frame, while
            # the manifest contract records the stable set of warning classes.
            "warnings": list(dict.fromkeys(warning["code"] for warning in warnings)),
        },
        "summary": summary,
        "artifacts": artifacts,
    }
    manifest["package_id"] = coco_package_identity(manifest)
    try:
        manifest_errors = validate_instance(manifest, "training-coco-v1.schema.json")
    except (OSError, TypeError, ValueError) as exc:
        manifest_errors = [f"schema unavailable: {exc}"]
    if manifest_errors:
        return _result_base(
            success=False,
            issues=[
                issue("PACKAGE_INVALID", f"Generated manifest schema: {message}")
                for message in manifest_errors
            ],
            warnings=warnings,
            task=task,
            saved_revision=revision,
            timings_ms=timings,
        )
    source_fingerprint = canonical_digest(
        {
            "metadata": [
                {"role": item["role"], "sha256": item["sha256"]}
                for item in manifest["provenance"]["source_files"]
            ],
            "images": [
                {"frame": frame, "sha256": inspected[frame]["sha256"]}
                for frame in selected
            ],
        }
    )
    preparation_digest = canonical_digest(
        {
            "session_id": snapshot["session_id"],
            "saved_revision": snapshot["revision"],
            "package_id": manifest["package_id"],
            "source_fingerprint": source_fingerprint,
            "task": task,
            "selected_frame_ids": selected,
        }
    )
    timings["total_prepare"] = (time.perf_counter_ns() - began) // 1_000_000
    result = _result_base(success=True, warnings=warnings, task=task, saved_revision=revision, timings_ms=timings)
    result.update(
        {
            "package_id": manifest["package_id"],
            "package_saved_revision": int(manifest["saved_revision"]),
            "summary": summary,
            "manifest": manifest,
            "coco": coco,
            "diff": diff,
            "preparation_digest": preparation_digest,
            "source_fingerprint": source_fingerprint,
            "image_sources": [
                {
                    "frame_id": frame,
                    "source_path": inspected[frame]["source_path"],
                    "artifact_path": f"images/{inspected[frame]['file_name']}",
                    "bytes": inspected[frame]["bytes"],
                    "sha256": inspected[frame]["sha256"],
                }
                for frame in selected
            ],
            "label_bytes": label_bytes,
            "diff_bytes": diff_bytes,
            "dataset_root": metadata["dataset_root"],
            "source_metadata_paths": [item["source_path"] for item in metadata["source_files"]],
        }
    )
    return result
