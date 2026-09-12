# Model Assist 单帧后端:官方 SAM 2 图像预测器的 job 级安全适配层。
#
# 用途:被 python/model_assist_worker.py(由 Godot 客户端拉起的驻留 Python
# 子进程)调用,按协议提供 hello / set_image / predict / cancel / shutdown:
# 首次 hello 惰性构建 SAM2ImagePredictor;set_image 读取并缓存当前帧的
# image embedding;predict 按正/负点或 box 提示生成最多 3 个带 score 的二值
# mask 候选,写为 job 目录 candidates/ 内带 SHA-256 的 PNG(返回值中的路径
# 相对 job 目录)。
#
# 安全边界(门禁,失败不静默降级):只接受 job 目录内相对、无符号链接、
# 摘要匹配的 PNG;路径越界、摘要不符、PNG 容器或像素非法一律抛异常;候选
# 文件经临时文件 + fsync + 原子改名落盘;运行时只按调用方传入的
# config/checkpoint/device 加载 SAM 2,不自动安装 sam2、不下载 checkpoint。
#
# 输入:构造参数(job 目录、SAM 2 config/checkpoint 绝对路径、device、可选
# predictor_factory 测试替身)与各方法参数;输出:可 JSON 序列化的字典。
# 生命周期:每个 worker 进程一个实例,由协议主循环单线程串行调用;
# predictor 惰性创建,shutdown 幂等。
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


# 从 job 目录读取的单个 PNG 载荷字节上限(64 MiB):超限直接拒绝。
MAX_INPUT_BYTES = 64 * 1024 * 1024
# set_image 接受的图像像素数上限(32 M 像素,宽*高):防止超大图耗尽内存。
MAX_IMAGE_PIXELS = 32 * 1024 * 1024
# 单次 predict 允许返回的候选 mask 数上限(multimask_output=True 每次输出 3 个)。
MAX_CANDIDATES = 3


