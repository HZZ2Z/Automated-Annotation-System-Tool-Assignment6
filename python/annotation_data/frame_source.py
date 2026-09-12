# 帧源(frame_source)归一化库模块:把视频原子发布为帧序列数据集。
#
# 用途:对一段 FFmpeg 支持的视频执行 ffprobe 探测 → ffmpeg 无丢帧抽帧
# (-vsync 0) → 逐帧图像校验与相邻帧相似度打分 → 生成 dataset-manifest-v1;
# 全部成功后才把同级 staging 目录原子发布为 frames/ + manifest.json 的归一化
# 数据集目录。任何失败或取消都会清理 staging 并上抛异常,输出目录要么完整
# 出现、要么不出现;源视频与已有数据始终只读。
#
# 角色与协作:核心实现库,被顶层 python/frame_source.py 命令行外壳(Godot
# 客户端以子进程调起)复用,测试与其他调用方也可直接 import。协作模块:
# contracts(schema 与 manifest 语义校验)、similarity.normalized_mad(帧间
# 相似度分数)。取消采用协作式:cancel_check 回调在各阶段间隙轮询,命中即抛
# VideoImportCancelled 并终止、清理。
"""Normalize an FFmpeg-supported video into the dataset frame-source format."""

import hashlib
import json
import math
import os
from pathlib import Path
import re
import select
import shutil
import subprocess
import tempfile
import time
from typing import Any, Callable
from uuid import uuid4

import cv2
import numpy as np

from annotation_data.contracts import validate_instance, validate_manifest_semantics
from annotation_data.similarity import normalized_mad


# ffmpeg 输出帧文件名的合法形式(frame_000001.png),捕获序号用于连续性校验。
_FRAME_NAME = re.compile(r"frame_(\d{6})\.png$")
# 仓库根目录(python/ 的上一级)与项目自带的 FFmpeg 可执行文件目录。
_PROJECT_ROOT = Path(__file__).resolve().parents[2]
_PROJECT_MEDIA_BIN = _PROJECT_ROOT / ".tools" / "ffmpeg" / "bin"

# 回调类型别名:progress_callback 接收进度快照字典;cancel_check 为无参轮询
# 回调,返回 True 表示外部请求取消。
ProgressCallback = Callable[[dict[str, Any]], None]
CancelCheck = Callable[[], bool]


# 协作取消信号:cancel_check 轮询命中时抛出;调用方(命令行外壳/Godot)以它
# 区分「已请求的取消」与「真正的失败」(含义见英文 docstring)。
class VideoImportCancelled(RuntimeError):
    """Raised after a cooperative video-import cancellation request."""


# 解析媒体工具(ffmpeg/ffprobe)的可执行路径。
# 参数 name:工具名。优先使用项目自带 .tools/ffmpeg/bin 下的固定版本(保证
#   可复现),其次回退到 PATH。
# 返回:可直接传给 subprocess 的可执行文件路径字符串。
# 异常:两者都不可用时抛 FileNotFoundError。
def _media_tool(name: str) -> str:
    project_tool = _PROJECT_MEDIA_BIN / name
    if project_tool.is_file() and os.access(project_tool, os.X_OK):
        return str(project_tool)
    resolved = shutil.which(name)
    if resolved is not None:
        return resolved
    raise FileNotFoundError(
        f"required media tool '{name}' was not found; expected an executable at "
        f"{project_tool} or on PATH"
    )


