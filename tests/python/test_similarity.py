from pathlib import Path

import cv2
import numpy as np
import pytest

from annotation_data.sample import generate_sample
from annotation_data.similarity import (
    contiguous_run,
    gray64_area_mad,
    normalized_mad,
    similarity_gate,
)


def test_identical_frames_have_zero_distance() -> None:
    frame = np.full((32, 32, 3), 64, dtype=np.uint8)

    assert normalized_mad(frame, frame) == 0.0


def test_normalized_mad_is_finite_and_bounded_for_valid_images() -> None:
    black = np.zeros((20, 20, 3), dtype=np.uint8)
    white = np.full((10, 15, 3), 255, dtype=np.uint8)

    score = normalized_mad(black, white)

    assert np.isfinite(score)
    assert 0.0 <= score <= 1.0
    assert score == 1.0


def test_gray64_area_mad_normalizes_bgr_bgra_and_grayscale() -> None:
    black = np.zeros((96, 80), dtype=np.uint8)
    gray = np.full((96, 80), 51, dtype=np.uint8)
    bgr = cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR)
    bgra = cv2.cvtColor(gray, cv2.COLOR_GRAY2BGRA)

    assert gray64_area_mad(black, gray) == pytest.approx(0.2)
    assert gray64_area_mad(cv2.cvtColor(black, cv2.COLOR_GRAY2BGR), bgr) == pytest.approx(0.2)
    assert gray64_area_mad(cv2.cvtColor(black, cv2.COLOR_GRAY2BGRA), bgra) == pytest.approx(0.2)


def test_similarity_gate_requires_adjacent_and_keyframe_scores_below_threshold() -> None:
    key = np.zeros((72, 88), dtype=np.uint8)
    previous = np.full((72, 88), 10, dtype=np.uint8)
    target = np.full((72, 88), 20, dtype=np.uint8)

    result = similarity_gate(previous, target, key, threshold=0.06)

    assert result == {
        "accepted": False,
        "adjacent_mad": pytest.approx(10 / 255),
        "keyframe_mad": pytest.approx(20 / 255),
    }


def test_similarity_gate_rejects_score_equal_to_threshold() -> None:
    key = np.zeros((64, 64), dtype=np.uint8)
    target = np.full((64, 64), 51, dtype=np.uint8)

    result = similarity_gate(key, target, key, threshold=0.2)

    assert result["accepted"] is False
    assert result["adjacent_mad"] == pytest.approx(0.2)
    assert result["keyframe_mad"] == pytest.approx(0.2)


@pytest.mark.parametrize(
    "image",
    [
        np.zeros((2, 2, 3), dtype=np.complex64),
        np.zeros((2, 2, 3), dtype=np.uint64),
        np.zeros((2, 2, 3), dtype=np.float16),
        np.full((2, 2, 3), 256.0, dtype=np.float32),
    ],
)
def test_normalized_mad_rejects_unsupported_pixel_arrays(image: np.ndarray) -> None:
    valid = np.zeros((2, 2, 3), dtype=np.uint8)

    with pytest.raises((TypeError, ValueError)):
        normalized_mad(image, valid)


@pytest.mark.parametrize(
    ("left", "right", "error"),
    [
        ("not an image", np.zeros((2, 2, 3), dtype=np.uint8), TypeError),
        (np.zeros((0, 2, 3), dtype=np.uint8), np.zeros((2, 2, 3), dtype=np.uint8), ValueError),
        (np.zeros((2, 2), dtype=np.uint8), np.zeros((2, 2, 3), dtype=np.uint8), ValueError),
        (np.zeros((2, 2, 2), dtype=np.uint8), np.zeros((2, 2, 2), dtype=np.uint8), ValueError),
    ],
)
def test_normalized_mad_rejects_incompatible_images(
    left: object, right: np.ndarray, error: type[Exception]
) -> None:
    with pytest.raises(error):
        normalized_mad(left, right)  # type: ignore[arg-type]


def test_contiguous_run_stops_at_threshold_boundaries() -> None:
    scores = [0.4, 0.01, 0.01, 0.03, 0.01]

    assert contiguous_run(scores, keyframe=2, threshold=0.02) == (1, 3)


def test_contiguous_run_does_not_cross_an_equal_threshold_score() -> None:
    scores = [0.02, 0.01]

    assert contiguous_run(scores, keyframe=1, threshold=0.02) == (1, 2)


@pytest.mark.parametrize(
    ("scores", "keyframe", "threshold"),
    [
        ([0.1], -1, 0.02),
        ([0.1], 2, 0.02),
        ([float("nan")], 0, 0.02),
        ([1.1], 0, 0.02),
        ([0.1], 0, float("nan")),
        ([0.1], 0, 1.1),
    ],
)
def test_contiguous_run_rejects_invalid_score_and_frame_inputs(
    scores: list[float], keyframe: int, threshold: float
) -> None:
    with pytest.raises((TypeError, ValueError)):
        contiguous_run(scores, keyframe=keyframe, threshold=threshold)


def test_sample_similarity_run_has_clear_boundaries(tmp_path: Path) -> None:
    sample_dir = tmp_path / "sample"
    generate_sample(sample_dir)
    frames = [
        cv2.imread(str(sample_dir / f"frames/frame_{frame:06d}.png"), cv2.IMREAD_COLOR)
        for frame in range(120)
    ]
    scores = [normalized_mad(frames[index], frames[index + 1]) for index in range(119)]

    assert contiguous_run(scores, keyframe=50, threshold=0.02) == (40, 59)
    assert scores[39] >= 0.02
    assert scores[59] >= 0.02
