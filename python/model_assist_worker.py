#!/usr/bin/env python3
# Project 6 模型辅助(Model Assist)单帧 worker:驻留子进程形式的 SAM 2 图像预测
# 服务。由 Godot 客户端的 ModelAssistService 读取 PROJECT6_MODEL_PYTHON /
# PROJECT6_SAM2_CONFIG / PROJECT6_SAM2_CHECKPOINT / PROJECT6_SAM2_DEVICE 后拉起,
# 在 stdin/stdout 上按行收发 model-assist-v1 JSONL 协议消息(hello / set_image /
# predict / cancel / shutdown),调 ModelAssistBackend 对单帧生成带 hash 的二值
# mask 候选 PNG;不接触标注 store,诊断输出一律改道 stderr。
#   $PROJECT6_MODEL_PYTHON python/model_assist_worker.py \
#       --job-dir <任务 job 目录> --config <sam2 配置 yaml(绝对路径)> \
#       --checkpoint <sam2 权重文件(绝对路径)> --device auto|cpu|cuda \
#       --session-id <service 分配的会话 ID>
# 退出码:0 = 收到 shutdown 或 stdin EOF 正常退出;2 = backend 初始化失败
# (原因写 stderr,不静默);其他非 0 = 循环内未捕获异常冒泡(如写响应失败)。
"""Persistent JSONL worker for the official SAM 2 image predictor."""
from __future__ import annotations

import argparse
from contextlib import redirect_stdout
import json
import os
from pathlib import Path
import re
import sys
from typing import Any, BinaryIO

# ModelAssistBackend 持有唯一的 SAM 2 predictor、当前帧 embedding 与 job 目录内
# candidate 文件;protocol 负责请求行解码校验、响应封装与常量 MAX_LINE_BYTES(1 MiB)。
from annotation_data.model_assist_backend import ModelAssistBackend
from annotation_data.model_assist_protocol import (
    MAX_LINE_BYTES,
    error_response,
    loads_line,
    success_response,
)


# 把响应字典序列化为单行紧凑 JSON(ensure_ascii=False、allow_nan=False)写入
# output 并 flush;含换行超过 MAX_LINE_BYTES(1 MiB)时抛 ValueError——该异常
# 在 run_loop 捕获范围之外,worker 经 finally 关闭 backend 后以非 0 退出。
def _write(output: BinaryIO, response: dict[str, Any]) -> None:
    raw = (json.dumps(
        response, ensure_ascii=False, allow_nan=False, separators=(",", ":")
    ) + "\n").encode("utf-8")
    if len(raw) > MAX_LINE_BYTES:
        raise ValueError("response line exceeds one MiB")
    output.write(raw)
    output.flush()


# 从解析失败的原始请求行中宽松提取 request_id(只扫前 4096 字节,非 UTF-8 字节
# 用替换符解码),让错误响应能关联到原请求;找不到或匹配为空时返回 "invalid"。
def _best_effort_request_id(raw: bytes) -> str:
    match = re.search(rb'"request_id"\s*:\s*"([^"\\\r\n]{1,128})"', raw[:4096])
    if match is None:
        return "invalid"
    return match.group(1).decode("utf-8", errors="replace") or "invalid"


# 把已校验请求(request 含 protocol/request_id/op/context/data 五键)分发给
# backend,返回 (响应字典, 是否结束主循环)。各 op:hello 惰性构建 SAM 2
# predictor 并握手(service_session_id 非空时在结果中追加 session_id 与 pid,
# 供客户端确认 worker 身份);set_image 读取 job 目录内带 hash 的 PNG 并计算
# embedding;predict 按点/box 提示生成 mask 候选;cancel 直接确认;shutdown
# 关闭 predictor 并返回空 data(第二项仅 shutdown 为 True)。backend 抛出的
# 异常交由 run_loop 转 error 响应;redirect_stdout 把杂散 stdout 输出改道 stderr。
def _dispatch(
    backend: Any,
    request: dict[str, Any],
    *,
    service_session_id: str = "",
) -> tuple[dict[str, Any], bool]:
    op = request["op"]
    data = request["data"]
    with redirect_stdout(sys.stderr):
        if op == "hello":
            result = backend.hello()
            if service_session_id:
                result = {
                    **result,
                    "session_id": service_session_id,
                    "pid": os.getpid(),
                }
        elif op == "set_image":
            image = data["image"]
            result = backend.set_image(
                image["path"], image["sha256"], width=image["width"], height=image["height"]
            )
        elif op == "predict":
            result = backend.predict(
                points=data["points"], labels=data["labels"], box=data["box"],
                initial_mask=data["initial_mask"],
            )
        elif op == "cancel":
            result = backend.cancel(data["target_request_id"])
        else:
            backend.shutdown()
            result = {}
    return success_response(request, result), op == "shutdown"


