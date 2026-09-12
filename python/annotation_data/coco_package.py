"""Atomic writer for the self-contained training_coco_v1 package."""

from __future__ import annotations

import ctypes
import errno
import os
from pathlib import Path
import re
import shutil
import time
import uuid
from typing import Any, Callable

from annotation_data.coco_export import (
    PACKAGE_TYPE,
    _result_base,
    canonical_json_bytes,
    issue,
    prepare_coco_export,
    sha256_file,
)
from annotation_data.coco_package_validator import validate_coco_package


_SAFE_COMPONENT = re.compile(r"[^A-Za-z0-9_-]+")
AT_FDCWD = -100
RENAME_NOREPLACE = 1


def _component(value: Any) -> str:
    cleaned = _SAFE_COMPONENT.sub("_", str(value)).strip("_")
    return (cleaned or "unnamed")[:64]


def _remove_owned_tree(path: Path, parent: Path) -> None:
    try:
        if path.parent != parent or ".coco-export-" not in path.name or not path.exists():
            return
        shutil.rmtree(path)
    except OSError:
        pass


def _copy_verified(
    source: Path,
    destination: Path,
    expected_bytes: int,
    expected_sha256: str,
    cancel: Callable[[], bool] | None,
) -> tuple[bool, str, str]:
    import hashlib

    try:
        if source.is_symlink() or not source.is_file():
            return False, "source", "source image is missing or symbolic"
        digest = hashlib.sha256()
        copied = 0
        try:
            reader = source.open("rb")
        except OSError as exc:
            return False, "source", str(exc)
        try:
            writer = destination.open("xb")
        except OSError as exc:
            reader.close()
            return False, "destination", str(exc)
        try:
            while True:
                if cancel is not None and cancel():
                    raise InterruptedError("cancelled")
                try:
                    chunk = reader.read(1024 * 1024)
                except OSError as exc:
                    return False, "source", str(exc)
                if not chunk:
                    break
                try:
                    writer.write(chunk)
                except OSError as exc:
                    return False, "destination", str(exc)
                digest.update(chunk)
                copied += len(chunk)
            try:
                writer.flush()
                os.fsync(writer.fileno())
            except OSError as exc:
                return False, "destination", str(exc)
        finally:
            reader.close()
            writer.close()
        if copied != expected_bytes or digest.hexdigest() != expected_sha256:
            return False, "source", "source image changed after export preparation"
        return True, "", ""
    except InterruptedError:
        raise
    except OSError as exc:
        return False, "destination", str(exc)


def _write_bytes(path: Path, value: bytes) -> None:
    with path.open("xb") as handle:
        handle.write(value)
        handle.flush()
        os.fsync(handle.fileno())


def _rename_noreplace(source: Path, destination: Path) -> None:
    """Use Linux renameat2 when available; never replace an existing path."""

    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = getattr(libc, "renameat2", None)
    if renameat2 is not None:
        renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        renameat2.restype = ctypes.c_int
        status = renameat2(
            AT_FDCWD,
            os.fsencode(source),
            AT_FDCWD,
            os.fsencode(destination),
            RENAME_NOREPLACE,
        )
        if status == 0:
            return
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(destination))
    if destination.exists():
        raise FileExistsError(errno.EEXIST, "destination exists", str(destination))
    os.rename(source, destination)


def _failure(
    prepared: dict[str, Any],
    code: str,
    message: str,
    *,
    path: str | None = None,
    cancelled: bool = False,
    timings: dict[str, int] | None = None,
) -> dict[str, Any]:
    result = _result_base(
        success=False,
        issues=[] if cancelled else [issue(code, message, path=path)],
        warnings=prepared.get("warnings", []),
        task=prepared.get("task", "detection"),
        saved_revision=int(prepared.get("saved_revision", -1)),
        timings_ms=timings or dict(prepared.get("timings_ms", {})),
    )
    result["cancelled"] = cancelled
    result["package_id"] = prepared.get("package_id", "")
    return result


