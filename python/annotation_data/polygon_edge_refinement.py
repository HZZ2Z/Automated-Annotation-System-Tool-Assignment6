"""在光流 mask 附近做有界边缘精修；预期性拒绝必须保留原始候选。"""

from __future__ import annotations

from dataclasses import dataclass
import math

import cv2
import numpy as np


EDGE_GAIN_THRESHOLD = 0.01
MIN_RAW_IOU = 0.85
MIN_AREA_RATIO = 0.80
MAX_AREA_RATIO = 1.25
MAX_HAUSDORFF = 6.0
MAX_ROI_PIXELS = 32_000_000


@dataclass(frozen=True)
class EdgeRefinement:
    accepted: bool
    mask: np.ndarray
    reason: str
    scores: dict[str, float]


def _grayscale(image: np.ndarray, shape: tuple[int, int]) -> np.ndarray:
    array = np.asarray(image)
    if array.shape[:2] != shape:
        raise ValueError("image and raw_mask dimensions differ")
    if array.ndim == 2:
        gray = array
    elif array.ndim == 3 and array.shape[2] == 3:
        gray = cv2.cvtColor(array, cv2.COLOR_BGR2GRAY)
    elif array.ndim == 3 and array.shape[2] == 4:
        gray = cv2.cvtColor(array, cv2.COLOR_BGRA2GRAY)
    else:
        raise ValueError("image must be grayscale, BGR or BGRA")
    if gray.dtype != np.uint8:
        if not np.issubdtype(gray.dtype, np.number) or not np.isfinite(gray).all():
            raise ValueError("image pixels must be finite numeric values")
        gray = np.clip(gray, 0, 255).astype(np.uint8)
    return np.ascontiguousarray(gray)


def _boundary(binary: np.ndarray) -> np.ndarray:
    eroded = cv2.erode(binary, np.ones((3, 3), np.uint8), iterations=1)
    return (binary > eroded)


def _edge_map(gray: np.ndarray) -> np.ndarray:
    source = gray.astype(np.float32)
    dx = cv2.Sobel(source, cv2.CV_32F, 1, 0, ksize=3)
    dy = cv2.Sobel(source, cv2.CV_32F, 0, 1, ksize=3)
    return np.clip(cv2.magnitude(dx, dy) / (4.0 * math.sqrt(2.0) * 255.0), 0.0, 1.0)


def _edge_score(edges: np.ndarray, binary: np.ndarray) -> float:
    boundary = _boundary(binary)
    return float(np.mean(edges[boundary])) if boundary.any() else 0.0


def _hausdorff(left: np.ndarray, right: np.ndarray) -> float:
    left_boundary, right_boundary = _boundary(left), _boundary(right)
    if not left_boundary.any() or not right_boundary.any():
        return float(math.hypot(*left.shape))
    to_left = cv2.distanceTransform((~left_boundary).astype(np.uint8), cv2.DIST_L2, cv2.DIST_MASK_PRECISE)
    to_right = cv2.distanceTransform((~right_boundary).astype(np.uint8), cv2.DIST_L2, cv2.DIST_MASK_PRECISE)
    return float(max(np.max(to_left[right_boundary]), np.max(to_right[left_boundary])))


def _scores(edges: np.ndarray, raw: np.ndarray, candidate: np.ndarray) -> dict[str, float]:
    intersection = np.count_nonzero((raw > 0) & (candidate > 0))
    union = np.count_nonzero((raw > 0) | (candidate > 0))
    raw_area = np.count_nonzero(raw)
    return {
        "raw_edge_score": _edge_score(edges, raw),
        "refined_edge_score": _edge_score(edges, candidate),
        "raw_iou": float(intersection / union) if union else 0.0,
        "area_ratio": float(np.count_nonzero(candidate) / raw_area) if raw_area else 0.0,
        "hausdorff": _hausdorff(raw, candidate),
    }


def _fallback(raw: np.ndarray, reason: str, scores: dict[str, float]) -> EdgeRefinement:
    return EdgeRefinement(False, raw.copy(), reason, scores)


def _topology_reason(candidate: np.ndarray) -> str | None:
    component_count, _ = cv2.connectedComponents(candidate, connectivity=8)
    if component_count != 2:
        return "multiple components"
    contours, hierarchy = cv2.findContours(candidate, cv2.RETR_TREE, cv2.CHAIN_APPROX_NONE)
    if hierarchy is not None and np.any(hierarchy[0, :, 3] >= 0):
        return "hole"
    if len(contours) != 1:
        return "multiple components"
    return None


