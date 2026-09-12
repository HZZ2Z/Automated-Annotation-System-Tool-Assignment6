# SAM Video 批量传播后端:官方 SAM 2 video predictor 的 job 级状态机适配层。
#
# 用途:被 python/sam_video_worker.py(由 Godot 客户端拉起的驻留 Python 子进程)
# 调用,按 sam-video-v1 协议提供 hello / open_batch / add_mask / propagate /
# cancel / reset_batch / shutdown:open_batch 装入"关键帧 + 1..MAX_TARGETS(30)
# 个目标帧"并初始化推理状态;add_mask 在关键帧(本地索引 0)提交唯一的
# region mask;propagate 把关键帧 mask 向后传播到各目标帧,产出只读候选
# mask;cancel 使当前批作废。协议、路径、hash 或状态不一致以及进程错误都会
# 让整批作废(失败不静默降级)。
#
# 安全边界(门禁):一切文件读写被限制在 job 目录内——只接受相对、无符号
# 链接、SHA-256 摘要匹配的 PNG/JPEG;路径越界、摘要不符、容器或像素非法、
# 读取期间文件被改动一律抛异常;runtime 帧与输出 mask 经临时文件 + fsync +
# 原子改名落盘;运行时只按调用方传入的 config/checkpoint/device 加载 SAM 2,
# 不自动安装 sam2、不下载 checkpoint。
#
# 输入:构造参数(job 目录、SAM 2 config/checkpoint 绝对路径、device、可选
# predictor_factory 测试替身)与各方法参数;输出:可 JSON 序列化的字典。
# 生命周期:每个 worker 进程一个实例,由协议主循环单线程串行调用;predictor
# 惰性创建,同一时刻至多一个活动批,shutdown 幂等。
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


# 从 job 目录读取的单个文件字节上限(64 MiB):帧 PNG、mask PNG、runtime JPEG
# 等超限一律拒绝。
MAX_INPUT_BYTES = 64 * 1024 * 1024
# 单帧图像像素数上限(32 M 像素,宽*高):防止超大帧耗尽内存。
MAX_IMAGE_PIXELS = 32 * 1024 * 1024
# open_batch 帧描述符的精确字段集(多一字段、少一字段都拒绝)。
_FRAME_KEYS = frozenset({
    "path", "sha256", "width", "height", "playback_index", "frame_id"
})
# add_mask mask 描述符的精确字段集(roi 为 [x, y, width, height])。
_MASK_KEYS = frozenset({"path", "sha256", "roi"})