def decode_video(
    input_path: Path,
    output_dir: Path,
    *,
    progress_callback: ProgressCallback | None = None,
    cancel_check: CancelCheck | None = None,
    staging_dir: Path | None = None,
) -> dict[str, Any]:
    # 归一化主入口:探测 → 抽帧 → 重命名 → 逐帧校验/打分 → 构建/校验 manifest
    # → 原子发布(流程总览见上方英文 docstring)。
    # 参数 input_path:输入视频;output_dir:必须不存在的新输出目录;
    #   progress_callback:可选进度回调(快照字典含 version/state/stage/
    #   completed/total/fraction/message);cancel_check:可选取消轮询回调;
    #   staging_dir:可选显式 staging 目录(必须是 output_dir 的同级且不存在,
    #   默认自动生成同级隐藏临时目录)。
    # 返回:发布成功的 manifest 字典(与写入 manifest.json 的内容一致)。
    # 副作用:创建 staging 目录并最终发布或清理;不修改源视频。
    # 异常:FileExistsError(输出/staging 已存在)、FileNotFoundError(输入
    #   不存在)、ValueError(路径/内容/校验问题)、VideoImportCancelled
    #   (协作取消);其余异常同样先清理 staging 再原样上抛。
    """Decode ``input_path`` into ``output_dir`` and return its normalized metadata.

    The published directory is created only after probing, extraction, image checks,
    and manifest validation have all succeeded.
    """
    input_path = Path(input_path)
    output_dir = Path(output_dir)
    # 在创建输出前检查路径，避免覆盖已有数据。
    if output_dir.exists():
        raise FileExistsError(f"output directory already exists: {output_dir}")
    if not input_path.exists():
        raise FileNotFoundError(f"input video does not exist: {input_path}")
    if not input_path.is_file():
        raise ValueError(f"input video is not a file: {input_path}")
    if not output_dir.parent.is_dir():
        raise ValueError(f"output parent directory does not exist: {output_dir.parent}")
    # 先写入同级临时目录，全部校验通过后再发布。
    if staging_dir is None:
        staging_dir = output_dir.parent / f".{output_dir.name}.tmp-{uuid4().hex}"
    else:
        staging_dir = Path(staging_dir)
        if staging_dir == output_dir:
            raise ValueError("staging directory must differ from output directory")
        if staging_dir.parent.resolve() != output_dir.parent.resolve():
            raise ValueError("staging directory must be a sibling of the output directory")
    if staging_dir.exists():
        raise FileExistsError(f"staging directory already exists: {staging_dir}")

    # 标记 staging 是否已创建:异常时据此决定是否需要清理(成功发布后复位)。
    staging_created = False
    try:
        # 阶段 1 probe:ffprobe 读取流信息与逐帧时间戳。
        _emit_progress(progress_callback, "running", "probe", 0, 1, 0.0, "Probing video")
        _raise_if_cancelled(cancel_check)
        probe = _probe_video(input_path, cancel_check)
        _raise_if_cancelled(cancel_check)
        _emit_progress(progress_callback, "running", "probe", 1, 1, 0.05, "Video probe complete")
        # 阶段 2 extract:在 staging 内创建 frames/ 子目录,按探测到的帧数抽帧。
        staging_dir.mkdir()
        staging_created = True
        frames_dir = staging_dir / "frames"
        frames_dir.mkdir()
        expected_frames = len(probe["timestamps"])
        _emit_progress(
            progress_callback,
            "running",
            "extract",
            0,
            expected_frames,
            0.05,
            "Extracting frames",
        )
        _extract_frames(
            input_path,
            frames_dir,
            expected_frames,
            progress_callback,
            cancel_check,
        )
        # 帧名重命名为 0 基连续序号,并与探测时间戳数量核对(不符即丢帧/多帧)。
        frame_paths = _normalize_frame_names(frames_dir, cancel_check)
        if len(probe["timestamps"]) != len(frame_paths):
            raise ValueError(
                "video timestamp count does not match extracted frame count "
                f"({len(probe['timestamps'])} != {len(frame_paths)})"
            )
        _emit_progress(
            progress_callback,
            "running",
            "extract",
            expected_frames,
            expected_frames,
            0.8,
            "Frame extraction complete",
        )
        _emit_progress(
            progress_callback,
            "running",
            "validate",
            0,
            len(frame_paths),
            0.8,
            "Validating frames",
        )
        # 阶段 3 validate:逐张校验可读性/尺寸一致性,并计算相邻帧相似度分数。
        width, height, similarity_scores = _validate_and_score_frames(
            frame_paths, progress_callback, cancel_check
        )
        # 阶段 4 publish 准备:构建 manifest 并做 schema + 语义双重校验。
        manifest = _build_manifest(
            input_path,
            probe,
            frame_paths,
            width,
            height,
            similarity_scores,
            cancel_check,
        )
        _validate_manifest(manifest)
        _raise_if_cancelled(cancel_check)
        _emit_progress(
            progress_callback,
            "running",
            "publish",
            0,
            1,
            0.95,
            "Publishing normalized source",
        )
        # 先在 staging 内写 manifest.json,再原子改名发布:staging.replace 保证
        # 输出目录要么不存在、要么完整。
        _write_manifest(staging_dir / "manifest.json", manifest)
        _raise_if_cancelled(cancel_check)
        staging_dir.replace(output_dir)
        staging_created = False
        _emit_progress(
            progress_callback,
            "completed",
            "publish",
            1,
            1,
            1.0,
            "Import complete",
        )
        return manifest
    except Exception:
        # 失败清理:staging 已创建(无论自动生成还是外部指定)就整体删除;
        # 成功发布后 staging 已被改名,不会误删输出目录。
        if staging_created and staging_dir.exists():
            shutil.rmtree(staging_dir)
        raise


