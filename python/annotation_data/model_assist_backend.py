"""Safe job-scoped adapter around the official SAM 2 image predictor."""
from __future__ import annotations

import hashlib
import math
import os
from pathlib import Path, PurePosixPath
import stat
import struct
from typing import Any, Callable
import zlib

import cv2
import numpy as np


MAX_INPUT_BYTES = 64 * 1024 * 1024
MAX_IMAGE_PIXELS = 32 * 1024 * 1024
MAX_CANDIDATES = 3


class ModelAssistBackend:
    """Own one predictor, one image embedding and job-local candidate files."""

    def __init__(
        self,
        job_dir: str | Path,
        *,
        config_path: str,
        checkpoint_path: str,
        device: str = "auto",
        predictor_factory: Callable[[str, str, str], Any] | None = None,
    ) -> None:
        raw_root = Path(job_dir)
        if raw_root.is_symlink():
            raise ValueError("job directory must not be a symlink")
        try:
            root = raw_root.resolve(strict=True)
        except OSError as exc:
            raise ValueError(f"job directory cannot be resolved: {exc}") from exc
        if not root.is_dir():
            raise ValueError("job directory must be a directory")
        self.job_dir = root
        self.config_path = config_path
        self.checkpoint_path = checkpoint_path
        self.device = device
        self.max_input_bytes = MAX_INPUT_BYTES
        self.max_image_pixels = MAX_IMAGE_PIXELS
        self._predictor_factory = predictor_factory
        self._predictor: Any = None
        self._actual_device = ""
        self._image_path: Path | None = None
        self._image_sha256 = ""
        self._image_size = (0, 0)
        self._prediction_serial = 0
        self._closed = False

    def hello(self) -> dict[str, Any]:
        if self._closed:
            raise RuntimeError("model assist backend is shut down")
        if self._predictor is None:
            factory = self._predictor_factory or self._official_predictor
            requested_device = self.device
            self._predictor = factory(self.config_path, self.checkpoint_path, requested_device)
            if self._predictor is None or not hasattr(self._predictor, "set_image") or not hasattr(self._predictor, "predict"):
                raise RuntimeError("predictor factory returned an invalid SAM image predictor")
            self._actual_device = getattr(
                self._predictor,
                "model_assist_device",
                requested_device if requested_device in {"cpu", "cuda"} else "cpu",
            )
        checkpoint_digest = ""
        checkpoint = Path(self.checkpoint_path)
        if checkpoint.is_file() and not checkpoint.is_symlink():
            checkpoint_digest = _sha256_file(checkpoint)
        return {
            "backend": "sam2-image-predictor",
            "persistent": True,
            "device": self._actual_device,
            "checkpoint_sha256": checkpoint_digest,
        }

    @staticmethod
    def _official_predictor(config_path: str, checkpoint_path: str, requested_device: str) -> Any:
        if requested_device not in {"auto", "cpu", "cuda"}:
            raise RuntimeError("device must be auto, cpu or cuda")
        raw_config = Path(config_path)
        raw_checkpoint = Path(checkpoint_path)
        if not raw_config.is_absolute() or not raw_config.is_file():
            raise RuntimeError("SAM2 config must be an absolute readable file")
        if not raw_checkpoint.is_absolute() or not raw_checkpoint.is_file():
            raise RuntimeError("SAM2 checkpoint must be an absolute readable file")
        try:
            config = raw_config.resolve(strict=True)
            checkpoint = raw_checkpoint.resolve(strict=True)
        except OSError as exc:
            raise RuntimeError(f"SAM2 config or checkpoint cannot be resolved: {exc}") from exc
        import torch
        import sam2
        from sam2.build_sam import build_sam2
        from sam2.sam2_image_predictor import SAM2ImagePredictor

        config_name = ""
        for raw_package_root in sam2.__path__:
            try:
                package_root = Path(raw_package_root).resolve(strict=True)
                relative = config.relative_to(package_root)
            except (OSError, ValueError):
                continue
            if relative.parts and relative.parts[0] == "configs":
                config_name = relative.as_posix()
                break
        if not config_name:
            raise RuntimeError(
                "SAM2 config must be inside the installed sam2 package configs directory"
            )

        if requested_device == "cuda" and not torch.cuda.is_available():
            raise RuntimeError("CUDA was requested but is unavailable")
        actual_device = "cuda" if requested_device == "cuda" or (
            requested_device == "auto" and torch.cuda.is_available()
        ) else "cpu"
        # Hydra's package search path accepts the config name relative to the
        # installed sam2 module, even though the UI contract uses an absolute file.
        model = build_sam2(config_name, str(checkpoint), device=actual_device)
        predictor = SAM2ImagePredictor(model)
        predictor.model_assist_device = actual_device
        return predictor

    def set_image(
        self,
        image_path: str,
        expected_sha256: str,
        *,
        width: int,
        height: int,
    ) -> dict[str, Any]:
        self.hello()
        path, payload = self._read_job_png(image_path, expected_sha256, "image")
        image = _decode_png(payload, cv2.IMREAD_COLOR, "image")
        actual_height, actual_width = image.shape[:2]
        if (width, height) != (actual_width, actual_height):
            raise ValueError("image dimensions do not match the descriptor")
        if actual_width * actual_height > self.max_image_pixels:
            raise ValueError("image exceeds the configured pixels limit")
        if self._image_sha256 == expected_sha256 and self._image_size == (actual_width, actual_height):
            self._image_path = path
            return {
                "image_sha256": expected_sha256,
                "width": actual_width,
                "height": actual_height,
                "cached": True,
            }
        rgb = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
        self._predictor.set_image(rgb)
        self._image_path = path
        self._image_sha256 = expected_sha256
        self._image_size = (actual_width, actual_height)
        return {
            "image_sha256": expected_sha256,
            "width": actual_width,
            "height": actual_height,
            "cached": False,
        }

    def predict(
        self,
        *,
        points: list[list[float]],
        labels: list[int],
        box: list[float] | None,
        initial_mask: dict[str, Any] | None,
    ) -> dict[str, Any]:
        if self._predictor is None or self._image_path is None:
            raise RuntimeError("set_image must succeed before predict")
        _, current_payload = self._read_job_png(
            self._relative(self._image_path), self._image_sha256, "current image"
        )
        if _sha256_bytes(current_payload) != self._image_sha256:
            raise ValueError("current image changed after set_image")
        point_array, label_array, box_array = _normalize_prompts(points, labels, box)
        mask_logits = self._mask_logits(initial_mask)

        try:
            returned = self._predictor.predict(
                point_coords=point_array,
                point_labels=label_array,
                box=box_array,
                mask_input=mask_logits,
                multimask_output=True,
            )
        except Exception as exc:
            raise RuntimeError(f"SAM image predictor failed: {exc}") from exc
        masks, scores = _validate_predictor_output(returned, self._image_size)
        self._prediction_serial += 1
        serial = self._prediction_serial
        candidates = [
            self._write_candidate(mask, float(scores[index]), serial, index)
            for index, mask in enumerate(masks)
        ]
        return {"image_sha256": self._image_sha256, "candidates": candidates}

    def _mask_logits(self, descriptor: dict[str, Any] | None) -> np.ndarray | None:
        if descriptor is None:
            return None
        if not isinstance(descriptor, dict) or set(descriptor) != {"path", "sha256", "width", "height"}:
            raise ValueError("initial mask descriptor has invalid fields")
        width, height = self._image_size
        if descriptor["width"] != width or descriptor["height"] != height:
            raise ValueError("initial mask dimensions do not match the current image")
        _, payload = self._read_job_png(descriptor["path"], descriptor["sha256"], "initial mask")
        mask = _decode_png(payload, cv2.IMREAD_GRAYSCALE, "initial mask")
        if mask.shape != (height, width):
            raise ValueError("initial mask decoded dimensions do not match the current image")
        values = np.unique(mask)
        if not set(values.tolist()).issubset({0, 255}):
            raise ValueError("initial mask must contain only binary 0/255 pixels")
        resized = cv2.resize(mask, (256, 256), interpolation=cv2.INTER_NEAREST)
        return np.where(resized[np.newaxis, :, :] > 0, 8.0, -8.0).astype(np.float32)

    def _read_job_png(self, relative_path: str, expected_sha256: str, label: str) -> tuple[Path, bytes]:
        if not isinstance(expected_sha256, str) or len(expected_sha256) != 64 or any(
            character not in "0123456789abcdef" for character in expected_sha256
        ):
            raise ValueError(f"{label} digest must be lower-case SHA-256")
        relative = PurePosixPath(relative_path) if isinstance(relative_path, str) else PurePosixPath("")
        if relative.is_absolute() or relative.suffix.lower() != ".png" or any(
            part in {"", ".", ".."} for part in relative.parts
        ):
            raise ValueError(f"{label} path must be a traversal-free relative PNG")
        candidate = self.job_dir.joinpath(*relative.parts)
        try:
            metadata = candidate.lstat()
        except OSError as exc:
            raise ValueError(f"{label} path cannot be inspected: {exc}") from exc
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            raise ValueError(f"{label} path must be a regular non-symlink file")
        resolved = candidate.resolve(strict=True)
        try:
            resolved.relative_to(self.job_dir)
        except ValueError as exc:
            raise ValueError(f"{label} path is outside the job directory") from exc
        if metadata.st_size > self.max_input_bytes:
            raise ValueError(f"{label} exceeds the configured bytes limit")
        payload = resolved.read_bytes()
        if len(payload) != metadata.st_size or _sha256_bytes(payload) != expected_sha256:
            raise ValueError(f"{label} digest does not match or file changed during read")
        return resolved, payload

    def _write_candidate(self, mask: np.ndarray, score: float, serial: int, index: int) -> dict[str, Any]:
        ys, xs = np.nonzero(mask)
        if len(xs) == 0:
            raise ValueError("predictor candidate mask must not be empty")
        x0, x1 = int(xs.min()), int(xs.max()) + 1
        y0, y1 = int(ys.min()), int(ys.max()) + 1
        crop = np.where(mask[y0:y1, x0:x1], 255, 0).astype(np.uint8)
        encoded_ok, encoded = cv2.imencode(".png", crop)
        if not encoded_ok:
            raise RuntimeError("candidate PNG encoding failed")
        payload = encoded.tobytes()
        directory = self.job_dir / "candidates"
        if directory.exists():
            if directory.is_symlink() or not directory.is_dir():
                raise ValueError("candidate directory must be a regular directory")
        else:
            directory.mkdir(mode=0o700)
        name = f"predict-{serial:06d}-{index}.png"
        output = directory / name
        if output.exists() or output.is_symlink():
            raise ValueError(f"candidate output collision: {name}")
        temporary = directory / f".{name}.tmp-{os.getpid()}"
        try:
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            if output.exists() or output.is_symlink():
                raise ValueError(f"candidate output collision: {name}")
            os.replace(temporary, output)
        finally:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass
        return {
            "path": self._relative(output),
            "roi": [x0, y0, x1 - x0, y1 - y0],
            "sha256": _sha256_bytes(payload),
            "score": score,
        }

    def _relative(self, path: Path) -> str:
        return path.resolve(strict=True).relative_to(self.job_dir).as_posix()

    def cancel(self, target_request_id: str) -> dict[str, Any]:
        return {"target_request_id": target_request_id, "cancelled": True}

    def shutdown(self) -> None:
        if self._closed:
            return
        self._closed = True
        predictor = self._predictor
        self._predictor = None
        if predictor is not None and hasattr(predictor, "close"):
            predictor.close()


