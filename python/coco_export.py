#!/usr/bin/env python3
"""One-shot file-protocol worker for Project6 training_coco_v1 exports."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
from typing import Any, Callable
import uuid


PACKAGE_TYPE = "training_coco_v1"
_DIGEST = re.compile(r"^[0-9a-f]{64}$")
_PUBLIC_FIELDS = {
    "success",
    "errors",
    "issues",
    "warnings",
    "output_path",
    "package_id",
    "package_type",
    "task",
    "saved_revision",
    "package_saved_revision",
    "reused",
    "cancelled",
    "summary",
    "timings_ms",
    "preparation_digest",
}


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Prepare or publish one Project6 COCO training package."
    )
    parser.add_argument("--request", required=True)
    parser.add_argument("--result", required=True)
    parser.add_argument("--progress-file", required=True)
    parser.add_argument("--cancel-file", required=True)
    return parser


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


def _write_json(path: Path, value: dict[str, Any]) -> None:
    raw = (
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
        + "\n"
    ).encode("utf-8")
    temporary = path.parent / f".{path.name}.tmp-{os.getpid()}-{uuid.uuid4().hex}"
    try:
        with temporary.open("xb") as handle:
            handle.write(raw)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass


def _failure(code: str, message: str, *, task: str = "detection") -> dict[str, Any]:
    problem = {"code": code, "message": message}
    return {
        "success": False,
        "errors": [f"{code}: {message}"],
        "issues": [problem],
        "warnings": [],
        "output_path": "",
        "package_id": "",
        "package_type": PACKAGE_TYPE,
        "task": task,
        "saved_revision": -1,
        "package_saved_revision": -1,
        "reused": False,
        "cancelled": False,
        "summary": {},
        "timings_ms": {},
    }


def _control_paths(args: argparse.Namespace) -> tuple[Path, Path, Path, Path]:
    values = tuple(
        Path(value).absolute()
        for value in (args.request, args.result, args.progress_file, args.cancel_file)
    )
    request, result, progress, cancel = values
    parent = request.parent
    if not parent.is_dir() or parent.is_symlink():
        raise ValueError("worker job directory is missing or symbolic")
    if any(path.parent != parent for path in values):
        raise ValueError("all worker control files must share one job directory")
    if request.is_symlink() or not request.is_file():
        raise ValueError("worker request must be a regular non-symbolic file")
    for path in (result, progress, cancel):
        if path.exists() and path.is_symlink():
            raise ValueError(f"worker control path is symbolic: {path.name}")
    return request, result, progress, cancel


def _validate_request(value: Any) -> str | None:
    if not isinstance(value, dict):
        return "request must be an object"
    operation = value.get("operation")
    expected = {"schema_version", "operation", "context"}
    if operation == "export":
        expected |= {"output_parent", "expected_preparation_digest"}
    elif operation in {"parent_descriptor", "source_projection"}:
        expected = {"schema_version", "operation", "package_path"}
    if set(value) != expected:
        return "request fields do not exactly match the selected operation"
    if value.get("schema_version") != 1 or type(value.get("schema_version")) is not int:
        return "request schema_version must be integer 1"
    if operation not in {"prepare", "export", "parent_descriptor", "source_projection"}:
        return "operation must be prepare, export, parent_descriptor or source_projection"
    if operation not in {"parent_descriptor", "source_projection"} and not isinstance(value.get("context"), dict):
        return "context must be an object"
    if operation == "export":
        if not isinstance(value.get("output_parent"), str) or not value["output_parent"]:
            return "output_parent must be a non-empty path string"
        digest = value.get("expected_preparation_digest")
        if not isinstance(digest, str) or _DIGEST.fullmatch(digest) is None:
            return "expected_preparation_digest must be a lowercase SHA-256"
    elif operation in {"parent_descriptor", "source_projection"}:
        package_path = value.get("package_path")
        if (
            not isinstance(package_path, str)
            or not package_path
            or not Path(package_path).is_absolute()
        ):
            return "package_path must be a non-empty absolute path string"
    return None


def _public_result(result: dict[str, Any]) -> dict[str, Any]:
    public = {key: value for key, value in result.items() if key in _PUBLIC_FIELDS}
    manifest = result.get("manifest")
    if result.get("success") and isinstance(manifest, dict):
        public["coverage"] = manifest.get("coverage", {})
        public["dataset"] = manifest.get("dataset", {})
        public["quality"] = manifest.get("quality", {})
    return public


def run(
    request: dict[str, Any],
    *,
    cancelled: Callable[[], bool],
    report_progress: Callable[[dict[str, Any]], None],
) -> dict[str, Any]:
    error = _validate_request(request)
    context = request.get("context", {}) if isinstance(request, dict) else {}
    task = (
        context.get("export_options", {}).get("task", "detection")
        if isinstance(context, dict)
        else "detection"
    )
    if error is not None:
        return _failure("PACKAGE_INVALID", error, task=task)
    if request["operation"] == "parent_descriptor":
        try:
            from annotation_data.coco_package_validator import (
                read_coco_parent_descriptor,
            )
        except ImportError as exc:
            return {
                "success": False,
                "errors": [f"DEPENDENCY_MISSING: Parent validator is unavailable: {exc}"],
                "issues": [{
                    "code": "DEPENDENCY_MISSING",
                    "message": f"Parent validator is unavailable: {exc}",
                }],
                "cancelled": False,
            }
        if cancelled():
            return {
                "success": False,
                "errors": [],
                "issues": [],
                "cancelled": True,
            }
        result = read_coco_parent_descriptor(
            request["package_path"], cancel=cancelled
        )
        result["cancelled"] = False
        return result
    if request["operation"] == "source_projection":
        try:
            from annotation_data.coco_package_validator import (
                read_coco_source_projection,
            )
        except ImportError as exc:
            return {
                "success": False,
                "errors": [f"DEPENDENCY_MISSING: Package source reader is unavailable: {exc}"],
                "issues": [{
                    "code": "DEPENDENCY_MISSING",
                    "message": f"Package source reader is unavailable: {exc}",
                }],
                "cancelled": False,
            }
        if cancelled():
            return {"success": False, "errors": [], "issues": [], "cancelled": True}
        result = read_coco_source_projection(
            request["package_path"],
            cancel=cancelled,
            progress=report_progress,
        )
        result["cancelled"] = False
        return result
    try:
        from annotation_data.coco_export import prepare_coco_export
        from annotation_data.coco_package import export_coco_package
    except ImportError as exc:
        return _failure(
            "DEPENDENCY_MISSING",
            f"COCO export dependency is unavailable: {exc}",
            task=task,
        )

    if request["operation"] == "prepare":
        result = prepare_coco_export(
            context,
            cancel=cancelled,
            progress=report_progress,
        )
    else:
        result = export_coco_package(
            context,
            request["output_parent"],
            expected_preparation_digest=request["expected_preparation_digest"],
            cancel=cancelled,
            progress=report_progress,
        )
    return _public_result(result)


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        request_path, result_path, progress_path, cancel_path = _control_paths(args)
    except (OSError, ValueError) as exc:
        print(f"COCO export worker startup failed: {exc}", file=sys.stderr)
        return 2

    def cancelled() -> bool:
        try:
            return cancel_path.is_file() and not cancel_path.is_symlink()
        except OSError:
            return False

    def report_progress(value: dict[str, Any]) -> None:
        _write_json(progress_path, value)

    request: dict[str, Any] = {}
    try:
        if cancelled():
            result = _failure("CANCELLED", "COCO export cancelled")
            result["errors"] = []
            result["issues"] = []
            result["cancelled"] = True
        else:
            request = _strict_json(request_path)
            result = run(
                request,
                cancelled=cancelled,
                report_progress=report_progress,
            )
    except InterruptedError:
        result = _failure("CANCELLED", "COCO export cancelled")
        result["errors"] = []
        result["issues"] = []
        result["cancelled"] = True
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        result = _failure("PACKAGE_INVALID", f"Cannot read worker request: {exc}")
    except Exception as exc:  # Keep the file protocol total for unexpected worker faults.
        result = _failure(
            "PACKAGE_INVALID",
            f"COCO export worker failed: {exc or exc.__class__.__name__}",
        )
    try:
        _write_json(result_path, result)
        terminal_stage = (
            "published"
            if result.get("success") and request.get("operation") == "export"
            else "ready"
            if result.get("success")
            else "cancelled"
            if result.get("cancelled")
            else "failed"
        )
        report_progress(
            {
                "stage": terminal_stage,
                "completed": 1,
                "total": 1,
                "fraction": 1.0 if result.get("success") else 0.0,
                "message": terminal_stage,
            }
        )
    except OSError as exc:
        print(f"COCO export worker could not write its result: {exc}", file=sys.stderr)
        return 2
    if result.get("cancelled"):
        return 130
    return 0 if result.get("success") else 1


if __name__ == "__main__":
    raise SystemExit(main())