def _emit_progress(
    callback: ProgressCallback | None,
    state: str,
    stage: str,
    completed: int,
    total: int,
    fraction: float,
    message: str,
) -> None:
    # 构造并发送一份进度快照(无回调时为空操作)。
    # 参数 callback:进度回调;state:running/completed 等状态;stage:probe/
    #   extract/validate/publish 阶段名;completed/total:阶段内计数;fraction:
    #   总体进度(0..1,越界截断);message:人类可读说明。
    # 副作用:仅调用回调;回调抛出的异常原样上抛。
    if callback is None:
        return
    callback(
        {
            "version": 1,
            "state": state,
            "stage": stage,
            "completed": completed,
            "total": total,
            "fraction": min(1.0, max(0.0, fraction)),
            "message": message,
        }
    )


# 协作取消检查:cancel_check() 返回 True 时抛 VideoImportCancelled;未提供
# 回调则永不取消。
def _raise_if_cancelled(cancel_check: CancelCheck | None) -> None:
    if cancel_check is not None and cancel_check():
        raise VideoImportCancelled("video import cancelled")


def _probe_video(
    input_path: Path, cancel_check: CancelCheck | None = None
) -> dict[str, Any]:
    # 用 ffprobe 探测视频:读取首条视频流的宽高、名义帧率与逐帧时间戳。
    # 参数 input_path:输入视频;cancel_check:子进程运行期间的取消轮询回调。
    # 返回:{"width": int, "height": int, "nominal_fps": float, "timestamps":
    #   [float, ...]}——timestamps 与解码出的帧一一对应(单位为秒,单调不减,
    #   首帧为负时整体平移到 0 起点)。
    # 异常(ValueError):无可读视频流、宽高非法、无有效名义帧率、无帧时间戳、
    #   部分帧缺时间戳、时间戳非法或非单调。
    payload = _run_json(
        # ffprobe 参数:-v error 只输出错误;-select_streams v:0 只取第一条视频
        # 流;-show_streams/-show_frames 输出流与逐帧信息;-show_entries 只保留
        # 宽、高、两种帧率与 best_effort_timestamp_time;-of json 输出 JSON。
        [
            _media_tool("ffprobe"),
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_streams",
            "-show_frames",
            "-show_entries",
            "stream=width,height,avg_frame_rate,r_frame_rate:frame=best_effort_timestamp_time",
            "-of",
            "json",
            str(input_path),
        ],
        "probe",
        cancel_check,
    )
    streams = payload.get("streams")
    if not isinstance(streams, list) or len(streams) != 1 or not isinstance(streams[0], dict):
        raise ValueError("video has no readable video stream")
    stream = streams[0]
    width, height = stream.get("width"), stream.get("height")
    if type(width) is not int or type(height) is not int or width <= 0 or height <= 0:
        raise ValueError("video has invalid dimensions")
    # 优先使用平均帧率，缺失时回退到流帧率。
    nominal_fps = _parse_fps(stream.get("avg_frame_rate"))
    if nominal_fps is None:
        nominal_fps = _parse_fps(stream.get("r_frame_rate"))
    if nominal_fps is None:
        raise ValueError("video has no valid nominal frame rate")

    frames = payload.get("frames")
    if not isinstance(frames, list) or not frames:
        raise ValueError("video has no readable frame timestamps")
    # 收集每帧的原始时间戳(可能缺失或非法,后面统一处理)。
    raw_timestamps: list[object] = []
    for index, frame in enumerate(frames):
        if not isinstance(frame, dict):
            raise ValueError(f"video frame {index} has no timestamp")
        raw_timestamps.append(frame.get("best_effort_timestamp_time"))

    missing_indices = [
        index for index, raw_timestamp in enumerate(raw_timestamps) if raw_timestamp is None
    ]
    # 全部帧都缺时间戳时,按名义帧率用序号合成时间戳(仍与帧数一一对应)。
    if len(missing_indices) == len(raw_timestamps):
        timestamps = [index / nominal_fps for index in range(len(raw_timestamps))]
        return {
            "width": width,
            "height": height,
            "nominal_fps": nominal_fps,
            "timestamps": timestamps,
        }
    # 只有部分帧缺时间戳:无法确定缺帧位置,直接拒绝。
    if missing_indices:
        raise ValueError(f"video frame {missing_indices[0]} has no timestamp")

    timestamps: list[float] = []
    for index, raw_timestamp in enumerate(raw_timestamps):
        try:
            timestamp = float(raw_timestamp)  # 标准化为秒数浮点值。
        except (TypeError, ValueError):
            raise ValueError(f"video frame {index} has invalid timestamp") from None
        # 时间戳必须有限且单调不减,否则说明解码/封装异常。
        if not math.isfinite(timestamp):
            raise ValueError(f"video frame {index} has invalid timestamp")
        if timestamps and timestamp < timestamps[-1]:
            raise ValueError("video frame timestamps are not monotonic")
        timestamps.append(timestamp)
    # 首帧为负(时间基偏移)时整体平移,使时间戳从 0 开始。
    if timestamps[0] < 0:
        offset = -timestamps[0]
        timestamps = [timestamp + offset for timestamp in timestamps]
    return {
        "width": width,
        "height": height,
        "nominal_fps": nominal_fps,
        "timestamps": timestamps,
    }


