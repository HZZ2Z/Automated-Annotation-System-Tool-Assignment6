"""光流工作 mask 与 V1 单外环之间的受限转换；不改写人工关键帧。"""

from __future__ import annotations

import math

import cv2
import numpy as np


MAX_VERTICES = 4096
MAX_OUTPUT_VERTICES = 2048
MIN_MASK_AREA = 64


def validate_polygon(points: object, size: tuple[int, int]) -> np.ndarray:
    """校验简单环，返回独立数组；首尾重复的闭合记号只在内部去除。"""
    if not isinstance(points, list) or not 3 <= len(points) <= MAX_VERTICES:
        raise ValueError(f"polygon needs 3 to {MAX_VERTICES} vertices")
    for point in points:
        if not isinstance(point, list) or len(point) != 2:
            raise ValueError("polygon vertices must contain exactly two coordinates")
        if any(type(v) not in (int, float) or not math.isfinite(v) for v in point):
            raise ValueError("polygon coordinates must be finite numbers")
    ring = np.asarray(points, dtype=np.float64)
    if np.array_equal(ring[0], ring[-1]):
        ring = ring[:-1].copy()
    if len(ring) < 3 or len(np.unique(ring, axis=0)) != len(ring):
        raise ValueError("polygon has duplicate or degenerate vertices")
    width, height = size
    if np.any(ring < 0) or np.any(ring[:, 0] > width) or np.any(ring[:, 1] > height):
        raise ValueError("polygon is outside image bounds")
    next_points = np.roll(ring, -1, axis=0)
    if abs(float(np.sum(ring[:, 0] * next_points[:, 1] - ring[:, 1] * next_points[:, 0]))) < 2:
        raise ValueError("polygon is degenerate or has zero area")
    # 相邻共线边允许顺行，不允许沿原边折返；非相邻边不能相交或接触。
    incoming, outgoing = np.roll(ring, 1, axis=0) - ring, next_points - ring
    cross = incoming[:, 0] * outgoing[:, 1] - incoming[:, 1] * outgoing[:, 0]
    if np.any((np.abs(cross) <= 1e-8) & (np.sum(incoming * outgoing, axis=1) > 0)):
        raise ValueError("polygon has overlapping adjacent edges")
    for i in range(len(ring)):
        indices = np.arange(i + 2, len(ring))
        if i == 0:
            indices = indices[indices != len(ring) - 1]
        if not len(indices):
            continue
        a, b, c, d = ring[i], next_points[i], ring[indices], next_points[indices]
        overlap = np.all(np.maximum(np.minimum(a, b), np.minimum(c, d)) <= np.minimum(np.maximum(a, b), np.maximum(c, d)) + 1e-8, axis=1)
        c, d = c[overlap], d[overlap]
        ab, cd = b - a, d - c
        side_c = ab[0] * (c[:, 1] - a[1]) - ab[1] * (c[:, 0] - a[0])
        side_d = ab[0] * (d[:, 1] - a[1]) - ab[1] * (d[:, 0] - a[0])
        side_a = cd[:, 0] * (a[1] - c[:, 1]) - cd[:, 1] * (a[0] - c[:, 0])
        side_b = cd[:, 0] * (b[1] - c[:, 1]) - cd[:, 1] * (b[0] - c[:, 0])
        if np.any((side_c * side_d <= 1e-8) & (side_a * side_b <= 1e-8)):
            raise ValueError("polygon has a self-intersection")
    return ring.copy()


def polygon_to_mask(points: np.ndarray, original_size: tuple[int, int], shape: tuple[int, int]) -> np.ndarray:
    """仅初始化关键帧 mask；后续传播始终使用 mask，不重栅格化候选多边形。"""
    height, width = shape
    scale = np.array([width / original_size[0], height / original_size[1]])
    mask = np.zeros(shape, dtype=np.uint8)
    cv2.fillPoly(mask, [np.rint(points * scale * 16).astype(np.int32)], 255, shift=4)
    return mask


def mask_iou(left: np.ndarray, right: np.ndarray) -> float:
    left, right = left >= 128, right >= 128
    union = np.count_nonzero(left | right)
    return float(np.count_nonzero(left & right) / union) if union else 0.0


def single_mask_contour(mask: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """只校验 mask 拓扑和可见边界，人工关键帧不受候选顶点预算限制。"""
    binary = np.asarray(mask >= (128 if mask.max() > 1 else 1), dtype=np.uint8)
    if np.count_nonzero(binary) < MIN_MASK_AREA:
        raise ValueError("mask is degenerate or too small at analysis resolution")
    if binary[0].any() or binary[-1].any() or binary[:, 0].any() or binary[:, -1].any():
        raise ValueError("mask reaches image bounds; clipping cannot be verified")
    contours, hierarchy = cv2.findContours(binary, cv2.RETR_TREE, cv2.CHAIN_APPROX_NONE)
    if hierarchy is None or len(contours) != 1:
        if hierarchy is not None and np.any(hierarchy[0, :, 3] >= 0):
            raise ValueError("mask contains a hole; V1 supports one simple ring")
        raise ValueError("mask contains multiple components; V1 supports one simple ring")
    return binary, contours[0]


def mask_to_polygon(mask: np.ndarray, original_size: tuple[int, int]) -> list[list[float]]:
    """保留凹形单环；误差最多 0.65 分析像素、IoU >= .99、候选 <= 2048 点。"""
    binary, contour = single_mask_contour(mask)
    approximation = cv2.approxPolyDP(contour, 0.65, True)
    check = np.zeros_like(binary)
    cv2.fillPoly(check, [approximation], 1)
    if mask_iou(check * 255, binary * 255) < 0.99:
        approximation = cv2.approxPolyDP(contour, 0.25, True)
        check.fill(0)
        cv2.fillPoly(check, [approximation], 1)
        if mask_iou(check * 255, binary * 255) < 0.99:
            raise ValueError("polygon approximation loses mask geometry")
    if len(approximation) > MAX_OUTPUT_VERTICES:
        raise ValueError(f"candidate exceeds {MAX_OUTPUT_VERTICES} vertices; manual correction is required")
    scale = np.array([original_size[0] / mask.shape[1], original_size[1] / mask.shape[0]])
    points = (approximation.reshape(-1, 2) * scale).tolist()
    validate_polygon(points, original_size)
    return points
