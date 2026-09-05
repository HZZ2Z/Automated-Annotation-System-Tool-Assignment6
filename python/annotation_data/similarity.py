"""Frame similarity and contiguous-range helpers."""

import math
from numbers import Real

import cv2
import numpy as np


def normalized_mad(left: np.ndarray, right: np.ndarray) -> float:
    """Return a bounded grayscale mean absolute difference for two images."""
    _validate_image(left, "left")
    _validate_image(right, "right")
    if left.ndim != right.ndim or _channel_count(left) != _channel_count(right):
        raise ValueError("left and right images must have matching channel counts")

    left_gray = _to_gray(left)
    right_gray = _to_gray(right)
    difference = float(np.mean(np.abs(left_gray - right_gray)) / 255.0)
    return float(np.clip(difference, 0.0, 1.0))


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


def _channel_count(image: np.ndarray) -> int:
    return 1 if image.ndim == 2 else int(image.shape[2])


def _to_gray(image: np.ndarray) -> np.ndarray:
    resized = cv2.resize(image, (64, 64), interpolation=cv2.INTER_AREA)
    if image.ndim == 2 or image.shape[2] == 1:
        gray = resized if resized.ndim == 2 else resized[:, :, 0]
    elif image.shape[2] == 3:
        gray = cv2.cvtColor(resized, cv2.COLOR_BGR2GRAY)
    else:
        gray = cv2.cvtColor(resized, cv2.COLOR_BGRA2GRAY)
    return gray.astype(np.float32)


def _validate_score(value: object, name: str) -> None:
    if isinstance(value, bool) or not isinstance(value, Real):
        raise TypeError(f"{name} must be a finite number")
    if not math.isfinite(float(value)) or not 0.0 <= float(value) <= 1.0:
        raise ValueError(f"{name} must be between 0 and 1")
