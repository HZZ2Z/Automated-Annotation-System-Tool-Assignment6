from __future__ import annotations

import json
from pathlib import Path

import pytest

from run_endoscapes_lazy_source_acceptance import (
    fingerprint_tree,
    validate_report,
)


def _report() -> dict:
    return {
        "schema_version": 1,
        "evidence_type": "endoscapes-lazy-source-acceptance",
        "logical_video_count": 201,
        "media_id_collisions": 0,
        "media_ids_sha256": "a" * 64,
        "workspace_retained_frame_paths": 0,
        "catalog_scan_elapsed_seconds": 1.25,
        "catalog_scan_heartbeats": 4,
        "selected_media_id": "endoscapes_train_video_004",
        "selected_video_frame_count": 633,
        "selected_source_retained_frame_paths": 633,
        "selected_first_frame_id": 21725,
        "selected_last_frame_id": 37525,
        "selected_import_statistics": {
            "imported_regions": 98,
            "polygon_regions": 75,
            "box_fallbacks": 3,
            "skipped_regions": 0,
        },
        "secondary_media_id": "endoscapes_train_video_001",
        "secondary_video_frame_count": 153,
        "secondary_import_statistics": {
            "imported_regions": 28,
            "polygon_regions": 0,
            "box_fallbacks": 0,
            "skipped_regions": 0,
        },
        "texture_cache_limit": 12,
        "texture_load_attempt_count": 15,
        "texture_load_success_count": 15,
        "texture_cache_peak": 12,
        "old_source_retained_frame_paths_after_switch": 0,
        "old_source_cache_size_after_switch": 0,
        "source_fingerprint_before": "b" * 64,
        "source_fingerprint_after": "b" * 64,
        "source_dataset_modified": False,
    }


def test_valid_report_requires_real_lazy_loading_invariants(tmp_path: Path) -> None:
    assert validate_report(_report(), tmp_path / "endoscapes") == []


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("logical_video_count", 200),
        ("media_id_collisions", 1),
        ("workspace_retained_frame_paths", 1),
        ("selected_source_retained_frame_paths", 632),
        ("texture_cache_peak", 13),
        ("texture_load_attempt_count", 12),
        ("old_source_retained_frame_paths_after_switch", 1),
        ("old_source_cache_size_after_switch", 1),
        ("source_dataset_modified", True),
    ],
)
def test_report_rejects_broken_acceptance_invariants(
    tmp_path: Path,
    field: str,
    value: object,
) -> None:
    report = _report()
    report[field] = value
    assert validate_report(report, tmp_path / "endoscapes")


def test_report_requires_all_label_conversion_counters(tmp_path: Path) -> None:
    for group in ("selected_import_statistics", "secondary_import_statistics"):
        for counter in (
            "imported_regions",
            "polygon_regions",
            "box_fallbacks",
            "skipped_regions",
        ):
            report = _report()
            del report[group][counter]
            assert validate_report(report, tmp_path / "endoscapes")


def test_selected_video_must_exercise_rle_conversion_or_fallback(
    tmp_path: Path,
) -> None:
    report = _report()
    report["selected_import_statistics"]["polygon_regions"] = 0
    report["selected_import_statistics"]["box_fallbacks"] = 0
    assert validate_report(report, tmp_path / "endoscapes")


def test_report_never_discloses_the_absolute_dataset_path(tmp_path: Path) -> None:
    dataset = (tmp_path / "private" / "endoscapes").resolve()
    report = _report()
    report["dataset_root"] = str(dataset)
    assert validate_report(report, dataset)
    report = _report()
    report["note"] = f"opened {dataset}/train"
    assert validate_report(report, dataset)


def test_tree_fingerprint_tracks_metadata_without_following_symlinks(
    tmp_path: Path,
) -> None:
    root = tmp_path / "dataset"
    root.mkdir()
    frame = root / "frame.jpg"
    frame.write_bytes(b"frame")
    (root / "alias").symlink_to("frame.jpg")
    first = fingerprint_tree(root)
    assert len(first) == 64
    assert first == fingerprint_tree(root)
    frame.write_bytes(b"changed")
    assert fingerprint_tree(root) != first
    assert json.dumps(_report(), allow_nan=False)