def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _decode_png(payload: bytes, mode: int, label: str) -> np.ndarray:
    _validate_png_container(payload, label)
    image = cv2.imdecode(np.frombuffer(payload, np.uint8), mode)
    if image is None or image.size == 0:
        raise ValueError(f"{label} PNG decode failed")
    return image


def _validate_png_container(payload: bytes, label: str) -> None:
    if not payload.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError(f"{label} PNG decode failed: invalid signature")
    offset = 8
    saw_header = False
    saw_data = False
    while offset < len(payload):
        if offset + 12 > len(payload):
            raise ValueError(f"{label} PNG decode failed: truncated chunk")
        length = struct.unpack(">I", payload[offset:offset + 4])[0]
        kind = payload[offset + 4:offset + 8]
        end = offset + 12 + length
        if length > MAX_INPUT_BYTES or end > len(payload):
            raise ValueError(f"{label} PNG decode failed: invalid chunk length")
        data = payload[offset + 8:offset + 8 + length]
        checksum = struct.unpack(">I", payload[offset + 8 + length:end])[0]
        if checksum != zlib.crc32(kind + data) & 0xFFFFFFFF:
            raise ValueError(f"{label} PNG decode failed: chunk checksum mismatch")
        if not saw_header:
            if kind != b"IHDR" or length != 13:
                raise ValueError(f"{label} PNG decode failed: missing IHDR")
            saw_header = True
        elif kind == b"IDAT":
            saw_data = True
        elif kind == b"IEND":
            if length != 0 or not saw_data or end != len(payload):
                raise ValueError(f"{label} PNG decode failed: invalid terminal chunk")
            return
        offset = end
    raise ValueError(f"{label} PNG decode failed: missing IEND")


