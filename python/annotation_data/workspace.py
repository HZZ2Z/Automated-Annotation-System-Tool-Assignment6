"""Workspace media identity and single-file label validation."""

from pathlib import Path
import re
from typing import Any

from annotation_data.contracts import validate_instance


_PORTABLE_SEPARATOR = re.compile(r"[^A-Za-z0-9]+")
_PORTABLE_ID = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9_]{0,62}[A-Za-z0-9])?$")
_FRAME_KEY = re.compile(r"^(0|[1-9][0-9]{0,5})$")


def portable_media_id(stem: str) -> str:
    """Return a stable portable ID from a source file or directory stem."""
    if not isinstance(stem, str):
        raise TypeError("media stem must be text")
    # Apply the same ASCII-only rule as the Godot client. Do not transliterate.
    value = _PORTABLE_SEPARATOR.sub("_", stem).strip("_")[:64].rstrip("_")
    return value or "media"


def sample_id(media_id: str, frame_id: int) -> str:
    """Build the training identity for one original media frame."""
    _require_portable_id(media_id)
    if type(frame_id) is not int or not 0 <= frame_id <= 999_999:
        raise ValueError("frame_id must be an integer from 0 through 999999")
    return f"{media_id}_{frame_id:06d}"


def label_path(workspace_root: Path, media_id: str) -> Path:
    """Return the sole native label path for a workspace media item."""
    _require_portable_id(media_id)
    return Path(workspace_root) / "label" / f"{media_id}.json"


def validate_media_label_semantics(value: object) -> list[str]:
    """Validate Model Output V1 records against their media and frame keys."""
    if not isinstance(value, dict):
        return ["$: expected object"]
    errors: list[str] = []
    media_id_value = value.get("media_id")
    frames = value.get("frames")
    if not isinstance(frames, dict):
        return errors

    for frame_key, record in sorted(frames.items(), key=lambda item: str(item[0])):
        prefix = f"frames.{frame_key}"
        if not isinstance(frame_key, str) or _FRAME_KEY.fullmatch(frame_key) is None:
            errors.append(f"{prefix}: expected an unpadded decimal frame key")
            continue
        frame_id = int(frame_key)
        for error in validate_instance(record, "model_output_v1.schema.json"):
            suffix = error[2:] if error.startswith("$:") else f".{error}"
            errors.append(f"{prefix}{suffix}")
        if not isinstance(record, dict):
            continue
        if record.get("frame") != frame_id:
            errors.append(
                f"{prefix}.frame: expected frame {frame_id}, got {record.get('frame')!r}"
            )
        if isinstance(media_id_value, str) and record.get("source") != media_id_value:
            errors.append(
                f"{prefix}.source: expected {media_id_value!r}, "
                f"got {record.get('source')!r}"
            )
    return errors


def _require_portable_id(value: str) -> None:
    if not isinstance(value, str) or _PORTABLE_ID.fullmatch(value) is None:
        raise ValueError("media_id must be a portable workspace identifier")