# 主循环:逐行读请求、分发并回写响应,直到 shutdown、stdin EOF 或致命写错误,
# 返回 0(EOF 与 shutdown 都视为干净退出)。细节:
# - readline(MAX_LINE_BYTES + 1):单行最多 1 MiB + 1 字节,超长行交由 loads_line
#   判为非法;读到 b"" 表示 stdin 已关闭,立即返回 0。
# - loads_line / _dispatch 抛出的异常转为一条 error 响应(已解析出请求则沿用其
#   request_id 与 context,否则用 _best_effort_request_id 与空 context),
#   写回后继续服务。
# - _write 抛错不在捕获范围内:finally 调 backend.shutdown()(幂等)后向上
#   冒泡,worker 以非 0 退出。
def run_loop(
    backend: Any,
    source: BinaryIO,
    output: BinaryIO,
    *,
    service_session_id: str = "",
) -> int:
    """Serve bounded requests until shutdown or clean EOF."""
    try:
        while True:
            raw = source.readline(MAX_LINE_BYTES + 1)
            if raw == b"":
                return 0
            request: dict[str, Any] | None = None
            try:
                request = loads_line(raw)
                response, should_stop = _dispatch(
                    backend, request, service_session_id=service_session_id
                )
            except Exception as exc:
                request_id = request["request_id"] if request is not None else _best_effort_request_id(raw)
                context = request["context"] if request is not None else {}
                response = error_response(request_id, context, [str(exc) or exc.__class__.__name__])
                should_stop = False
            _write(output, response)
            if should_stop:
                return 0
    finally:
        with redirect_stdout(sys.stderr):
            backend.shutdown()


# 构建命令行解析器(参数由客户端 service 或测试 harness 传入):
# --job-dir 任务隔离目录,须为已存在的普通目录(非符号链接);backend 从这里
#   读带 hash 的 PNG,并把候选 mask 写入其 candidates/;
# --config / --checkpoint:SAM 2 配置与权重绝对路径,首次 hello 构建 predictor
#   时才校验;--device auto|cpu|cuda(默认 auto,有 CUDA 用 CUDA 否则 CPU);
# --session-id 客户端分配的会话 ID,hello 响应原样带回。
def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the Project6 model-assist SAM 2 JSONL worker.")
    parser.add_argument("--job-dir", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--device", choices=("auto", "cpu", "cuda"), default="auto")
    parser.add_argument("--session-id", required=True)
    return parser


# 进程入口:解析命令行 → 构造 ModelAssistBackend(只做 job 目录校验,模型懒加载
# 到首次 hello)→ 进入 run_loop。返回退出码:0 = shutdown/EOF 正常结束;
# 2 = backend 初始化失败(job 目录门禁未通过,原因打印到 stderr);其余异常
# 直接冒泡终止进程。
def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        backend = ModelAssistBackend(
            Path(args.job_dir), config_path=args.config,
            checkpoint_path=args.checkpoint, device=args.device,
        )
    except Exception as exc:
        print(f"model assist worker startup failed: {exc}", file=sys.stderr)
        return 2
    return run_loop(
        backend,
        sys.stdin.buffer,
        sys.stdout.buffer,
        service_session_id=args.session_id,
    )


if __name__ == "__main__":
    raise SystemExit(main())