def publish_coco_package(
    prepared: dict[str, Any],
    output_parent: str | Path,
    *,
    expected_preparation_digest: str | None = None,
    cancel: Callable[[], bool] | None = None,
    progress: Callable[[dict[str, Any]], None] | None = None,
) -> dict[str, Any]:
    """Copy, round-trip validate, and atomically publish a prepared export."""

    if not prepared.get("success"):
        return prepared
    if expected_preparation_digest is not None and prepared.get("preparation_digest") != expected_preparation_digest:
        return _failure(prepared, "STALE_CONTEXT", "Prepared export no longer matches the confirmed preview")
    required = {
        "manifest",
        "label_bytes",
        "diff_bytes",
        "image_sources",
        "package_id",
        "dataset_root",
        "source_metadata_paths",
    }
    if not required <= set(prepared):
        return _failure(prepared, "PACKAGE_INVALID", "Prepared export is incomplete")
    parent = Path(output_parent).absolute()
    dataset_root = Path(str(prepared["dataset_root"])).absolute()
    try:
        if parent.exists() and (not parent.is_dir() or parent.is_symlink()):
            return _failure(prepared, "DESTINATION_CONFLICT", "Output parent is not a safe directory", path=str(parent))
        resolved_dataset_root = dataset_root.resolve(strict=True)
        if (
            dataset_root.is_symlink()
            or resolved_dataset_root != dataset_root
            or not resolved_dataset_root.is_dir()
        ):
            return _failure(prepared, "SOURCE_CHANGED", "Prepared dataset root is missing or symbolic", path=str(dataset_root))
        candidate_parent = parent.resolve(strict=False)
        if candidate_parent != parent:
            return _failure(
                prepared,
                "DESTINATION_CONFLICT",
                "Output parent must not traverse symbolic links",
                path=str(parent),
            )
        if (
            candidate_parent == resolved_dataset_root
            or candidate_parent.is_relative_to(resolved_dataset_root)
            or resolved_dataset_root.is_relative_to(candidate_parent)
        ):
            return _failure(
                prepared,
                "DESTINATION_CONFLICT",
                "Output directory must not overlap the source dataset tree",
                path=str(parent),
            )
        for image in prepared["image_sources"]:
            source_path = Path(image["source_path"]).absolute()
            try:
                source = source_path.resolve(strict=True)
            except (OSError, RuntimeError) as exc:
                return _failure(
                    prepared,
                    "SOURCE_CHANGED",
                    f"Prepared source image is no longer available: {exc}",
                    path=str(source_path),
                )
            if (
                source_path.is_symlink()
                or source != source_path
                or not source.is_file()
                or not source.is_relative_to(resolved_dataset_root)
            ):
                return _failure(
                    prepared,
                    "SOURCE_CHANGED",
                    "Prepared source image is missing, symbolic, or outside the dataset",
                    path=str(source),
                )
    except (OSError, RuntimeError) as exc:
        return _failure(prepared, "SOURCE_CHANGED", f"Cannot revalidate prepared source paths: {exc}", path=str(dataset_root))

    try:
        parent.mkdir(parents=True, exist_ok=True)
        resolved_parent = parent.resolve(strict=True)
    except OSError as exc:
        return _failure(prepared, "SAVE_FAILED", f"Cannot create output parent: {exc}", path=str(parent))
    if not os.access(resolved_parent, os.W_OK | os.X_OK):
        return _failure(prepared, "SAVE_FAILED", "Output parent is not writable", path=str(parent))

    manifest = prepared["manifest"]
    required_bytes = (
        sum(int(item["bytes"]) for item in prepared["image_sources"])
        + len(prepared["label_bytes"])
        + len(prepared["diff_bytes"])
        + len(canonical_json_bytes(manifest))
    )
    try:
        available_bytes = shutil.disk_usage(resolved_parent).free
    except OSError as exc:
        return _failure(prepared, "SAVE_FAILED", f"Cannot inspect output capacity: {exc}", path=str(parent))
    if available_bytes < required_bytes:
        return _failure(
            prepared,
            "SAVE_FAILED",
            f"Insufficient output space: need {required_bytes} bytes, have {available_bytes}",
            path=str(parent),
        )

    marker = parent / ".gdignore"
    try:
        if marker.exists() and (marker.is_symlink() or not marker.is_file()):
            return _failure(prepared, "DESTINATION_CONFLICT", "Output .gdignore marker is unsafe", path=str(marker))
        if not marker.exists():
            _write_bytes(marker, b"")
    except FileExistsError:
        # A cooperative exporter may have created the same regular marker after
        # the check. It carries no job-owned state and is safe to share.
        if marker.is_symlink() or not marker.is_file():
            return _failure(prepared, "DESTINATION_CONFLICT", "Output .gdignore marker is unsafe", path=str(marker))
    except OSError as exc:
        return _failure(prepared, "SAVE_FAILED", f"Cannot create output isolation marker: {exc}", path=str(marker))

    destination_name = "%s_%s_%s_%s" % (
        PACKAGE_TYPE,
        _component(manifest["media"]["media_id"]),
        _component(manifest["round_id"]),
        prepared["package_id"][:12],
    )
    destination = parent / destination_name
    lock_path = parent / f".{destination_name}.publish.lock"
    lock_fd = -1
    try:
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.write(lock_fd, f"pid={os.getpid()}\n".encode())
        os.fsync(lock_fd)
    except FileExistsError:
        return _failure(prepared, "DESTINATION_CONFLICT", "Another exporter owns the destination publication lock", path=str(destination))
    except OSError as exc:
        return _failure(prepared, "SAVE_FAILED", f"Cannot reserve destination: {exc}", path=str(destination))

    staging = parent / f".{destination_name}.coco-export-{os.getpid()}-{uuid.uuid4().hex}"
    timings = dict(prepared.get("timings_ms", {}))
    began = time.perf_counter_ns()
    try:
        if destination.exists():
            existing_problems = validate_coco_package(destination)
            if not existing_problems:
                import json

                existing = json.loads((destination / "manifest.json").read_text(encoding="utf-8"))
                if existing.get("package_id") == prepared["package_id"]:
                    result = _result_base(
                        success=True,
                        warnings=prepared.get("warnings", []),
                        task=prepared.get("task", "detection"),
                        saved_revision=int(prepared.get("saved_revision", -1)),
                        timings_ms=timings,
                    )
                    result.update(
                        {
                            "output_path": str(destination),
                            "package_id": prepared["package_id"],
                            "package_saved_revision": int(existing["saved_revision"]),
                            "reused": True,
                            "summary": prepared["summary"],
                            "preparation_digest": prepared["preparation_digest"],
                        }
                    )
                    return result
            return _failure(prepared, "DESTINATION_CONFLICT", "Destination exists but is not the same valid package", path=str(destination), timings=timings)
        if cancel is not None and cancel():
            return _failure(prepared, "CANCELLED", "Export cancelled", cancelled=True, timings=timings)
        staging.mkdir(mode=0o700)
        (staging / "images").mkdir()
        (staging / "labels").mkdir()
        (staging / "reports").mkdir()
        copied_bytes = 0
        total_bytes = sum(int(item["bytes"]) for item in prepared["image_sources"])
        copy_started = time.perf_counter_ns()
        for index, image in enumerate(prepared["image_sources"]):
            source = Path(image["source_path"])
            target = staging / image["artifact_path"]
            ok, failure_domain, message = _copy_verified(
                source,
                target,
                int(image["bytes"]),
                str(image["sha256"]),
                cancel,
            )
            if not ok:
                if failure_domain == "source":
                    return _failure(prepared, "SOURCE_CHANGED", message, path=str(source), timings=timings)
                return _failure(prepared, "SAVE_FAILED", message, path=str(target), timings=timings)
            copied_bytes += int(image["bytes"])
            if progress is not None:
                progress(
                    {
                        "stage": "copy",
                        "completed": index + 1,
                        "total": len(prepared["image_sources"]),
                        "bytes_completed": copied_bytes,
                        "bytes_total": total_bytes,
                        "fraction": 0.5 + 0.3 * (index + 1) / len(prepared["image_sources"]),
                        "message": f"Copied image {index + 1}/{len(prepared['image_sources'])}",
                    }
                )
        timings["image_copy"] = (time.perf_counter_ns() - copy_started) // 1_000_000

        # Metadata must remain the same version used by preparation.
        expected_sources = {item["relative_path"]: item["sha256"] for item in manifest["provenance"]["source_files"]}
        for source_path_value in prepared.get("source_metadata_paths", []):
            source_path = Path(source_path_value).absolute()
            try:
                resolved_source = source_path.resolve(strict=True)
                if (
                    source_path.is_symlink()
                    or resolved_source != source_path
                    or not resolved_source.is_file()
                    or not resolved_source.is_relative_to(resolved_dataset_root)
                ):
                    raise ValueError("metadata path is no longer safe")
                relative = source_path.relative_to(dataset_root).as_posix()
                digest = sha256_file(source_path, cancel)
            except (OSError, ValueError):
                return _failure(
                    prepared,
                    "SOURCE_CHANGED",
                    "Source metadata is missing or no longer belongs to the prepared dataset",
                    path=str(source_path),
                    timings=timings,
                )
            if expected_sources.get(relative) != digest:
                return _failure(prepared, "SOURCE_CHANGED", "Source metadata changed after export preparation", path=str(source_path), timings=timings)
        _write_bytes(staging / "labels/annotation_coco.json", prepared["label_bytes"])
        _write_bytes(staging / "reports/diff.json", prepared["diff_bytes"])
        _write_bytes(staging / "manifest.json", canonical_json_bytes(manifest))
        if cancel is not None and cancel():
            return _failure(prepared, "CANCELLED", "Export cancelled", cancelled=True, timings=timings)
        validate_started = time.perf_counter_ns()
        package_problems = validate_coco_package(staging, cancel=cancel)
        timings["independent_validation"] = (time.perf_counter_ns() - validate_started) // 1_000_000
        if package_problems:
            result = _result_base(
                success=False,
                issues=[issue("PACKAGE_INVALID", item["message"], path=item.get("path")) for item in package_problems],
                warnings=prepared.get("warnings", []),
                task=prepared.get("task", "detection"),
                saved_revision=int(prepared.get("saved_revision", -1)),
                timings_ms=timings,
            )
            result["package_id"] = prepared["package_id"]
            return result
        if progress is not None:
            progress({"stage": "validate", "completed": 1, "total": 1, "fraction": 0.95, "message": "Package independently validated"})
        if cancel is not None and cancel():
            return _failure(prepared, "CANCELLED", "Export cancelled", cancelled=True, timings=timings)
        publish_started = time.perf_counter_ns()
        _rename_noreplace(staging, destination)
        timings["atomic_publish"] = (time.perf_counter_ns() - publish_started) // 1_000_000
        timings["total_publish"] = (time.perf_counter_ns() - began) // 1_000_000
        if progress is not None:
            progress({"stage": "publish", "completed": 1, "total": 1, "fraction": 1.0, "message": "Package published"})
        result = _result_base(
            success=True,
            warnings=prepared.get("warnings", []),
            task=prepared.get("task", "detection"),
            saved_revision=int(prepared.get("saved_revision", -1)),
            timings_ms=timings,
        )
        result.update(
            {
                "output_path": str(destination),
                "package_id": prepared["package_id"],
                "package_saved_revision": int(manifest["saved_revision"]),
                "summary": prepared["summary"],
                "preparation_digest": prepared["preparation_digest"],
            }
        )
        return result
    except InterruptedError:
        return _failure(prepared, "CANCELLED", "Export cancelled", cancelled=True, timings=timings)
    except FileExistsError:
        return _failure(prepared, "DESTINATION_CONFLICT", "Destination appeared during atomic publication", path=str(destination), timings=timings)
    except OSError as exc:
        return _failure(prepared, "SAVE_FAILED", f"Package publication failed: {exc}", path=str(destination), timings=timings)
    finally:
        if staging.exists():
            _remove_owned_tree(staging, parent)
        if lock_fd >= 0:
            try:
                os.close(lock_fd)
            except OSError:
                pass
        try:
            lock_path.unlink(missing_ok=True)
        except OSError:
            pass


def export_coco_package(
    context: dict[str, Any],
    output_parent: str | Path,
    *,
    expected_preparation_digest: str | None = None,
    cancel: Callable[[], bool] | None = None,
    progress: Callable[[dict[str, Any]], None] | None = None,
) -> dict[str, Any]:
    prepared = prepare_coco_export(context, cancel=cancel, progress=progress)
    if not prepared.get("success") or prepared.get("cancelled"):
        return prepared
    return publish_coco_package(
        prepared,
        output_parent,
        expected_preparation_digest=expected_preparation_digest,
        cancel=cancel,
        progress=progress,
    )
