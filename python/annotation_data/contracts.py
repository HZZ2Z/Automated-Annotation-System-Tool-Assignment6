"""Canonical JSON Schema loading and domain-level contract validation."""

from functools import lru_cache
import json
import math
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator
from jsonschema.validators import extend


ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATHS = {
    "model_output_v1.schema.json": ROOT / "core/schemas/model_output_v1.schema.json",
    "dataset-manifest-v1.schema.json": ROOT
    / "core/frame_source/dataset-manifest-v1.schema.json",
    "media-label-v1.schema.json": ROOT
    / "core/workspace/media-label-v1.schema.json",
}


def _is_integral_json_number(instance: Any) -> bool:
    """Match JSON Schema integer semantics without accepting booleans."""
    if type(instance) is int:
        return True
    return type(instance) is float and math.isfinite(instance) and instance.is_integer()


def _is_json_schema_integer(_checker: Any, instance: Any) -> bool:
    return _is_integral_json_number(instance)


def _is_finite_json_number(_checker: Any, instance: Any) -> bool:
    if type(instance) is int:
        return True
    return type(instance) is float and math.isfinite(instance)


StrictDraft202012Validator = extend(
    Draft202012Validator,
    type_checker=(
        Draft202012Validator.TYPE_CHECKER
        .redefine("integer", _is_json_schema_integer)
        .redefine("number", _is_finite_json_number)
    ),
)


@lru_cache(maxsize=None)
def load_schema(name: str) -> dict[str, Any]:
    """Load a known contract by logical filename."""
    try:
        path = SCHEMA_PATHS[name]
    except KeyError:
        raise ValueError(f"unknown schema: {name}") from None
    return json.loads(path.read_text(encoding="utf-8"))


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


def validate_manifest_semantics(record: dict[str, Any]) -> list[str]:
    """Validate cross-entry dataset-manifest invariants."""
    errors: list[str] = []
    frames = record.get("frames")
    if not isinstance(frames, list):
        return errors

    frame_count = record.get("frame_count")
    if not _is_integral_json_number(frame_count):
        errors.append("frame_count: must be an integer")
    elif int(frame_count) != len(frames):
        errors.append(
            f"frame_count: expected {len(frames)} entries, got {frame_count}"
        )

    similarity_scores = record.get("similarity_scores")
    if "similarity_scores" in record and isinstance(similarity_scores, list):
        if (
            _is_integral_json_number(frame_count)
            and len(similarity_scores) != int(frame_count) - 1
        ):
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


def _is_finite_number(value: Any) -> bool:
    return type(value) is int or (type(value) is float and math.isfinite(value))
