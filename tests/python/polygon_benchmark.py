"""Reproduce independent synthetic mask-IoU comparisons, without editing input data."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import platform
import resource
import sys
import tempfile
import time

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "python"))

from annotation_data.polygon_edge_refinement import EdgeRefinement
from annotation_data.polygon_propagation import propagate
from polygon_fixtures import boundary_offset_scene, deformed_scene, iou, polygon_mask, translated_scene


def _raw_only(_image, mask):
    return EdgeRefinement(
        False, mask.copy(), "benchmark raw-flow baseline",
        {"raw_edge_score": 0.0, "refined_edge_score": 0.0, "raw_iou": 1.0,
         "area_ratio": 1.0, "hausdorff": 0.0},
    )


def measure(directory, case):
    if case in {"translation", "reverse_translation"}:
        sign = 1 if case == "translation" else -1
        request, truths = translated_scene(directory, [(sign * 5 * t, sign * 3 * t) for t in range(-3, 4)], key=3)
    elif case in {"rotation", "deformation"}:
        request, truths = deformed_scene(directory, case)
    else:
        request, truths = boundary_offset_scene(directory)
    begin = time.perf_counter()
    raw_result = propagate(request, edge_refiner=_raw_only)
    result = propagate(request)
    runtime = time.perf_counter() - begin
    raw_by_index = {proposal["index"]: proposal for proposal in raw_result.get("proposals", [])}
    rows = []
    for proposal in result.get("proposals", []):
        truth = truths[proposal["index"]]
        final_candidate = polygon_mask(proposal["regions"][0]["polygon"], truth.shape)
        raw_proposal = raw_by_index[proposal["index"]]
        raw_candidate = polygon_mask(raw_proposal["regions"][0]["polygon"], truth.shape)
        edge = proposal["quality"]["poly-1"]["edge"]
        rows.append({"index": proposal["index"], "raw_iou": iou(raw_candidate, truth),
                     "final_iou": iou(final_candidate, truth),
                     "copy_iou": iou(truths[request["key_index"]], truth),
                     "edge_accepted": edge["accepted"], "edge_reason": edge["reason"],
                     "quality_score": proposal["quality"]["poly-1"]["score"]})
    assert raw_result["success"] and result["success"], (raw_result, result)
    assert len(rows) == len(request["frames"]) - 1, result
    raw = [row["raw_iou"] for row in rows]
    final = [row["final_iou"] for row in rows]
    copied = [row["copy_iou"] for row in rows]
    if case == "boundary_offset":
        assert np.mean(final) > np.mean(raw) and any(row["edge_accepted"] for row in rows)
    else:
        assert min(final) > 0.90 and np.mean(final) > np.mean(copied) + 0.06
    return {"case": case, "resolution": list(truths[0].shape[::-1]), "frames": len(request["frames"]),
            "key_index": request["key_index"], "accepted_proposals": len(rows), "runtime_seconds": runtime,
            "raw_mean_iou": float(np.mean(raw)), "raw_min_iou": min(raw),
            "final_mean_iou": float(np.mean(final)), "final_min_iou": min(final),
            "copy_mean_iou": float(np.mean(copied)), "copy_min_iou": min(copied),
            "edge_accepted": sum(row["edge_accepted"] for row in rows),
            "edge_fallback": sum(not row["edge_accepted"] for row in rows),
            "mean_edge_iou_gain": float(np.mean(final) - np.mean(raw)),
            "mean_copy_iou_gain": float(np.mean(final) - np.mean(copied)),
            "raw_stop_reasons": {"left": raw_result["left_stop"], "right": raw_result["right_stop"]},
            "final_stop_reasons": {"left": result["left_stop"], "right": result["right_stop"]},
            "per_frame": rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "tmp/poly-benchmark.json")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="poly-benchmark-") as directory:
        names = ("translation", "reverse_translation", "rotation", "deformation", "boundary_offset")
        cases = [measure(Path(directory) / name, name) for name in names]
    result = {"created_utc": datetime.now(timezone.utc).isoformat(), "metric_id": "poly-sim-flow-edge-v1",
              "similarity_threshold": 1.0, "flow_quality_threshold": 0.65,
              "python": platform.python_version(), "opencv": cv2.__version__, "numpy": np.__version__,
              "scene_seed": 27, "process_peak_rss_mib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024,
              "scope": "Synthetic textured concave target only; these values do not establish surgical-video accuracy.",
              "cases": cases}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, allow_nan=False, indent=2) + "\n", encoding="utf-8")
    print(str(args.output.resolve()))
    for case in cases:
        print(f"{case['case']}: raw={case['raw_mean_iou']:.6f}, final={case['final_mean_iou']:.6f}, copy={case['copy_mean_iou']:.6f}, accepted={case['edge_accepted']}, fallback={case['edge_fallback']}, time={case['runtime_seconds']:.3f}s")


if __name__ == "__main__":
    main()
