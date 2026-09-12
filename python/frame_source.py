# Project 6 Part 1.3 帧源(frame_source)命令行适配器:把视频归一化为帧序列数据集。
#
# 用途:把一段 FFmpeg 支持的视频解码、校验并原子发布为 frame-source 数据集目录
# (frames/ 下的 PNG 帧序列 + manifest.json),供 Godot 客户端以子进程方式导入帧源。
#
# 角色:本文件只是"进程外壳"——负责 argparse 参数解析与面向进程的进度/结果文件;
# 真正的 FFmpeg 探测、抽帧、图像校验、协作取消、临时目录清理与原子发布都实现在
# annotation_data.frame_source.decode_video 中,测试与其他调用方可直接复用同一实现。
#
# 输入:命令行参数(输入视频、输出目录、可选的 progress/result/cancel/staging 文件路径);
# 输出:归一化输出目录(frames/ 与 manifest.json)、可选的原子 JSON 进度/结果文件、
# stdout 的一行成功摘要与 stderr 的错误行。
#
# 典型运行方式:
#   .venv/bin/python python/frame_source.py input.mp4 --output .local/import1 \
#       --progress-file .local/import1.progress.json
#
# 退出码:0 = 发布成功;1 = 导入或结果文件写入失败(原因写 stderr);
# 130 = 检测到 cancel 文件的协作式取消。
"""Part 1.3 command-line adapter for frame-accurate video normalization.

Argument parsing and process-facing progress/result files live here. Reusable
FFmpeg probing, decoding, validation, cancellation, cleanup, and atomic dataset
publication live in :mod:`annotation_data.frame_source` so tests and other
clients can call the same implementation without invoking a subprocess.
"""

import argparse
import json
import os
from pathlib import Path
import tempfile
from typing import Any, Sequence

# 复用核心实现:decode_video 完成探测/抽帧/校验/原子发布;VideoImportCancelled
# 是外部取消请求被接受后抛出的协作取消信号(异常类型)。
from annotation_data.frame_source import VideoImportCancelled, decode_video


# 命令行主入口:解析参数 → 组装进度/取消回调 → 调 decode_video 完成导入 → 写终态文件。
# 参数 argv:命令行参数列表(None 时取 sys.argv),便于测试直接注入。
# 命令行参数含义:input 输入视频;--output 必填的新输出目录(不得已存在);
# --result-file 进程终态一次性写入的 JSON 状态文件(供监控方读取);
# --progress-file 随解码进度原子覆盖的 JSON 文件;--cancel-file 出现即取消的哨兵文件;
# --staging-dir 显式指定的同级 staging 目录(默认自动生成,原子发布前暂存)。
# 返回:进程退出码(0/1/130,含义见下方 docstring 与文件头)。
# 副作用:创建输出目录(经 staging 原子发布);按需持续写 progress-file、终态写
# result-file;失败时向 stderr 打印 "frame-source: <原因>";staging 残留由
# decode_video 自行清理。
def main(argv: Sequence[str] | None = None) -> int:
    """Run one import request and return a process-compatible exit status.

    ``0`` means frames were published successfully, ``1`` represents a normal
    import or result-file error, and ``130`` records an explicit cancellation.
    The decoder remains the sole owner of frame output; this adapter only
    translates command-line state into its callback and cancellation contracts.
    """
    parser = argparse.ArgumentParser(description="Normalize a video into PNG frames and a manifest.")
    parser.add_argument("input", type=Path, help="video file to decode")
    parser.add_argument("--output", type=Path, required=True, help="new normalized output directory")
    parser.add_argument("--result-file", type=Path, help="JSON status file for process monitoring")
    parser.add_argument("--progress-file", type=Path, help="atomic JSON progress file")
    parser.add_argument("--cancel-file", type=Path, help="cancel when this file appears")
    parser.add_argument(
        "--staging-dir",
        type=Path,
        help="explicit new sibling staging directory used before atomic publication",
    )
    args = parser.parse_args(argv)
    # 初始进度快照(last_progress 的兜底值):若异常发生在任何进度回调之前,终态
    # 快照将以这份默认值为基础构造(stage=probe、total=1、fraction=0.0),保证写出的
    # progress-file 终态仍是结构合法的进度对象。
    last_progress: dict[str, Any] = {
        "version": 1,
        "state": "running",
        "stage": "probe",
        "completed": 0,
        "total": 1,
        "fraction": 0.0,
        "message": "Starting import",
    }

    # 进度回调(decode_video 的阶段推进与抽帧进度都会调用):保存最新快照,并在
    # 指定 --progress-file 时原子覆盖写入。payload 为含 version/state/stage/
    # completed/total/fraction/message 的快照字典;副作用:更新闭包变量
    # last_progress,供异常路径构造终态快照。
    def report_progress(payload: dict[str, Any]) -> None:
        nonlocal last_progress
        # Keep the most recent snapshot so terminal progress preserves context
        # even when decoding exits before another callback can be emitted.
        last_progress = payload.copy()
        if args.progress_file is not None:
            _write_result(args.progress_file, payload)

    # 取消检查回调(decode_video 在各阶段间隙轮询):仅当外部创建了 --cancel-file
    # 哨兵文件时返回 True。只读文件存在性、不写不删,外部 UI 进程无需与本进程
    # 共享内存即可触发协作取消。
    def cancel_requested() -> bool:
        # File polling is intentionally side-effect free: an external UI can
        # request cancellation without sharing process memory with this CLI.
        return args.cancel_file is not None and args.cancel_file.exists()

    # 仅在对应命令行参数给定时才挂接回调;不指定时向 decode_video 传 None,
    # 即关闭进度上报或取消轮询能力。
    try:
        decode_video(
            args.input,
            args.output,
            progress_callback=report_progress if args.progress_file is not None else None,
            cancel_check=cancel_requested if args.cancel_file is not None else None,
            staging_dir=args.staging_dir,
        )
    # 协作式取消分支:decode_video 轮询到 cancel 文件后抛 VideoImportCancelled。
    # 尽力把 progress-file 更新为 cancelled 终态快照、result-file 写为
    # {"success": false, "cancelled": true, "error": <消息>},stderr 提示后返回 130;
    # 此处写文件用尽力而为版本(_try_write_result),失败不再抛新异常。
    except VideoImportCancelled as error:
        message = str(error) or "video import cancelled"
        if args.progress_file is not None:
            _try_write_result(
                args.progress_file,
                _terminal_progress(last_progress, "cancelled", "Import cancelled"),
            )
        if args.result_file is not None:
            _try_write_result(
                args.result_file,
                {"success": False, "cancelled": True, "error": message},
            )
        print(f"frame-source: {message}", file=__import__("sys").stderr)
        return 130
    # 其余一切异常(路径检查、探测、抽帧、校验、发布失败等)都归为导入失败:
    # progress-file 写 failed 终态、result-file 写 {"success": false, "error": <消息>},
    # stderr 打印原因后返回 1;此时输出目录尚未发布,残留 staging 由 decode_video 清理。
    except Exception as error:
        message = str(error) or error.__class__.__name__
        if args.progress_file is not None:
            _try_write_result(
                args.progress_file,
                _terminal_progress(last_progress, "failed", message),
            )
        if args.result_file is not None:
            _try_write_result(args.result_file, {"success": False, "error": message})
        print(f"frame-source: {message}", file=__import__("sys").stderr)
        return 1

    # 导入成功:progress-file 的最后一份内容已是 decode_video 发出的 completed
    # 快照,无需再改;result-file 若指定,则原子写入 success=True 与输出目录路径。
    if args.result_file is not None:
        try:
            # Replace the status atomically so readers never observe partial JSON.
            _write_result(args.result_file, {"success": True, "path": str(args.output)})
        except OSError as error:
            print(f"frame-source: could not write result file: {error}", file=__import__("sys").stderr)
            return 1
    # 走到这里说明发布与结果文件写入都成功;stdout 打印一行摘要后返回退出码 0。
    print(f"normalized video to {args.output}")
    return 0


