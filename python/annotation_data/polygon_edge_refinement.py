# 有界 polygon 边缘精化(annotation_data 包核心库)。
#
# 用途:在光流 raw mask 的局部带状区域(band)与 ROI 内运行 GrabCut,
# 用 Sobel 边缘强度衡量精化是否真正改善边界贴合;只有通过全部拓扑与
# 质量门(单连通、无孔、不触 ROI 边界、raw IoU、面积比、Hausdorff 距离、
# 边缘增益)才接受精化结果;任何预期性拒绝都原样返回 raw mask 并记录
# 英文原因,绝不静默改写或降级。
#
# 角色与协作:被 annotation_data.polygon_propagation(传播管线的边缘精化
# 步骤)与 python/run_endoscapes_poly_acceptance.py(验收脚本)调用;
# 图像与形态学运算基于 OpenCV(cv2)与 numpy。
"""在光流 mask 附近做有界边缘精修；预期性拒绝必须保留原始候选。"""

from __future__ import annotations

from dataclasses import dataclass
import math

import cv2
import numpy as np


# 接受精化所需的最低边缘分数增益(refined 相对 raw 的提升量)。
EDGE_GAIN_THRESHOLD = 0.01
# 候选与 raw mask 的最低 IoU。
MIN_RAW_IOU = 0.85
# 候选面积相对 raw 面积的允许比值区间。
MIN_AREA_RATIO = 0.80
MAX_AREA_RATIO = 1.25
# 边界间对称 Hausdorff 距离上限(像素)。
MAX_HAUSDORFF = 6.0
# GrabCut ROI 允许的最大像素数,超限视为 ROI 无效并预期拒绝。
MAX_ROI_PIXELS = 32_000_000


# 边缘精化结果(frozen dataclass,不可变纯数据,无共享状态)。
# 属性:
#   accepted:True 表示精化被接受;False 表示预期性拒绝;
#   mask:接受时为精化结果(candidate * 255,uint8 0/255);拒绝时为
#     原始 raw mask 的原样副本(字节级保留,供调用方回退);
#   reason:接受时为 "accepted";拒绝时为第一条命中的英文原因;
#   scores:本次评估的指标字典(字段见 _scores)。
@dataclass(frozen=True)
class EdgeRefinement:
    accepted: bool
    mask: np.ndarray
    reason: str
    scores: dict[str, float]


# 把输入帧图像转成与 raw mask 同形状的 uint8 灰度图。
# 参数 image:2D 灰度、3 通道 BGR 或 4 通道 BGRA 数组;shape:raw mask 的
#   (height, width),要求严格一致。
# 异常:形状不一致或通道数不支持抛 ValueError;非 uint8 输入必须是有限
#   数值(否则抛 ValueError),并截断到 [0, 255] 后转 uint8。
# 返回:C 连续的 uint8 灰度数组;无副作用。
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


# 计算 1 像素宽的 mask 内边界:原 mask 减去 3x3 方核腐蚀一次的结果。
# 返回:bool 数组,True 为边界像素;无副作用。
def _boundary(binary: np.ndarray) -> np.ndarray:
    eroded = cv2.erode(binary, np.ones((3, 3), np.uint8), iterations=1)
    return (binary > eroded)


# 用 3x3 Sobel 计算灰度图的边缘强度图。
# 返回:float32 数组,梯度幅值除以理论最大值 4*sqrt(2)*255,归一化到 [0, 1]。
def _edge_map(gray: np.ndarray) -> np.ndarray:
    source = gray.astype(np.float32)
    dx = cv2.Sobel(source, cv2.CV_32F, 1, 0, ksize=3)
    dy = cv2.Sobel(source, cv2.CV_32F, 0, 1, ksize=3)
    return np.clip(cv2.magnitude(dx, dy) / (4.0 * math.sqrt(2.0) * 255.0), 0.0, 1.0)


