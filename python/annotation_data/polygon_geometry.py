# polygon 几何门禁与 polygon/mask 受限转换(annotation_data 包核心库)。
#
# 用途:校验 Model Output V1 的 polygon 是否为合法简单环(顶点结构与数量
# 合法、非退化、非自交、不越界),并提供 polygon -> mask 初始化、mask 拓扑
# 检查、受限的 mask -> polygon 提取,以及候选 mask 相对相邻帧/固定关键帧
# 的面积门禁。所有门禁失败都以 ValueError 原子拒绝并给出英文原因,
# 不做静默修复或降级。
#
# 角色与协作:被 annotation_data.polygon_propagation(光流传播管线)、
# annotation_data.endoscapes_fixture(样例构造)与
# python/run_endoscapes_poly_acceptance.py(验收脚本)调用;几何运算
# 基于 OpenCV(cv2)与 numpy。
"""光流工作 mask 与 V1 单外环之间的受限转换；不改写人工关键帧。"""

from __future__ import annotations

import math

import cv2
import numpy as np


# validate_polygon 接受的输入顶点数上限。
MAX_VERTICES = 4096
# mask_to_polygon 产出的候选 polygon 顶点数上限,超出要求人工修正。
MAX_OUTPUT_VERTICES = 2048
# 分析分辨率下 mask 的最小前景像素面积,低于此值视为退化。
MIN_MASK_AREA = 64
# 候选 mask 面积相对前一帧(相邻帧)面积的允许比值区间。
MIN_ADJACENT_AREA_RATIO = 0.75
MAX_ADJACENT_AREA_RATIO = 1.33
# 候选 mask 面积相对固定关键帧(anchor)面积的允许比值区间。
MIN_ANCHOR_AREA_RATIO = 0.60
MAX_ANCHOR_AREA_RATIO = 1.67


# 校验单条 polygon 是否构成合法的 V1 简单环,并把顶点转为内部计算用的数组。
# 参数 points:待校验顶点列表,每个顶点为 [x, y];size:所属图像的 (width, height)。
# 全部门禁通过才返回;任何一条不满足都以 ValueError 原子拒绝(消息说明原因)。
# 返回:shape (N, 2) 的 float64 数组独立副本(不含首尾闭合记号);入参不被修改。
def validate_polygon(points: object, size: tuple[int, int]) -> np.ndarray:
    """校验简单环，返回独立数组；首尾重复的闭合记号只在内部去除。"""
    if not isinstance(points, list) or not 3 <= len(points) <= MAX_VERTICES:
        raise ValueError(f"polygon needs 3 to {MAX_VERTICES} vertices")
    # 逐点结构检查:每个顶点必须是恰含两个有限数字的列表(bool 不算数字)。
    for point in points:
        if not isinstance(point, list) or len(point) != 2:
            raise ValueError("polygon vertices must contain exactly two coordinates")
        if any(type(v) not in (int, float) or not math.isfinite(v) for v in point):
            raise ValueError("polygon coordinates must be finite numbers")
    # 转为 float64 数组;首尾重复只视为闭合记号,仅在内部去除。
    ring = np.asarray(points, dtype=np.float64)
    if np.array_equal(ring[0], ring[-1]):
        ring = ring[:-1].copy()
    # 去除闭合记号后仍要求至少 3 个互不重复的顶点。
    if len(ring) < 3 or len(np.unique(ring, axis=0)) != len(ring):
        raise ValueError("polygon has duplicate or degenerate vertices")
    width, height = size
    if np.any(ring < 0) or np.any(ring[:, 0] > width) or np.any(ring[:, 1] > height):
        raise ValueError("polygon is outside image bounds")
    # 鞋带公式得到有向面积的两倍;绝对值 < 2(面积不足 1 平方像素)视为退化环。
    next_points = np.roll(ring, -1, axis=0)
    if abs(float(np.sum(ring[:, 0] * next_points[:, 1] - ring[:, 1] * next_points[:, 0]))) < 2:
        raise ValueError("polygon is degenerate or has zero area")
    # 相邻共线边允许顺行，不允许沿原边折返；非相邻边不能相交或接触。
    incoming, outgoing = np.roll(ring, 1, axis=0) - ring, next_points - ring
    cross = incoming[:, 0] * outgoing[:, 1] - incoming[:, 1] * outgoing[:, 0]
    if np.any((np.abs(cross) <= 1e-8) & (np.sum(incoming * outgoing, axis=1) > 0)):
        raise ValueError("polygon has overlapping adjacent edges")
    # 自交检测:对每条边 (i, i+1),先做包围盒预筛出候选相交的非相邻边,
    # 再逐对做叉积定向测试(容差 1e-8,接触也算相交)。
    for i in range(len(ring)):
        indices = np.arange(i + 2, len(ring))
        # i == 0 时排除收尾边 (last, 0):它与首条边共享顶点 0,属相邻边。
        if i == 0:
            indices = indices[indices != len(ring) - 1]
        if not len(indices):
            continue
        a, b, c, d = ring[i], next_points[i], ring[indices], next_points[indices]
        overlap = np.all(np.maximum(np.minimum(a, b), np.minimum(c, d)) <= np.minimum(np.maximum(a, b), np.maximum(c, d)) + 1e-8, axis=1)
        c, d = c[overlap], d[overlap]
        # 叉积定向测试:c、d 相对直线 ab、a、b 相对直线 cd 各算一次有向侧积,
        # 两个乘积都不超过 1e-8(即不严格同侧)时判为相交或接触。
        ab, cd = b - a, d - c
        side_c = ab[0] * (c[:, 1] - a[1]) - ab[1] * (c[:, 0] - a[0])
        side_d = ab[0] * (d[:, 1] - a[1]) - ab[1] * (d[:, 0] - a[0])
        side_a = cd[:, 0] * (a[1] - c[:, 1]) - cd[:, 1] * (a[0] - c[:, 0])
        side_b = cd[:, 0] * (b[1] - c[:, 1]) - cd[:, 1] * (b[0] - c[:, 0])
        if np.any((side_c * side_d <= 1e-8) & (side_a * side_b <= 1e-8)):
            raise ValueError("polygon has a self-intersection")
    return ring.copy()


