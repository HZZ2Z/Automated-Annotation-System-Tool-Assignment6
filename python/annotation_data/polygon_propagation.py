"""短段 polygon 光流基线；只产生候选，人工关键帧及输入文件始终只读。"""

from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass
import hashlib
import math
from pathlib import Path
import stat
import struct
from typing import Callable

import cv2
import numpy as np

from .contracts import validate_instance
from .polygon_edge_refinement import EdgeRefinement, refine
from .polygon_flow import MotionPair
from .polygon_geometry import candidate_mask_geometry, mask_iou, polygon_to_mask, single_mask_contour, validate_polygon
from .similarity import similarity_gate


METRIC_ID = "poly-sim-flow-edge-v1"
DEFAULT_SIMILARITY_THRESHOLD = 0.02
FLOW_QUALITY_THRESHOLD = 0.65
MAX_FRAMES = 30
MAX_ANALYSIS_SIDE = 1024
MAX_IMAGE_PIXELS = 32_000_000
MAX_IMAGE_BYTES = 64 * 1024 * 1024
MAX_MASK_BYTES = 128 * 1024 * 1024


class Cancelled(Exception):
    pass


@dataclass(frozen=True)
class Snapshot:
    path: Path
    size: tuple[int, int]
    digest: bytes
    stat: tuple[int, int, int, int]


def _file_signature(path: Path) -> tuple[int, int, int, int]:
    details = path.stat()
    if not stat.S_ISREG(details.st_mode):
        raise ValueError("image snapshot must be a regular file")
    return details.st_ino, details.st_size, details.st_mtime_ns, details.st_ctime_ns


def _load_image(path: Path, expected: Snapshot | None = None) -> tuple[np.ndarray, Snapshot]:
    signature = _file_signature(path)
    if signature[1] > MAX_IMAGE_BYTES:
        raise ValueError("PNG image exceeds the 64 MiB input limit")
    with path.open("rb") as stream:
        header = stream.read(24)
        if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
            raise ValueError(f"image is not a PNG snapshot: {path.name}")
        width, height = struct.unpack(">II", header[16:24])
        if min(width, height) < 16 or max(width, height) > 32768 or width * height > MAX_IMAGE_PIXELS:
            raise ValueError("image dimensions exceed supported bounds (16px minimum, 32MP maximum)")
        data = header + stream.read(MAX_IMAGE_BYTES + 1 - len(header))
    if len(data) > MAX_IMAGE_BYTES or _file_signature(path) != signature:
        raise ValueError("image snapshot changed while being read")
    snapshot = Snapshot(path, (width, height), hashlib.sha256(data).digest(), signature)
    if expected is not None and snapshot != expected:
        raise ValueError("image snapshot changed during analysis")
    image = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_GRAYSCALE)
    if image is None or image.shape != (height, width):
        raise ValueError(f"image PNG could not be decoded: {path.name}")
    scale = min(1.0, MAX_ANALYSIS_SIDE / max(width, height))
    if scale < 1:
        image = cv2.resize(image, (max(1, round(width * scale)), max(1, round(height * scale))), interpolation=cv2.INTER_AREA)
    return image, snapshot


def _integer(value: object, name: str) -> int:
    if type(value) not in (int, float) or not math.isfinite(value) or value < 0 or int(value) != value:
        raise ValueError(f"{name} must be a nonnegative integer")
    return int(value)