# 计算 mask 内边界上的平均边缘强度:值越高说明边界与图像边缘贴合越好。
# 返回:float;边界为空时返回 0.0;无副作用。
def _edge_score(edges: np.ndarray, binary: np.ndarray) -> float:
    boundary = _boundary(binary)
    return float(np.mean(edges[boundary])) if boundary.any() else 0.0


# 计算两个 mask 边界间的对称 Hausdorff 距离(像素)。
# 思路:对各自边界的补图做精确 L2 距离变换,得到每个像素到该边界的最近
#   距离;取"右边界各点到左边界"与"左边界各点到右边界"两个有向距离的
#   最大值。
# 任一边界为空时返回图像对角线长度(最差情形,必然无法通过门禁)。
def _hausdorff(left: np.ndarray, right: np.ndarray) -> float:
    left_boundary, right_boundary = _boundary(left), _boundary(right)
    if not left_boundary.any() or not right_boundary.any():
        return float(math.hypot(*left.shape))
    to_left = cv2.distanceTransform((~left_boundary).astype(np.uint8), cv2.DIST_L2, cv2.DIST_MASK_PRECISE)
    to_right = cv2.distanceTransform((~right_boundary).astype(np.uint8), cv2.DIST_L2, cv2.DIST_MASK_PRECISE)
    return float(max(np.max(to_left[right_boundary]), np.max(to_right[left_boundary])))


# 汇总 raw 与 candidate 的质量指标,返回字典字段:
#   raw_edge_score / refined_edge_score:raw、candidate 各自边界的平均边缘强度;
#   raw_iou:两 mask 前景(> 0)的 IoU;
#   area_ratio:candidate 前景面积 / raw 前景面积;
#   hausdorff:两边界间的对称 Hausdorff 距离。
# 无副作用。
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


# 构造预期性拒绝结果:mask 为 raw 的原样副本(候选字节级保留,不改写),
# 附拒绝原因与已算出的指标。
def _fallback(raw: np.ndarray, reason: str, scores: dict[str, float]) -> EdgeRefinement:
    return EdgeRefinement(False, raw.copy(), reason, scores)


# 检查候选 mask 的拓扑是否满足 V1 单环要求。
# 返回:None 表示通过;否则返回原因字符串——连通分量数(含背景)不为 2
#   或轮廓数不为 1 返回 "multiple components";存在带父轮廓的内轮廓
#   (即孔)返回 "hole"。
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