# SAM 2 图像预测后端:持有唯一的 predictor、当前帧的 image embedding 状态,
# 以及 job 目录内候选文件的写入权。
# 关键属性:job_dir(已 resolve 的任务目录,一切文件读写的边界)、
# config_path/checkpoint_path/device(SAM 2 加载参数,首次 hello 才校验)、
# _predictor(惰性创建的官方 SAM2ImagePredictor)、_actual_device(实际生效
# 设备)、_image_path/_image_sha256/_image_size(当前已 set_image 的帧)、
# _prediction_serial(候选文件名使用的预测序号,单调递增)、_closed
# (shutdown 幂等标记)。
# 线程模型:非线程安全,由 worker 主循环单线程串行调用。
class ModelAssistBackend:
    """Own one predictor, one image embedding and job-local candidate files."""

    # 构造后端:只做 job 目录门禁与参数登记,不加载 SAM 2(懒加载推迟到 hello)。
    # 参数 job_dir:任务隔离目录,须为已存在的真实目录(非符号链接、可
    # resolve);config_path/checkpoint_path:SAM 2 配置与权重路径(此处不
    # 校验,首次 hello 构建时才校验);device:"auto"|"cpu"|"cuda";
    # predictor_factory:测试注入替身,签名 (config, checkpoint, device) -> predictor。
    # 异常:job 目录是符号链接、无法 resolve(不存在等)或不是目录时抛 ValueError。
    # 副作用:登记实例状态;输入上限复制为实例属性(默认取模块常量)。
    def __init__(
        self,
        job_dir: str | Path,
        *,
        config_path: str,
        checkpoint_path: str,
        device: str = "auto",
        predictor_factory: Callable[[str, str, str], Any] | None = None,
    ) -> None:
        # job 目录门禁:拒绝符号链接;resolve(strict=True) 失败(不存在等)
        # 或结果不是目录时抛 ValueError。
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

    # 握手:确保 predictor 已构建,并返回后端描述信息。
    # 返回字典:backend(实现标识 "sam2-image-predictor")、persistent(True,
    # image embedding 跨请求驻留)、device(实际生效设备)、checkpoint_sha256
    # (checkpoint 文件存在且非符号链接时为其 SHA-256,否则为空串)。
    # 副作用:首次调用时经工厂(默认 _official_predictor)构建 predictor 并
    # 记录实际设备;之后的调用只重复计算 checkpoint 摘要。
    # 异常:已 shutdown 抛 RuntimeError;工厂返回的对象缺少 set_image/predict
    # 接口抛 RuntimeError;工厂内部异常原样冒泡。
    def hello(self) -> dict[str, Any]:
        if self._closed:
            raise RuntimeError("model assist backend is shut down")
        if self._predictor is None:
            factory = self._predictor_factory or self._official_predictor
            requested_device = self.device
            self._predictor = factory(self.config_path, self.checkpoint_path, requested_device)
            if self._predictor is None or not hasattr(self._predictor, "set_image") or not hasattr(self._predictor, "predict"):
                raise RuntimeError("predictor factory returned an invalid SAM image predictor")
            # 实际设备:优先读取工厂标注在 predictor 上的 model_assist_device;
            # 替身 predictor 没有该属性时,请求为 cpu/cuda 则按请求记录,
            # 否则视为 cpu。
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

    # 官方 predictor 工厂:校验参数、选择设备并构建 SAM2ImagePredictor。
    # 参数:config_path/checkpoint_path 必须是绝对路径且指向真实存在的文件;
    # requested_device ∈ {auto, cpu, cuda}。
    # 返回:带 model_assist_device 属性(实际设备)的 SAM2ImagePredictor。
    # 异常:参数校验失败、torch/sam2 导入失败或模型构建失败均抛 RuntimeError
    # (依赖与 checkpoint 由运行环境预先备好,此处不做任何安装/下载)。
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
        # 惰性导入:只有真正构建官方 predictor 时才需要 torch 与 sam2。
        import torch
        import sam2
        from sam2.build_sam import build_sam2
        from sam2.sam2_image_predictor import SAM2ImagePredictor

        # UI 合同用绝对 config 文件路径,但 Hydra 只接受相对已安装 sam2 包的
        # 配置名:把绝对路径映射为 sam2 包内 configs/ 目录下的相对 POSIX 名;
        # config 不在任何 sam2 包的 configs/ 下则拒绝。
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

        # 设备选择:显式请求 cuda 但 CUDA 不可用时直接拒绝;
        # auto 在有 CUDA 时选 cuda,否则一律 cpu。
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

    # 设置当前帧:读取并校验 job 目录内的图像 PNG,必要时计算 image embedding。
    # 参数 image_path:job 目录内相对路径;expected_sha256:期望的图像字节
    # 摘要;width/height:协议描述符声明的图像尺寸。
    # 返回:image_sha256/width/height/cached(False=本次重新计算 embedding,
    # True=命中缓存,仅刷新内部路径引用)。
    # 异常:图像读取/解码失败、尺寸与描述符不符或超出像素上限时抛 ValueError;
    # 内部先调 hello(),其异常同样适用。
    # 副作用:登记当前帧状态(_image_path/_image_sha256/_image_size);
    # 换帧时调用 predictor.set_image 重算 embedding(成本高,故按
    # sha256+尺寸缓存)。
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
        # 解码后的实际尺寸必须与协议描述符一致,且不超过像素上限。
        if (width, height) != (actual_width, actual_height):
            raise ValueError("image dimensions do not match the descriptor")
        if actual_width * actual_height > self.max_image_pixels:
            raise ValueError("image exceeds the configured pixels limit")
        # 同一图像(sha256 与尺寸都相同)命中缓存:不重算 embedding,
        # 仅刷新内部路径引用并回报 cached=True。
        if self._image_sha256 == expected_sha256 and self._image_size == (actual_width, actual_height):
            self._image_path = path
            return {
                "image_sha256": expected_sha256,
                "width": actual_width,
                "height": actual_height,
                "cached": True,
            }
        # OpenCV 按 BGR 读入,SAM 2 期望 RGB,先转通道再计算 embedding。
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

    # 按提示生成 mask 候选:要求此前 set_image 已成功。
    # 参数:points/labels 为提示点坐标与 0/1 标签(0=负点,1=正点);
    # box 为可选 [x0, y0, x1, y1] 提示框;initial_mask 为可选的上一次 mask
    # 描述符(迭代精修时转成低分辨率 logits 喂给 SAM,见 _mask_logits)。
    # 返回:image_sha256 与 candidates 列表,每个候选含 path(相对 job 目录)、
    # roi=[x0,y0,w,h](候选内容在整图中的包围盒)、sha256 与 score。
    # 异常:未先 set_image 抛 RuntimeError;当前图像字节已变、提示不合法或
    # 输出不符合约定抛 ValueError;SAM 调用本身失败抛 RuntimeError。
    # 副作用:预测序号自增;把每个候选 mask 落盘为 candidates/ 下的 PNG
    # (见 _write_candidate)。
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
        # 重新读取当前图像并比对摘要:防止 set_image 之后图像文件被改动。
        _, current_payload = self._read_job_png(
            self._relative(self._image_path), self._image_sha256, "current image"
        )
        if _sha256_bytes(current_payload) != self._image_sha256:
            raise ValueError("current image changed after set_image")
        point_array, label_array, box_array = _normalize_prompts(points, labels, box)
        mask_logits = self._mask_logits(initial_mask)

        # multimask_output=True:让 SAM 每次输出多个候选(数量受
        # MAX_CANDIDATES 约束)供前端挑选;调用失败包装为 RuntimeError,
        # 不泄露第三方栈给协议层之外。
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
        # 输出门禁:mask 形状/数量/二值性与 score 有效性都必须符合约定,否则拒绝。
        masks, scores = _validate_predictor_output(returned, self._image_size)
        self._prediction_serial += 1
        serial = self._prediction_serial
        # 逐个把候选 mask 落盘为带哈希的 PNG;文件名含单调递增的预测序号,
        # 保证同会话内不重名。
        candidates = [
            self._write_candidate(mask, float(scores[index]), serial, index)
            for index, mask in enumerate(masks)
        ]
        return {"image_sha256": self._image_sha256, "candidates": candidates}

    # 把可选的 initial_mask 描述符转换为 SAM 的低分辨率 mask logits 输入。
    # 参数 descriptor:含 path/sha256/width/height 四个字段的字典,或 None。
    # 返回:形状 (1, 256, 256) 的 float32 logits(前景 +8.0、背景 -8.0);
    # descriptor 为 None 时返回 None(不使用 mask 提示)。
    # 异常:字段不齐、宽高与当前图像不符、PNG 读取/解码失败或像素不是
    # 纯 0/255 二值时抛 ValueError。
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
        # SAM 约定 mask_input 为 1x256x256 的低分辨率 logits:最近邻缩放到
        # 256x256 后按 0/255 阈值映射为 ±8.0 的 float32(前景为正、背景为负)。
        resized = cv2.resize(mask, (256, 256), interpolation=cv2.INTER_NEAREST)
        return np.where(resized[np.newaxis, :, :] > 0, 8.0, -8.0).astype(np.float32)

    # 从 job 目录安全读取一个 PNG:路径与摘要双重门禁,是图像与初始 mask 的
    # 唯一读取通道。
    # 参数 relative_path:job 目录内的相对 POSIX 路径(仅接受 .png 后缀);
    # expected_sha256:期望的 64 位小写十六进制摘要;label:错误消息里的载荷名。
    # 返回:(resolve 后的绝对路径, 原始字节)。
    # 异常:摘要格式不对、路径含绝对/空段/"."/".." 成分、符号链接或非常规
    # 文件、越出 job 目录、超过字节上限、读取期间文件变化或摘要不匹配,
    # 均抛 ValueError。
    def _read_job_png(self, relative_path: str, expected_sha256: str, label: str) -> tuple[Path, bytes]:
        if not isinstance(expected_sha256, str) or len(expected_sha256) != 64 or any(
            character not in "0123456789abcdef" for character in expected_sha256
        ):
            raise ValueError(f"{label} digest must be lower-case SHA-256")
        # 路径门禁:仅接受相对、.png 后缀、每段都不为空/"."/".." 的 POSIX 路径。
        relative = PurePosixPath(relative_path) if isinstance(relative_path, str) else PurePosixPath("")
        if relative.is_absolute() or relative.suffix.lower() != ".png" or any(
            part in {"", ".", ".."} for part in relative.parts
        ):
            raise ValueError(f"{label} path must be a traversal-free relative PNG")
        # lstat(不跟随链接)确认是常规文件且非符号链接;resolve 之后还必须
        # 仍位于 job 目录内,防止符号链接逃逸出任务目录。
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
        # 读取后复核:实际字节数与 lstat 时一致,且 SHA-256 与期望一致
        # (覆盖 TOCTOU:读取期间文件被替换的情形)。
        payload = resolved.read_bytes()
        if len(payload) != metadata.st_size or _sha256_bytes(payload) != expected_sha256:
            raise ValueError(f"{label} digest does not match or file changed during read")
        return resolved, payload

    # 把一个候选 mask 写为 job 目录 candidates/ 下的二值 PNG(原子写)。
    # 参数 mask:bool 数组(整幅图尺寸);score:SAM 给出的候选分数;serial:
    # 本次会话内单调递增的预测序号;index:同一批候选内的下标。
    # 返回:候选描述符 {path, roi:[x0,y0,w,h], sha256, score}。
    # 异常:mask 无前景、PNG 编码失败抛 ValueError/RuntimeError;
    # candidates/ 不是常规目录或目标文件名冲突抛 ValueError。
    # 副作用:必要时创建 candidates/(权限 0o700);先写临时文件
    # (O_EXCL 独占创建、权限 0o600、fsync 落盘)再 os.replace 原子改名;
    # 无论成败都在 finally 里清理临时文件。
    def _write_candidate(self, mask: np.ndarray, score: float, serial: int, index: int) -> dict[str, Any]:
        # 候选必须非空;只保存前景的紧包围盒(ROI)以缩小 PNG 体积,
        # roi 字段让前端能把候选还原回整图坐标。
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
        # 候选目录门禁:已存在则必须是常规目录(拒绝符号链接),
        # 不存在则以 0o700 权限创建。
        directory = self.job_dir / "candidates"
        if directory.exists():
            if directory.is_symlink() or not directory.is_dir():
                raise ValueError("candidate directory must be a regular directory")
        else:
            directory.mkdir(mode=0o700)
        # 文件名含预测序号,正常不会重名;写入前后都检查冲突,拒绝覆盖已有文件。
        name = f"predict-{serial:06d}-{index}.png"
        output = directory / name
        if output.exists() or output.is_symlink():
            raise ValueError(f"candidate output collision: {name}")
        # 原子写:临时文件名带 PID,O_EXCL 独占创建;写入并 fsync 落盘后,
        # 再次确认目标无冲突,再 os.replace 原子改名为最终文件;finally 兜底
        # 删除临时文件(改名成功后 unlink 落空,仅忽略 FileNotFoundError)。
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

    # 把 job 目录内的绝对路径转为相对 POSIX 路径(供候选描述符使用);
    # 路径必须真实存在且位于 job 目录内,否则抛 ValueError。
    def _relative(self, path: Path) -> str:
        return path.resolve(strict=True).relative_to(self.job_dir).as_posix()

    # 取消请求:predict 是同步执行,没有可中断的后台任务,这里仅回显
    # target_request_id 并确认取消,由协议层关联回原请求。
    def cancel(self, target_request_id: str) -> dict[str, Any]:
        return {"target_request_id": target_request_id, "cancelled": True}

    # 关闭后端(幂等):置 _closed 标记后释放 predictor;predictor 实现了
    # close() 才调用,从未构建过则无事可做。此后再调 hello 会因 _closed
    # 抛 RuntimeError。
    def shutdown(self) -> None:
        if self._closed:
            return
        self._closed = True
        predictor = self._predictor
        self._predictor = None
        if predictor is not None and hasattr(predictor, "close"):
            predictor.close()