# 把原图坐标下的 polygon 栅格化为指定分辨率的 uint8 mask(功能见英文 docstring)。
# 参数 points:(N, 2) 顶点数组,坐标系为 original_size;original_size:
#   原图 (width, height);shape:目标 mask 的 (height, width)。
# 返回:uint8 mask,前景填充 255,背景为 0;纯函数,无副作用。
def polygon_to_mask(points: np.ndarray, original_size: tuple[int, int], shape: tuple[int, int]) -> np.ndarray:
    """仅初始化关键帧 mask；后续传播始终使用 mask，不重栅格化候选多边形。"""
    height, width = shape
    # 顶点先按分辨率比例缩放,再放大 16 倍取整、以 shift=4 定点方式填充,
    # 保留亚像素精度后由 fillPoly 就近取整,减少栅格化偏移。
    scale = np.array([width / original_size[0], height / original_size[1]])
    mask = np.zeros(shape, dtype=np.uint8)
    cv2.fillPoly(mask, [np.rint(points * scale * 16).astype(np.int32)], 255, shift=4)
    return mask


# 计算两个 mask 的 IoU(交并比)。
# 参数 left/right:形状相同的 mask 数组,前景阈值 >= 128。
# 返回:float 交并比;并集为空时返回 0.0;无副作用。
def mask_iou(left: np.ndarray, right: np.ndarray) -> float:
    left, right = left >= 128, right >= 128
    union = np.count_nonzero(left | right)
    return float(np.count_nonzero(left & right) / union) if union else 0.0


# 对 raw/refined 候选 mask 施加同一套几何门(功能见英文 docstring)。
# 参数 mask:候选 mask;previous_mask:前一帧(相邻)mask;anchor_mask:
#   固定关键帧 mask;original_size:原图 (width, height)。
# 门禁:previous/anchor 任一为空抛 ValueError;候选面积相对前一帧的比值
#   越出 [0.75, 1.33]、相对关键帧越出 [0.60, 1.67] 也抛 ValueError;
#   mask_to_polygon 内部的拓扑/顶点门禁失败同样抛 ValueError。
# 返回:(polygon 顶点列表, 指标字典) 二元组;字典含 area_ratio(相对
#   前一帧)与 anchor_area_ratio(相对关键帧)。
def candidate_mask_geometry(mask: np.ndarray, previous_mask: np.ndarray,
                            anchor_mask: np.ndarray,
                            original_size: tuple[int, int]) -> tuple[list[list[float]], dict[str, float]]:
    """对 raw/refined 候选使用同一拓扑、面积和多边形转换门。"""
    polygon = mask_to_polygon(mask, original_size)
    # 面积一律按 >= 128 的二值前景像素数统计。
    area = int(np.count_nonzero(np.asarray(mask) >= 128))
    previous_area = int(np.count_nonzero(np.asarray(previous_mask) >= 128))
    anchor_area = int(np.count_nonzero(np.asarray(anchor_mask) >= 128))
    if previous_area == 0 or anchor_area == 0:
        raise ValueError("reference mask is empty")
    area_ratio = float(area / previous_area)
    anchor_area_ratio = float(area / anchor_area)
    if not MIN_ADJACENT_AREA_RATIO <= area_ratio <= MAX_ADJACENT_AREA_RATIO:
        raise ValueError("area changed beyond the supported visible-target range")
    if not MIN_ANCHOR_AREA_RATIO <= anchor_area_ratio <= MAX_ANCHOR_AREA_RATIO:
        raise ValueError("area changed beyond the fixed-keyframe range")
    return polygon, {"area_ratio": area_ratio, "anchor_area_ratio": anchor_area_ratio}


