import cv2
import numpy as np
import pytest

from annotation_data.polygon_edge_refinement import refine


SHAPE = (128, 144)


def _scene():
    image = np.full(SHAPE, 25, np.uint8)
    image[30:98, 36:112] = 220
    truth = np.zeros(SHAPE, np.uint8)
    truth[30:98, 36:112] = 255
    raw = np.zeros(SHAPE, np.uint8)
    raw[32:96, 38:110] = 255
    return image, raw, truth


def _iou(left, right):
    left, right = left > 0, right > 0
    return np.count_nonzero(left & right) / np.count_nonzero(left | right)


def _install_candidate(monkeypatch, candidate, raw):
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (13, 13))
    x, y, width, height = cv2.boundingRect(cv2.dilate(raw, kernel))
    x0, y0 = max(0, x - 8), max(0, y - 8)
    x1, y1 = min(raw.shape[1], x + width + 8), min(raw.shape[0], y + height + 8)

    def fake_grabcut(_image, mask, _rect, _bg, _fg, _iterations, _mode):
        mask[:] = cv2.GC_BGD
        mask[candidate[y0:y1, x0:x1] > 0] = cv2.GC_FGD

    monkeypatch.setattr(cv2, "grabCut", fake_grabcut)


def test_strong_nearby_edge_improves_mask_and_is_accepted(monkeypatch):
    image, raw, truth = _scene()
    _install_candidate(monkeypatch, truth, raw)

    result = refine(image, raw)

    assert result.accepted, result
    assert _iou(result.mask, truth) > _iou(raw, truth)
    assert result.scores["refined_edge_score"] >= result.scores["raw_edge_score"] + 0.01


def test_real_grabcut_accepts_the_deterministic_strong_edge_scene():
    image, raw, truth = _scene()

    result = refine(image, raw)

    assert result.accepted, result
    assert _iou(result.mask, truth) > _iou(raw, truth)


def test_weak_edge_falls_back_to_exact_raw_mask(monkeypatch):
    _, raw, truth = _scene()
    _install_candidate(monkeypatch, truth, raw)

    result = refine(np.full(SHAPE, 100, np.uint8), raw)

    assert not result.accepted
    assert result.reason == "edge gain below 0.01"
    assert np.array_equal(result.mask, raw)


def test_thin_seed_with_empty_eroded_foreground_falls_back(monkeypatch):
    image = np.full(SHAPE, 100, np.uint8)
    raw = np.zeros(SHAPE, np.uint8)
    raw[40:80, 60:64] = 255
    called = False

    def forbidden(*_args):
        nonlocal called
        called = True

    monkeypatch.setattr(cv2, "grabCut", forbidden)
    result = refine(image, raw)

    assert not result.accepted and result.reason == "definite foreground is empty"
    assert not called


@pytest.mark.parametrize(
    ("mutation", "reason"),
    [
        ("multi", "multiple components"),
        ("hole", "hole"),
        ("boundary", "crop boundary"),
        ("area", "area ratio"),
        ("iou", "raw IoU"),
        ("distance", "Hausdorff"),
    ],
)
def test_unsafe_grabcut_shape_falls_back(monkeypatch, mutation, reason):
    image, raw, truth = _scene()
    candidate = truth.copy()
    if mutation == "multi":
        candidate[20:24, 27:31] = 255
    elif mutation == "hole":
        candidate[50:60, 60:70] = 0
    elif mutation == "boundary":
        candidate[18:30, 36:50] = 255
    elif mutation == "area":
        candidate[:] = 0
        candidate[40:85, 50:98] = 255
    elif mutation == "iou":
        candidate[:] = 0
        candidate[32:96, 44:116] = 255
    else:
        candidate = raw.copy()
        candidate[55:65, 109:117] = 255
    _install_candidate(monkeypatch, candidate, raw)

    result = refine(image, raw)

    assert not result.accepted
    assert reason.lower() in result.reason.lower()
    assert np.array_equal(result.mask, raw)
    assert all(np.isfinite(value) for value in result.scores.values())


def test_opencv_runtime_error_is_not_silently_converted_to_fallback(monkeypatch):
    image, raw, _ = _scene()

    def broken(*_args):
        raise cv2.error("grabcut failed")

    monkeypatch.setattr(cv2, "grabCut", broken)
    with pytest.raises(cv2.error):
        refine(image, raw)