# 计算字节串的 SHA-256 十六进制摘要(小写)。
def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


# 流式计算文件的 SHA-256(每次读 1 MiB),避免把大 checkpoint 整体载入内存。
def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


# 解码 PNG 载荷:先手工过一遍容器门禁(见 _validate_png_container),再交
# cv2.imdecode 按 mode(cv2.IMREAD_COLOR / IMREAD_GRAYSCALE)解码。
# 参数 label:错误消息中的载荷名称。
# 返回:解码后的 numpy 数组;解码失败(imdecode 返回 None 或空数组)抛 ValueError。
def _decode_png(payload: bytes, mode: int, label: str) -> np.ndarray:
    _validate_png_container(payload, label)
    image = cv2.imdecode(np.frombuffer(payload, np.uint8), mode)
    if image is None or image.size == 0:
        raise ValueError(f"{label} PNG decode failed")
    return image


# 手工遍历 PNG chunk 结构做容器门禁(先于 cv2 解码执行,失败原因更明确):
# 签名、chunk 长度上限与边界、逐 chunk CRC32 校验、首个 chunk 必须是 13 字节
# IHDR、必须出现 IDAT、必须以 0 长度 IEND 结尾且之后没有多余字节。
# 异常:任何一条不满足都抛 ValueError,消息带 label 前缀。
def _validate_png_container(payload: bytes, label: str) -> None:
    if not payload.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError(f"{label} PNG decode failed: invalid signature")
    offset = 8
    saw_header = False
    saw_data = False
    while offset < len(payload):
        if offset + 12 > len(payload):
            raise ValueError(f"{label} PNG decode failed: truncated chunk")
        # 每个 chunk = 4 字节长度 + 4 字节类型 + data + 4 字节 CRC(共 12 字节
        # 开销);长度超过上限或越过文件末尾都视为被截断/伪造。
        length = struct.unpack(">I", payload[offset:offset + 4])[0]
        kind = payload[offset + 4:offset + 8]
        end = offset + 12 + length
        if length > MAX_INPUT_BYTES or end > len(payload):
            raise ValueError(f"{label} PNG decode failed: invalid chunk length")
        data = payload[offset + 8:offset + 8 + length]
        checksum = struct.unpack(">I", payload[offset + 8 + length:end])[0]
        # CRC32 覆盖 chunk 类型与数据字节,必须逐 chunk 匹配。
        if checksum != zlib.crc32(kind + data) & 0xFFFFFFFF:
            raise ValueError(f"{label} PNG decode failed: chunk checksum mismatch")
        # 第一个 chunk 必须是 IHDR(13 字节图像头);其后记录是否出现过 IDAT;
        # IEND 必须为 0 长度、出现在 IDAT 之后并恰好终止文件。
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


