#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# 文件用途:本脚本是「SAM Video Batch」功能的持久化 JSONL worker 进程,包装官方
# SAM 2 video predictor,通过 stdin/stdout 逐行收发 sam-video-v1 协议 JSON
# (协议定义见 annotation_data/sam_video_protocol.py):每个请求一行,每个请求
# 恰好回写一行响应,直到收到 shutdown 操作或 stdin 关闭(EOF)。
#
# 在项目中的角色:Godot 客户端(client/services/sam_video_service.gd)用
# PROJECT6_MODEL_PYTHON 指定的解释器启动本进程并常驻,以复用已加载的 SAM 2 模型。
# stdout 专用于协议响应;后端与 predictor 的杂散 stdout 输出一律重定向到 stderr。
# 文件读写被限制在 --job-dir 任务目录内。
#
# 输入:stdin 上的请求行,op 为 hello/open_batch/add_mask/propagate/cancel/
#       reset_batch/shutdown;输出:stdout 上的响应行(ok=true 带 data,
#       ok=false 带 errors)。
# 典型运行方式(通常由客户端自动启动,手工调试示例):
#   python python/sam_video_worker.py --job-dir /abs/job \
#       --config /abs/sam2.yaml --checkpoint /abs/sam2.ckpt \
#       --device auto --session-id <会话ID>
# 退出码:0 正常结束(EOF 或 shutdown);2 后端构造失败。
# 协作模块:annotation_data.sam_video_backend(批状态机,持有 predictor)、
#           annotation_data.sam_video_protocol(请求校验与响应封装)。
# ---------------------------------------------------------------------------
"""Persistent JSONL worker for the official SAM 2 video predictor."""
from __future__ import annotations

import argparse
from contextlib import redirect_stdout
from copy import deepcopy
import json
import os
from pathlib import Path
import re
import sys
from typing import Any, BinaryIO

from annotation_data.sam_video_backend import SamVideoBackend
from annotation_data.sam_video_protocol import (
    MAX_LINE_BYTES,
    error_response,
    loads_line,
    success_response,
)


# 把一条响应字典序列化为一行紧凑 JSON 并写入 output,随后立即 flush。
# 约束:ensure_ascii=False 保留非 ASCII 字符;allow_nan=False 禁止 NaN/Infinity;
# 紧凑分隔符节省字节。序列化后检查行字节数不得超过协议上限 MAX_LINE_BYTES
# (1 MiB),超限抛 ValueError——此时响应无法走协议通道,只能按致命错误处理。
def _write(output: BinaryIO, response: dict[str, Any]) -> None:
    raw = (json.dumps(
        response, ensure_ascii=False, allow_nan=False, separators=(",", ":")
    ) + "\n").encode("utf-8")
    if len(raw) > MAX_LINE_BYTES:
        raise ValueError("response line exceeds one MiB")
    output.write(raw)
    output.flush()


# 从原始请求字节中尽力恢复 request_id,供 JSON 解析失败时仍能回出可关联的错误响应。
# 只扫描前 4096 字节;正则把值限定为 1-128 个不含引号、反斜杠、控制字符的字符,
# 避免在损坏数据上误匹配;取不到或为空则返回占位符 "invalid"。
def _best_effort_request_id(raw: bytes) -> str:
    match = re.search(rb'"request_id"\s*:\s*"([^"\\\x00-\x1f\x7f]{1,128})"', raw[:4096])
    if match is None:
        return "invalid"
    return match.group(1).decode("utf-8", errors="replace") or "invalid"


# 把异常转成可放进协议 errors 字段的安全字符串:优先取异常消息(为空则用类名),
# 把控制字符(码点 < 32 或 127)替换为空格,再截断到 512 字符;仍为空时用通用文案。
def _safe_error(exc: Exception) -> str:
    message = str(exc) or exc.__class__.__name__
    cleaned = "".join(character if ord(character) >= 32 and ord(character) != 127 else " " for character in message)
    return cleaned[:512] or "worker request failed"


# 读取一条物理行:readline 最多取 MAX_LINE_BYTES+1 字节;只要行完整(以换行结尾)
# 或未超限就原样返回。否则说明该行超过上限,继续读并丢弃余下分段直到换行或 EOF,
# 只返回截断的前缀——该前缀随后会因缺少行尾 LF 或超长而被 loads_line 拒绝,
# 以此保证单请求内存有界。
def _read_request_line(source: BinaryIO) -> bytes:
    """Read one physical line and discard its tail when it exceeds the bound."""
    raw = source.readline(MAX_LINE_BYTES + 1)
    if len(raw) <= MAX_LINE_BYTES or raw.endswith(b"\n"):
        return raw
    while True:
        remainder = source.readline(MAX_LINE_BYTES + 1)
        if remainder == b"" or remainder.endswith(b"\n"):
            return raw


