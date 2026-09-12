# model-assist-v1 JSONL 线路协议的纯数据校验层(annotation_data 包核心库)。
#
# 用途:定义并严格校验 Godot 客户端与 SAM 2 单帧 worker 子进程之间按行收发
# 的 JSONL 协议:请求行解码与校验(loads_line)、请求规范化(validate_request)、
# 成功/失败响应构造(success_response / error_response),以及响应信封校验
# (validate_response);op 覆盖 hello / set_image / predict / cancel /
# shutdown。所有越界、缺字段、多字段、类型错误都以 ValueError 原子拒绝,
# 不做静默修复或截断。
#
# 边界与安全:本模块是"有界纯数据"层——绝不解析或打开任何文件路径;
# PNG 描述符只做相对路径/后缀/遍历的字段级检查,其字节与尺寸的真伪由
# worker 侧的 job 目录边界(annotation_data.model_assist_backend)核验。
#
# 角色与协作:worker 侧被 python/model_assist_worker.py 使用(逐行读入请求、
# 构造成功/失败响应、复用 MAX_LINE_BYTES 限制响应行);客户端侧由 Godot 的
# client/services/model_assist_service.gd 按同一合同构造并核验消息。本模块
# 与 sam_video_protocol 同构,分别服务单帧与视频两条 worker 通道。
"""Bounded pure-data validation for the ``model-assist-v1`` JSONL wire format.

The protocol module never resolves or opens a path.  File authority belongs to
the worker/service job boundary; this layer only accepts relative PNG
descriptors whose bytes and dimensions are checked by that boundary.
"""
from __future__ import annotations

from copy import deepcopy
import json
import math
from pathlib import PurePosixPath
from typing import Any


# 协议版本标识:每条请求/响应的 protocol 字段必须逐字等于该值。
PROTOCOL = "model-assist-v1"
# 单行字节上限(1 MiB):loads_line 强制请求行不超过它,worker 写响应行时
# 同样以它拒绝超限;_validate_json_tree 还借用它作为树内字符串的长度上限。
MAX_LINE_BYTES = 1024 * 1024
# predict 请求允许的最大点提示数量。
MAX_POINTS = 64

# 请求对象允许的字段集合(恰好五键,缺一或多一都拒绝)。
_REQUEST_KEYS = frozenset({"protocol", "request_id", "op", "context", "data"})
# 响应信封允许的字段集合(恰好六键)。
_RESPONSE_KEYS = frozenset({"protocol", "request_id", "ok", "context", "data", "errors"})
# context(会话上下文)的固定字段集合,字段含义:
#   session_id:客户端分配的会话 ID;frame_id:原始帧号;playback_index:
#   播放下标;image_sha256 / record_sha256:当前帧图与当前 V1 记录的小写
#   SHA-256;selected_region_id:当前选中 region 的 ID(允许空串);
#   prompt_revision:提示(prompt)修订号。
_CONTEXT_KEYS = frozenset({
    "session_id",
    "frame_id",
    "playback_index",
    "image_sha256",
    "record_sha256",
    "selected_region_id",
    "prompt_revision",
})
# PNG 描述符的固定字段集合:path=job 目录内的相对 PNG 路径;sha256=文件
# 内容摘要;width/height=像素尺寸(均 >= 1)。
_DESCRIPTOR_KEYS = frozenset({"path", "sha256", "width", "height"})
# predict 请求 data 的固定字段集合:points=[[x, y], ...] 点提示;labels=
# 与 points 一一对应的 0/1 标记(SAM 语义:1=前景点,0=背景点);box=
# 可选 [x0, y0, x1, y1];initial_mask=可选初始 mask 的 PNG 描述符。
_PREDICT_KEYS = frozenset({"points", "labels", "box", "initial_mask"})
# 协议支持的全部操作:hello=握手;set_image=装载帧图;predict=按点/box
# 提示生成 mask 候选;cancel=取消在途请求;shutdown=关闭 worker。
_OPS = frozenset({"hello", "set_image", "predict", "cancel", "shutdown"})
# 合法小写十六进制字符集,用于 SHA-256 摘要字段校验。
_LOWER_HEX = frozenset("0123456789abcdef")


# json.loads 的 parse_constant 回调:JSON 文本出现 NaN / Infinity /
# -Infinity 等非有限常量时抛 ValueError,使整行解析失败。
def _reject_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON constant: {value}")


# json.loads 的 object_pairs_hook:对象出现重复键时抛 ValueError(JSON
# 标准本身不禁止重复键,这里收紧为非法),否则按出现顺序构造普通字典返回。
def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key!r}")
        result[key] = value
    return result