# 校验并规范化 predict 的提示参数,转为 numpy 数组。
# 参数:points 为 [x, y] 坐标对列表(最多 64 个,必须有限),labels 与 points
# 等长且每项取值只能是 0/1(0=负点,1=正点;bool 被显式拒绝),box 为可选
# [x0, y0, x1, y1](有限且 x0<x1、y0<y1)。
# 返回:(point_array, label_array, box_array);点或 box 缺失时对应项为 None。
# 异常:点数超限、类型/长度不匹配、坐标非有限、标签非 0/1、box 形状或大小
# 关系非法,或点与 box 全部缺失(至少要有一个提示)时抛 ValueError。
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


# 校验 SAM predictor 的返回并规范化为 (masks, scores)。
# 参数 returned:predictor.predict 的原始返回;image_size:当前图像 (宽, 高)。
# 约定:returned 必须是 (masks, scores, logits) 三元组;masks 形状
# (N, 高, 宽) 且 1 <= N <= MAX_CANDIDATES、与当前图像尺寸一致、像素二值
# (bool,或仅含 0/1 的数值型,后者统一转成 bool);scores 形状 (N,) 且全部
# 为有限数字。
# 返回:bool masks 与 float64 scores;不符合约定抛 ValueError。
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
    # 数值型 mask 必须只含 0/1,统一转成 bool 再返回。
    if masks.dtype != np.bool_:
        if not np.issubdtype(masks.dtype, np.number) or not np.isfinite(masks).all() or not set(np.unique(masks).tolist()).issubset({0, 1}):
            raise ValueError("predictor candidate masks must be binary")
        masks = masks.astype(bool)
    if any(not math.isfinite(float(score)) for score in scores):
        raise ValueError("predictor returned a non-finite candidate score")
    return masks, scores.astype(np.float64)