# worker 的可变会话状态(单线程,由 run_loop 独占使用)。
# service_session_id:启动参数 --session-id,限定本进程只服务该会话的请求;
# active_context:最近一次成功 open_batch 深拷贝绑定的请求上下文,
# None 表示当前没有活动批。
class _WorkerState:
    # 记录服务会话 ID;活动批上下文初始为空,等待 open_batch 成功后再绑定。
    def __init__(self, service_session_id: str) -> None:
        self.service_session_id = service_session_id
        self.active_context: dict[str, Any] | None = None


# 校验请求 context 与 worker 的启动配置一致,防止跨会话/跨设备串用:
# 配置了 service_session_id 时 context["session_id"] 必须与之相同;
# context["requested_device"] 必须等于后端配置的 backend.device。
# 任一不匹配抛 RuntimeError。
def _verify_configured_context(
    backend: SamVideoBackend,
    context: dict[str, Any],
    state: _WorkerState,
) -> None:
    if (
        state.service_session_id
        and context["session_id"] != state.service_session_id
    ):
        raise RuntimeError("request context session does not match the worker session")
    configured_device = backend.device
    if context["requested_device"] != configured_device:
        raise RuntimeError("request context device does not match the worker device")


# 要求请求 context 与当前活动批上下文完全一致:尚未 open_batch 绑定,或 context
# 与绑定值有任何差异,都抛 RuntimeError。这保证 add_mask/propagate 等操作只作用于
# 绑定它的那个批。
def _require_bound_context(
    context: dict[str, Any], state: _WorkerState
) -> None:
    if state.active_context is None:
        raise RuntimeError("open_batch must bind context before this operation")
    if context != state.active_context:
        raise RuntimeError("request context does not match the active batch context")


# 使当前批失效:先清空 active_context,再尽力调用 backend.reset_batch() 释放
# predictor 推理状态。reset 期间可能的 stdout 输出被重定向到 stderr 以免污染协议;
# reset 失败也被吞掉——后端在调用 predictor 前已先清空自己持有的状态引用,
# 失败也不会让坏批被复用(与 sam_video_backend 内部的保障一致)。
def _invalidate_batch(backend: SamVideoBackend, state: _WorkerState) -> None:
    state.active_context = None
    try:
        with redirect_stdout(sys.stderr):
            backend.reset_batch()
    except Exception:
        # Backend reset clears owned state references before calling the
        # predictor, so even a predictor reset failure cannot permit reuse.
        pass


# 按请求 op 分发到后端方法,返回 (成功响应, 是否停机)。
# 先用 _verify_configured_context 校验会话与设备;整个分发过程把后端/predictor
# 可能写往 stdout 的杂散输出重定向到 stderr,保证 stdout 只有协议内容。各 op:
#   hello:       首次调用时惰性加载 SAM 2 predictor;requested_device 非 auto 时
#                要求 predictor 实际设备一致;结果附加 session_id 与本进程 pid。
#   open_batch:  用 data["frames"] 打开批(关键帧+目标帧),成功后把 context
#                深拷贝绑定为活动批上下文。
#   add_mask / propagate: 必须已绑定活动批且 context 与之一致。
#   cancel:      取消目标请求后立即 reset 批并解绑上下文(取消后批不可再用)。
#   reset_batch: 已有活动批时同样要求 context 一致,然后释放批并解绑。
#   shutdown(else 分支): 已有活动批时要求 context 一致;关闭后端、解绑上下文,
#                返回空 data,并让 run_loop 停机。
# 任何异常向上抛出,由 run_loop 统一转成 error_response。
def _dispatch(
    backend: SamVideoBackend,
    request: dict[str, Any],
    *,
    state: _WorkerState,
) -> tuple[dict[str, Any], bool]:
    op = request["op"]
    context = request["context"]
    data = request["data"]
    _verify_configured_context(backend, context, state)
    with redirect_stdout(sys.stderr):
        if op == "hello":
            result = backend.hello()
            requested_device = context["requested_device"]
            if requested_device != "auto" and result.get("device") != requested_device:
                raise RuntimeError("loaded predictor device does not match request context")
            result = {
                **result,
                "session_id": state.service_session_id,
                "pid": os.getpid(),
            }
        elif op == "open_batch":
            result = backend.open_batch(data["frames"])
            state.active_context = deepcopy(context)
        elif op == "add_mask":
            _require_bound_context(context, state)
            result = backend.add_mask(data["mask"], data["object_id"])
        elif op == "propagate":
            _require_bound_context(context, state)
            result = backend.propagate(data["count"], data["object_id"])
        elif op == "cancel":
            _require_bound_context(context, state)
            result = backend.cancel(data["target_request_id"])
            backend.reset_batch()
            state.active_context = None
        elif op == "reset_batch":
            if state.active_context is not None:
                _require_bound_context(context, state)
            result = backend.reset_batch()
            state.active_context = None
        else:
            if state.active_context is not None:
                _require_bound_context(context, state)
            backend.shutdown()
            state.active_context = None
            result = {}
    return success_response(request, result), op == "shutdown"


