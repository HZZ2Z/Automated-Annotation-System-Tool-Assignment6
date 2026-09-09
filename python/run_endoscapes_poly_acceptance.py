"""Run Poly propagation on a prepared Endoscapes fixture and render local evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import time

import cv2
import numpy as np

from annotation_data.contracts import validate_instance
from annotation_data.polygon_edge_refinement import refine
from annotation_data.polygon_propagation import propagate
from annotation_data.polygon_geometry import polygon_to_mask, validate_polygon
from annotation_data.similarity import similarity_gate


def _digest(value: object) -> str:
    raw = json.dumps(value, ensure_ascii=False, allow_nan=False,
                     sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(raw).hexdigest()


def _write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, allow_nan=False,
                               indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _overlay(image: np.ndarray, mask: np.ndarray, color: tuple[int, int, int]) -> np.ndarray:
    mask = np.asarray(mask) >= (128 if np.asarray(mask).max() > 1 else 1)
    if mask.shape != image.shape[:2]:
        mask = cv2.resize(mask.astype(np.uint8), (image.shape[1], image.shape[0]),
                          interpolation=cv2.INTER_NEAREST) != 0
    output = image.copy()
    tint = np.zeros_like(output)
    tint[:] = color
    output[mask] = cv2.addWeighted(output, 0.55, tint, 0.45, 0)[mask]
    contours, _ = cv2.findContours(mask.astype(np.uint8), cv2.RETR_EXTERNAL,
                                   cv2.CHAIN_APPROX_SIMPLE)
    cv2.drawContours(output, contours, -1, color, 2, cv2.LINE_AA)
    return output


class _RecordingRefiner:
    def __init__(self, output: Path, originals: dict[int, np.ndarray],
                 analysis: dict[str, int], original_ids: dict[int, int]):
        self.output = output
        self.originals = originals
        self.analysis = analysis
        self.original_ids = original_ids
        self.counts: dict[int, int] = {}
        self.overlays: list[dict] = []

    def __call__(self, target: np.ndarray, raw_mask: np.ndarray):
        result = refine(target, raw_mask)
        key = hashlib.sha256(np.ascontiguousarray(target).tobytes()).hexdigest()
        if key not in self.analysis:
            raise TypeError("acceptance recorder could not identify the target frame")
        index = self.analysis[key]
        call = self.counts.get(index, 0)
        self.counts[index] = call + 1
        role = "adjacent" if call % 2 == 0 else "anchor"
        if role == "adjacent":
            original_id = self.original_ids[index]
            base = f"frame-{index:02d}-original-{original_id}"
            raw_path = self.output / "overlays" / f"{base}-raw.png"
            final_path = self.output / "overlays" / f"{base}-final.png"
            if not cv2.imwrite(str(raw_path), _overlay(self.originals[index], raw_mask, (0, 0, 255))):
                raise OSError("could not write raw acceptance overlay")
            if not cv2.imwrite(str(final_path), _overlay(self.originals[index], result.mask, (0, 255, 0))):
                raise OSError("could not write final acceptance overlay")
            self.overlays.append({
                "playback_index": index,
                "original_frame_id": original_id,
                "accepted": result.accepted,
                "reason": result.reason,
                "raw": raw_path.relative_to(self.output).as_posix(),
                "final": final_path.relative_to(self.output).as_posix(),
            })
        return result


def run_acceptance(fixture: Path, output: Path, threshold: float = 0.02) -> dict:
    fixture, output = fixture.resolve(), output.resolve()
    if output.exists() or output.is_symlink():
        raise ValueError("acceptance output already exists")
    if not fixture.is_dir():
        raise ValueError("fixture directory does not exist")
    if not 0 < threshold <= 1 or not np.isfinite(threshold):
        raise ValueError("threshold must be finite and in (0, 1]")
    manifest = json.loads((fixture / "manifest.json").read_text(encoding="utf-8"))
    provenance = json.loads((fixture / "provenance.json").read_text(encoding="utf-8"))
    records = [json.loads(line) for line in
               (fixture / "model_output_v1.jsonl").read_text(encoding="utf-8").splitlines()
               if line]
    errors = validate_instance(manifest, "dataset-manifest-v1.schema.json")
    if errors or len(records) != manifest.get("frame_count"):
        raise ValueError("fixture manifest/record count is invalid")
    for index, record in enumerate(records):
        errors = validate_instance(record, "model_output_v1.schema.json")
        if errors or record.get("frame") != index:
            raise ValueError(f"fixture model record {index} is invalid")
    key = int(provenance["keyframe_seed"]["playback_index"])
    regions = records[key]["regions"]
    if not regions:
        raise ValueError("fixture keyframe has no polygon seed")

    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{output.name}.staging-", dir=output.parent))
    try:
        (staging / "snapshots").mkdir()
        (staging / "overlays").mkdir()
        original_ids = {int(item["playback_index"]): int(item["original_frame_id"])
                        for item in provenance["frames"]}
        originals: dict[int, np.ndarray] = {}
        gray: dict[int, np.ndarray] = {}
        request_frames = []
        for index, entry in enumerate(manifest["frames"]):
            source = fixture / entry["image_path"]
            image = cv2.imread(str(source), cv2.IMREAD_COLOR)
            if image is None:
                raise ValueError(f"fixture frame {index} could not be decoded")
            snapshot = staging / "snapshots" / f"frame_{index:06d}.png"
            if not cv2.imwrite(str(snapshot), image):
                raise OSError(f"could not write frame {index} snapshot")
            data = snapshot.read_bytes()
            originals[index] = image
            snapshot_gray = cv2.imread(str(snapshot), cv2.IMREAD_GRAYSCALE)
            if snapshot_gray is None:
                raise OSError(f"could not verify frame {index} snapshot")
            gray[index] = snapshot_gray
            request_frames.append({
                "index": index,
                "frame_id": index,
                "image_path": str(snapshot),
                "image_sha256": hashlib.sha256(data).hexdigest(),
                "entry_digest": _digest(entry),
                "record_digest": _digest(records[index]),
                "verified": False,
            })
        analysis_lookup = {
            hashlib.sha256(np.ascontiguousarray(image).tobytes()).hexdigest(): index
            for index, image in gray.items()
        }
        if len(analysis_lookup) != len(gray):
            raise ValueError("fixture contains duplicate grayscale frames; evidence mapping is ambiguous")
        recorder = _RecordingRefiner(staging, originals, analysis_lookup, original_ids)
        request = {
            "schema_version": 2,
            "key_index": key,
            "similarity_threshold": float(threshold),
            "frames": request_frames,
            "regions": regions,
        }
        similarities = []
        for index in range(len(gray)):
            if index == key:
                continue
            previous = index - 1 if index > key else index + 1
            scores = similarity_gate(gray[previous], gray[index], gray[key], threshold)
            similarities.append({
                "playback_index": index,
                "original_frame_id": original_ids[index],
                "toward_keyframe_index": previous,
                **scores,
            })
        started = time.perf_counter()
        result = propagate(request, edge_refiner=recorder)
        elapsed = time.perf_counter() - started
        if not result.get("success"):
            raise ValueError("propagation failed: " + str(result.get("error", "unknown error")))

        seed_mask = polygon_to_mask(
            validate_polygon(regions[0]["polygon"], (manifest["width"], manifest["height"])),
            (manifest["width"], manifest["height"]),
            (manifest["height"], manifest["width"]),
        )
        seed_path = staging / "overlays" / f"frame-{key:02d}-original-{original_ids[key]}-seed.png"
        if not cv2.imwrite(str(seed_path), _overlay(originals[key], seed_mask, (255, 255, 0))):
            raise OSError("could not write keyframe seed overlay")
        edge_summary = []
        for proposal in result["proposals"]:
            for region_id, quality in proposal["quality"].items():
                edge = quality["edge"]
                edge_summary.append({
                    "playback_index": proposal["index"],
                    "original_frame_id": original_ids[proposal["index"]],
                    "region_id": region_id,
                    "adjacent_mad": quality["adjacent_mad"],
                    "keyframe_mad": quality["keyframe_mad"],
                    "accepted": edge["accepted"],
                    "reason": edge["reason"],
                    "raw_edge_score": edge["raw_edge_score"],
                    "refined_edge_score": edge["refined_edge_score"],
                    "raw_iou": edge["raw_iou"],
                    "area_ratio": edge["area_ratio"],
                    "hausdorff": edge["hausdorff"],
                    "final_score": quality["score"],
                })
        report = {
            "schema_version": 1,
            "evidence_type": "endoscapes-poly-qualitative-acceptance",
            "fixture_id": manifest["dataset_id"],
            "metric_id": result["metric_id"],
            "threshold": result["threshold"],
            "elapsed_seconds": elapsed,
            "key_playback_index": key,
            "key_original_frame_id": original_ids[key],
            "candidate_range": [result["start_index"], result["end_index"]],
            "proposal_indices": [proposal["index"] for proposal in result["proposals"]],
            "left_stop": result["left_stop"],
            "right_stop": result["right_stop"],
            "similarities": similarities,
            "edge_results": edge_summary,
            "overlays": recorder.overlays,
            "seed_overlay": seed_path.relative_to(staging).as_posix(),
            "evidence_limit": provenance["evidence_limit"],
            "manual_ui_checklist": [
                "Open the copied fixture in Main and select the keyframe.",
                "Preview every proposed target and apply once.",
                "Undo once, redo once, save/reopen, confirm, then verify auto-next.",
            ],
            "manual_ui_status": "pending",
        }
        _write_json(staging / "report.json", report)
        accepted = sum(1 for item in edge_summary if item["accepted"])
        fallback = len(edge_summary) - accepted
        markdown = f"""# Endoscapes Poly acceptance (local evidence)\n\n\
- Fixture: `{manifest['dataset_id']}`; keyframe {key} (original {original_ids[key]})\n\
- Algorithm: `{result['metric_id']}`; similarity threshold `{threshold:.6f}`\n\
- Candidate range: `{result['start_index']}..{result['end_index']}`; proposals `{report['proposal_indices']}`\n\
- Stop reasons: left `{result['left_stop']}`; right `{result['right_stop']}`\n\
- Edge decisions: {accepted} accepted, {fallback} raw-flow fallback\n\
- Elapsed: {elapsed:.6f} seconds\n\
- Manual UI status: pending\n\n\
The keyframe mask is the only ground-truth seed. Target overlays are qualitative reviewer evidence, not dense target-frame IoU evidence.\n"""
        (staging / "report.md").write_text(markdown, encoding="utf-8")
        staging.replace(output)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return report


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--threshold", type=float, default=0.02)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        report = run_acceptance(args.fixture, args.output, args.threshold)
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        print(f"Endoscapes Poly acceptance failed: {error}")
        return 1
    print(json.dumps({key: report[key] for key in (
        "metric_id", "candidate_range", "proposal_indices", "left_stop", "right_stop",
        "elapsed_seconds", "manual_ui_status")}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