def _run_json(
    command: list[str], action: str, cancel_check: CancelCheck | None = None
) -> dict[str, Any]:
    # 运行一个输出 JSON 的媒体工具子进程并解析结果。
    # 参数 command:完整命令行;action:动作名(如 probe),用于错误信息;
    #   cancel_check:子进程运行期间的取消轮询回调。
    # 返回:解析后的 JSON 字典。
    # 副作用:启动子进程;stdout/stderr 写入临时文件(避免管道缓冲死锁)。
    # 异常:ValueError——无法启动子进程、退出码非零(附 stderr 详情)、输出
    #   不是合法 JSON 或不是字典;VideoImportCancelled——轮询期间命中取消。
    #   取消或其他异常都会先终止子进程再上抛。
    with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as output_file, \
        tempfile.TemporaryFile(mode="w+", encoding="utf-8") as error_file:
        try:
            process = subprocess.Popen(
                command, stdout=output_file, stderr=error_file, text=True
            )
        except OSError as error:
            raise ValueError(f"could not run {command[0]} for video {action}: {error}") from None
        try:
            # 轮询等待子进程退出,期间保持取消响应。
            while process.poll() is None:
                _raise_if_cancelled(cancel_check)
                time.sleep(0.05)
            return_code = process.wait()
        except BaseException:
            # 任何异常(含取消)都先终止子进程,避免留下孤儿进程。
            _stop_process(process)
            raise
        output_file.seek(0)
        stdout = output_file.read()
        error_file.seek(0)
        stderr = error_file.read()
    # 非零退出码:以 stderr 详情抛出。
    if return_code != 0:
        detail = stderr.strip() or "unknown error"
        raise ValueError(f"video {action} failed: {detail}")
    # 输出必须是合法 JSON 字典。
    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError:
        raise ValueError(f"video {action} returned invalid metadata") from None
    if not isinstance(payload, dict):
        raise ValueError(f"video {action} returned invalid metadata")
    return payload