def _validate_request(request: object) -> tuple[list[dict], list[dict], int, float]:
    if not isinstance(request, dict) or set(request) - {"schema_version", "key_index", "similarity_threshold", "frames", "regions"}:
        raise ValueError("request must be an object with only the versioned protocol fields")
    if _integer(request.get("schema_version"), "schema_version") != 2:
        raise ValueError("unsupported schema_version")
    key = _integer(request.get("key_index"), "key_index")
    threshold = request.get("similarity_threshold", DEFAULT_SIMILARITY_THRESHOLD)
    if type(threshold) not in (int, float) or not math.isfinite(threshold) or not 0 < threshold <= 1:
        raise ValueError("similarity_threshold must be a finite score in (0, 1]")
    frames = request.get("frames")
    if not isinstance(frames, list) or not 1 <= len(frames) <= MAX_FRAMES:
        raise ValueError("frames must contain 1 to 30 consecutive snapshots")
    for i, frame in enumerate(frames):
        if not isinstance(frame, dict) or set(frame) != {"index", "frame_id", "image_path"}:
            raise ValueError("each frame must contain index, frame_id and image_path")
        index = _integer(frame["index"], "frame index")
        frame_id = _integer(frame["frame_id"], "frame_id")
        if i and (index != frames[i - 1]["index"] + 1 or frame_id != frames[i - 1]["frame_id"] + 1):
            raise ValueError("frame indices and original frame IDs must be sorted and consecutive")
        path = frame["image_path"]
        if not isinstance(path, str) or not path or not Path(path).is_absolute():
            raise ValueError("image_path must be an absolute PNG snapshot path")
    if key not in [frame["index"] for frame in frames]:
        raise ValueError("key_index is not present in frames")
    regions = request.get("regions")
    if not isinstance(regions, list) or not regions:
        raise ValueError("regions must contain at least one V1 polygon region")
    errors = validate_instance({"schema_version": 1, "source": "polygon-propagation", "frame": 0, "regions": regions}, "model_output_v1.schema.json")
    if errors:
        raise ValueError("invalid V1 polygon region: " + errors[0])
    if any("polygon" not in region for region in regions):
        raise ValueError("every region must contain a polygon")
    if len({region["id"] for region in regions}) != len(regions):
        raise ValueError("polygon region IDs must be unique")
    return frames, regions, key, float(threshold)


def _analyse_pair(source, target, masks, check_cancel, motion_factory):
    motion = motion_factory(source, target, check_cancel)
    warped, evidence = [], []
    for region, mask in masks:
        check_cancel()
        try:
            evidence.append(motion.evidence(mask))
            warped.append(motion.warp_mask(mask))
        except ValueError as error:
            raise ValueError(f"region {region['id']}: {error}") from error
    return motion, warped, evidence


_EDGE_SCORE_FIELDS = {"raw_edge_score", "refined_edge_score", "raw_iou", "area_ratio", "hausdorff"}


def _validated_edge_result(result: object, raw_mask: np.ndarray) -> tuple[np.ndarray, dict]:
    if not isinstance(result, EdgeRefinement):
        raise TypeError("edge refinement returned an invalid result type")
    if type(result.accepted) is not bool or not isinstance(result.reason, str) or not 1 <= len(result.reason) <= 160:
        raise TypeError("edge refinement returned invalid status fields")
    if any(ord(character) < 32 for character in result.reason):
        raise TypeError("edge refinement reason contains control characters")
    candidate = np.asarray(result.mask)
    if candidate.shape != raw_mask.shape or candidate.ndim != 2:
        raise TypeError("edge refinement returned an invalid mask shape")
    if not np.issubdtype(candidate.dtype, np.number) or not np.isfinite(candidate).all():
        raise TypeError("edge refinement returned invalid mask values")
    if not result.accepted and not np.array_equal(candidate, raw_mask):
        raise TypeError("edge refinement fallback changed the raw mask")
    if not isinstance(result.scores, dict) or set(result.scores) != _EDGE_SCORE_FIELDS:
        raise TypeError("edge refinement returned invalid score fields")
    scores = {}
    for field in sorted(_EDGE_SCORE_FIELDS):
        value = result.scores[field]
        if isinstance(value, (bool, np.bool_)) or not isinstance(value, (int, float, np.integer, np.floating)):
            raise TypeError("edge refinement returned a nonnumeric score")
        value = float(value)
        if not math.isfinite(value):
            raise TypeError("edge refinement returned a non-finite score")
        scores[field] = value
    diagnostics = {"attempted": True, "accepted": result.accepted,
                   "reason": result.reason, **scores}
    return candidate.copy(), diagnostics


def _run_edge_refinement(edge_refiner, target: np.ndarray,
                         raw_mask: np.ndarray) -> tuple[np.ndarray, dict]:
    try:
        result = edge_refiner(target, raw_mask)
    except cv2.error:
        raise
    except ValueError as error:
        raise TypeError("edge refinement rejected its internal inputs") from error
    return _validated_edge_result(result, raw_mask)