# SAM 2 视频预测后端:持有唯一的 predictor 与至多一个活动批的推理状态。
# 关键属性:job_dir(已 resolve 的任务目录,一切文件读写的边界)、
# config_path/checkpoint_path/device(SAM 2 加载参数,首次 hello 才校验并
# 使用)、_predictor(惰性创建的官方 predictor)、_actual_device(实际生效
# 设备)、_state(当前批的 predictor 推理状态,None 表示无活动批)、_frames
# (活动批冻结的规范化帧描述符)、_runtime_dir/_runtime_frames(为 predictor
# 准备的 runtime JPEG 目录与描述符)、_batch_serial(单调递增批序号,runtime
# 目录与输出文件命名用)、_generation(批纪元计数,取消/重置都自增,用于识别
# 过期状态)、_propagation_serial(输出文件名用的传播序号)、_mask_added/
# _cancelled/_closed(关键帧 mask 已提交、批已取消、已停机标记)。
# 线程模型:非线程安全,由 worker 主循环单线程串行调用。
class SamVideoBackend:
    """Own one loaded predictor and at most one fresh batch inference state."""

    # 构造后端:只做 job 目录门禁与参数登记,不加载 SAM 2(懒加载推迟到 hello)。
    # 参数 job_dir:任务隔离目录,须为已存在的真实目录(非符号链接、可
    #   resolve);config_path/checkpoint_path:SAM 2 配置与权重路径(此处不
    #   校验,首次 hello 构建时才校验);device:"auto"|"cpu"|"cuda";
    #   predictor_factory:测试注入替身,签名 (config, checkpoint, device) -> predictor。
    # 异常:job 目录是符号链接、无法 resolve(不存在等)或不是目录、device
    #   取值非法时抛 ValueError。
    # 副作用:登记实例状态并初始化空批状态;输入上限复制为实例属性(默认取
    #   模块常量)。
    def __init__(
        self,
        job_dir: str | Path,
        config_path: str,
        checkpoint_path: str,
        device: str,
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
        # device 取值在此先行校验;实际设备选择推迟到 _official_predictor。
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

    # 握手:确保 predictor 已构建,并返回后端描述信息。
    # 返回字典:backend(实现标识 "sam2-video-predictor")、persistent(True,
    # predictor 跨请求驻留)、device(实际生效设备)、checkpoint_sha256
    # (checkpoint 文件存在且非符号链接时为其 SHA-256,否则为空串)。
    # 副作用:首次调用时经工厂(默认 _official_predictor)构建 predictor 并
    #   记录实际设备;之后的调用只重复计算 checkpoint 摘要。
    # 异常:已 shutdown 抛 RuntimeError;工厂返回的对象缺少 init_state/
    #   add_new_mask/propagate_in_video/reset_state 接口、或上报设备非法时抛
    #   RuntimeError;工厂内部异常原样冒泡。
    def hello(self) -> dict[str, Any]:
        self._require_open()
        # 惰性构建:predictor 只在首次 hello(或首个 open_batch)时加载一次。
        if self._predictor is None:
            factory = self._predictor_factory or self._official_predictor
            predictor = factory(self.config_path, self.checkpoint_path, self.device)
            # 接口门禁:predictor 必须实现视频预测所需的四个方法(鸭子类型检查)。
            required = ("init_state", "add_new_mask", "propagate_in_video", "reset_state")
            if predictor is None or any(not callable(getattr(predictor, name, None)) for name in required):
                raise RuntimeError("predictor factory returned an invalid SAM video predictor")
            self._predictor = predictor
            # 实际设备:优先读取工厂标注在 predictor 上的 sam_video_device;
            # 替身没有该属性时,请求为 cpu/cuda 则按请求记录,否则视为 cpu。
            self._actual_device = getattr(
                predictor,
                "sam_video_device",
                self.device if self.device in {"cpu", "cuda"} else "cpu",
            )
            if self._actual_device not in {"cpu", "cuda"}:
                raise RuntimeError("predictor reported an invalid device")
        # checkpoint 摘要:文件存在且非符号链接时流式计算 SHA-256,供客户端追溯。
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

    # 官方 predictor 工厂:校验参数、选择设备并构建 SAM 2 video predictor。
    # 参数:config_path/checkpoint_path 必须是绝对路径且指向真实存在的常规
    #   文件(非符号链接);requested_device ∈ {auto, cpu, cuda}。
    # 返回:带 sam_video_device 属性(实际设备)的官方 video predictor。
    # 异常:参数校验失败、torch/sam2 导入失败或模型构建失败均抛 RuntimeError
    # (依赖与 checkpoint 由运行环境预先备好,此处不做任何安装/下载)。
    @staticmethod
    def _official_predictor(
        config_path: str, checkpoint_path: str, requested_device: str
    ) -> Any:
        if requested_device not in {"auto", "cpu", "cuda"}:
            raise RuntimeError("device must be auto, cpu or cuda")
        # config/checkpoint 门禁:必须是绝对路径的常规文件(拒绝符号链接),
        # 并能 strict resolve(不存在等失败同样抛 RuntimeError)。
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

        # 惰性导入:只有真正构建官方 predictor 时才需要 torch 与 sam2。
        import torch
        import sam2
        from sam2.build_sam import build_sam2_video_predictor

        # UI 合同用绝对 config 文件路径,但 Hydra 只接受相对已安装 sam2 包的
        # 配置名:把绝对路径映射为 sam2 包内 configs/ 目录下的相对 POSIX 名
        # (保留 configs/ 前缀);不在任何 sam2 包的 configs/ 下则拒绝。
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
        # 设备选择:显式请求 cuda 但 CUDA 不可用时直接拒绝;auto 在有 CUDA
        # 时选 cuda,否则一律 cpu。
        if requested_device == "cuda" and not torch.cuda.is_available():
            raise RuntimeError("CUDA was requested but is unavailable")
        actual_device = "cuda" if requested_device == "cuda" or (
            requested_device == "auto" and torch.cuda.is_available()
        ) else "cpu"
        predictor = build_sam2_video_predictor(
            config_name, str(checkpoint), device=actual_device
        )
        # 把实际设备标注在 predictor 上,供 hello 回报(测试替身可仿照)。
        setattr(predictor, "sam_video_device", actual_device)
        return predictor

    # 打开新批:校验并冻结关键帧 + 目标帧,构建 runtime 输入并初始化推理状态。
    # 参数 frames:2..MAX_TARGETS+1 个帧描述符(第 0 个是关键帧,其余为按
    #   playback_index 严格递增的目标帧),每个含 path/sha256/width/height/
    #   playback_index/frame_id(字段细节见 _validate_new_frames)。
    # 返回:{"batch_serial": 本批序号, "frame_count": 帧总数}。
    # 副作用:使上一个活动批失效并 reset;_batch_serial 自增;在 job 目录
    #   runtime/batch-NNNNNN/ 下写入 JPEG 帧;登记 _state/_frames 等;
    #   _generation 自增(旧状态引用全部过期)。
    # 异常:已 shutdown 抛 RuntimeError;帧校验失败抛 ValueError——此时已有
    #   的活动批也会一并作废(不一致的输入使整批不可信);旧批释放之后,
    #   runtime 构建失败抛 ValueError、init_state 失败抛 RuntimeError,此时
    #   旧批已释放、新批未建立(后端处于无活动批状态)。
    def open_batch(self, frames: list[dict[str, Any]]) -> dict[str, Any]:
        self._require_open()
        # 先记住旧批:新帧校验失败时把它一并作废(不一致的输入使整批不可信)。
        previous_state = self._state
        try:
            normalized, payloads = self._validate_new_frames(frames)
        except Exception:
            if previous_state is not None:
                self._invalidate_failed_batch(previous_state)
            raise
        # 确保 predictor 已加载(首个批才会真正触发模型加载)。
        self.hello()
        # 一个实例同一时刻只保留一个活动批:开新批前先释放旧批。
        if self._state is not None:
            self._release_batch()
        self._batch_serial += 1
        runtime, runtime_frames = self._build_runtime(
            self._batch_serial, normalized, payloads
        )
        # 用 runtime JPEG 目录初始化 predictor 推理状态(按目录内文件名序读帧)。
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

    # 在关键帧(本地索引 0)上提交唯一的 region mask。
    # 参数 mask_descriptor:含 path/sha256/roi 的 mask 描述符;object_id:协议
    #   对象 ID(必须等于 OBJECT_ID)。
    # 返回:{"local_index": 0, "object_id": OBJECT_ID}。
    # 副作用:调用 predictor.add_new_mask 把 mask 写入推理状态;成功后置
    #   _mask_added(每批只允许一个关键帧 mask)。
    # 异常:任何失败都会先把当前批作废再上抛——描述符/门禁问题抛 ValueError,
    #   SAM 调用或状态问题抛 RuntimeError。
    def add_mask(self, mask_descriptor: dict[str, Any], object_id: int) -> dict[str, Any]:
        state, generation = self._active_state()
        try:
            return self._add_mask_active(
                state, generation, mask_descriptor, object_id
            )
        except Exception:
            self._invalidate_failed_batch(state)
            raise

    # add_mask 的实际执行体(独立成方法以便失败时拿到当前状态精确作废)。
    # 异常:object_id 不符、批已有关键帧 mask、mask 描述符字段/ROI/尺寸/像素
    #   不合法抛 ValueError;SAM add_new_mask 失败、或执行期间批被取消/重置
    #   (状态过期)抛 RuntimeError。
    def _add_mask_active(
        self,
        state: Any,
        generation: int,
        mask_descriptor: dict[str, Any],
        object_id: int,
    ) -> dict[str, Any]:
        _require_object_id(object_id)
        # 每个批只允许提交一个关键帧 mask:先提交 mask 才允许传播。
        if self._mask_added:
            raise RuntimeError("the batch already has its keyframe mask")
        self._validate_active_inputs()
        descriptor = _exact_dict(mask_descriptor, _MASK_KEYS, "mask descriptor")
        width = self._frames[0]["width"]
        height = self._frames[0]["height"]
        # ROI 门禁:关键帧 mask 必须覆盖整幅图(roi == [0, 0, width, height])。
        roi = descriptor["roi"]
        if (
            not isinstance(roi, list)
            or len(roi) != 4
            or any(isinstance(item, bool) or not isinstance(item, int) for item in roi)
            or roi != [0, 0, width, height]
        ):
            raise ValueError("key mask must use the full-image ROI")
        # PNG 经 hash 门禁读取后解码:必须与关键帧同尺寸,且像素只有 0/255。
        _, payload = self._read_job_png(
            descriptor["path"], descriptor["sha256"], "key mask"
        )
        mask = _decode_png(payload, cv2.IMREAD_GRAYSCALE, "key mask")
        if mask.shape != (height, width):
            raise ValueError("key mask decoded dimensions do not match the key frame")
        if not set(np.unique(mask).tolist()).issubset({0, 255}):
            raise ValueError("key mask must contain only binary 0/255 pixels")
        # mask 以 bool 数组(>0 即前景)写入关键帧(frame_idx=0)的推理状态。
        try:
            self._predictor.add_new_mask(
                inference_state=state,
                frame_idx=0,
                obj_id=OBJECT_ID,
                mask=mask > 0,
            )
        except Exception as exc:
            raise RuntimeError(f"SAM video predictor add_new_mask failed: {exc}") from exc
        # 竞态防护:执行期间批被取消/重置(纪元变化)则结果作废。
        if self._state is not state or self._generation != generation:
            raise RuntimeError("key mask result became stale after batch reset")
        self._mask_added = True
        return {"local_index": 0, "object_id": OBJECT_ID}

    # 把关键帧 mask 向后传播到目标帧,产出只读候选 mask。
    # 参数 count:目标帧数(1..MAX_TARGETS,且不得超过批内目标帧数);
    #   object_id:协议对象 ID(必须等于 OBJECT_ID)。
    # 返回:{"masks": [候选描述符...]},描述符结构见 _write_output。
    # 副作用:消费 predictor 的传播输出流;_propagation_serial 自增;把每个
    #   目标帧的 mask 写为 outputs/ 下的 PNG。
    # 异常:任何失败都会先把当前批作废再上抛——count/object_id 非法、未先
    #   add_mask、输出不符合约定抛 ValueError;SAM 传播调用失败或状态问题抛
    #   RuntimeError。
    def propagate(self, count: int, object_id: int) -> dict[str, Any]:
        state, generation = self._active_state()
        try:
            return self._propagate_active(state, generation, count, object_id)
        except Exception:
            self._invalidate_failed_batch(state)
            raise

    # propagate 的实际执行体(独立成方法以便失败时拿到当前状态精确作废)。
    # 异常:count 越界或超过批内目标帧数、尚未 add_mask、传播输出不合法
    #   (索引重复/越界、对象 ID 不符、logits 形状或数值非法、输出缺失)抛
    #   ValueError;SAM 传播调用失败或状态过期抛 RuntimeError。
    def _propagate_active(
        self, state: Any, generation: int, count: int, object_id: int
    ) -> dict[str, Any]:
        _require_object_id(object_id)
        if isinstance(count, bool) or not isinstance(count, int) or not 1 <= count <= MAX_TARGETS:
            raise ValueError(f"count must be an integer from 1 to {MAX_TARGETS}")
        # 目标帧数不能超过 open_batch 装入的目标帧个数(总帧数 - 关键帧)。
        if count > len(self._frames) - 1:
            raise ValueError("count exceeds the opened batch targets")
        if not self._mask_added:
            raise RuntimeError("add_mask must succeed before propagate")
        self._validate_active_inputs()
        # 从关键帧(本地索引 0)起按播放顺序正向传播最多 count 帧,输出为流。
        try:
            stream = self._predictor.propagate_in_video(
                inference_state=state,
                start_frame_idx=0,
                max_frame_num_to_track=count,
                reverse=False,
            )
            outputs: dict[int, tuple[np.ndarray, float]] = {}
            # 逐项消费传播输出流:每项是 (本地帧索引, 对象 ID 数组, logits)。
            for returned in stream:
                # 流式消费期间的竞态防护:批被取消/重置则立即作废。
                if self._state is not state or self._generation != generation:
                    raise RuntimeError("predictor output became stale after batch reset")
                local_index, returned_object_ids, logits = _video_output(returned)
                if not 0 <= local_index <= count or local_index in outputs:
                    raise ValueError("predictor returned an invalid or duplicate local frame index")
                # 输出门禁:每帧必须恰好返回一个对象,且 ID 等于协议 OBJECT_ID。
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
        # 校验类异常原样上抛;SAM 调用自身的其他异常统一包装为 RuntimeError。
        except (ValueError, RuntimeError):
            raise
        except Exception as exc:
            raise RuntimeError(f"SAM video predictor propagation failed: {exc}") from exc
        if self._state is not state or self._generation != generation:
            raise RuntimeError("predictor output became stale after batch reset")
        # 完整性门禁:除关键帧 0 外,1..count 每个目标帧都必须有输出。
        expected = set(range(1, count + 1))
        if set(outputs) - {0} != expected:
            raise ValueError("predictor target output count or indices do not match the request")
        # 落盘前最后复核冻结帧与 runtime 未被改动,再按目标帧序写出 mask。
        self._validate_active_inputs()
        self._propagation_serial += 1
        serial = self._propagation_serial
        masks = [
            self._write_output(outputs[index][0], outputs[index][1], serial, index)
            for index in range(1, count + 1)
        ]
        return {"masks": masks}

    # 取消当前批:置取消标记并推进纪元,使后续 add_mask/propagate 立即失败。
    # 参数 request_id:被取消的协议请求 ID(原样回显,供调用方关联)。
    # 返回:{"target_request_id": request_id, "cancelled": True}。
    # 副作用:_cancelled 置 True、_generation 自增;批本身由协议层随后
    #   reset_batch 释放(worker 在 cancel 后立即 reset)。
    # 异常:request_id 不是非空字符串抛 ValueError;不要求已有活动批。
    def cancel(self, request_id: str) -> dict[str, Any]:
        if not isinstance(request_id, str) or not request_id:
            raise ValueError("request_id must be a non-empty string")
        self._cancelled = True
        self._generation += 1
        return {"target_request_id": request_id, "cancelled": True}

    # 释放当前批:清空批状态并 reset predictor 推理状态(无批时幂等无事)。
    # 返回:{"reset": True}。
    # 异常:已 shutdown 抛 RuntimeError;reset_state 失败抛 RuntimeError
    # (状态引用已先行清空,坏状态不会被复用)。
    def reset_batch(self) -> dict[str, Any]:
        self._require_open()
        self._release_batch()
        return {"reset": True}

    # 关闭后端(幂等):释放当前批后关闭并丢弃 predictor;此后所有操作都因
    # _closed 抛 RuntimeError。predictor 实现了 close() 才调用。
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

    # 取当前活动批的 (推理状态, 纪元) 二元组;无批、已取消或已 shutdown 都抛
    # RuntimeError。纪元在操作结束后用于识别批是否已被取消/重置(状态过期)。
    def _active_state(self) -> tuple[Any, int]:
        self._require_open()
        if self._state is None:
            raise RuntimeError("open_batch must succeed before using the batch")
        if self._cancelled:
            raise RuntimeError("the current batch was cancelled")
        return self._state, self._generation

    # 停机门禁:shutdown 之后的任何操作都抛 RuntimeError。
    def _require_open(self) -> None:
        if self._closed:
            raise RuntimeError("SAM video backend is shut down")

    # 失败作废:仅当传入状态仍是当前批时才释放批;释放过程中的异常一律吞掉
    # (安全性论证见函数内英文注释)。
    def _invalidate_failed_batch(self, state: Any) -> None:
        if self._state is not state:
            return
        try:
            self._release_batch()
        except Exception:
            # State references are cleared before reset_state is invoked, so a
            # reset failure cannot make the failed inference state reusable.
            pass

    # 释放批:先清空全部批状态引用并推进纪元,再调用 predictor.reset_state。
    # 先清引用保证:即使 reset 失败,坏状态也不可能被复用;reset 失败包装为
    # RuntimeError 上抛。
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

    # 校验 open_batch 的帧描述符列表,并经门禁读取全部帧 PNG(只校验不落盘)。
    # 参数 frames:原始帧描述符列表。
    # 返回:(normalized, payloads)——normalized 为逐字段校验后的描述符列表,
    #   payloads 为与之一一对应的 PNG 字节。
    # 异常:数量不在 2..MAX_TARGETS+1、字段不精确、路径/摘要/尺寸/
    #   playback_index/frame_id 非法、playback_index 不严格递增、path 重复、
    #   PNG 读取或解码失败、解码尺寸与描述符不符、超出像素上限、各帧尺寸
    #   不一致,均抛 ValueError。
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
            # playback_index 必须严格递增(目标帧按播放顺序排列,兼具唯一性)。
            if playback <= previous_playback:
                raise ValueError("frame playback indices must be unique and strictly increasing")
            if path in paths:
                raise ValueError("frame paths must be unique")
            previous_playback = playback
            paths.add(path)
            # 帧图像经 hash 门禁读取并试解码:尺寸必须与描述符一致且不超像素上限。
            _, payload = self._read_job_png(path, digest, f"frame {index}")
            image = _decode_png(payload, cv2.IMREAD_COLOR, f"frame {index}")
            if image.shape[:2] != (height, width):
                raise ValueError(f"frame {index} decoded dimensions do not match its descriptor")
            if width * height > self.max_image_pixels:
                raise ValueError(f"frame {index} exceeds the configured pixels limit")
            # 整批帧必须尺寸一致(SAM 视频序列的要求)。
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

    # 为 predictor 构建 runtime 输入:把冻结帧重编码为 JPEG 写入
    # runtime/batch-NNNNNN/(SAM 视频接口按目录内文件名序读取帧序列)。
    # 参数 serial:批序号(目录名);frames:规范化帧描述符;payloads:帧 PNG 字节。
    # 返回:(runtime 目录绝对路径, runtime 帧描述符列表[path/sha256/width/
    #   height],路径相对 job 目录)。
    # 异常:runtime 目录非法(符号链接/非常规目录)、批目录名冲突、JPEG 重
    #   编码或写入失败抛 ValueError/RuntimeError;末尾经 _validate_runtime 复核。
    # 副作用:创建 runtime/ 与批目录(权限 0o700),写入与帧数相同的 JPEG。
    def _build_runtime(
        self, serial: int, frames: list[dict[str, Any]], payloads: list[bytes]
    ) -> tuple[Path, list[dict[str, Any]]]:
        # runtime 根目录门禁:已存在则必须是常规目录(拒绝符号链接),否则以
        # 0o700 权限新建。
        root = self.job_dir / "runtime"
        if root.exists():
            if root.is_symlink() or not root.is_dir():
                raise ValueError("runtime must be a regular directory")
        else:
            root.mkdir(mode=0o700)
        # 批目录名含单调递增批序号;已存在即视为冲突,拒绝复用或覆盖。
        runtime = root / f"batch-{serial:06d}"
        if runtime.exists() or runtime.is_symlink():
            raise ValueError("runtime batch directory collision")
        runtime.mkdir(mode=0o700)
        runtime_frames: list[dict[str, Any]] = []
        # 逐帧把 PNG 解码后以质量 100 重编码为 JPEG(SAM 视频接口按帧序列读图),
        # 再过一遍 JPEG 容器门禁,确保写出的文件可被 predictor 读取。
        for index, payload in enumerate(payloads):
            image = _decode_png(payload, cv2.IMREAD_COLOR, f"runtime source frame {index}")
            encoded_ok, encoded = cv2.imencode(
                ".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 100]
            )
            if not encoded_ok:
                raise RuntimeError(f"runtime frame {index} JPEG encoding failed")
            runtime_payload = encoded.tobytes()
            _validate_jpeg_container(runtime_payload, f"runtime frame {index}")
            # 原子写:文件名即帧序(000000.jpg..),O_EXCL 独占创建(0o600),
            # 写入并 fsync 落盘。
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
        # 写完后立即复核目录内容与每个文件的路径/摘要/尺寸。
        self._validate_runtime(runtime, frames, runtime_frames)
        return runtime, runtime_frames

    # 复核当前批的全部冻结输入:重读每个帧 PNG(hash + 尺寸)并整体复核
    # runtime 目录,防止两次操作之间磁盘内容被改动(TOCTOU 防护)。
    # 异常:无活动批抛 RuntimeError;帧或 runtime 校验失败抛 ValueError。
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

    # 校验 runtime 批目录与描述符:lstat 确认是常规目录(非符号链接)、描述符
    # 数量与冻结帧一致、目录内容恰好是 000000.jpg..NNNNNN.jpg(无缺失、无
    # 多余)、每个描述符路径与本地顺序一致、每个 JPEG 经 hash 门禁读取且解码
    # 尺寸与冻结帧一致。任一不满足抛 ValueError。
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
        # 目录内容必须恰好等于预期文件名集合(缺失或多余文件都拒绝)。
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

    # 把一个传播输出 mask 写为 outputs/ 下的二值 PNG(原子写)。
    # 参数 mask:bool 数组(整幅目标帧尺寸);score:该帧的置信度分数;
    #   serial:传播序号;local_index:目标帧本地索引(1..count)。
    # 返回:候选描述符 {local_index, playback_index, frame_id, object_id,
    #   path(相对 job 目录), roi=[x,y,w,h], score, sha256}。
    # 异常:score 非有限、PNG 编码失败、outputs/ 非常规目录或目标文件名冲突
    # 抛 ValueError/RuntimeError。
    # 副作用:必要时创建 outputs/(权限 0o700);先写临时文件(O_EXCL 独占
    #   创建、权限 0o600、fsync 落盘)再 os.replace 原子改名;无论成败都在
    #   finally 里清理临时文件。
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
        # 只保存前景的紧包围盒(ROI)以缩小 PNG 体积;空 mask 也是合法输出,
        # 此时 ROI 退化为整幅帧(内容为全零 PNG)。
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
        # 输出目录门禁:已存在则必须是常规目录(拒绝符号链接),否则以 0o700 创建。
        directory = self.job_dir / "outputs"
        if directory.exists():
            if directory.is_symlink() or not directory.is_dir():
                raise ValueError("outputs must be a regular directory")
        else:
            directory.mkdir(mode=0o700)
        # 文件名含传播序号与本地索引;写入前后都检查冲突,拒绝覆盖已有文件。
        name = f"propagate-{serial:06d}-{local_index:06d}.png"
        output = directory / name
        if output.exists() or output.is_symlink():
            raise ValueError(f"output collision: {name}")
        # 原子写:临时文件名带 PID,O_EXCL 独占创建(0o600);写入并 fsync 落盘
        # 后再次确认目标无冲突,再 os.replace 原子改名;finally 兜底删除临时
        # 文件(改名成功后 unlink 落空,仅忽略 FileNotFoundError)。
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

    # 从 job 目录安全读取一个 PNG(帧与关键 mask 的唯一读取通道),门禁细节
    # 见 _read_job_file。
    # 返回:(resolve 后的绝对路径, 原始字节);门禁失败抛 ValueError。
    def _read_job_png(
        self, relative_path: str, expected_sha256: str, label: str
    ) -> tuple[Path, bytes]:
        return self._read_job_file(
            relative_path, expected_sha256, label, frozenset({".png"})
        )

    # 从 job 目录安全读取一个 JPEG(runtime 帧复核用),门禁细节同上。
    # 返回:(resolve 后的绝对路径, 原始字节);门禁失败抛 ValueError。
    def _read_job_jpeg(
        self, relative_path: str, expected_sha256: str, label: str
    ) -> tuple[Path, bytes]:
        return self._read_job_file(
            relative_path, expected_sha256, label, frozenset({".jpg", ".jpeg"})
        )

    # job 目录内文件的安全读取通道(帧 PNG、mask PNG 与 runtime JPEG 共用):
    # 路径与摘要双重门禁,并防护读取期间的文件替换(TOCTOU)。
    # 参数 relative_path:job 目录内相对 POSIX 路径(后缀必须在 suffixes 白名单
    #   内);expected_sha256:期望的 64 位小写十六进制摘要;label:错误消息里的
    #   载荷名;suffixes:允许的文件后缀集合。
    # 返回:(resolve 后的绝对路径, 原始字节)。
    # 异常:路径格式非法(非相对、含反斜杠、空段/"."/".."、后缀不符)、job
    #   目录或目标不是常规非符号链接文件、越出 job 目录、超过字节上限、读取
    #   期间文件身份(设备号/inode/大小/mtime)变化或摘要不匹配,均抛
    #   ValueError。
    def _read_job_file(
        self,
        relative_path: str,
        expected_sha256: str,
        label: str,
        suffixes: frozenset[str],
    ) -> tuple[Path, bytes]:
        path_text = _relative_file(relative_path, f"{label} path", suffixes)
        digest = _digest(expected_sha256, f"{label} digest")
        # lstat(不跟随链接)复核 job 目录与目标文件:job 目录必须仍是常规
        # 目录、目标必须是常规文件,防止读取路径被符号链接劫持。
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
        # resolve 之后必须仍位于 job 目录内,防止符号链接逃逸出任务目录。
        try:
            resolved = candidate.resolve(strict=True)
            resolved.relative_to(self.job_dir)
        except (OSError, ValueError) as exc:
            raise ValueError(f"{label} path is outside the job directory") from exc
        if metadata.st_size > self.max_input_bytes:
            raise ValueError(f"{label} exceeds the configured bytes limit")
        # O_NOFOLLOW 打开(最终打开的也不能是符号链接);分块读取并累计字节
        # 数,超限立即拒绝(单块大小取 1 MiB 与剩余额度中的较小者)。
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
        # 读取前后三次核对文件身份(设备号/inode/大小/mtime):打开前(fstat)、
        # 读完后(fstat)、关闭后(lstat)——任一变化都说明读取期间文件被替换。
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
        # 最终门禁:三次身份一致、字节数与 fstat 一致、SHA-256 与期望一致。
        if (
            identity_before != identity_after
            or identity_after != identity_path
            or len(payload) != opened_after.st_size
            or hashlib.sha256(payload).hexdigest() != digest
        ):
            raise ValueError(f"{label} digest does not match or file changed during read")
        return resolved, payload


# 解包 predictor 传播输出的一项:必须是 (本地帧索引, 对象 ID 数组, logits)
# 三元组,且本地帧索引为整数(bool 拒绝,int 与 numpy 整数均可)。
# 返回:(int 本地索引, 原始对象 ID 数组, 原始 logits);不符合约定抛 ValueError。
def _video_output(returned: Any) -> tuple[int, Any, Any]:
    if not isinstance(returned, tuple) or len(returned) != 3:
        raise ValueError("predictor output must be a frame/object/logits tuple")
    local_index = returned[0]
    if isinstance(local_index, bool) or not isinstance(local_index, (int, np.integer)):
        raise ValueError("predictor local frame index must be an integer")
    return int(local_index), returned[1], returned[2]


# 把 predictor 输出的 logits 转成二值 mask 与置信度分数。
# 参数 logits:torch/numpy 数值数组;frame:目标帧描述符(提供宽高)。
# 返回:(bool mask, float score)——mask 取 logits > 0;score 为全平面
#   sigmoid(|logit|) 的均值。
# 异常:logits 含非有限数值、形状既不是 (1,1,H,W) 也不是 (1,H,W) 或与目标帧
#   尺寸不符、score 非有限,抛 ValueError。
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
    # logits > 0 即前景;置信度取 sigmoid(|logit|)(幅值截断到 80 防止 exp
    # 溢出),全平面均值作为该帧候选的 score。
    mask = plane > 0.0
    confidence = 1.0 / (1.0 + np.exp(-np.clip(np.abs(plane.astype(np.float64)), 0.0, 80.0)))
    score = float(np.mean(confidence))
    if not math.isfinite(score):
        raise ValueError("predictor score is not finite")
    return mask, score


# 把 torch 张量形的外部值搬到 CPU 并转为 numpy:鸭子类型调用 detach/to/numpy,
# 不导入 torch;已是 numpy 的值原样转换。
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


# 校验协议对象 ID:必须恰好等于 OBJECT_ID(bool 与其他值都拒绝)。
# 返回:原值;不合法抛 ValueError。
def _require_object_id(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value != OBJECT_ID:
        raise ValueError(f"object_id must be {OBJECT_ID}")
    return value


# 要求 value 是字段恰好等于 keys 的字典(多字段、少字段都拒绝)。
# 返回:原字典;不符合抛 ValueError(label 用于错误消息)。
def _exact_dict(value: object, keys: frozenset[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or frozenset(value) != keys:
        raise ValueError(f"{label} has invalid fields")
    return value


# 校验非负整数(bool 不是整数,显式拒绝)。
# 返回:原值;不合法抛 ValueError(label 用于错误消息)。
def _nonnegative_integer(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"{label} must be a non-negative integer")
    return value


# 校验正整数(>= 1;bool 显式拒绝)。
# 返回:原值;不合法抛 ValueError(label 用于错误消息)。
def _positive_integer(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise ValueError(f"{label} must be a positive integer")
    return value


# 校验 64 位小写十六进制的 SHA-256 摘要字符串。
# 返回:原值;不合法抛 ValueError(label 用于错误消息)。
def _digest(value: object, label: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise ValueError(f"{label} must be a lower-case SHA-256 digest")
    return value


# 校验 job 目录内相对 PNG 路径(门禁细节见 _relative_file)。
# 返回:规范化的 POSIX 路径字符串;不合法抛 ValueError。
def _relative_png(value: object, label: str) -> str:
    return _relative_file(value, label, frozenset({".png"}))


# 校验防目录穿越的相对文件路径:必须是非空字符串、不含反斜杠、POSIX 相对
# 路径、后缀在白名单内、每段都不为空/"."/".."。
# 返回:规范化 POSIX 路径字符串;不合法抛 ValueError(label 用于错误消息)。
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


# JPEG 容器门禁:只检查 SOI(FF D8)开头与 EOI(FF D9)结尾;更完整的校验
# 交给 cv2 解码与尺寸/摘要比对。
def _validate_jpeg_container(payload: bytes, label: str) -> None:
    if not payload.startswith(b"\xff\xd8") or not payload.endswith(b"\xff\xd9"):
        raise ValueError(f"{label} JPEG decode failed: invalid container")


# 解码 JPEG 载荷:先过容器门禁再交 cv2.imdecode;失败抛 ValueError。
def _decode_jpeg(payload: bytes, mode: int, label: str) -> np.ndarray:
    _validate_jpeg_container(payload, label)
    image = cv2.imdecode(np.frombuffer(payload, np.uint8), mode)
    if image is None or image.size == 0:
        raise ValueError(f"{label} JPEG decode failed")
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
