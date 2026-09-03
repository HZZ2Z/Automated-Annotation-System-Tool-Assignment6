"""Canonical JSON Schema loading and domain-level contract validation."""

from functools import lru_cache
import json
import math
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator
from jsonschema.validators import extend


ROOT = Path(__file__).resolve().parents[2]
SCHEMA_DIR = ROOT / "core/schemas"
TAXONOMY_PATH = ROOT / "core/taxonomy/classes.json"


def _is_exact_integer(_checker: Any, instance: Any) -> bool:
    return type(instance) is int


def _is_finite_json_number(_checker: Any, instance: Any) -> bool:
    if type(instance) is int:
        return True
    return type(instance) is float and math.isfinite(instance)


StrictDraft202012Validator = extend(
    Draft202012Validator,
    type_checker=(
        Draft202012Validator.TYPE_CHECKER
        .redefine("integer", _is_exact_integer)
        .redefine("number", _is_finite_json_number)
    ),
)


@lru_cache(maxsize=None)
def load_schema(name: str) -> dict[str, Any]:
    """Load one canonical schema by filename."""
    return json.loads((SCHEMA_DIR / name).read_text(encoding="utf-8"))


@lru_cache(maxsize=1)
def _load_taxonomy_class_kinds() -> dict[str, str]:
    taxonomy = json.loads(TAXONOMY_PATH.read_text(encoding="utf-8"))
    return {
        item["id"]: item["kind"]
        for item in taxonomy.get("classes", [])
        if isinstance(item, dict)
        and isinstance(item.get("id"), str)
        and isinstance(item.get("kind"), str)
    }


def validate_instance(data: object, schema_name: str) -> list[str]:
    """Return deterministic, field-specific JSON Schema validation errors."""
    validator = StrictDraft202012Validator(load_schema(schema_name))
    errors = sorted(validator.iter_errors(data), key=lambda item: list(item.path))
    return [
        f"{_validation_error_path(error)}: "
        f"{error.message} [{error.validator}]"
        for error in errors
    ]


def _validation_error_path(error: Any) -> str:
    """Point required/additional-property errors at the actual field."""
    parts = [str(part) for part in error.absolute_path]
    if error.validator == "required":
        missing = error.message.split("'", 2)[1:2]
        if missing:
            parts.append(missing[0])
    elif error.validator == "additionalProperties" and isinstance(error.instance, dict):
        properties = error.schema.get("properties", {})
        unexpected = sorted(set(error.instance) - set(properties))
        if unexpected:
            parts.append(unexpected[0])
    return ".".join(parts) or "$"


def validate_annotation_semantics(record: dict[str, Any]) -> list[str]:
    """Validate annotation constraints that depend on multiple fields."""
    image_size = record.get("image_size")
    errors: list[str] = []
    seen_ids: set[str] = set()
    regions = record.get("regions")
    if not isinstance(regions, list):
        return errors

    bounds_are_valid = _valid_image_size(image_size)
    if bounds_are_valid:
        width, height = image_size

    for index, region in enumerate(regions):
        if not isinstance(region, dict):
            continue
        region_id = region.get("id")
        if isinstance(region_id, str):
            if region_id in seen_ids:
                errors.append(f"regions.{index}.id: duplicate region id {region_id!r}")
            seen_ids.add(region_id)

        class_label = region.get("class")
        kind = region.get("kind")
        if isinstance(class_label, str) and isinstance(kind, str):
            expected_kind = _load_taxonomy_class_kinds().get(class_label)
            if expected_kind is not None and kind != expected_kind:
                errors.append(
                    f"regions.{index}.kind: class {class_label!r} requires kind "
                    f"{expected_kind!r}"
                )

        box = region.get("box")
        if bounds_are_valid and _valid_box(box) and not _box_within_bounds(box, width, height):
            errors.append(
                f"regions.{index}.box: box must stay within image bounds "
                f"[0, {width}] x [0, {height}]"
            )

        polygon = region.get("polygon")
        if _valid_polygon(polygon):
            if polygon[0] == polygon[-1]:
                errors.append(
                    f"regions.{index}.polygon: first vertex must not be repeated at the end"
                )
            if len({tuple(vertex) for vertex in polygon}) < 3:
                errors.append(
                    f"regions.{index}.polygon: expected at least three distinct coordinates"
                )
        if bounds_are_valid and isinstance(polygon, list):
            for vertex_index, vertex in enumerate(polygon):
                if _valid_vertex(vertex) and not _vertex_within_bounds(vertex, width, height):
                    errors.append(
                        f"regions.{index}.polygon.{vertex_index}: vertex must stay within "
                        f"image bounds [0, {width}) x [0, {height})"
                    )
    return errors