def _candidate_frame(previous, target, anchor, masks, anchor_masks, frame, size,
                     adjacent, check_cancel, motion_factory, edge_refiner, similarity):
    """局部作用域释放临时光流；同时持有关键帧、上一步和当前 mask 状态。"""
    motion, warped, qualities = _analyse_pair(previous, target, masks, check_cancel, motion_factory)
    if adjacent:
        anchor_motion, anchor_warped, anchor_qualities = motion, warped, qualities
    else:
        anchor_motion, anchor_warped, anchor_qualities = _analyse_pair(
            anchor, target, anchor_masks, check_cancel, motion_factory
        )
    output_regions, quality_by_id = [], {}
    next_masks = []
    for i, ((region, prior), raw_candidate, raw_anchor_candidate) in enumerate(
            zip(masks, warped, anchor_warped)):
        check_cancel()
        try:
            _, raw_geometry = candidate_mask_geometry(
                raw_candidate, prior, anchor_masks[i][1], size
            )
            raw_anchor_iou = mask_iou(raw_candidate, raw_anchor_candidate)
            if raw_anchor_iou < 0.85:
                raise ValueError(f"fixed anchor disagreement ({raw_anchor_iou:.3f})")
            raw_anchor_quality = min(
                anchor_qualities[i][field] for field in ("appearance", "fb_consistency", "texture")
            )
            raw_quality = {
                **qualities[i], **raw_geometry, "anchor_iou": raw_anchor_iou,
                "anchor_quality": raw_anchor_quality,
            }
            raw_quality["score"] = min(
                raw_quality[field] for field in
                ("appearance", "fb_consistency", "texture", "anchor_iou", "anchor_quality")
            )
            if raw_quality["score"] < FLOW_QUALITY_THRESHOLD:
                raise ValueError(
                    f"quality {raw_quality['score']:.3f} below threshold {FLOW_QUALITY_THRESHOLD:.3f}"
                )

            check_cancel()
            candidate, edge = _run_edge_refinement(edge_refiner, target, raw_candidate)
            check_cancel()
            anchor_candidate, _ = _run_edge_refinement(
                edge_refiner, target, raw_anchor_candidate
            )
            check_cancel()

            polygon, final_geometry = candidate_mask_geometry(
                candidate, prior, anchor_masks[i][1], size
            )
            anchor_iou = mask_iou(candidate, anchor_candidate)
            if anchor_iou < 0.85:
                raise ValueError(f"fixed anchor disagreement ({anchor_iou:.3f})")
            # 光流证据定义在 source 坐标；选择 refined/fallback 后重新执行相同证据门。
            final_evidence = motion.evidence(prior)
            final_anchor_evidence = anchor_motion.evidence(anchor_masks[i][1])
            anchor_quality = min(
                final_anchor_evidence[field]
                for field in ("appearance", "fb_consistency", "texture")
            )
            quality = {
                **final_evidence, **final_geometry, "anchor_iou": anchor_iou,
                "anchor_quality": anchor_quality, "adjacent_mad": similarity["adjacent_mad"],
                "keyframe_mad": similarity["keyframe_mad"], "raw_flow": raw_quality,
                "edge": edge,
            }
            quality["score"] = min(
                quality[field] for field in
                ("appearance", "fb_consistency", "texture", "anchor_iou", "anchor_quality")
            )
            if quality["score"] < FLOW_QUALITY_THRESHOLD:
                raise ValueError(
                    f"quality {quality['score']:.3f} below threshold {FLOW_QUALITY_THRESHOLD:.3f}"
                )
            updated = deepcopy(region)
            updated["polygon"] = polygon
            if "box" in updated:
                vertices = np.asarray(polygon)
                updated["box"] = [*vertices.min(axis=0).tolist(), *np.ptp(vertices, axis=0).tolist()]
            output_regions.append(updated)
            quality_by_id[region["id"]] = quality
            next_masks.append((region, candidate))
        except ValueError as error:
            raise ValueError(f"region {region['id']}: {error}") from error
    proposal = {"index": int(frame["index"]), "frame_id": int(frame["frame_id"]),
                "regions": output_regions, "quality": quality_by_id}
    return proposal, next_masks