# 严格对象检查:value 必须是 dict 且键集合与 keys 完全一致。
# 参数 value:待检对象;keys:允许的字段集合;label:错误消息中的字段名。
# 返回:原 dict(不拷贝);不满足则抛 ValueError,消息列出缺失与多余字段。
def _exact_object(value: object, keys: frozenset[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
    actual = frozenset(value)
    if actual != keys:
        raise ValueError(
            f"{label} has invalid fields "
            f"(missing={sorted(keys - actual)}, extra={sorted(actual - keys)})"
        )
    return value


# 字符串字段检查:必须是 str、满足空串与长度约束、可 UTF-8 编码、不含
# 控制字符(编码后字节 < 32 或 == 127,即 C0 控制符与 DEL)。
# 参数 value:待检对象;label:错误消息字段名;allow_empty=True 时允许
# 空串;maximum:最大字符数(默认 256)。
# 返回:原字符串;违反任一约束抛 ValueError。
def _text(value: object, label: str, *, allow_empty: bool = False, maximum: int = 256) -> str:
    if not isinstance(value, str) or (not allow_empty and not value) or len(value) > maximum:
        qualifier = "a string" if allow_empty else "a non-empty string"
        raise ValueError(f"{label} must be {qualifier} of at most {maximum} characters")
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise ValueError(f"{label} must be UTF-8 encodable") from exc
    if any(byte < 32 or byte == 127 for byte in encoded):
        raise ValueError(f"{label} must not contain control characters")
    return value


# request_id 字段检查:非空字符串且不超过 128 字符(检查细节转发 _text)。
def _request_id(value: object, label: str = "request_id") -> str:
    return _text(value, label, maximum=128)


# 整数字段检查:必须是精确 int(bool 不算)且不小于 minimum(默认 0)。
# 返回:原值;违反抛 ValueError。
def _integer(value: object, label: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ValueError(f"{label} must be an integer >= {minimum}")
    return value


# 数字字段检查:接受 int/float(bool 不算),统一规范化为有限 float;
# NaN/Infinity 与溢出都以 ValueError 拒绝。返回 float 值。
def _number(value: object, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{label} must be a finite number")
    try:
        normalized = float(value)
    except (OverflowError, ValueError) as exc:
        raise ValueError(f"{label} must be a finite number") from exc
    if not math.isfinite(normalized):
        raise ValueError(f"{label} must be a finite number")
    return normalized


# SHA-256 摘要字段检查:必须是恰好 64 个字符的小写十六进制字符串。
# 返回:原字符串;否则抛 ValueError。
def _digest(value: object, label: str) -> str:
    digest = _text(value, label, maximum=64)
    if len(digest) != 64 or any(character not in _LOWER_HEX for character in digest):
        raise ValueError(f"{label} must be a lower-case SHA-256 digest")
    return digest


# 校验 context 会话上下文对象(字段含义见 _CONTEXT_KEYS 上方注释)。
# 返回:逐字段检查后重建的新字典;任何字段非法抛 ValueError。
def _context(value: object) -> dict[str, Any]:
    source = _exact_object(value, _CONTEXT_KEYS, "context")
    return {
        "session_id": _text(source["session_id"], "context.session_id"),
        "frame_id": _integer(source["frame_id"], "context.frame_id"),
        "playback_index": _integer(source["playback_index"], "context.playback_index"),
        "image_sha256": _digest(source["image_sha256"], "context.image_sha256"),
        "record_sha256": _digest(source["record_sha256"], "context.record_sha256"),
        "selected_region_id": _text(
            source["selected_region_id"], "context.selected_region_id", allow_empty=True
        ),
        "prompt_revision": _integer(source["prompt_revision"], "context.prompt_revision"),
    }


# 校验 PNG 描述符(data.image / data.initial_mask)。
# 返回:新字典 {path, sha256, width, height},path 统一为 POSIX 风格;
# 违反任一约束抛 ValueError。本层不读取该文件,字节与尺寸的真伪由 worker
# 的 job 目录边界核验。
def _descriptor(value: object, label: str) -> dict[str, Any]:
    source = _exact_object(value, _DESCRIPTOR_KEYS, label)
    path_text = _text(source["path"], f"{label}.path", maximum=512)
    path = PurePosixPath(path_text)
    # 必须是相对路径、.png 后缀且非空。
    if path.is_absolute() or path.suffix.lower() != ".png" or not path.parts:
        raise ValueError(f"{label}.path must be a relative .png path")
    # 禁止空段、"."、".." 等路径遍历成分。
    if any(part in {"", ".", ".."} for part in path.parts):
        raise ValueError(f"{label}.path must not contain traversal")
    return {
        "path": path.as_posix(),
        "sha256": _digest(source["sha256"], f"{label}.sha256"),
        "width": _integer(source["width"], f"{label}.width", minimum=1),
        "height": _integer(source["height"], f"{label}.height", minimum=1),
    }


# 校验 predict 的点提示列表:最多 MAX_POINTS(64)个点,每点必须恰含
# [x, y] 两个坐标。
# 返回:坐标经 _number 规范化后的 [[x, y], ...] 新列表;违反抛 ValueError。
def _points(value: object) -> list[list[float]]:
    if not isinstance(value, list) or len(value) > MAX_POINTS:
        raise ValueError(f"data.points must be an array of at most {MAX_POINTS} points")
    normalized: list[list[float]] = []
    for index, point in enumerate(value):
        if not isinstance(point, list) or len(point) != 2:
            raise ValueError(f"data.points[{index}] must contain exactly two coordinates")
        normalized.append([
            _number(point[0], f"data.points[{index}][0]"),
            _number(point[1], f"data.points[{index}][1]"),
        ])
    return normalized


# 校验点提示标记:labels 必须与 points 等长,每个值恰为 int 0 或 1
# (bool 不算);按 SAM 语义 1=前景点,0=背景点。
# 参数 value:待检列表;count:必须匹配的点数。
# 返回:原值组成的新列表;违反抛 ValueError。
def _labels(value: object, count: int) -> list[int]:
    if not isinstance(value, list) or len(value) != count:
        raise ValueError("data.labels must contain exactly one label per point")
    result: list[int] = []
    for index, label in enumerate(value):
        if isinstance(label, bool) or not isinstance(label, int) or label not in (0, 1):
            raise ValueError(f"data.labels[{index}] must be 0 or 1")
        result.append(label)
    return result


# 校验 box 提示:null 表示无 box;否则必须是 [x0, y0, x1, y1] 四个有限
# 数字,且 x0 < x1、y0 < y1(不允许退化或颠倒的框)。
# 返回:float 列表,无 box 时返回 None;违反抛 ValueError。
def _box(value: object) -> list[float] | None:
    if value is None:
        return None
    if not isinstance(value, list) or len(value) != 4:
        raise ValueError("data.box must be null or one [x0, y0, x1, y1] box")
    result = [_number(coordinate, f"data.box[{index}]") for index, coordinate in enumerate(value)]
    if result[0] >= result[2] or result[1] >= result[3]:
        raise ValueError("data.box must have x0 < x1 and y0 < y1")
    return result


# 校验 predict 请求的 data 对象(字段含义见 _PREDICT_KEYS 上方注释)。
# 返回:含 points/labels/box/initial_mask 四键的新字典;initial_mask 为
# null 时保持 null,否则过 _descriptor。
# 门禁:至少提供一个点或一个 box——纯 initial_mask 不构成有效提示
# (违反抛 ValueError)。
def _predict_data(value: object) -> dict[str, Any]:
    source = _exact_object(value, _PREDICT_KEYS, "data")
    points = _points(source["points"])
    labels = _labels(source["labels"], len(points))
    box = _box(source["box"])
    if not points and box is None:
        raise ValueError("predict requires at least one point or a box")
    initial = source["initial_mask"]
    return {
        "points": points,
        "labels": labels,
        "box": box,
        "initial_mask": None if initial is None else _descriptor(initial, "data.initial_mask"),
    }


# 要求字段恰为空对象 {}:hello/shutdown/cancel 的 context 与部分 data
# 都必须是空对象,防止夹带未定义字段。失败抛 ValueError。
def _empty_object(value: object, label: str) -> dict[str, Any]:
    return _exact_object(value, frozenset(), label)


# 迭代遍历整个 JSON 树,拒绝非 JSON 值与非有限数字,并施加规模与字符串
# 长度上限(功能见英文 docstring)。
# 参数 value:任意已解析对象;label:错误消息前缀。
# 实现:用显式栈代替递归,深嵌套不会触发 RecursionError;副作用:无。
def _validate_json_tree(value: object, label: str) -> None:
    """Reject non-JSON and non-finite values without recursive stack growth."""
    pending: list[tuple[object, int]] = [(value, 0)]
    nodes = 0
    while pending:
        current, depth = pending.pop()
        nodes += 1
        # 规模门限:节点总数超过 100000 或嵌套深度超过 256 即视为畸形/恶意
        # 输入而拒绝(魔数上限)。
        if nodes > 100_000 or depth > 256:
            raise ValueError(f"{label} is too deeply nested or large")
        # 标量分支:字符串复用 _text 检查(允许空串,长度上限取单行字节数)。
        if current is None or isinstance(current, (str, bool, int)):
            if isinstance(current, str):
                _text(current, label, allow_empty=True, maximum=MAX_LINE_BYTES)
            continue
        # 浮点分支:JSON 数字不允许 NaN/Infinity。
        if isinstance(current, float):
            if not math.isfinite(current):
                raise ValueError(f"{label} contains a non-finite number")
            continue
        # 数组分支:子节点连同深度 +1 入栈,继续迭代。
        if isinstance(current, list):
            pending.extend((item, depth + 1) for item in current)
            continue
        # 对象分支:键先过字符串检查(上限 512 字符),值再入栈。
        if isinstance(current, dict):
            for key, item in current.items():
                _text(key, f"{label} key", allow_empty=True, maximum=512)
                pending.append((item, depth + 1))
            continue
        # 其余类型不可能来自合法 JSON,直接拒绝。
        raise ValueError(f"{label} contains a non-JSON value")


# 解码并校验恰好一条请求行(功能见英文 docstring)。
# 参数 raw:原始字节行,必须以单个 LF 结尾且总长不超过 MAX_LINE_BYTES(1 MiB)。
# 返回:validate_request 规范化后的请求字典。
# 逐条门禁(违反抛 ValueError):必须是 bytes、以 LF 结尾、不超长;行内
# 不得再出现 LF 或任何 CR(拒绝多行与回车注入);UTF-8 解码失败、JSON
# 语法错误、重复键、非有限常量、递归过深同样拒绝并保留原始原因。
def loads_line(raw: bytes) -> dict[str, Any]:
    """Decode and validate exactly one bounded LF-terminated request line."""
    # 单行门禁:必须是 bytes、以单个终端 LF 结尾、总长不超过 1 MiB。
    if not isinstance(raw, bytes) or not raw.endswith(b"\n") or len(raw) > MAX_LINE_BYTES:
        raise ValueError(f"request line must be LF-terminated and at most {MAX_LINE_BYTES} bytes")
    # 行内禁止第二个 LF 与任何 CR:协议是严格的单行 LF 分隔。
    if b"\n" in raw[:-1] or b"\r" in raw:
        raise ValueError("request line must contain exactly one terminal LF")
    # object_pairs_hook 与 parse_constant 在解析阶段即拒绝重复键与非有限
    # 常量;解析阶段的任何失败统一包成 ValueError。
    try:
        text = raw[:-1].decode("utf-8")
        value = json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError, ValueError) as exc:
        raise ValueError(f"invalid request JSON: {exc}") from exc
    return validate_request(value)


# 校验并归一化一条完整请求(功能见英文 docstring)。
# 参数 value:已解析的 JSON 对象(loads_line 末尾调用,也可直接调用)。
# 返回:校验后的请求字典,固定五键 protocol/request_id/op/context/data:
# protocol 写回版本常量,context 与 data 按 op 逐字段校验重建。
# 各 op 的形状:hello/shutdown 的 context 与 data 都必须是空对象;cancel
# 的 context 为空、data 恰含 target_request_id;set_image 的 context 必须
# 完整、data 恰含 image 描述符;predict 的 context 必须完整、data 为
# 点/box/初始 mask 提示。违反任一约束抛 ValueError。
def validate_request(value: object) -> dict[str, Any]:
    """Return a normalized defensive copy of a strict request object."""
    source = _exact_object(value, _REQUEST_KEYS, "request")
    # protocol 必须逐字等于版本标识。
    if source["protocol"] != PROTOCOL:
        raise ValueError(f"protocol must be {PROTOCOL}")
    request_id = _request_id(source["request_id"])
    # op 必须是白名单内的字符串。
    op = source["op"]
    if not isinstance(op, str) or op not in _OPS:
        raise ValueError(f"unsupported operation: {op!r}")

    # 握手与关机:context/data 都必须是空对象。
    if op in {"hello", "shutdown"}:
        normalized_context = _empty_object(source["context"], "context")
        normalized_data = _empty_object(source["data"], "data")
    # 取消:只需指明要取消的目标请求 ID,context 为空。
    elif op == "cancel":
        normalized_context = _empty_object(source["context"], "context")
        cancel = _exact_object(source["data"], frozenset({"target_request_id"}), "data")
        normalized_data = {"target_request_id": _request_id(cancel["target_request_id"], "data.target_request_id")}
    # 装载帧图:context 必须完整,data 恰含一个 image PNG 描述符。
    elif op == "set_image":
        normalized_context = _context(source["context"])
        data = _exact_object(source["data"], frozenset({"image"}), "data")
        normalized_data = {"image": _descriptor(data["image"], "data.image")}
    # 其余合法 op 即 predict:点/box/初始 mask 提示,context 必须完整。
    else:
        normalized_context = _context(source["context"])
        normalized_data = _predict_data(source["data"])

    return {
        "protocol": PROTOCOL,
        "request_id": request_id,
        "op": op,
        "context": normalized_context,
        "data": normalized_data,
    }


# 构造成功响应(功能见英文 docstring)。
# 参数 request:此前 validate_request 产出的请求字典(内部会再复验一次,
# 并复用其中的 request_id 与 context);data:响应数据字典(具体结构由
# 各 op 的 backend 结果决定,这里只做通用检查)。
# 返回:固定六键信封 {protocol, request_id, ok=True, context, data,
# errors=[]}。异常:request 复验失败、data 不是 dict、data 树含非 JSON
# 值/非有限数字/超限字符串时抛 ValueError。
def success_response(request: dict[str, Any], data: dict[str, Any]) -> dict[str, Any]:
    """Build a successful response that cannot alias caller-owned data."""
    normalized = validate_request(request)
    # data 必须是 JSON 对象,且整棵树可安全序列化(有限、可编码、不超限)。
    if not isinstance(data, dict):
        raise ValueError("response data must be an object")
    _validate_json_tree(data, "response data")
    # context 与 data 均深拷贝,响应不与调用方数据共享任何引用。
    return {
        "protocol": PROTOCOL,
        "request_id": normalized["request_id"],
        "ok": True,
        "context": deepcopy(normalized["context"]),
        "data": deepcopy(data),
        "errors": [],
    }


# 构造失败响应(功能见英文 docstring)。
# 参数 request_id:原请求 ID(解析失败拿不到时由调用方兜底,如 "invalid");
# context:原请求上下文或空对象;errors:一到十六条错误消息。
# 返回:固定六键信封 {protocol, request_id, ok=False, context, data={},
# errors=[...]}。异常:request_id 非法、context 不是 dict 或树不合法、
# errors 不在 1-16 条范围或含非法消息时抛 ValueError。
def error_response(request_id: str, context: dict[str, Any], errors: list[str]) -> dict[str, Any]:
    """Build a strict failure response with one or more bounded messages."""
    normalized_id = _request_id(request_id)
    if not isinstance(context, dict):
        raise ValueError("response context must be an object")
    _validate_json_tree(context, "response context")
    # 失败响应必须至少携带一条错误,且不超过 16 条。
    if not isinstance(errors, list) or not errors or len(errors) > 16:
        raise ValueError("response errors must contain from one to 16 messages")
    # 逐条消息检查:非空字符串、不超过 512 字符。
    normalized_errors = [
        _text(message, f"response errors[{index}]", maximum=512)
        for index, message in enumerate(errors)
    ]
    return {
        "protocol": PROTOCOL,
        "request_id": normalized_id,
        "ok": False,
        "context": deepcopy(context),
        "data": {},
        "errors": normalized_errors,
    }


# 校验响应信封的公共结构(功能见英文 docstring)。
# 参数 value:对端(worker)返回的已解析 JSON 对象。
# 返回:深拷贝的响应字典;data 的 op 级细节由调用方继续核验。
# 一致性门禁(违反抛 ValueError):六键齐全;protocol 匹配;ok 为 bool;
# context/data 为对象且整棵树合法;errors 为字符串数组且每条非空;ok 为
# 真当且仅当 errors 为空,ok 为假时 data 必须是空对象。
def validate_response(value: object) -> dict[str, Any]:
    """Validate the common response envelope for service-side consumption."""
    source = _exact_object(value, _RESPONSE_KEYS, "response")
    if source["protocol"] != PROTOCOL:
        raise ValueError(f"protocol must be {PROTOCOL}")
    request_id = _request_id(source["request_id"])
    if not isinstance(source["ok"], bool):
        raise ValueError("response.ok must be boolean")
    if not isinstance(source["context"], dict) or not isinstance(source["data"], dict):
        raise ValueError("response context and data must be objects")
    _validate_json_tree(source["context"], "response context")
    _validate_json_tree(source["data"], "response data")
    errors = source["errors"]
    if not isinstance(errors, list) or any(not isinstance(item, str) or not item for item in errors):
        raise ValueError("response.errors must be an array of non-empty strings")
    # 信封自洽:ok 与 errors 数量互锁;失败响应不得携带 data。
    if source["ok"] != (len(errors) == 0) or (not source["ok"] and source["data"]):
        raise ValueError("response ok/data/errors fields are inconsistent")
    return deepcopy(source)
