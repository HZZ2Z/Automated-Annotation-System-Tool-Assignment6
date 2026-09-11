"""Job-scoped state machine around the official SAM 2 video predictor."""
from __future__ import annotations

from copy import deepcopy
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

from .sam_video_protocol import MAX_TARGETS, OBJECT_ID


MAX_INPUT_BYTES = 64 * 1024 * 1024
MAX_IMAGE_PIXELS = 32 * 1024 * 1024
_FRAME_KEYS = frozenset({
    "path", "sha256", "width", "height", "playback_index", "frame_id"
})
_MASK_KEYS = frozenset({"path", "sha256", "roi"})


class SamVideoBackend:
    """Own one loaded predictor and at most one fresh batch inference state."""

    def __init__(
        self,
        job_dir: str | Path,
        config_path: str,
        checkpoint_path: str,
        device: str,
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
        if device not in {"auto", "cpu", "cuda"}:
            raise ValueError("device must be auto, cpu or cuda")
        self.job_dir = root
        self.config_path = config_path
        self.checkpoint_path = checkpoint_path
        self.device = device
        self.max_input_bytes = MAX_INPUT_BYTES
        self.max_image_pixels = MAX_IMAGE_PIXELS
        self._predictor_factory = predictor_factory
        self._predictor: Any = None
        self._actual_device = ""
        self._state: Any = None
        self._frames: list[dict[str, Any]] = []
        self._runtime_dir: Path | None = None
        self._runtime_frames: list[dict[str, Any]] = []
        self._batch_serial = 0
        self._generation = 0
        self._propagation_serial = 0
        self._mask_added = False
        self._cancelled = False
        self._closed = False

    def hello(self) -> dict[str, Any]:
        self._require_open()
        if self._predictor is None:
            factory = self._predictor_factory or self._official_predictor
            predictor = factory(self.config_path, self.checkpoint_path, self.device)
            required = ("init_state", "add_new_mask", "propagate_in_video", "reset_state")
            if predictor is None or any(not callable(getattr(predictor, name, None)) for name in required):
                raise RuntimeError("predictor factory returned an invalid SAM video predictor")
            self._predictor = predictor
            self._actual_device = getattr(
                predictor,
                "sam_video_device",
                self.device if self.device in {"cpu", "cuda"} else "cpu",
            )
            if self._actual_device not in {"cpu", "cuda"}:
                raise RuntimeError("predictor reported an invalid device")
        checkpoint_digest = ""
        checkpoint = Path(self.checkpoint_path)
        if checkpoint.is_file() and not checkpoint.is_symlink():
            checkpoint_digest = _sha256_file(checkpoint)
        return {
            "backend": "sam2-video-predictor",
            "persistent": True,
            "device": self._actual_device,
            "checkpoint_sha256": checkpoint_digest,
        }

    @staticmethod
    def _official_predictor(
        config_path: str, checkpoint_path: str, requested_device: str
    ) -> Any:
        if requested_device not in {"auto", "cpu", "cuda"}:
            raise RuntimeError("device must be auto, cpu or cuda")
        raw_config = Path(config_path)
        raw_checkpoint = Path(checkpoint_path)
        if (
            not raw_config.is_absolute()
            or raw_config.is_symlink()
            or not raw_config.is_file()
        ):
            raise RuntimeError("SAM2 config must be an absolute regular file")
        if (
            not raw_checkpoint.is_absolute()
            or raw_checkpoint.is_symlink()
            or not raw_checkpoint.is_file()
        ):
            raise RuntimeError("SAM2 checkpoint must be an absolute regular file")
        try:
            config = raw_config.resolve(strict=True)
            checkpoint = raw_checkpoint.resolve(strict=True)
        except OSError as exc:
            raise RuntimeError(f"SAM2 config or checkpoint cannot be resolved: {exc}") from exc

        import torch
        import sam2
        from sam2.build_sam import build_sam2_video_predictor

        config_name = ""
        for raw_package_root in sam2.__path__:
            try:
                package_root = Path(raw_package_root).resolve(strict=True)
                relative = config.relative_to(package_root / "configs")
            except (OSError, ValueError):
                continue
            if relative.parts:
                config_name = (PurePosixPath("configs") / PurePosixPath(*relative.parts)).as_posix()
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
        predictor = build_sam2_video_predictor(
            config_name, str(checkpoint), device=actual_device
        )
        setattr(predictor, "sam_video_device", actual_device)
        return predictor

    def open_batch(self, frames: list[dict[str, Any]]) -> dict[str, Any]:
        self._require_open()
        previous_state = self._state
        try:
            normalized, payloads = self._validate_new_frames(frames)
        except Exception:
            if previous_state is not None:
                self._invalidate_failed_batch(previous_state)
            raise
        self.hello()
        if self._state is not None:
            self._release_batch()
        self._batch_serial += 1
        runtime, runtime_frames = self._build_runtime(
            self._batch_serial, normalized, payloads
        )
        try:
            state = self._predictor.init_state(video_path=str(runtime))
        except Exception as exc:
            raise RuntimeError(f"SAM video predictor init_state failed: {exc}") from exc
        if state is None:
            raise RuntimeError("SAM video predictor returned no inference state")
        self._state = state
        self._frames = deepcopy(normalized)
        self._runtime_dir = runtime
        self._runtime_frames = deepcopy(runtime_frames)
        self._mask_added = False
        self._cancelled = False
        self._generation += 1
        return {"batch_serial": self._batch_serial, "frame_count": len(normalized)}

    def add_mask(self, mask_descriptor: dict[str, Any], object_id: int) -> dict[str, Any]:
        state, generation = self._active_state()
        try:
            return self._add_mask_active(
                state, generation, mask_descriptor, object_id
            )
        except Exception:
            self._invalidate_failed_batch(state)
            raise

    def _add_mask_active(
        self,
        state: Any,
        generation: int,
        mask_descriptor: dict[str, Any],
        object_id: int,
    ) -> dict[str, Any]:
        _require_object_id(object_id)
        if self._mask_added:
            raise RuntimeError("the batch already has its keyframe mask")
        self._validate_active_inputs()
        descriptor = _exact_dict(mask_descriptor, _MASK_KEYS, "mask descriptor")
        width = self._frames[0]["width"]
        height = self._frames[0]["height"]
        roi = descriptor["roi"]
        if (
            not isinstance(roi, list)
            or len(roi) != 4
            or any(isinstance(item, bool) or not isinstance(item, int) for item in roi)
            or roi != [0, 0, width, height]
        ):
            raise ValueError("key mask must use the full-image ROI")
        _, payload = self._read_job_png(
            descriptor["path"], descriptor["sha256"], "key mask"
        )
        mask = _decode_png(payload, cv2.IMREAD_GRAYSCALE, "key mask")
        if mask.shape != (height, width):
            raise ValueError("key mask decoded dimensions do not match the key frame")
        if not set(np.unique(mask).tolist()).issubset({0, 255}):
            raise ValueError("key mask must contain only binary 0/255 pixels")
        try:
            self._predictor.add_new_mask(
                inference_state=state,
                frame_idx=0,
                obj_id=OBJECT_ID,
                mask=mask > 0,
            )
        except Exception as exc:
            raise RuntimeError(f"SAM video predictor add_new_mask failed: {exc}") from exc
        if self._state is not state or self._generation != generation:
            raise RuntimeError("key mask result became stale after batch reset")
        self._mask_added = True
        return {"local_index": 0, "object_id": OBJECT_ID}

    def propagate(self, count: int, object_id: int) -> dict[str, Any]:
        state, generation = self._active_state()
        try:
            return self._propagate_active(state, generation, count, object_id)
        except Exception:
            self._invalidate_failed_batch(state)
            raise

    def _propagate_active(
        self, state: Any, generation: int, count: int, object_id: int
    ) -> dict[str, Any]:
        _require_object_id(object_id)
        if isinstance(count, bool) or not isinstance(count, int) or not 1 <= count <= MAX_TARGETS:
            raise ValueError(f"count must be an integer from 1 to {MAX_TARGETS}")
        if count > len(self._frames) - 1:
            raise ValueError("count exceeds the opened batch targets")
        if not self._mask_added:
            raise RuntimeError("add_mask must succeed before propagate")
        self._validate_active_inputs()
        try:
            stream = self._predictor.propagate_in_video(
                inference_state=state,
                start_frame_idx=0,
                max_frame_num_to_track=count,
                reverse=False,
            )
            outputs: dict[int, tuple[np.ndarray, float]] = {}
            for returned in stream:
                if self._state is not state or self._generation != generation:
                    raise RuntimeError("predictor output became stale after batch reset")
                local_index, returned_object_ids, logits = _video_output(returned)
                if not 0 <= local_index <= count or local_index in outputs:
                    raise ValueError("predictor returned an invalid or duplicate local frame index")
                object_ids = _as_numpy(returned_object_ids)
                if (
                    object_ids.shape != (1,)
                    or not np.issubdtype(object_ids.dtype, np.integer)
                    or np.issubdtype(object_ids.dtype, np.bool_)
                    or int(object_ids[0]) != OBJECT_ID
                ):
                    raise ValueError("predictor returned the wrong object ID")
                mask, score = _mask_and_score(logits, self._frames[local_index])
                outputs[local_index] = (mask, score)
        except (ValueError, RuntimeError):
            raise
        except Exception as exc:
            raise RuntimeError(f"SAM video predictor propagation failed: {exc}") from exc
        if self._state is not state or self._generation != generation:
            raise RuntimeError("predictor output became stale after batch reset")
        expected = set(range(1, count + 1))
        if set(outputs) - {0} != expected:
            raise ValueError("predictor target output count or indices do not match the request")
        self._validate_active_inputs()
        self._propagation_serial += 1
        serial = self._propagation_serial
        masks = [
            self._write_output(outputs[index][0], outputs[index][1], serial, index)
            for index in range(1, count + 1)
        ]
        return {"masks": masks}

    def cancel(self, request_id: str) -> dict[str, Any]:
        if not isinstance(request_id, str) or not request_id:
            raise ValueError("request_id must be a non-empty string")
        self._cancelled = True
        self._generation += 1
        return {"target_request_id": request_id, "cancelled": True}

    def reset_batch(self) -> dict[str, Any]:
        self._require_open()
        self._release_batch()
        return {"reset": True}

    def shutdown(self) -> None:
        if self._closed:
            return
        try:
            self._release_batch()
        finally:
            predictor = self._predictor
            self._predictor = None
            self._closed = True
            if predictor is not None and callable(getattr(predictor, "close", None)):
                predictor.close()

    def _active_state(self) -> tuple[Any, int]:
        self._require_open()
        if self._state is None:
            raise RuntimeError("open_batch must succeed before using the batch")
        if self._cancelled:
            raise RuntimeError("the current batch was cancelled")
        return self._state, self._generation

    def _require_open(self) -> None:
        if self._closed:
            raise RuntimeError("SAM video backend is shut down")

    def _invalidate_failed_batch(self, state: Any) -> None:
        if self._state is not state:
            return
        try:
            self._release_batch()
        except Exception:
            # State references are cleared before reset_state is invoked, so a
            # reset failure cannot make the failed inference state reusable.
            pass

    def _release_batch(self) -> None:
        state = self._state
        self._state = None
        self._frames = []
        self._runtime_dir = None
        self._runtime_frames = []
        self._mask_added = False
        self._cancelled = False
        self._generation += 1
        if state is not None and self._predictor is not None:
            try:
                self._predictor.reset_state(state)
            except Exception as exc:
                raise RuntimeError(f"SAM video predictor reset_state failed: {exc}") from exc

    def _validate_new_frames(
        self, frames: list[dict[str, Any]]
    ) -> tuple[list[dict[str, Any]], list[bytes]]:
        if not isinstance(frames, list) or not 2 <= len(frames) <= MAX_TARGETS + 1:
            raise ValueError(f"frames must contain a key and from 1 to {MAX_TARGETS} targets")
        normalized: list[dict[str, Any]] = []
        payloads: list[bytes] = []
        previous_playback = -1
        paths: set[str] = set()
        image_size: tuple[int, int] | None = None
        for index, raw in enumerate(frames):
            source = _exact_dict(raw, _FRAME_KEYS, f"frames[{index}]")
            path = _relative_png(source["path"], f"frames[{index}].path")
            digest = _digest(source["sha256"], f"frames[{index}].sha256")
            width = _positive_integer(source["width"], f"frames[{index}].width")
            height = _positive_integer(source["height"], f"frames[{index}].height")
            playback = _nonnegative_integer(
                source["playback_index"], f"frames[{index}].playback_index"
            )
            frame_id = _nonnegative_integer(source["frame_id"], f"frames[{index}].frame_id")
            if playback <= previous_playback:
                raise ValueError("frame playback indices must be unique and strictly increasing")
            if path in paths:
                raise ValueError("frame paths must be unique")
            previous_playback = playback
            paths.add(path)
            _, payload = self._read_job_png(path, digest, f"frame {index}")
            image = _decode_png(payload, cv2.IMREAD_COLOR, f"frame {index}")
            if image.shape[:2] != (height, width):
                raise ValueError(f"frame {index} decoded dimensions do not match its descriptor")
            if width * height > self.max_image_pixels:
                raise ValueError(f"frame {index} exceeds the configured pixels limit")
            if image_size is None:
                image_size = (width, height)
            elif image_size != (width, height):
                raise ValueError("all batch frames must have identical dimensions")
            normalized.append({
                "path": path,
                "sha256": digest,
                "width": width,
                "height": height,
                "playback_index": playback,
                "frame_id": frame_id,
            })
            payloads.append(payload)
        return normalized, payloads

    def _build_runtime(
        self, serial: int, frames: list[dict[str, Any]], payloads: list[bytes]
    ) -> tuple[Path, list[dict[str, Any]]]:
        root = self.job_dir / "runtime"
        if root.exists():
            if root.is_symlink() or not root.is_dir():
                raise ValueError("runtime must be a regular directory")
        else:
            root.mkdir(mode=0o700)
        runtime = root / f"batch-{serial:06d}"
        if runtime.exists() or runtime.is_symlink():
            raise ValueError("runtime batch directory collision")
        runtime.mkdir(mode=0o700)
        runtime_frames: list[dict[str, Any]] = []
        for index, payload in enumerate(payloads):
            image = _decode_png(payload, cv2.IMREAD_COLOR, f"runtime source frame {index}")
            encoded_ok, encoded = cv2.imencode(
                ".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 100]
            )
            if not encoded_ok:
                raise RuntimeError(f"runtime frame {index} JPEG encoding failed")
            runtime_payload = encoded.tobytes()
            _validate_jpeg_container(runtime_payload, f"runtime frame {index}")
            path = runtime / f"{index:06d}.jpg"
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(runtime_payload)
                handle.flush()
                os.fsync(handle.fileno())
            runtime_frames.append({
                "path": path.relative_to(self.job_dir).as_posix(),
                "sha256": hashlib.sha256(runtime_payload).hexdigest(),
                "width": frames[index]["width"],
                "height": frames[index]["height"],
            })
        self._validate_runtime(runtime, frames, runtime_frames)
        return runtime, runtime_frames

    def _validate_active_inputs(self) -> None:
        if self._runtime_dir is None or not self._frames:
            raise RuntimeError("open_batch must succeed before validating the batch")
        for index, descriptor in enumerate(self._frames):
            _, payload = self._read_job_png(
                descriptor["path"], descriptor["sha256"], f"frozen frame {index}"
            )
            image = _decode_png(payload, cv2.IMREAD_COLOR, f"frozen frame {index}")
            if image.shape[:2] != (descriptor["height"], descriptor["width"]):
                raise ValueError(f"frozen frame {index} decoded dimensions changed")
        self._validate_runtime(
            self._runtime_dir, self._frames, self._runtime_frames
        )

    def _validate_runtime(
        self,
        runtime: Path,
        frames: list[dict[str, Any]],
        runtime_frames: list[dict[str, Any]],
    ) -> None:
        try:
            metadata = runtime.lstat()
        except OSError as exc:
            raise ValueError(f"runtime batch directory cannot be inspected: {exc}") from exc
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise ValueError("runtime batch path must be a regular directory")
        if len(runtime_frames) != len(frames):
            raise ValueError("runtime descriptor count does not match frozen frames")
        expected_names = {f"{index:06d}.jpg" for index in range(len(frames))}
        actual_names = {item.name for item in runtime.iterdir()}
        if actual_names != expected_names:
            raise ValueError("runtime inputs contain missing or extra files")
        for index, descriptor in enumerate(frames):
            runtime_descriptor = runtime_frames[index]
            expected_path = (
                runtime / f"{index:06d}.jpg"
            ).relative_to(self.job_dir).as_posix()
            if runtime_descriptor.get("path") != expected_path:
                raise ValueError("runtime frame descriptor path does not match local order")
            _, payload = self._read_job_jpeg(
                expected_path,
                runtime_descriptor.get("sha256"),
                f"runtime frame {index}",
            )
            image = _decode_jpeg(payload, cv2.IMREAD_COLOR, f"runtime frame {index}")
            if image.shape[:2] != (descriptor["height"], descriptor["width"]):
                raise ValueError(f"runtime frame {index} decoded dimensions changed")

    def _write_output(
        self,
        mask: np.ndarray,
        score: float,
        serial: int,
        local_index: int,
    ) -> dict[str, Any]:
        if not math.isfinite(score):
            raise ValueError("predictor output score must be finite")
        frame = self._frames[local_index]
        ys, xs = np.nonzero(mask)
        if len(xs) == 0:
            x0, y0 = 0, 0
            x1, y1 = frame["width"], frame["height"]
        else:
            x0, x1 = int(xs.min()), int(xs.max()) + 1
            y0, y1 = int(ys.min()), int(ys.max()) + 1
        crop = np.where(mask[y0:y1, x0:x1], 255, 0).astype(np.uint8)
        encoded_ok, encoded = cv2.imencode(".png", crop)
        if not encoded_ok:
            raise RuntimeError("output PNG encoding failed")
        payload = encoded.tobytes()
        directory = self.job_dir / "outputs"
        if directory.exists():
            if directory.is_symlink() or not directory.is_dir():
                raise ValueError("outputs must be a regular directory")
        else:
            directory.mkdir(mode=0o700)
        name = f"propagate-{serial:06d}-{local_index:06d}.png"
        output = directory / name
        if output.exists() or output.is_symlink():
            raise ValueError(f"output collision: {name}")
        temporary = directory / f".{name}.tmp-{os.getpid()}"
        try:
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            if output.exists() or output.is_symlink():
                raise ValueError(f"output collision: {name}")
            os.replace(temporary, output)
        finally:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass
        return {
            "local_index": local_index,
            "playback_index": frame["playback_index"],
            "frame_id": frame["frame_id"],
            "object_id": OBJECT_ID,
            "path": output.relative_to(self.job_dir).as_posix(),
            "roi": [x0, y0, x1 - x0, y1 - y0],
            "score": score,
            "sha256": hashlib.sha256(payload).hexdigest(),
        }

    def _read_job_png(
        self, relative_path: str, expected_sha256: str, label: str
    ) -> tuple[Path, bytes]:
        return self._read_job_file(
            relative_path, expected_sha256, label, frozenset({".png"})
        )

    def _read_job_jpeg(
        self, relative_path: str, expected_sha256: str, label: str
    ) -> tuple[Path, bytes]:
        return self._read_job_file(
            relative_path, expected_sha256, label, frozenset({".jpg", ".jpeg"})
        )

    def _read_job_file(
        self,
        relative_path: str,
        expected_sha256: str,
        label: str,
        suffixes: frozenset[str],
    ) -> tuple[Path, bytes]:
        path_text = _relative_file(relative_path, f"{label} path", suffixes)
        digest = _digest(expected_sha256, f"{label} digest")
        candidate = self.job_dir.joinpath(*PurePosixPath(path_text).parts)
        try:
            root_metadata = self.job_dir.lstat()
            metadata = candidate.lstat()
        except OSError as exc:
            raise ValueError(f"{label} path cannot be inspected: {exc}") from exc
        if stat.S_ISLNK(root_metadata.st_mode) or not stat.S_ISDIR(root_metadata.st_mode):
            raise ValueError("job directory changed or became linked")
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            raise ValueError(f"{label} must be a regular non-symlink file")
        try:
            resolved = candidate.resolve(strict=True)
            resolved.relative_to(self.job_dir)
        except (OSError, ValueError) as exc:
            raise ValueError(f"{label} path is outside the job directory") from exc
        if metadata.st_size > self.max_input_bytes:
            raise ValueError(f"{label} exceeds the configured bytes limit")
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(candidate, flags)
        try:
            opened_before = os.fstat(descriptor)
            chunks: list[bytes] = []
            total = 0
            while True:
                chunk = os.read(descriptor, min(1024 * 1024, self.max_input_bytes + 1 - total))
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
                if total > self.max_input_bytes:
                    raise ValueError(f"{label} exceeds the configured bytes limit")
            opened_after = os.fstat(descriptor)
        finally:
            os.close(descriptor)
        try:
            final_metadata = candidate.lstat()
        except OSError as exc:
            raise ValueError(f"{label} changed during read: {exc}") from exc
        identity_before = (
            opened_before.st_dev, opened_before.st_ino, opened_before.st_size,
            opened_before.st_mtime_ns,
        )
        identity_after = (
            opened_after.st_dev, opened_after.st_ino, opened_after.st_size,
            opened_after.st_mtime_ns,
        )
        identity_path = (
            final_metadata.st_dev, final_metadata.st_ino, final_metadata.st_size,
            final_metadata.st_mtime_ns,
        )
        payload = b"".join(chunks)
        if (
            identity_before != identity_after
            or identity_after != identity_path
            or len(payload) != opened_after.st_size
            or hashlib.sha256(payload).hexdigest() != digest
        ):
            raise ValueError(f"{label} digest does not match or file changed during read")
        return resolved, payload


def _video_output(returned: Any) -> tuple[int, Any, Any]:
    if not isinstance(returned, tuple) or len(returned) != 3:
        raise ValueError("predictor output must be a frame/object/logits tuple")
    local_index = returned[0]
    if isinstance(local_index, bool) or not isinstance(local_index, (int, np.integer)):
        raise ValueError("predictor local frame index must be an integer")
    return int(local_index), returned[1], returned[2]


def _mask_and_score(logits: Any, frame: dict[str, Any]) -> tuple[np.ndarray, float]:
    array = _as_numpy(logits)
    if not np.issubdtype(array.dtype, np.number) or not np.isfinite(array).all():
        raise ValueError("predictor logits must be finite numbers")
    if array.shape == (1, 1, frame["height"], frame["width"]):
        plane = array[0, 0]
    elif array.shape == (1, frame["height"], frame["width"]):
        plane = array[0]
    else:
        raise ValueError("predictor logits dimensions do not match the target frame")
    mask = plane > 0.0
    confidence = 1.0 / (1.0 + np.exp(-np.clip(np.abs(plane.astype(np.float64)), 0.0, 80.0)))
    score = float(np.mean(confidence))
    if not math.isfinite(score):
        raise ValueError("predictor score is not finite")
    return mask, score


def _as_numpy(value: Any) -> np.ndarray:
    """Move a Torch-shaped external value to CPU without importing Torch."""
    detach = getattr(value, "detach", None)
    if callable(detach):
        value = detach()
        move = getattr(value, "to", None)
        if callable(move):
            value = move("cpu")
        convert = getattr(value, "numpy", None)
        if callable(convert):
            value = convert()
    return np.asarray(value)


def _require_object_id(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value != OBJECT_ID:
        raise ValueError(f"object_id must be {OBJECT_ID}")
    return value


def _exact_dict(value: object, keys: frozenset[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or frozenset(value) != keys:
        raise ValueError(f"{label} has invalid fields")
    return value


def _nonnegative_integer(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"{label} must be a non-negative integer")
    return value


def _positive_integer(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise ValueError(f"{label} must be a positive integer")
    return value


def _digest(value: object, label: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise ValueError(f"{label} must be a lower-case SHA-256 digest")
    return value


def _relative_png(value: object, label: str) -> str:
    return _relative_file(value, label, frozenset({".png"}))


def _relative_file(
    value: object, label: str, suffixes: frozenset[str]
) -> str:
    if not isinstance(value, str) or not value or "\\" in value:
        raise ValueError(f"{label} must be a relative file path")
    path = PurePosixPath(value)
    if (
        path.is_absolute()
        or path.suffix.lower() not in suffixes
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise ValueError(f"{label} must be a traversal-free relative file path")
    return path.as_posix()


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


def _validate_jpeg_container(payload: bytes, label: str) -> None:
    if not payload.startswith(b"\xff\xd8") or not payload.endswith(b"\xff\xd9"):
        raise ValueError(f"{label} JPEG decode failed: invalid container")


def _decode_jpeg(payload: bytes, mode: int, label: str) -> np.ndarray:
    _validate_jpeg_container(payload, label)
    image = cv2.imdecode(np.frombuffer(payload, np.uint8), mode)
    if image is None or image.size == 0:
        raise ValueError(f"{label} JPEG decode failed")
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