def _normalize_prompts(
    points: list[list[float]], labels: list[int], box: list[float] | None
) -> tuple[np.ndarray | None, np.ndarray | None, np.ndarray | None]:
    if not isinstance(points, list) or len(points) > 64 or not isinstance(labels, list) or len(labels) != len(points):
        raise ValueError("predict prompts are inconsistent")
    point_array = np.asarray(points, dtype=np.float32) if points else None
    if point_array is not None and (point_array.shape != (len(points), 2) or not np.isfinite(point_array).all()):
        raise ValueError("predict points must be finite coordinate pairs")
    if any(isinstance(label, bool) or label not in (0, 1) for label in labels):
        raise ValueError("predict labels must be 0 or 1")
    label_array = np.asarray(labels, dtype=np.int32) if labels else None
    box_array = None
    if box is not None:
        box_array = np.asarray(box, dtype=np.float32)
        if box_array.shape != (4,) or not np.isfinite(box_array).all() or box_array[0] >= box_array[2] or box_array[1] >= box_array[3]:
            raise ValueError("predict box must be one finite normalized box")
    if point_array is None and box_array is None:
        raise ValueError("predict requires at least one point or box")
    return point_array, label_array, box_array


def _validate_predictor_output(returned: Any, image_size: tuple[int, int]) -> tuple[np.ndarray, np.ndarray]:
    if not isinstance(returned, tuple) or len(returned) != 3:
        raise ValueError("predictor output must be a masks/scores/logits tuple")
    masks = np.asarray(returned[0])
    scores = np.asarray(returned[1])
    width, height = image_size
    if masks.ndim != 3 or not 1 <= masks.shape[0] <= MAX_CANDIDATES or masks.shape[1:] != (height, width):
        raise ValueError("predictor returned invalid candidate mask dimensions or count")
    if scores.shape != (masks.shape[0],) or not np.issubdtype(scores.dtype, np.number) or not np.isfinite(scores).all():
        raise ValueError("predictor returned invalid candidate scores")
    if masks.dtype != np.bool_:
        if not np.issubdtype(masks.dtype, np.number) or not np.isfinite(masks).all() or not set(np.unique(masks).tolist()).issubset({0, 1}):
            raise ValueError("predictor candidate masks must be binary")
        masks = masks.astype(bool)
    if any(not math.isfinite(float(score)) for score in scores):
        raise ValueError("predictor returned a non-finite candidate score")
    return masks, scores.astype(np.float64)