# 边缘精化主入口(门禁概览见英文 docstring)。
# 参数 image:与 raw_mask 同分辨率的帧图像(灰度/BGR/BGRA);
#   raw_mask:待精化的 2D raw mask(0/255 或 0/1);band_radius:形态学带
#   半径(像素),决定确定前景与可能区域的范围;roi_padding:ROI 在膨胀
#   包围盒之外追加的边距(像素)。
# 返回:EdgeRefinement;接受时 mask 为 0/255 精化结果,拒绝时为 raw mask
#   原样副本,reason 给出第一条命中的拒绝原因。
# 异常:参数非法或图像/mask 尺寸不符抛 ValueError;精化指标出现非有限值
#   属运行时故障,同样抛 ValueError(而非预期拒绝)。
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
    # 二值化 raw mask:最大值 > 1 按 0/255 处理(阈值 128),否则按 0/1 处理。
    raw = np.asarray(raw_original >= (128 if raw_original.size and raw_original.max() > 1 else 1), dtype=np.uint8)
    edges = _edge_map(gray)
    # 先算一份 candidate=raw 的"未改动"指标,供早期拒绝路径复用。
    unchanged_scores = _scores(edges, raw, raw)
    # 空 mask 无可精化,预期拒绝。
    if not raw.any():
        return _fallback(raw_original, "raw mask is empty", unchanged_scores)

    # 用椭圆结构元腐蚀/膨胀构造带状区域:腐蚀内为确定前景,膨胀与腐蚀
    # 之间为可能区域,是 GrabCut 的搜索空间。
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * band_radius + 1, 2 * band_radius + 1))
    eroded = cv2.erode(raw, kernel, iterations=1)
    # mask 过窄、腐蚀后为空:没有可靠的确定前景,预期拒绝。
    if not eroded.any():
        return _fallback(raw_original, "definite foreground is empty", unchanged_scores)
    dilated = cv2.dilate(raw, kernel, iterations=1)
    # raw 与腐蚀/膨胀之间任一侧没有过渡带,GrabCut 无可调整空间,预期拒绝。
    if not np.any(raw & ~eroded) or not np.any(dilated & ~raw):
        return _fallback(raw_original, "refinement band is empty", unchanged_scores)

    # ROI 取膨胀区域的包围盒并向四周外扩 roi_padding(裁到图像边界);
    # ROI 为空或像素数超过 MAX_ROI_PIXELS 时预期拒绝。
    x, y, width, height = cv2.boundingRect(dilated)
    x0, y0 = max(0, x - roi_padding), max(0, y - roi_padding)
    x1 = min(raw.shape[1], x + width + roi_padding)
    y1 = min(raw.shape[0], y + height + roi_padding)
    if x1 <= x0 or y1 <= y0 or (x1 - x0) * (y1 - y0) > MAX_ROI_PIXELS:
        return _fallback(raw_original, "refinement ROI is invalid", unchanged_scores)

    roi_raw = raw[y0:y1, x0:x1]
    roi_eroded = eroded[y0:y1, x0:x1]
    roi_dilated = dilated[y0:y1, x0:x1]
    # 以 mask 模式初始化 GrabCut:膨胀外=确定背景(GC_BGD),膨胀内=可能
    # 背景(GC_PR_BGD),raw 内=可能前景(GC_PR_FGD),腐蚀内=确定前景
    # (GC_FGD),迭代 3 次;两个模型数组是 API 要求的 GMM 输出缓冲,
    # 不携带先验。灰度 ROI 先转 BGR(grabCut 要求 3 通道输入)。
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
    # GrabCut 结束后取确定前景+可能前景为候选,并从 ROI 坐标写回全图尺寸。
    candidate = np.zeros_like(raw)
    candidate[y0:y1, x0:x1] = candidate_roi
    # 计算候选指标;出现非有限值属于运行时故障,抛 ValueError 而不是降级。
    scores = _scores(edges, raw, candidate)
    if not all(math.isfinite(value) for value in scores.values()):
        raise ValueError("edge refinement produced non-finite scores")

    # 以下为预期性门禁:按序检查,命中即返回 raw mask 原样副本与原因。
    topology_reason = _topology_reason(candidate)
    if topology_reason is not None:
        return _fallback(raw_original, topology_reason, scores)
    # 候选触碰 ROI 边界说明目标可能被裁剪、结果不可验证,预期拒绝。
    if candidate_roi[0].any() or candidate_roi[-1].any() or candidate_roi[:, 0].any() or candidate_roi[:, -1].any():
        return _fallback(raw_original, "crop boundary", scores)
    # IoU 不足时,若面积比同样越界则并入同一条原因,便于一次看清门禁状态。
    if scores["raw_iou"] < MIN_RAW_IOU:
        reason = "raw IoU below 0.85"
        if not MIN_AREA_RATIO <= scores["area_ratio"] <= MAX_AREA_RATIO:
            reason += "; area ratio outside [0.80, 1.25]"
        return _fallback(raw_original, reason, scores)
    if not MIN_AREA_RATIO <= scores["area_ratio"] <= MAX_AREA_RATIO:
        return _fallback(raw_original, "area ratio outside [0.80, 1.25]", scores)
    if scores["hausdorff"] > MAX_HAUSDORFF:
        return _fallback(raw_original, "Hausdorff above 6", scores)
    # 精化必须有收益:refined 边界分数至少要比 raw 高出 EDGE_GAIN_THRESHOLD。
    if scores["refined_edge_score"] < scores["raw_edge_score"] + EDGE_GAIN_THRESHOLD:
        return _fallback(raw_original, "edge gain below 0.01", scores)
    return EdgeRefinement(True, candidate * 255, "accepted", scores)
