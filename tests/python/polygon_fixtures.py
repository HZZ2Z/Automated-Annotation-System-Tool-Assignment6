"""Independent rendered scenes and mask truth for polygon propagation checks."""

from pathlib import Path
import hashlib

import cv2
import numpy as np


SHAPE = (192, 224)
POLYGON = [[62, 48], [132, 48], [132, 74], [92, 74], [92, 120], [62, 120]]


def complex_mask():
    mask = np.zeros((1024, 1024), np.uint8)
    mask[80:944, 80:944] = 255
    for coordinate in range(84, 500, 4):
        mask[74:80, coordinate:coordinate + 2] = 255
        mask[944:950, coordinate:coordinate + 2] = 255
        mask[coordinate:coordinate + 2, 74:80] = 255
        mask[coordinate:coordinate + 2, 944:950] = 255
    return mask


def polygon_mask(polygon, shape=SHAPE):
    mask = np.zeros(shape, np.uint8)
    cv2.fillPoly(mask, [np.rint(polygon).astype(np.int32)], 1)
    return mask


def iou(left, right):
    left, right = left > 0, right > 0
    return float(np.count_nonzero(left & right) / np.count_nonzero(left | right))


def scene_layers(seed=27, shape=SHAPE):
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[:shape[0], :shape[1]]
    grain = cv2.GaussianBlur(rng.normal(0, 1, shape).astype(np.float32), (0, 0), 0.8)
    foreground = np.clip(155 + 60 * grain + 25 * np.sin(x * 0.37) * np.cos(y * 0.31), 70, 235).astype(np.uint8)
    background = np.clip(30 + 7 * cv2.GaussianBlur(rng.normal(0, 1, shape).astype(np.float32), (0, 0), 1), 0, 255).astype(np.uint8)
    return foreground, background


def translated_scene(directory: Path, offsets, *, key=0, polygon=POLYGON, shape=SHAPE):
    directory.mkdir(parents=True, exist_ok=True)
    foreground, background = scene_layers(shape=shape)
    frames, truths, polygons = [], {}, {}
    for index, (dx, dy) in enumerate(offsets):
        # The oracle is the literal polygon translated by the known rendering transform.
        truth_polygon = [[x + dx, y + dy] for x, y in polygon]
        truth = polygon_mask(truth_polygon, shape)
        transformed = cv2.warpAffine(foreground, np.float32([[1, 0, dx], [0, 1, dy]]), (shape[1], shape[0]))
        image = np.where(truth > 0, transformed, background).astype(np.uint8)
        path = directory / f"frame-{index}.png"
        assert cv2.imwrite(str(path), image)
        frames.append({"index": index, "frame_id": 100 + index, "image_path": str(path),
                       "image_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                       "entry_digest": hashlib.sha256(f"entry:{index}".encode()).hexdigest(),
                       "record_digest": hashlib.sha256(f"record:{index}".encode()).hexdigest(),
                       "verified": False})
        truths[index], polygons[index] = truth, truth_polygon
    region = {"id": "poly-1", "class": "grasper", "kind": "instrument", "polygon": polygons[key], "track_id": "T7", "conf": 0.83}
    return {"schema_version": 3, "key_index": key, "similarity_threshold": 1.0,
            "frame_step": 1, "frames": frames, "regions": [region]}, truths


def deformed_scene(directory: Path, mode):
    request, _ = translated_scene(directory, [(0, 0)] * 4)
    foreground, background = scene_layers()
    mask = polygon_mask(POLYGON)
    truths = {}
    for index, frame in enumerate(request["frames"]):
        if mode == "rotation":
            transform = cv2.getRotationMatrix2D((94, 82), 4 * index, 1)
            transform[:, 2] += (2 * index, index)
            points = np.asarray(POLYGON) @ transform[:, :2].T + transform[:, 2]
            truth = polygon_mask(points)
            appearance = cv2.warpAffine(foreground, transform, (SHAPE[1], SHAPE[0]))
        else:
            yy, xx = np.mgrid[:SHAPE[0], :SHAPE[1]].astype(np.float32)
            # Known inverse rendering map: horizontal bending varies with y.
            source_x = xx - 2 * index - 4 * index * np.sin((yy - 48) * np.pi / 72)
            truth = cv2.remap(mask, source_x, yy, cv2.INTER_NEAREST)
            appearance = cv2.remap(foreground, source_x, yy, cv2.INTER_LINEAR)
        image = np.where(truth > 0, appearance, background).astype(np.uint8)
        assert cv2.imwrite(frame["image_path"], image)
        refresh_frame_digest(frame)
        truths[index] = truth
    return request, truths


def boundary_offset_scene(directory: Path):
    """目标边界向外移动两像素；纹理保持可观测，真值独立于传播结果。"""
    request, _ = translated_scene(directory, [(0, 0), (0, 0)])
    raw = polygon_mask(request["regions"][0]["polygon"])
    truth = cv2.dilate(raw, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)))
    foreground, background = scene_layers()
    source = np.where(raw > 0, foreground, background).astype(np.uint8)
    target = np.where(truth > 0, foreground, background).astype(np.uint8)
    assert cv2.imwrite(request["frames"][0]["image_path"], source)
    assert cv2.imwrite(request["frames"][1]["image_path"], target)
    refresh_frame_digest(request["frames"][0])
    refresh_frame_digest(request["frames"][1])
    return request, {0: raw, 1: truth}
def refresh_frame_digest(frame):
    frame["image_sha256"] = hashlib.sha256(Path(frame["image_path"]).read_bytes()).hexdigest()