# 解析 "分子/分母" 形式的帧率字符串(如 "30000/1001")。
# 返回:float 帧率;输入非字符串、无 "/"、无法换算、非有限或 <= 0 时返回
#   None(不抛异常,由调用方决定回退或报错)。
def _parse_fps(value: object) -> float | None:
    if not isinstance(value, str) or "/" not in value:
        return None
    numerator, denominator = value.split("/", 1)
    try:
        fps = float(numerator) / float(denominator)
    except (ValueError, ZeroDivisionError):
        return None
    return fps if math.isfinite(fps) and fps > 0 else None


def _extract_frames(
    input_path: Path,
    frames_dir: Path,
    expected_frames: int,
    progress_callback: ProgressCallback | None,
    cancel_check: CancelCheck | None,
) -> None:
    # 用 ffmpeg 把视频逐帧解码为 PNG 序列(无丢帧),同时转发抽帧进度。
    # 参数 input_path:输入视频;frames_dir:输出目录;expected_frames:探测到
    #   的帧数(进度上限);progress_callback:进度回调;cancel_check:取消回调。
    # 副作用:在 frames_dir 写入 frame_%06d.png;启动并监控 ffmpeg 子进程。
    # 异常:ValueError——无法启动 ffmpeg 或退出码非零(附 stderr 详情);
    #   VideoImportCancelled——取消(先终止子进程再上抛)。
    command = [
        # ffmpeg 参数:-hide_banner/-loglevel error/-nostats 抑制无关输出;
        # -progress pipe:1 把 frame=N 进度行写到 stdout;-i 输入;-map 0:v:0
        # 只取第一条视频流;-vsync 0 为 passthrough 模式,每个解码帧恰好输出
        # 一个 PNG(不丢帧、不复制帧),保证帧数与探测时间戳一一对应。
        _media_tool("ffmpeg"),
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostats",
        "-progress",
        "pipe:1",
        "-i",
        str(input_path),
        "-map",
        "0:v:0",
        "-vsync",
        "0",
        str(frames_dir / "frame_%06d.png"),
    ]
    _raise_if_cancelled(cancel_check)
    # stderr 写入临时文件(失败时读取详情),进度行从 stdout 逐行读取。
    with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as error_file:
        try:
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=error_file,
                text=True,
                bufsize=1,
            )
        except OSError as error:
            raise ValueError(f"could not run ffmpeg: {error}") from None
        try:
            assert process.stdout is not None
            last_completed = 0
            # select 0.1 秒轮询:既及时响应取消,又逐行读取 frame= 进度行。
            while process.poll() is None:
                _raise_if_cancelled(cancel_check)
                ready, _, _ = select.select([process.stdout], [], [], 0.1)
                if not ready:
                    continue
                line = process.stdout.readline().strip()
                if not line.startswith("frame="):
                    continue
                try:
                    completed = int(line.split("=", 1)[1])
                except ValueError:
                    continue
                # 进度单调不减且封顶于探测帧数,避免 ffmpeg 异常输出导致回退。
                completed = min(expected_frames, max(last_completed, completed))
                if completed == last_completed:
                    continue
                last_completed = completed
                # 抽帧进度占总进度的 0.05..0.80 区间(probe 占前 0.05)。
                fraction = 0.05 + 0.75 * completed / max(1, expected_frames)
                _emit_progress(
                    progress_callback,
                    "running",
                    "extract",
                    completed,
                    expected_frames,
                    fraction,
                    "Extracting frame %d of %d" % (completed, expected_frames),
                )
            return_code = process.wait()
        except BaseException:
            # 任何异常(含取消)都先终止子进程再上抛。
            _stop_process(process)
            raise
        # 非零退出码:读取临时文件中的 stderr 详情抛 ValueError。
        if return_code != 0:
            error_file.seek(0)
            detail = error_file.read().strip() or "unknown error"
            raise ValueError(f"video decode failed: {detail}")