# 尽力而为版 JSON 写入:专用于取消/失败等收尾路径——此时若写进度/结果文件再失败,
# 不应抛出新异常打断原有的失败处理,因此吞掉 OSError 静默跳过。
# 参数 path:目标文件;payload:JSON 快照;无返回值。
def _try_write_result(path: Path, payload: dict[str, Any]) -> None:
    try:
        _write_result(path, payload)
    except OSError:
        pass


# 基于最近一次进度快照构造终态快照:state 换成 cancelled/failed,message 换成
# 终态说明,其余字段继承 previous 并做防御性钳制(fraction 限 [0,1]、total 至少
# 为 1、缺字段取默认值),保证 progress-file 始终是结构合法的进度对象。
# 参数 previous:最近一次进度快照(从未收到回调时为初始兜底值);返回新字典,
# 不修改 previous。
def _terminal_progress(
    previous: dict[str, Any], state: str, message: str
) -> dict[str, Any]:
    return {
        "version": 1,
        "state": state,
        "stage": str(previous.get("stage", "probe")),
        "completed": int(previous.get("completed", 0)),
        "total": max(1, int(previous.get("total", 1))),
        "fraction": min(1.0, max(0.0, float(previous.get("fraction", 0.0)))),
        "message": message,
    }


# 原子写一个 JSON 快照:先在目标目录内创建唯一临时文件(.tmp 后缀、delete=False)
# 写入 JSON 与结尾换行,再 os.replace 原子改名——读者永远不会看到半截 JSON。
# 参数 path:目标文件;payload:可 JSON 序列化字典(allow_nan=False,禁 NaN/Inf)。
# 副作用:自动创建父目录;os.replace 失败时删除临时文件并重抛 OSError。
def _write_result(path: Path, payload: dict[str, Any]) -> None:
    """Atomically publish one JSON progress or result snapshot at ``path``."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", suffix=".tmp", delete=False
    ) as temporary:
        json.dump(payload, temporary, ensure_ascii=False, allow_nan=False)
        temporary.write("\n")
        temporary_path = Path(temporary.name)
    try:
        os.replace(temporary_path, path)
    except OSError:
        temporary_path.unlink(missing_ok=True)
        raise


# 以脚本方式运行:用 main() 的返回值作为进程退出码。
if __name__ == "__main__":
    raise SystemExit(main())