def validate_manifest_semantics(record: dict[str, Any]) -> list[str]:
    """Validate cross-entry dataset-manifest invariants."""
    errors: list[str] = []
    frames = record.get("frames")
    if not isinstance(frames, list):
        return errors

    frame_count = record.get("frame_count")
    if type(frame_count) is not int:
        errors.append("frame_count: must be an exact integer")
    elif frame_count != len(frames):
        errors.append(
            f"frame_count: expected {len(frames)} entries, got {frame_count}"
        )

    similarity_scores = record.get("similarity_scores")
    if "similarity_scores" in record and isinstance(similarity_scores, list):
        if type(frame_count) is int and len(similarity_scores) != frame_count - 1:
            errors.append(
                "similarity_scores: expected "
                f"{frame_count - 1} entries, got {len(similarity_scores)}"
            )
        for index, score in enumerate(similarity_scores):
            if (
                not _is_finite_number(score)
                or not 0.0 <= score <= 1.0
            ):
                errors.append(
                    f"similarity_scores.{index}: must be a finite number between 0 and 1"
                )

    seen_paths: set[str] = set()
    previous_time: float | int | None = None
    for index, entry in enumerate(frames):
        if not isinstance(entry, dict):
            continue
        frame = entry.get("frame")
        if frame != index:
            errors.append(f"frames.{index}.frame: expected {index}, got {frame!r}")

        image_path = entry.get("image_path")
        if isinstance(image_path, str):
            if image_path in seen_paths:
                errors.append(f"frames.{index}.image_path: duplicate path {image_path!r}")
            seen_paths.add(image_path)

        time_s = entry.get("time_s")
        if _is_finite_number(time_s):
            if previous_time is not None and time_s < previous_time:
                errors.append(
                    f"frames.{index}.time_s: must be non-decreasing "
                    f"(previous {previous_time})"
                )
            previous_time = time_s
    return errors


def _valid_image_size(value: Any) -> bool:
    return (
        isinstance(value, list)
        and len(value) == 2
        and all(type(item) is int and item > 0 for item in value)
    )


def _valid_box(value: Any) -> bool:
    return (
        isinstance(value, list)
        and len(value) == 4
        and all(_is_finite_number(item) for item in value)
    )


def _box_within_bounds(box: list[Any], width: int | float, height: int | float) -> bool:
    x, y, box_width, box_height = box
    return x >= 0 and y >= 0 and x + box_width <= width and y + box_height <= height


def _valid_vertex(value: Any) -> bool:
    return (
        isinstance(value, list)
        and len(value) == 2
        and all(_is_finite_number(item) for item in value)
    )


def _valid_polygon(value: Any) -> bool:
    return (
        isinstance(value, list)
        and len(value) >= 3
        and all(_valid_vertex(vertex) for vertex in value)
    )


def _is_finite_number(value: Any) -> bool:
    return type(value) is int or (type(value) is float and math.isfinite(value))


def _vertex_within_bounds(vertex: list[Any], width: int | float, height: int | float) -> bool:
    x, y = vertex
    return 0 <= x < width and 0 <= y < height
