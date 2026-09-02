"""Canonical JSON Schema loading and domain-level contract validation."""

from functools import lru_cache
import json
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator


ROOT = Path(__file__).resolve().parents[2]
SCHEMA_DIR = ROOT / "core/schemas"


@lru_cache(maxsize=None)
def load_schema(name: str) -> dict[str, Any]:
    """Load one canonical schema by filename."""
    return json.loads((SCHEMA_DIR / name).read_text(encoding="utf-8"))


def validate_instance(data: dict[str, Any], schema_name: str) -> list[str]:
    """Return deterministic, field-specific JSON Schema validation errors."""
    validator = Draft202012Validator(load_schema(schema_name))
    errors = sorted(validator.iter_errors(data), key=lambda item: list(item.path))
    return [
        f"{'.'.join(str(part) for part in error.absolute_path) or '$'}: "
        f"{error.message} [{error.validator}]"
        for error in errors
    ]


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

        box = region.get("box")
        if bounds_are_valid and _valid_box(box) and not _box_within_bounds(box, width, height):
            errors.append(
                f"regions.{index}.box: box must stay within image bounds "
                f"[0, {width}] x [0, {height}]"
            )

        polygon = region.get("polygon")
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
    if frame_count != len(frames):
        errors.append(
            f"frame_count: expected {len(frames)} entries, got {frame_count}"
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
        if isinstance(time_s, (int, float)) and not isinstance(time_s, bool):
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
        and all(isinstance(item, (int, float)) and not isinstance(item, bool) for item in value)
    )


def _valid_box(value: Any) -> bool:
    return (
        isinstance(value, list)
        and len(value) == 4
        and all(isinstance(item, (int, float)) and not isinstance(item, bool) for item in value)
    )


def _box_within_bounds(box: list[Any], width: int | float, height: int | float) -> bool:
    x, y, box_width, box_height = box
    return x >= 0 and y >= 0 and x + box_width <= width and y + box_height <= height


def _valid_vertex(value: Any) -> bool:
    return (
        isinstance(value, list)
        and len(value) == 2
        and all(isinstance(item, (int, float)) and not isinstance(item, bool) for item in value)
    )


def _vertex_within_bounds(vertex: list[Any], width: int | float, height: int | float) -> bool:
    x, y = vertex
    return 0 <= x < width and 0 <= y < height
