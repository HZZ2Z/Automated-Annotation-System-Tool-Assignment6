"""Read-only consumer smoke for a detached ``training_coco_v1`` package.

This deliberately starts from the package directory.  It never accepts or
consults a Source workspace, Godot cache, saved review session, or original
metadata path.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import cv2
import numpy as np

from annotation_data.coco_export import _strict_json, decode_coco_rle
from annotation_data.coco_package_validator import validate_coco_package


def _failure(message: str, *, path: str = "") -> dict[str, Any]:
    problem: dict[str, Any] = {"code": "PACKAGE_LOAD_FAILED", "message": message}
    if path:
        problem["path"] = path
    return {
        "success": False,
        "errors": [f"PACKAGE_LOAD_FAILED: {message}"],
        "issues": [problem],
        "package_path": path,
        "package_id": "",
        "task": "",
        "summary": {},
    }


def _decode_polygon_mask(segmentation: list[Any], width: int, height: int) -> np.ndarray:
    mask = np.zeros((height, width), dtype=np.uint8)
    polygons: list[np.ndarray] = []
    for flat in segmentation:
        if not isinstance(flat, list) or len(flat) < 6 or len(flat) % 2:
            raise ValueError("polygon segmentation is malformed")
        coordinates = np.asarray(flat, dtype=np.float64).reshape((-1, 2))
        if not np.isfinite(coordinates).all():
            raise ValueError("polygon segmentation contains a non-finite coordinate")
        points = np.rint(coordinates).astype(np.int32)
        polygons.append(points)
    cv2.fillPoly(mask, polygons, 1)
    if not np.any(mask):
        raise ValueError("decoded polygon mask is empty")
    return mask


def load_coco_package(directory: str | Path) -> dict[str, Any]:
    """Validate and exhaustively enumerate one self-contained package."""

    root = Path(directory).absolute()
    problems = validate_coco_package(root)
    if problems:
        return {
            "success": False,
            "errors": [f"{item['code']}: {item['message']}" for item in problems],
            "issues": problems,
            "package_path": str(root),
            "package_id": "",
            "task": "",
            "summary": {},
        }
    try:
        manifest = _strict_json(root / "manifest.json")
        coco = _strict_json(root / manifest["annotation_path"])
        categories = {item["id"]: item for item in coco["categories"]}
        annotations_by_image: dict[int, list[dict[str, Any]]] = {
            image["id"]: [] for image in coco["images"]
        }
        for annotation in coco["annotations"]:
            annotations_by_image[annotation["image_id"]].append(annotation)

        decoded_segmentations = 0
        negative_images = 0
        for image in coco["images"]:
            image_path = root / manifest["image_root"] / image["file_name"]
            raw = image_path.read_bytes()
            decoded = cv2.imdecode(np.frombuffer(raw, dtype=np.uint8), cv2.IMREAD_UNCHANGED)
            if decoded is None or decoded.shape[:2] != (image["height"], image["width"]):
                raise ValueError(f"cannot decode image with declared dimensions: {image['file_name']}")
            objects = annotations_by_image[image["id"]]
            negative_images += not objects
            for annotation in objects:
                if annotation["category_id"] not in categories:
                    raise ValueError(f"annotation references an unknown category: {annotation['id']}")
                if "segmentation" not in annotation:
                    continue
                segmentation = annotation["segmentation"]
                mask = (
                    decode_coco_rle(segmentation)
                    if isinstance(segmentation, dict)
                    else _decode_polygon_mask(segmentation, image["width"], image["height"])
                )
                if mask.shape != (image["height"], image["width"]) or not np.any(mask):
                    raise ValueError(f"annotation mask cannot be decoded: {annotation['id']}")
                decoded_segmentations += 1
    except (KeyError, OSError, TypeError, ValueError) as exc:
        return _failure(str(exc), path=str(root))

    return {
        "success": True,
        "errors": [],
        "issues": [],
        "package_path": str(root),
        "package_id": manifest["package_id"],
        "task": manifest["task"],
        "summary": {
            "images": len(coco["images"]),
            "annotations": len(coco["annotations"]),
            "categories": len(coco["categories"]),
            "negative_images": int(negative_images),
            "decoded_segmentations": decoded_segmentations,
        },
    }