# 主循环:逐行读取请求,每条请求恰好回写一行响应;收到 shutdown 或 stdin EOF 时
# 以 0 退出。
# 正常路径:loads_line 解析校验请求 -> _dispatch 执行 -> success_response 写回。
# 异常路径:任何异常都会先 _invalidate_batch 丢弃当前批(失败不留可复用状态),
# 再构造 error_response:request_id 优先取已解析请求的值,解析失败时用
# _best_effort_request_id 从原始字节尽力恢复;context 取已解析请求的值,否则空对象。
# 错误响应后不停机(should_stop 置 False),继续服务后续请求。
# finally:无论正常结束还是异常退出,都会调用 backend.shutdown() 释放 predictor
# (其 stdout 输出重定向到 stderr)。
def run_loop(
    backend: SamVideoBackend,
    source: BinaryIO,
    output: BinaryIO,
    *,
    service_session_id: str = "",
) -> int:
    """Serve one bounded response per request until shutdown or clean EOF."""
    state = _WorkerState(service_session_id)
    try:
        while True:
            raw = _read_request_line(source)
            if raw == b"":
                return 0
            request: dict[str, Any] | None = None
            try:
                request = loads_line(raw)
                response, should_stop = _dispatch(
                    backend, request, state=state
                )
            except Exception as exc:
                _invalidate_batch(backend, state)
                request_id = (
                    request["request_id"] if request is not None else _best_effort_request_id(raw)
                )
                context = request["context"] if request is not None else {}
                response = error_response(request_id, context, [_safe_error(exc)])
                should_stop = False
            _write(output, response)
            if should_stop:
                return 0
    finally:
        with redirect_stdout(sys.stderr):
            backend.shutdown()


# 构建命令行参数解析器:
#   --job-dir     任务目录(worker 的文件读写边界,批运行时目录建在其 runtime/ 下)
#   --config      SAM 2 模型配置(须为已安装 sam2 包 configs 目录内的绝对路径文件)
#   --checkpoint  SAM 2 权重文件(绝对路径)
#   --device      推理设备:auto(有 CUDA 用 CUDA,否则 CPU)/cpu/cuda
#   --session-id  本 worker 绑定的服务会话 ID(必须与每个请求的
#                 context.session_id 一致)
def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run the Project6 SAM 2 video JSONL worker."
    )
    parser.add_argument("--job-dir", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--device", choices=("auto", "cpu", "cuda"), default="auto")
    parser.add_argument("--session-id", required=True)
    return parser


# 入口:解析参数并构造 SamVideoBackend(此处只校验任务目录与设备,不加载模型,
# predictor 在首个 hello 时才惰性加载)。构造失败时向 stderr 打印一行原因并以
# 退出码 2 结束;成功则进入 run_loop,以 stdin/stdout 的二进制缓冲作为协议通道。
def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        backend = SamVideoBackend(
            Path(args.job_dir),
            config_path=args.config,
            checkpoint_path=args.checkpoint,
            device=args.device,
        )
    except Exception as exc:
        print(f"SAM video worker startup failed: {_safe_error(exc)}", file=sys.stderr)
        return 2
    return run_loop(
        backend,
        sys.stdin.buffer,
        sys.stdout.buffer,
        service_session_id=args.session_id,
    )


# 以脚本方式运行时,用 main 的返回值作为进程退出码。
if __name__ == "__main__":
    raise SystemExit(main())
