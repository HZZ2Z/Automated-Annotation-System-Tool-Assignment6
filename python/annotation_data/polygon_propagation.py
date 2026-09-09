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
from .polygon_flow import MotionPair
from .polygon_geometry import mask_iou, mask_to_polygon, polygon_to_mask, single_mask_contour, validate_polygon


METRIC_ID = "poly-flow-mask-v1"
DEFAULT_THRESHOLD = 0.65
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
    if not isinstance(request, dict) or set(request) - {"schema_version", "key_index", "threshold", "frames", "regions"}:
        raise ValueError("request must be an object with only the versioned protocol fields")
    if _integer(request.get("schema_version"), "schema_version") != 1:
        raise ValueError("unsupported schema_version")
    key = _integer(request.get("key_index"), "key_index")
    threshold = request.get("threshold", DEFAULT_THRESHOLD)
    if type(threshold) not in (int, float) or not math.isfinite(threshold) or not 0 <= threshold <= 1:
        raise ValueError("threshold must be a finite quality score from 0 to 1")
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


def _analyse_pair(source, target, masks, check_cancel):
    motion = MotionPair(source, target, check_cancel)
    warped, evidence = [], []
    for region, mask in masks:
        check_cancel()
        try:
            evidence.append(motion.evidence(mask))
            warped.append(motion.warp_mask(mask))
        except ValueError as error:
            raise ValueError(f"region {region['id']}: {error}") from error
    return warped, evidence


def _candidate_frame(previous, target, anchor, masks, anchor_masks, frame, size, threshold, adjacent, check_cancel):
    """局部作用域释放临时光流；同时持有关键帧、上一步和当前 mask 状态。"""
    warped, qualities = _analyse_pair(previous, target, masks, check_cancel)
    anchor_motion = None if adjacent else MotionPair(anchor, target, check_cancel)
    output_regions, quality_by_id = [], {}
    for i, ((region, prior), candidate) in enumerate(zip(masks, warped)):
        check_cancel()
        try:
            polygon = mask_to_polygon(candidate, size)
            area = np.count_nonzero(candidate >= 128)
            ratio = float(area / np.count_nonzero(prior >= 128))
            anchor_ratio = float(area / np.count_nonzero(anchor_masks[i][1] >= 128))
            if not 0.75 <= ratio <= 1.33 or not 0.60 <= anchor_ratio <= 1.67:
                raise ValueError("area changed beyond the supported visible-target range")
            # 固定关键帧的临时 mask 逐目标计算，不缓存一整组直接预测。
            anchor_evidence = qualities[i] if adjacent else anchor_motion.evidence(anchor_masks[i][1])
            anchor_iou = 1.0 if adjacent else mask_iou(candidate, anchor_motion.warp_mask(anchor_masks[i][1]))
            if anchor_iou < 0.85:
                raise ValueError(f"fixed anchor disagreement ({anchor_iou:.3f})")
            quality = {**qualities[i], "anchor_iou": anchor_iou, "area_ratio": ratio,
                       "anchor_area_ratio": anchor_ratio}
            quality["anchor_quality"] = min(anchor_evidence[field] for field in ("appearance", "fb_consistency", "texture"))
            quality["score"] = min(quality[field] for field in ("appearance", "fb_consistency", "texture", "anchor_iou", "anchor_quality"))
            if quality["score"] < threshold:
                raise ValueError(f"quality {quality['score']:.3f} below threshold {threshold:.3f}")
            updated = deepcopy(region)
            updated["polygon"] = polygon
            if "box" in updated:
                vertices = np.asarray(polygon)
                updated["box"] = [*vertices.min(axis=0).tolist(), *np.ptp(vertices, axis=0).tolist()]
            output_regions.append(updated)
            quality_by_id[region["id"]] = quality
        except ValueError as error:
            raise ValueError(f"region {region['id']}: {error}") from error
    proposal = {"index": int(frame["index"]), "frame_id": int(frame["frame_id"]),
                "regions": output_regions, "quality": quality_by_id}
    return proposal, [(region, mask) for (region, _), mask in zip(masks, warped)]


def propagate(request: dict, *, cancelled: Callable[[], bool] | None = None,
              progress: Callable[[dict], None] | None = None) -> dict:
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
                try:
                    proposal, next_masks = _candidate_frame(previous, target, anchor, masks, anchor_masks,
                                                            frame, size, threshold, abs(position - key_position) == 1,
                                                            check_cancel)
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