def propagate(request: dict, *, cancelled: Callable[[], bool] | None = None,
              progress: Callable[[dict], None] | None = None,
              motion_factory=MotionPair, edge_refiner=refine) -> dict:
    """消耗独立图像快照，返回连续候选闭区间；失败/取消丢弃全部临时结果。"""
    def check_cancel():
        if cancelled is not None and cancelled():
            raise Cancelled("polygon analysis cancelled")

    def report(completed, total, message):
        check_cancel()
        if progress is not None:
            progress({"completed": completed, "total": total, "message": message})
        check_cancel()

    try:
        check_cancel()
        frames, regions, key, threshold = _validate_request(request)
        key_position = next(i for i, frame in enumerate(frames) if frame["index"] == key)
        total, completed = len(frames) - 1, 0
        report(0, total, "Validating immutable PNG snapshots")
        snapshots = []
        # 每张图都先验证，坏图使整份计划失效；预检和方向分析最多保留 3 张灰度图。
        for frame in frames:
            check_cancel()
            image, snapshot = _load_image(Path(frame["image_path"]))
            snapshots.append(snapshot)
            if frame["index"] == key:
                anchor = image
            del image
        size = snapshots[key_position].size
        if len(regions) * anchor.size * 3 > MAX_MASK_BYTES:
            raise ValueError("polygon masks exceed the 128 MiB working-mask budget")
        anchor_masks = []
        for region in regions:
            check_cancel()
            points = validate_polygon(region["polygon"], size)
            mask = polygon_to_mask(points, size, anchor.shape)
            single_mask_contour(mask)
            anchor_masks.append((region, mask))
        proposals = []
        stops = {"left": "source boundary", "right": "source boundary"}
        for direction, name in ((-1, "left"), (1, "right")):
            previous = anchor
            masks = anchor_masks
            next_masks = anchor_masks
            target = anchor
            position = key_position + direction
            while 0 <= position < len(frames):
                check_cancel()
                frame = frames[position]
                if snapshots[position].size != size:
                    stops[name] = f"frame {frame['index']}: image dimensions changed"
                    break
                target, _ = _load_image(snapshots[position].path, snapshots[position])
                similarity = similarity_gate(previous, target, anchor, threshold)
                if not similarity["accepted"]:
                    stops[name] = (
                        f"frame {frame['index']}: similarity adjacent "
                        f"{similarity['adjacent_mad']:.6f} / keyframe "
                        f"{similarity['keyframe_mad']:.6f} >= threshold {threshold:.6f}"
                    )
                    completed += 1
                    report(completed, total, stops[name])
                    break
                try:
                    proposal, next_masks = _candidate_frame(previous, target, anchor, masks, anchor_masks,
                                                            frame, size, abs(position - key_position) == 1,
                                                            check_cancel, motion_factory, edge_refiner, similarity)
                    proposals.append(proposal)
                except ValueError as error:
                    stops[name] = f"frame {frame['index']}: {error}"
                    completed += 1
                    report(completed, total, stops[name])
                    break
                completed += 1
                report(completed, total, f"Analysed frame {frame['index']}")
                previous = target
                masks = next_masks
                position += direction
        check_cancel()
        if any(_file_signature(snapshot.path) != snapshot.stat for snapshot in snapshots):
            raise ValueError("image snapshot changed during analysis")
        proposals.sort(key=lambda proposal: proposal["index"])
        indices = [key] + [proposal["index"] for proposal in proposals]
        return {"schema_version": 1, "success": True, "cancelled": False, "metric_id": METRIC_ID,
                "threshold": threshold, "key_index": key, "start_index": min(indices), "end_index": max(indices),
                "left_stop": stops["left"], "right_stop": stops["right"], "proposals": proposals}
    except Cancelled as error:
        return {"schema_version": 1, "success": False, "cancelled": True, "error": str(error)}
    except (ValueError, TypeError, OSError, OverflowError, cv2.error) as error:
        return {"schema_version": 1, "success": False, "cancelled": False, "error": str(error)}
