"""Run read-only real-data acceptance for the Endoscapes lazy Source."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "tests/manual/run_endoscapes_lazy_source_acceptance.gd"
MEDIA_ID_PATTERN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9_]{0,62}[A-Za-z0-9])?$")
STAT_FIELDS = (
    "imported_regions",
    "polygon_regions",
    "box_fallbacks",
    "skipped_regions",
)


def fingerprint_tree(root: Path) -> str:
    """Hash names and lstat metadata without reading payloads or following links."""

    root = root.resolve()
    if not root.is_dir():
        raise ValueError("dataset root is not a directory")
    digest = hashlib.sha256()
    pending: list[tuple[Path, str]] = [(root, ".")]
    while pending:
        directory, relative_directory = pending.pop()
        with os.scandir(directory) as entries:
            ordered = sorted(entries, key=lambda item: os.fsencode(item.name))
        children: list[tuple[Path, str]] = []
        for entry in ordered:
            relative = (
                entry.name
                if relative_directory == "."
                else f"{relative_directory}/{entry.name}"
            )
            metadata = entry.stat(follow_symlinks=False)
            mode = metadata.st_mode
            if stat.S_ISLNK(mode):
                kind = "link"
                target = os.readlink(entry.path)
            elif stat.S_ISDIR(mode):
                kind = "directory"
                target = ""
                children.append((Path(entry.path), relative))
            elif stat.S_ISREG(mode):
                kind = "file"
                target = ""
            else:
                kind = "other"
                target = ""
            row = (
                relative,
                kind,
                stat.S_IMODE(mode),
                metadata.st_size,
                metadata.st_mtime_ns,
                target,
            )
            digest.update(
                json.dumps(row, ensure_ascii=False, separators=(",", ":")).encode(
                    "utf-8"
                )
            )
            digest.update(b"\n")
        pending.extend(reversed(children))
    return digest.hexdigest()


def validate_report(report: object, dataset_root: Path) -> list[str]:
    errors: list[str] = []
    if not isinstance(report, dict):
        return ["report must be a JSON object"]
    try:
        serialized = json.dumps(
            report,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    except (TypeError, ValueError) as error:
        return [f"report is not finite JSON: {error}"]
    absolute_root = str(dataset_root.resolve())
    if absolute_root and absolute_root in serialized:
        errors.append("report must not contain the absolute dataset path")

    required = {
        "schema_version",
        "evidence_type",
        "logical_video_count",
        "media_id_collisions",
        "media_ids_sha256",
        "workspace_retained_frame_paths",
        "catalog_scan_elapsed_seconds",
        "catalog_scan_heartbeats",
        "selected_media_id",
        "selected_video_frame_count",
        "selected_source_retained_frame_paths",
        "selected_first_frame_id",
        "selected_last_frame_id",
        "selected_import_statistics",
        "secondary_media_id",
        "secondary_video_frame_count",
        "secondary_import_statistics",
        "texture_cache_limit",
        "texture_load_attempt_count",
        "texture_load_success_count",
        "texture_cache_peak",
        "old_source_retained_frame_paths_after_switch",
        "old_source_cache_size_after_switch",
        "source_fingerprint_before",
        "source_fingerprint_after",
        "source_dataset_modified",
    }
    for field in sorted(required - report.keys()):
        errors.append(f"missing report field: {field}")
    if errors:
        return errors

    if report["schema_version"] != 1:
        errors.append("schema_version must be 1")
    if report["evidence_type"] != "endoscapes-lazy-source-acceptance":
        errors.append("evidence_type is invalid")
    _expect_exact_int(report, "logical_video_count", errors, minimum=201, maximum=201)
    _expect_exact_int(report, "media_id_collisions", errors, minimum=0, maximum=0)
    _expect_exact_int(
        report, "workspace_retained_frame_paths", errors, minimum=0, maximum=0
    )
    _expect_non_negative_number(report, "catalog_scan_elapsed_seconds", errors)
    _expect_exact_int(report, "catalog_scan_heartbeats", errors, minimum=1)
    for field in ("selected_media_id", "secondary_media_id"):
        value = report[field]
        if not isinstance(value, str) or MEDIA_ID_PATTERN.fullmatch(value) is None:
            errors.append(f"{field} must be a portable media ID")
    if report["selected_media_id"] == report["secondary_media_id"]:
        errors.append("selected and secondary media IDs must differ")

    _expect_exact_int(report, "selected_video_frame_count", errors, minimum=13)
    _expect_exact_int(report, "secondary_video_frame_count", errors, minimum=1)
    _expect_exact_int(report, "selected_source_retained_frame_paths", errors, minimum=1)
    if (
        report["selected_source_retained_frame_paths"]
        != report["selected_video_frame_count"]
    ):
        errors.append("selected Source must retain exactly its selected video frame paths")
    _expect_exact_int(report, "selected_first_frame_id", errors, minimum=0)
    _expect_exact_int(report, "selected_last_frame_id", errors, minimum=0)
    if (
        type(report["selected_first_frame_id"]) is int
        and type(report["selected_last_frame_id"]) is int
        and report["selected_first_frame_id"] > report["selected_last_frame_id"]
    ):
        errors.append("selected frame IDs must be ordered")

    for group in ("selected_import_statistics", "secondary_import_statistics"):
        _validate_statistics(report[group], group, errors)
    selected_statistics = report["selected_import_statistics"]
    if isinstance(selected_statistics, dict):
        if selected_statistics.get("imported_regions", 0) <= 0:
            errors.append("selected video must import at least one region")
        if (
            selected_statistics.get("polygon_regions", 0)
            + selected_statistics.get("box_fallbacks", 0)
            <= 0
        ):
            errors.append("selected video must exercise RLE conversion or safe fallback")
    secondary_statistics = report["secondary_import_statistics"]
    if isinstance(secondary_statistics, dict):
        if secondary_statistics.get("imported_regions", 0) <= 0:
            errors.append("secondary video must import at least one box region")
        if secondary_statistics.get("polygon_regions") != 0:
            errors.append("secondary video must exercise the box-only baseline")

    _expect_exact_int(report, "texture_cache_limit", errors, minimum=12, maximum=12)
    _expect_exact_int(report, "texture_load_attempt_count", errors, minimum=13)
    _expect_exact_int(report, "texture_load_success_count", errors, minimum=13)
    if report["texture_load_success_count"] != report["texture_load_attempt_count"]:
        errors.append("every acceptance texture load must succeed")
    _expect_exact_int(report, "texture_cache_peak", errors, minimum=1, maximum=12)
    _expect_exact_int(
        report,
        "old_source_retained_frame_paths_after_switch",
        errors,
        minimum=0,
        maximum=0,
    )
    _expect_exact_int(
        report, "old_source_cache_size_after_switch", errors, minimum=0, maximum=0
    )

    for field in ("media_ids_sha256", "source_fingerprint_before", "source_fingerprint_after"):
        value = report[field]
        if (
            not isinstance(value, str)
            or len(value) != 64
            or any(character not in "0123456789abcdef" for character in value)
        ):
            errors.append(f"{field} must be a lowercase SHA-256")
    if report["source_fingerprint_before"] != report["source_fingerprint_after"]:
        errors.append("source fingerprints differ")
    if report["source_dataset_modified"] is not False:
        errors.append("source_dataset_modified must be false")
    return errors


def _expect_exact_int(
    report: dict,
    field: str,
    errors: list[str],
    *,
    minimum: int | None = None,
    maximum: int | None = None,
) -> None:
    value = report[field]
    if type(value) is not int:
        errors.append(f"{field} must be an integer")
        return
    if minimum is not None and value < minimum:
        errors.append(f"{field} must be at least {minimum}")
    if maximum is not None and value > maximum:
        errors.append(f"{field} must be at most {maximum}")


def _expect_non_negative_number(report: dict, field: str, errors: list[str]) -> None:
    value = report[field]
    if (
        type(value) not in (int, float)
        or not math.isfinite(float(value))
        or value < 0
    ):
        errors.append(f"{field} must be finite and non-negative")


def _validate_statistics(value: object, name: str, errors: list[str]) -> None:
    if not isinstance(value, dict):
        errors.append(f"{name} must be an object")
        return
    for field in STAT_FIELDS:
        if field not in value:
            errors.append(f"{name} is missing {field}")
        elif type(value[field]) is not int or value[field] < 0:
            errors.append(f"{name}.{field} must be a non-negative integer")
    if all(field in value and type(value[field]) is int for field in STAT_FIELDS):
        if value["polygon_regions"] > value["imported_regions"]:
            errors.append(f"{name}.polygon_regions exceeds imported_regions")
        if value["box_fallbacks"] > value["imported_regions"]:
            errors.append(f"{name}.box_fallbacks exceeds imported_regions")


def run_acceptance(dataset_root: Path, output: Path) -> dict:
    dataset_root = dataset_root.resolve()
    output = output.resolve()
    if not dataset_root.is_dir():
        raise ValueError("dataset root does not exist")
    if output.exists() or output.is_symlink():
        raise ValueError("acceptance output already exists; existing content was preserved")
    if output == dataset_root or dataset_root in output.parents:
        raise ValueError("acceptance output must remain outside the source dataset")
    godot = os.environ.get("GODOT_BIN") or shutil.which("godot4") or shutil.which("godot")
    if not godot:
        raise ValueError("Godot is unavailable; source project_env.sh or set GODOT_BIN")

    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(
        tempfile.mkdtemp(prefix=f".{output.name}.staging-", dir=output.parent)
    )
    try:
        fingerprint_before = fingerprint_tree(dataset_root)
        result_path = staging / "godot-result.json"
        log_path = staging / "godot.log"
        environment = os.environ.copy()
        environment["XDG_DATA_HOME"] = str(staging / "xdg-data")
        environment["XDG_CONFIG_HOME"] = str(staging / "xdg-config")
        process = subprocess.run(
            [
                godot,
                "--headless",
                "--path",
                str(ROOT),
                "--log-file",
                str(log_path),
                "--script",
                str(RUNNER),
                "--",
                "--dataset-root",
                str(dataset_root),
                "--output",
                str(result_path),
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=600,
            env=environment,
        )
        (staging / "godot-process.log").write_text(
            process.stdout + process.stderr, encoding="utf-8"
        )
        fingerprint_after = fingerprint_tree(dataset_root)
        if not result_path.is_file():
            raise ValueError(
                f"Godot acceptance produced no result (exit {process.returncode})"
            )
        payload = json.loads(result_path.read_text(encoding="utf-8"))
        if process.returncode != 0 or payload.get("success") is not True:
            detail = "; ".join(payload.get("errors", []))
            raise ValueError(
                f"Godot acceptance failed (exit {process.returncode}): {detail}"
            )
        report = dict(payload)
        report.pop("success", None)
        report.pop("errors", None)
        report["source_fingerprint_before"] = fingerprint_before
        report["source_fingerprint_after"] = fingerprint_after
        report["source_dataset_modified"] = fingerprint_before != fingerprint_after
        errors = validate_report(report, dataset_root)
        if errors:
            raise ValueError("invalid acceptance report: " + "; ".join(errors))
        result_path.unlink()
        (staging / "report.json").write_text(
            json.dumps(
                report,
                ensure_ascii=False,
                allow_nan=False,
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        selected = report["selected_import_statistics"]
        secondary = report["secondary_import_statistics"]
        (staging / "report.md").write_text(
            "# Endoscapes lazy Source acceptance\n\n"
            f"- Logical videos: {report['logical_video_count']}\n"
            f"- Discovery elapsed: {report['catalog_scan_elapsed_seconds']:.6f} seconds\n"
            f"- Selected video frames: {report['selected_video_frame_count']}\n"
            f"- Selected labels: {selected['imported_regions']} regions, "
            f"{selected['polygon_regions']} polygons, "
            f"{selected['box_fallbacks']} box fallbacks, "
            f"{selected['skipped_regions']} skipped\n"
            f"- Box-only labels: {secondary['imported_regions']} regions\n"
            f"- Texture cache peak: {report['texture_cache_peak']} / "
            f"{report['texture_cache_limit']}\n"
            "- Source dataset modified: no\n",
            encoding="utf-8",
        )
        staging.replace(output)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return report


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        report = run_acceptance(args.dataset_root, args.output)
    except (
        OSError,
        ValueError,
        TypeError,
        KeyError,
        json.JSONDecodeError,
        subprocess.TimeoutExpired,
    ) as error:
        print(f"Endoscapes lazy Source acceptance failed: {error}")
        return 1
    print(
        json.dumps(
            {
                key: report[key]
                for key in (
                    "logical_video_count",
                    "catalog_scan_elapsed_seconds",
                    "selected_video_frame_count",
                    "texture_cache_peak",
                    "source_dataset_modified",
                )
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