# 检查 mask 的拓扑与可见性约束,返回二值图与其唯一外轮廓(功能见英文 docstring)。
# 参数 mask:分析分辨率下的 mask。
# 门禁:前景像素 < MIN_MASK_AREA、mask 触碰图像四边、含孔或含多个连通
#   分量时抛 ValueError——V1 只允许一个不越界的简单外环。
# 返回:(binary, contour) 二元组;binary 为 uint8 0/1 数组,contour 为
#   cv2.findContours(RETR_TREE, CHAIN_APPROX_NONE) 输出的单条全点轮廓。
def single_mask_contour(mask: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """只校验 mask 拓扑和可见边界，人工关键帧不受候选顶点预算限制。"""
    # 兼容 0/255 与 0/1 两种取值:最大值 > 1 时以 128 为前景阈值。
    binary = np.asarray(mask >= (128 if mask.max() > 1 else 1), dtype=np.uint8)
    if np.count_nonzero(binary) < MIN_MASK_AREA:
        raise ValueError("mask is degenerate or too small at analysis resolution")
    if binary[0].any() or binary[-1].any() or binary[:, 0].any() or binary[:, -1].any():
        raise ValueError("mask reaches image bounds; clipping cannot be verified")
    # RETR_TREE 层级中父索引 >= 0 表示该轮廓嵌在其他轮廓内(即存在孔);
    # 轮廓总数不为 1 则是多个连通分量,两者都违反 V1 单环合同。
    contours, hierarchy = cv2.findContours(binary, cv2.RETR_TREE, cv2.CHAIN_APPROX_NONE)
    if hierarchy is None or len(contours) != 1:
        if hierarchy is not None and np.any(hierarchy[0, :, 3] >= 0):
            raise ValueError("mask contains a hole; V1 supports one simple ring")
        raise ValueError("mask contains multiple components; V1 supports one simple ring")
    return binary, contours[0]


# 从分析分辨率 mask 受限提取 V1 polygon(功能与硬指标见英文 docstring)。
# 参数 mask:分析分辨率 mask;original_size:目标原图 (width, height)。
# 门禁:先过 single_mask_contour 拓扑检查;approxPolyDP 逼近栅格还原的
#   IoU 必须 >= 0.99(先 0.65、再收紧 0.25 分析像素两档),候选顶点数
#   不得超过 MAX_OUTPUT_VERTICES;最后缩放回原图坐标再走一遍
#   validate_polygon 全套几何门禁。任一失败抛 ValueError。
# 返回:[[x, y], ...] 浮点顶点列表(原图坐标,不含闭合记号)。
def mask_to_polygon(mask: np.ndarray, original_size: tuple[int, int]) -> list[list[float]]:
    """保留凹形单环；误差最多 0.65 分析像素、IoU >= .99、候选 <= 2048 点。"""
    binary, contour = single_mask_contour(mask)
    # Douglas-Peucker 逼近后重新填充栅格核对还原度:先 0.65 分析像素,
    # IoU < 0.99 时收紧到 0.25;仍不足则拒绝,绝不输出失真 polygon。
    approximation = cv2.approxPolyDP(contour, 0.65, True)
    check = np.zeros_like(binary)
    cv2.fillPoly(check, [approximation], 1)
    if mask_iou(check * 255, binary * 255) < 0.99:
        approximation = cv2.approxPolyDP(contour, 0.25, True)
        check.fill(0)
        cv2.fillPoly(check, [approximation], 1)
        if mask_iou(check * 255, binary * 255) < 0.99:
            raise ValueError("polygon approximation loses mask geometry")
    # 超出候选顶点预算时不自动简化,转交人工修正。
    if len(approximation) > MAX_OUTPUT_VERTICES:
        raise ValueError(f"candidate exceeds {MAX_OUTPUT_VERTICES} vertices; manual correction is required")
    # 顶点从分析分辨率缩放回原图分辨率,并再过一遍几何门禁防止缩放引入退化。
    scale = np.array([original_size[0] / mask.shape[1], original_size[1] / mask.shape[0]])
    points = (approximation.reshape(-1, 2) * scale).tolist()
    validate_polygon(points, original_size)
    return points