def refine(image: np.ndarray, raw_mask: np.ndarray, *, band_radius: int = 6,
           roi_padding: int = 8) -> EdgeRefinement:
    """仅在所有边界和形状门通过时接受 GrabCut；预期拒绝返回原 mask。"""
    raw_original = np.asarray(raw_mask)
    if raw_original.ndim != 2:
        raise ValueError("raw_mask must be a two-dimensional array")
    if type(band_radius) is not int or band_radius < 1:
        raise ValueError("band_radius must be a positive integer")
    if type(roi_padding) is not int or roi_padding < 1:
        raise ValueError("roi_padding must be a positive integer")
    gray = _grayscale(image, raw_original.shape)
    raw = np.asarray(raw_original >= (128 if raw_original.size and raw_original.max() > 1 else 1), dtype=np.uint8)
    edges = _edge_map(gray)
    unchanged_scores = _scores(edges, raw, raw)
    if not raw.any():
        return _fallback(raw_original, "raw mask is empty", unchanged_scores)

    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * band_radius + 1, 2 * band_radius + 1))
    eroded = cv2.erode(raw, kernel, iterations=1)
    if not eroded.any():
        return _fallback(raw_original, "definite foreground is empty", unchanged_scores)
    dilated = cv2.dilate(raw, kernel, iterations=1)
    if not np.any(raw & ~eroded) or not np.any(dilated & ~raw):
        return _fallback(raw_original, "refinement band is empty", unchanged_scores)

    x, y, width, height = cv2.boundingRect(dilated)
    x0, y0 = max(0, x - roi_padding), max(0, y - roi_padding)
    x1 = min(raw.shape[1], x + width + roi_padding)
    y1 = min(raw.shape[0], y + height + roi_padding)
    if x1 <= x0 or y1 <= y0 or (x1 - x0) * (y1 - y0) > MAX_ROI_PIXELS:
        return _fallback(raw_original, "refinement ROI is invalid", unchanged_scores)

    roi_raw = raw[y0:y1, x0:x1]
    roi_eroded = eroded[y0:y1, x0:x1]
    roi_dilated = dilated[y0:y1, x0:x1]
    labels = np.full(roi_raw.shape, cv2.GC_BGD, dtype=np.uint8)
    labels[roi_dilated > 0] = cv2.GC_PR_BGD
    labels[roi_raw > 0] = cv2.GC_PR_FGD
    labels[roi_eroded > 0] = cv2.GC_FGD
    background_model = np.zeros((1, 65), np.float64)
    foreground_model = np.zeros((1, 65), np.float64)
    roi_image = cv2.cvtColor(gray[y0:y1, x0:x1], cv2.COLOR_GRAY2BGR)
    cv2.grabCut(
        roi_image, labels, None, background_model, foreground_model, 3,
        cv2.GC_INIT_WITH_MASK,
    )

    candidate_roi = np.asarray(
        (labels == cv2.GC_FGD) | (labels == cv2.GC_PR_FGD), dtype=np.uint8
    )
    candidate = np.zeros_like(raw)
    candidate[y0:y1, x0:x1] = candidate_roi
    scores = _scores(edges, raw, candidate)
    if not all(math.isfinite(value) for value in scores.values()):
        raise ValueError("edge refinement produced non-finite scores")

    topology_reason = _topology_reason(candidate)
    if topology_reason is not None:
        return _fallback(raw_original, topology_reason, scores)
    if candidate_roi[0].any() or candidate_roi[-1].any() or candidate_roi[:, 0].any() or candidate_roi[:, -1].any():
        return _fallback(raw_original, "crop boundary", scores)
    if scores["raw_iou"] < MIN_RAW_IOU:
        reason = "raw IoU below 0.85"
        if not MIN_AREA_RATIO <= scores["area_ratio"] <= MAX_AREA_RATIO:
            reason += "; area ratio outside [0.80, 1.25]"
        return _fallback(raw_original, reason, scores)
    if not MIN_AREA_RATIO <= scores["area_ratio"] <= MAX_AREA_RATIO:
        return _fallback(raw_original, "area ratio outside [0.80, 1.25]", scores)
    if scores["hausdorff"] > MAX_HAUSDORFF:
        return _fallback(raw_original, "Hausdorff above 6", scores)
    if scores["refined_edge_score"] < scores["raw_edge_score"] + EDGE_GAIN_THRESHOLD:
        return _fallback(raw_original, "edge gain below 0.01", scores)
    return EdgeRefinement(True, candidate * 255, "accepted", scores)