# 终止仍在运行的子进程:先 terminate 温和终止并等待 5 秒,超时则 kill 强杀
# 后回收;已退出的进程直接返回。
def _stop_process(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def _normalize_frame_names(
    frames_dir: Path, cancel_check: CancelCheck | None = None
) -> list[Path]:
    # 把 ffmpeg 输出的 1 基连续帧名(frame_000001.png..)重命名为 0 基
    # (frame_000000.png..),并做连续性校验。
    # 参数 frames_dir:抽帧输出目录;cancel_check:取消回调。
    # 返回:按 0 基顺序排列的最终帧路径列表。
    # 副作用:在 frames_dir 内两阶段改名。
    # 异常:ValueError——没有产出帧、出现意外文件名或序号不连续(丢帧/多帧);
    #   VideoImportCancelled——取消。
    source_paths = sorted(frames_dir.glob("frame_*.png"))
    if not source_paths:
        raise ValueError("video decode produced no PNG frames")
    source_indices: list[int] = []
    for path in source_paths:
        match = _FRAME_NAME.fullmatch(path.name)
        if match is None:
            raise ValueError(f"video decode produced an unexpected frame name: {path.name}")
        source_indices.append(int(match.group(1)))
    # 校验 ffmpeg 产出的序号恰好是 1..N 连续(不连续说明解码异常)。
    expected_indices = list(range(1, len(source_paths) + 1))
    if source_indices != expected_indices:
        raise ValueError("video decode produced non-contiguous frame indices")

    # 两阶段改名:先全部改成唯一的 .renaming_ 临时名,再落到最终 0 基名,
    # 避免顺序重命名时目标名与尚未改名的源名冲突(原地覆盖)。
    temporary_paths: list[Path] = []
    for index, source_path in enumerate(source_paths):
        _raise_if_cancelled(cancel_check)
        temporary_path = frames_dir / f".renaming_{index:06d}.png"
        source_path.replace(temporary_path)
        temporary_paths.append(temporary_path)
    # 第二阶段:按 0 基顺序改回最终文件名。
    normalized_paths: list[Path] = []
    for index, temporary_path in enumerate(temporary_paths):
        _raise_if_cancelled(cancel_check)
        normalized_path = frames_dir / f"frame_{index:06d}.png"
        temporary_path.replace(normalized_path)
        normalized_paths.append(normalized_path)
    return normalized_paths


def _validate_and_score_frames(
    frame_paths: list[Path],
    progress_callback: ProgressCallback | None = None,
    cancel_check: CancelCheck | None = None,
) -> tuple[int, int, list[float]]:
    # 逐张校验解码帧并计算相邻帧相似度分数(细节见上方英文 docstring)。
    # 参数 frame_paths:0 基帧路径列表;progress_callback/cancel_check:进度与
    #   取消回调。
    # 返回:(width, height, similarity_scores)——宽高取自首帧解码结果;
    #   similarity_scores[i] 为第 i 与第 i+1 帧的 normalized_mad 距离(共
    #   len(frame_paths) - 1 个)。
    # 副作用:只读帧文件。内存说明:同一时刻只保留当前帧与上一帧两幅图像,
    #   不缓存整个序列。
    # 异常:ValueError——某帧不可读、尺寸与首帧不一致,或没有任何可读帧。
    """Check one decoded image at a time and retain only adjacent frames."""
    previous_image: np.ndarray | None = None
    decoded_shape: tuple[int, int, int] | None = None
    similarity_scores: list[float] = []
    for index, frame_path in enumerate(frame_paths):
        _raise_if_cancelled(cancel_check)
        image = cv2.imread(str(frame_path), cv2.IMREAD_COLOR)
        # 每帧必须可解码,且形状(含通道数)与首帧一致,否则不允许发布。
        if image is None:
            raise ValueError(f"decoded frame {index} is unreadable or has invalid dimensions")
        if decoded_shape is None:
            decoded_shape = image.shape
        elif image.shape != decoded_shape:
            raise ValueError(f"decoded frame {index} is unreadable or has invalid dimensions")
        # 相邻帧对计算 MAD 距离;算完即可释放上一帧。
        if previous_image is not None:
            similarity_scores.append(normalized_mad(previous_image, image))
        previous_image = image
        completed = index + 1
        _emit_progress(
            progress_callback,
            "running",
            "validate",
            completed,
            len(frame_paths),
            min(0.95, 0.8 + 0.15 * completed / max(1, len(frame_paths))),
            "Validating frame %d of %d" % (completed, len(frame_paths)),
        )
    if decoded_shape is None:
        raise ValueError("video decode produced no readable PNG frames")
    height, width, _ = decoded_shape
    return width, height, similarity_scores


def _build_manifest(
    input_path: Path,
    probe: dict[str, Any],
    frame_paths: list[Path],
    width: int,
    height: int,
    similarity_scores: list[float],
    cancel_check: CancelCheck | None = None,
) -> dict[str, Any]:
    # 组装 dataset-manifest-v1 清单(尚未写入文件)。
    # 参数 input_path:源视频路径;probe:_probe_video 的结果;frame_paths:
    #   帧文件路径;width/height:帧尺寸;similarity_scores:相邻帧 MAD;
    #   cancel_check:计算源视频 SHA-256 期间的取消回调。
    # 返回:符合 dataset-manifest-v1 的字典——dataset_id 取源视频 SHA-256 前
    #   16 位;frames 每项含 frame(0 基序号)、time_s(探测时间戳)与相对路径
    #   image_path;model_version/taxonomy_version 置 "none"(与模型输出无关)。
    source_sha256 = _sha256_file(input_path, cancel_check)
    return {
        "schema_version": 1,
        "dataset_id": f"video-{source_sha256[:16]}",
        "source_name": input_path.name,
        "source_sha256": source_sha256,
        "width": width,
        "height": height,
        "frame_count": len(frame_paths),
        "nominal_fps": probe["nominal_fps"],
        "frames": [
            {
                "frame": index,
                "time_s": probe["timestamps"][index],
                "image_path": f"frames/{frame_path.name}",
            }
            for index, frame_path in enumerate(frame_paths)
        ],
        "similarity_scores": similarity_scores,
        "model_version": "none",
        "taxonomy_version": "none",
    }


# 分块(1 MiB)流式计算文件 SHA-256。
# 参数 path:目标文件;cancel_check:每块之间的取消轮询回调。
# 返回:十六进制摘要字符串;副作用:只读文件。
def _sha256_file(path: Path, cancel_check: CancelCheck | None = None) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            _raise_if_cancelled(cancel_check)
            hasher.update(chunk)
    return hasher.hexdigest()


# 对生成的 manifest 做 schema 校验与语义校验(均来自 contracts 模块),任何
# 错误都抛 ValueError——带错的清单不允许进入发布步骤。
def _validate_manifest(manifest: dict[str, Any]) -> None:
    errors = validate_instance(manifest, "dataset-manifest-v1.schema.json")
    errors.extend(validate_manifest_semantics(manifest))
    if errors:
        raise ValueError("generated manifest is invalid: " + "; ".join(errors))


# 把 manifest 写为 JSON 文件(位于 staging 内,发布时随目录一起原子改名)。
# 参数 path:目标文件;manifest:可 JSON 序列化字典。
# 序列化选项:ensure_ascii=False 保留非 ASCII 字符、indent=2 便于阅读、键
# 排序保证输出稳定、allow_nan=False 禁止 NaN/Inf,结尾补一个换行。
def _write_manifest(path: Path, manifest: dict[str, Any]) -> None:
    path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True, allow_nan=False) + "\n",
        encoding="utf-8",
    )
