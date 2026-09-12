# 帧间相似度度量与连续区间判定工具。
#
# 用途:提供版本化度量 gray64-area-mad-v1(两幅图缩放到 64×64 灰度后的
# 归一化平均绝对差),以及基于该度量的传播门禁(similarity_gate:相邻帧与
# 固定关键帧的距离都必须低于阈值)和连续帧段求解(contiguous_run)。
#
# 角色与协作:polygon_propagation 用 similarity_gate 做传播前的相似度门禁,
# frame_source 与 sample 用 normalized_mad 判断近似重复帧,
# run_endoscapes_poly_acceptance 复用门禁做验收;与 polygon_flow 解耦——
# 先由本模块确认画面足够相似,才开始计算光流。
"""Frame similarity and contiguous-range helpers."""

import math
from numbers import Real

import cv2
import numpy as np


# 计算两幅图像的 gray64-area-mad-v1 距离(值越小越相似)。
# 参数 left/right:待比较的 uint8 ndarray 图像,两者通道数必须一致。
# 算法:各自缩放到 64×64 并转灰度(float32),逐像素绝对差的均值除以 255
# 归一化,再截断到 [0,1]。
# 返回:float 距离;0.0 表示缩放后逐像素相同。
# 异常:输入不是合法 uint8 图像(见 _validate_image),或两者通道数不一致
#      时抛 TypeError/ValueError。
def gray64_area_mad(left: np.ndarray, right: np.ndarray) -> float:
    """Return gray64-area-mad-v1 for two uint8 images."""
    _validate_image(left, "left")
    _validate_image(right, "right")
    if left.ndim != right.ndim or _channel_count(left) != _channel_count(right):
        raise ValueError("left and right images must have matching channel counts")

    left_gray = _to_gray(left)
    right_gray = _to_gray(right)
    difference = float(np.mean(np.abs(left_gray - right_gray)) / 255.0)
    return float(np.clip(difference, 0.0, 1.0))


# 兼容别名:与 gray64_area_mad 完全等价,供沿用旧名称的调用方使用。
def normalized_mad(left: np.ndarray, right: np.ndarray) -> float:
    """Compatibility name for the versioned gray64 metric."""
    return gray64_area_mad(left, right)


# 传播门禁:target 必须同时「足够像上一帧」且「足够像固定关键帧」。
# 参数 previous/target/keyframe:同源的三幅 uint8 图像(上一帧、目标帧、
#      固定关键帧);threshold:0..1 的相似度阈值,严格小于才算通过。
# 返回:{"accepted": bool, "adjacent_mad": float, "keyframe_mad": float}。
# 异常:threshold 不合法时抛 TypeError/ValueError(见 _validate_score);
#      图像不合法时由 gray64_area_mad 抛错。
def similarity_gate(
    previous: np.ndarray,
    target: np.ndarray,
    keyframe: np.ndarray,
    threshold: float,
) -> dict[str, float | bool]:
    """Require both adjacent and fixed-keyframe distances below threshold."""
    _validate_score(threshold, "threshold")
    adjacent = gray64_area_mad(previous, target)
    fixed = gray64_area_mad(keyframe, target)
    return {
        "accepted": adjacent < threshold and fixed < threshold,
        "adjacent_mad": adjacent,
        "keyframe_mad": fixed,
    }


# 求「与关键帧连通」的连续帧号闭区间 [start, end]。
# 参数 scores:scores[i] 表示帧 i 到帧 i+1 的转移距离(共 len(scores) 个);
#      keyframe:关键帧帧号,合法取值 0..len(scores);threshold:判定阈值,
#      默认 0.02。
# 返回:(start, end):从 keyframe 出发向两侧扩展,只要相邻转移距离严格
#      小于 threshold 就继续延伸,返回含 keyframe 的闭区间端点。
# 异常:scores 不是 list、keyframe 不是 int、keyframe 越界、threshold 或
#      任一分数不合法时抛 TypeError/ValueError。
def contiguous_run(
    scores: list[float],
    keyframe: int,
    threshold: float = 0.02,
) -> tuple[int, int]:
    """Find frames connected to ``keyframe`` by transitions below ``threshold``.

    ``scores[i]`` measures the transition from frame ``i`` to frame ``i + 1``.
    """
    if not isinstance(scores, list):
        raise TypeError("scores must be a list")
    if type(keyframe) is not int:
        raise TypeError("keyframe must be an integer")
    if not 0 <= keyframe <= len(scores):
        raise ValueError("keyframe is outside the score sequence")
    _validate_score(threshold, "threshold")
    for index, score in enumerate(scores):
        _validate_score(score, f"scores[{index}]")

    start = keyframe
    end = keyframe
    while start > 0 and scores[start - 1] < threshold:
        start -= 1
    while end < len(scores) and scores[end] < threshold:
        end += 1
    return start, end


# 内部校验:image 必须是非空的 ndarray uint8 2D 灰度图或 1/3/4 通道 3D 彩图,
# 否则抛 TypeError(类型不符)或 ValueError(空/形状不符)。
def _validate_image(image: object, name: str) -> None:
    if not isinstance(image, np.ndarray):
        raise TypeError(f"{name} must be a numpy array")
    if image.size == 0:
        raise ValueError(f"{name} must not be empty")
    if image.ndim not in (2, 3):
        raise ValueError(f"{name} must be a 2D grayscale or 3D color image")
    if image.ndim == 3 and image.shape[2] not in (1, 3, 4):
        raise ValueError(f"{name} must have 1, 3, or 4 channels")
    if image.dtype != np.uint8:
        raise TypeError(f"{name} must use uint8 pixels")


# 返回通道数:2D 灰度图视为 1,3D 图取第三维长度。
def _channel_count(image: np.ndarray) -> int:
    return 1 if image.ndim == 2 else int(image.shape[2])


# 统一转成 64×64 float32 单通道灰度:先 INTER_AREA 面积缩放,再按原通道数
# 处理(灰度/单通道直接取用,3 通道按 BGR,4 通道按 BGRA 转灰度)。
def _to_gray(image: np.ndarray) -> np.ndarray:
    resized = cv2.resize(image, (64, 64), interpolation=cv2.INTER_AREA)
    if image.ndim == 2 or image.shape[2] == 1:
        gray = resized if resized.ndim == 2 else resized[:, :, 0]
    elif image.shape[2] == 3:
        gray = cv2.cvtColor(resized, cv2.COLOR_BGR2GRAY)
    else:
        gray = cv2.cvtColor(resized, cv2.COLOR_BGRA2GRAY)
    return gray.astype(np.float32)


# 内部校验:分数必须是有限实数(显式排除 bool)且落在 [0,1],否则抛
# TypeError(类型不符)或 ValueError(非有限或越界)。
def _validate_score(value: object, name: str) -> None:
    if isinstance(value, bool) or not isinstance(value, Real):
        raise TypeError(f"{name} must be a finite number")
    if not math.isfinite(float(value)) or not 0.0 <= float(value) <= 1.0:
        raise ValueError(f"{name} must be between 0 and 1")
