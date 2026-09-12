# sam-video-v1 JSONL 线路协议的纯数据校验层(annotation_data 包核心库)。
#
# 用途:定义并严格校验 Godot 客户端与 SAM 2 Video worker 子进程之间按行收发
# 的 JSONL 协议:请求行解码与校验(loads_line)、请求规范化(validate_request)、
# 成功/失败响应构造(success_response / error_response),以及响应信封校验
# (validate_response);op 覆盖 hello / open_batch / add_mask / propagate /
# cancel / reset_batch / shutdown。所有越界、缺字段、多字段、类型错误都以
# ValueError 原子拒绝,不做静默修复或截断。
#
# 协议流程:open_batch 装载关键帧与 1-30(MAX_TARGETS)个向后传播目标帧,
# add_mask 在关键帧写入待传播 region 的 mask,propagate 把该 mask 沿视频
# 向后传播到全部目标帧;cancel 取消在途请求并释放批,reset_batch 主动释放
# 批,shutdown 结束 worker。与 model_assist_protocol 同构,分别服务视频与
# 单帧两条 worker 通道。
#
# 边界与安全:本模块是"有界纯数据"层——绝不解析或打开任何文件路径;
# PNG 描述符只做相对路径/后缀/遍历的字段级检查,其字节与尺寸的真伪由
# worker 侧的 job 目录边界(annotation_data.sam_video_backend)核验。
#
# 角色与协作:worker 侧被 python/sam_video_worker.py 使用(逐行读入请求、
# 构造成功/失败响应、复用 MAX_LINE_BYTES 限制响应行);sam_video_backend
# 复用 MAX_TARGETS 与 OBJECT_ID;客户端侧由 Godot 的
# client/services/sam_video_service.gd 按同一合同构造并核验消息。
"""Strict bounded validation for the ``sam-video-v1`` JSONL protocol.

This module handles pure data only.  It never resolves or reads descriptor
paths; the job-scoped backend owns that file authority boundary.
"""
from __future__ import annotations

from copy import deepcopy
import json
import math
from pathlib import PurePosixPath
from typing import Any


# 协议版本标识:每条请求/响应的 protocol 字段必须逐字等于该值。
PROTOCOL = "sam-video-v1"
# 单行字节上限(1 MiB):loads_line 强制请求行不超过它,worker 写响应行时
# 同样以它拒绝超限。
MAX_LINE_BYTES = 1_048_576
# 单次传播允许的最大目标帧数:context.propagation_count、context.targets 的
# 长度与 propagate 的 data.count 都不得超过它(向后传播 1-30 帧)。
MAX_TARGETS = 30
# 本协议支持的唯一 SAM object id:每个批只传播一个 region 的 mask,
# add_mask/propagate 的 data.object_id 必须恰为该值。
OBJECT_ID = 1

# 请求对象允许的字段集合(恰好五键,缺一或多一都拒绝)。
_REQUEST_KEYS = frozenset({"protocol", "request_id", "op", "context", "data"})
# 响应信封允许的字段集合(恰好六键)。
_RESPONSE_KEYS = frozenset({"protocol", "request_id", "ok", "context", "data", "errors"})
# context(会话上下文)的必填字段集合,字段含义:
#   session_id:客户端分配的批审核会话 ID,worker 校验与本进程启动参数一致;
#   request_nonce:客户端生成的每请求一次性标识(实例 ID+微秒时间戳),
#   用于区分重复提交的请求;
#   key_playback_index / key_frame_id:关键帧在 Source 中的播放下标与原始帧号;
#   targets:向后传播目标帧描述符列表(字段见 _TARGET_REQUIRED_KEYS);
#   store_revision:发起请求时标注 store 的修订号;
#   review_sha256:关键帧所在会话评审状态(review_state)快照的 SHA-256;
#   key_record_sha256:关键帧 V1 标注记录内容的 SHA-256;
#   region_id:待传播 region 的稳定 ID;
#   propagation_count:目标帧数(1 到 MAX_TARGETS),必须等于 targets 长度;
#   requested_device:期望推理设备,auto/cpu/cuda 之一。
_CONTEXT_REQUIRED_KEYS = frozenset({
    "session_id",
    "request_nonce",
    "key_playback_index",
    "key_frame_id",
    "targets",
    "store_revision",
    "review_sha256",
    "key_record_sha256",
    "region_id",
    "propagation_count",
    "requested_device",
})
# context 的可选字段:key_time_s=关键帧时间戳(秒),Source 条目没有该
# 字段时整键省略。
_CONTEXT_OPTIONAL_KEYS = frozenset({"key_time_s"})
# 传播目标帧描述符的必填字段:playback_index=播放下标;frame_id=原始帧号;
# entry_sha256=Source 帧条目内容的 SHA-256;image_sha256=冻结 PNG 输入的
# SHA-256(客户端装批时逐帧写入,供两边核对帧身份与内容)。
_TARGET_REQUIRED_KEYS = frozenset({
    "playback_index", "frame_id", "entry_sha256", "image_sha256"
})
# 目标帧描述符的可选字段:time_s=该帧时间戳(秒),Source 条目缺失时省略。
_TARGET_OPTIONAL_KEYS = frozenset({"time_s"})
# 帧描述符(open_batch 的 data.frames 元素)的固定字段:path=job 目录内的
# 相对 PNG 路径;sha256=文件内容摘要;width/height=像素尺寸(均 >= 1);
# playback_index/frame_id=播放下标与原始帧号。
_FRAME_KEYS = frozenset({
    "path", "sha256", "width", "height", "playback_index", "frame_id"
})
# mask 描述符(add_mask 的 data.mask)的固定字段:path=关键帧 mask 的相对
# PNG 路径;sha256=文件内容摘要;roi=[x, y, width, height] 像素矩形。
_MASK_KEYS = frozenset({"path", "sha256", "roi"})
# 协议支持的全部操作:hello=握手并惰性加载 SAM 2 predictor;open_batch=
# 装载关键帧与目标帧;add_mask=在关键帧写入 mask;propagate=把 mask 向后
# 传播到目标帧;cancel=取消在途请求并释放批;reset_batch=释放当前批;
# shutdown=关闭 worker。
_OPS = frozenset({
    "hello", "open_batch", "add_mask", "propagate", "cancel", "reset_batch", "shutdown"
})
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


# 带可选字段的对象检查:value 必须是 dict,键集合必须恰为 required 与
# optional 的并集(缺任一必填键、或出现未知键都拒绝)。
# 参数含义同 _exact_object。返回:原 dict(不拷贝);不满足抛 ValueError。
def _object_with_optional(
    value: object,
    required: frozenset[str],
    optional: frozenset[str],
    label: str,
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
    actual = frozenset(value)
    missing = required - actual
    extra = actual - required - optional
    if missing or extra:
        raise ValueError(
            f"{label} has invalid fields (missing={sorted(missing)}, extra={sorted(extra)})"
        )
    return value


# 字符串字段检查:必须是 str、非空、不超过 maximum 个字符、可 UTF-8 编码、
# 不含控制字符(编码后字节 < 32 或 == 127,即 C0 控制符与 DEL)。
# 参数 value:待检对象;label:错误消息字段名;maximum:最大字符数
# (默认 256)。返回:原字符串;违反任一约束抛 ValueError。
def _text(value: object, label: str, *, maximum: int = 256) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise ValueError(f"{label} must be a non-empty string of at most {maximum} characters")
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


# 整数字段检查:必须是精确 int(bool 不算)且不小于 minimum(默认 0);
# 给定 maximum 时还不得超过它。返回:原值;违反抛 ValueError。
def _integer(
    value: object,
    label: str,
    *,
    minimum: int = 0,
    maximum: int | None = None,
) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ValueError(f"{label} must be an integer >= {minimum}")
    if maximum is not None and value > maximum:
        raise ValueError(f"{label} must be an integer <= {maximum}")
    return value


# 数字字段检查:接受 int/float(bool 不算),必须为有限值;NaN/Infinity
# 与溢出都以 ValueError 拒绝。返回:原值(int 保持 int,不强制转 float)。
def _finite_number(value: object, label: str) -> int | float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{label} must be a finite number")
    try:
        finite = math.isfinite(value)
    except (OverflowError, TypeError, ValueError) as exc:
        raise ValueError(f"{label} must be a finite number") from exc
    if not finite:
        raise ValueError(f"{label} must be a finite number")
    return value


# SHA-256 摘要字段检查:必须是恰好 64 个字符的小写十六进制字符串。
# 返回:原字符串;否则抛 ValueError。
def _digest(value: object, label: str) -> str:
    digest = _text(value, label, maximum=64)
    if len(digest) != 64 or any(character not in _LOWER_HEX for character in digest):
        raise ValueError(f"{label} must be a lower-case SHA-256 digest")
    return digest


# 校验 PNG 描述符的路径字段:非空、不超过 512 字符、后缀 .png 的相对
# POSIX 路径,禁止反斜杠与空段/"."/".." 等路径遍历成分。
# 返回:统一为 POSIX 风格的路径字符串;违反抛 ValueError。本层不读取
# 该文件,字节与尺寸的真伪由 worker 的 job 目录边界核验。
def _relative_png(value: object, label: str) -> str:
    path_text = _text(value, label, maximum=512)
    path = PurePosixPath(path_text)
    # 任一条件成立即判定为不安全路径:绝对路径、非 PNG、空路径、反斜杠、
    # 空段/"."/".." 遍历成分。
    if (
        path.is_absolute()
        or path.suffix.lower() != ".png"
        or not path.parts
        or "\\" in path_text
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise ValueError(f"{label} must be a traversal-free relative PNG path")
    return path.as_posix()


# 校验一个传播目标帧描述符(字段含义见 _TARGET_REQUIRED_KEYS 上方注释)。
# 参数 value:待检对象;index:targets 数组中的下标,用于错误消息定位。
# 返回:逐字段检查后重建的新字典;任何字段非法抛 ValueError。
def _target(value: object, index: int) -> dict[str, Any]:
    label = f"context.targets[{index}]"
    source = _object_with_optional(
        value, _TARGET_REQUIRED_KEYS, _TARGET_OPTIONAL_KEYS, label
    )
    result: dict[str, Any] = {
        "playback_index": _integer(source["playback_index"], f"{label}.playback_index"),
        "frame_id": _integer(source["frame_id"], f"{label}.frame_id"),
    }
    # 可选 time_s:出现才校验并保留,缺失不补默认值。
    if "time_s" in source:
        result["time_s"] = _finite_number(source["time_s"], f"{label}.time_s")
    result.update({
        "entry_sha256": _digest(source["entry_sha256"], f"{label}.entry_sha256"),
        "image_sha256": _digest(source["image_sha256"], f"{label}.image_sha256"),
    })
    return result


# 校验 context 会话上下文对象(字段含义见 _CONTEXT_REQUIRED_KEYS 上方注释)。
# 结构门禁(违反抛 ValueError):propagation_count 在 1 到 MAX_TARGETS 之间;
# targets 数组含 1 到 MAX_TARGETS 个元素且长度恰等于 propagation_count;
# 各目标 playback_index 严格递增、且全部大于 key_playback_index(传播只
# 向后不向前);requested_device 必须是 auto/cpu/cuda 之一。
# 返回:逐字段检查后重建的新字典(可选 key_time_s 仅在提供时保留)。
def _context(value: object) -> dict[str, Any]:
    source = _object_with_optional(
        value, _CONTEXT_REQUIRED_KEYS, _CONTEXT_OPTIONAL_KEYS, "context"
    )
    propagation_count = _integer(
        source["propagation_count"],
        "context.propagation_count",
        minimum=1,
        maximum=MAX_TARGETS,
    )
    raw_targets = source["targets"]
    if not isinstance(raw_targets, list) or not 1 <= len(raw_targets) <= MAX_TARGETS:
        raise ValueError(f"context.targets must contain from 1 to {MAX_TARGETS} targets")
    # 目标帧数组长度必须与声明的传播帧数互相吻合。
    if len(raw_targets) != propagation_count:
        raise ValueError("context.targets size must equal context.propagation_count")
    targets = [_target(item, index) for index, item in enumerate(raw_targets)]
    key_playback_index = _integer(
        source["key_playback_index"], "context.key_playback_index"
    )
    # 逐个比较播放下标:必须严格递增,且首个目标晚于关键帧(只向后传播)。
    previous = key_playback_index
    for target in targets:
        current = target["playback_index"]
        if current <= previous:
            raise ValueError("context target playback indices must be unique, sorted and forward")
        previous = current
    # 推理设备请求:三种合法取值之一。
    requested_device = source["requested_device"]
    if requested_device not in {"auto", "cpu", "cuda"} or not isinstance(requested_device, str):
        raise ValueError("context.requested_device must be auto, cpu or cuda")
    result: dict[str, Any] = {
        "session_id": _text(source["session_id"], "context.session_id"),
        "request_nonce": _text(source["request_nonce"], "context.request_nonce"),
        "key_playback_index": key_playback_index,
        "key_frame_id": _integer(source["key_frame_id"], "context.key_frame_id"),
    }
    if "key_time_s" in source:
        result["key_time_s"] = _finite_number(source["key_time_s"], "context.key_time_s")
    result.update({
        "targets": targets,
        "store_revision": _integer(source["store_revision"], "context.store_revision"),
        "review_sha256": _digest(source["review_sha256"], "context.review_sha256"),
        "key_record_sha256": _digest(
            source["key_record_sha256"], "context.key_record_sha256"
        ),
        "region_id": _text(source["region_id"], "context.region_id"),
        "propagation_count": propagation_count,
        "requested_device": requested_device,
    })
    return result


# 校验一个帧描述符(open_batch 的 data.frames 元素,字段含义见
# _FRAME_KEYS 上方注释)。
# 参数 value:待检对象;index:frames 数组中的下标,用于错误消息定位。
# 返回:逐字段检查后重建的新字典(path 统一为 POSIX 风格);
# 任何字段非法抛 ValueError。
def _frame(value: object, index: int) -> dict[str, Any]:
    label = f"data.frames[{index}]"
    source = _exact_object(value, _FRAME_KEYS, label)
    return {
        "path": _relative_png(source["path"], f"{label}.path"),
        "sha256": _digest(source["sha256"], f"{label}.sha256"),
        "width": _integer(source["width"], f"{label}.width", minimum=1),
        "height": _integer(source["height"], f"{label}.height", minimum=1),
        "playback_index": _integer(source["playback_index"], f"{label}.playback_index"),
        "frame_id": _integer(source["frame_id"], f"{label}.frame_id"),
    }


# 校验 open_batch 的 data 对象:必须恰含 frames 数组,数量等于目标帧数
# 加一(关键帧 1 个 + context.targets 全部)。
# 门禁(违反抛 ValueError):各帧的 (playback_index, frame_id) 身份序列必须
# 恰为「关键帧在前、其后按 targets 顺序」逐一对应;帧 path 不得重复。
# 返回:{"frames": [...]} 新字典;参数 context 为已规范化的请求上下文。
def _open_batch_data(value: object, context: dict[str, Any]) -> dict[str, Any]:
    source = _exact_object(value, frozenset({"frames"}), "data")
    raw_frames = source["frames"]
    expected_count = len(context["targets"]) + 1
    if not isinstance(raw_frames, list) or len(raw_frames) != expected_count:
        raise ValueError("data.frames size must equal context.targets size plus one")
    frames = [_frame(item, index) for index, item in enumerate(raw_frames)]
    # 期望身份序列:先关键帧,再按顺序逐个目标帧。
    expected_identities = [
        (context["key_playback_index"], context["key_frame_id"]),
        *((item["playback_index"], item["frame_id"]) for item in context["targets"]),
    ]
    actual_identities = [
        (item["playback_index"], item["frame_id"]) for item in frames
    ]
    if actual_identities != expected_identities:
        raise ValueError("data.frames identities must equal the key then ordered targets")
    # 同一批内帧文件不得重复(去重后数量必须不变)。
    if len({item["path"] for item in frames}) != len(frames):
        raise ValueError("data.frames paths must be unique")
    return {"frames": frames}


# 校验 add_mask 的 data.mask 描述符(字段含义见 _MASK_KEYS 上方注释)。
# roi 门禁:必须是恰含四个非负整数的 [x, y, width, height],且宽高为正。
# 返回:逐字段检查后重建的新字典;违反抛 ValueError。
def _mask(value: object) -> dict[str, Any]:
    source = _exact_object(value, _MASK_KEYS, "data.mask")
    roi = source["roi"]
    if not isinstance(roi, list) or len(roi) != 4:
        raise ValueError("data.mask.roi must be [x, y, width, height]")
    normalized_roi = [
        _integer(item, f"data.mask.roi[{index}]", minimum=0)
        for index, item in enumerate(roi)
    ]
    # 零尺寸 ROI 无意义,直接拒绝。
    if normalized_roi[2] == 0 or normalized_roi[3] == 0:
        raise ValueError("data.mask.roi width and height must be positive")
    return {
        "path": _relative_png(source["path"], "data.mask.path"),
        "sha256": _digest(source["sha256"], "data.mask.sha256"),
        "roi": normalized_roi,
    }


# 校验 SAM object id:必须等于 OBJECT_ID(1)——本协议每个批只跟踪一个
# 对象。返回:原值;违反抛 ValueError。
def _object_id(value: object, label: str = "data.object_id") -> int:
    object_id = _integer(value, label, minimum=OBJECT_ID, maximum=OBJECT_ID)
    if object_id != OBJECT_ID:
        raise ValueError(f"{label} must be {OBJECT_ID}")
    return object_id


# 要求 data 恰为空对象 {}:hello/reset_batch/shutdown 不携带任何载荷,
# 夹带字段即拒绝。返回:空字典;违反抛 ValueError。
def _empty_data(value: object) -> dict[str, Any]:
    _exact_object(value, frozenset(), "data")
    return {}


# 迭代遍历整个 JSON 树,拒绝非 JSON 值与非有限数字,并施加节点数与嵌套
# 深度的规模上限。参数 value:任意已解析对象;label:错误消息前缀。
# 实现:用显式栈代替递归,深嵌套不会触发 RecursionError;副作用:无。
def _validate_json_tree(value: object, label: str) -> None:
    pending: list[tuple[object, int]] = [(value, 0)]
    nodes = 0
    while pending:
        current, depth = pending.pop()
        nodes += 1
        # 规模门限:节点总数超过 100000 或嵌套深度超过 256 即视为畸形/恶意
        # 输入而拒绝(魔数上限)。
        if nodes > 100_000 or depth > 256:
            raise ValueError(f"{label} is too deeply nested or large")
        # 标量分支:null/bool/int 无需进一步检查,直接放行。
        if current is None or isinstance(current, (bool, int)):
            continue
        # 字符串分支:必须可 UTF-8 编码且不含控制字符(字节 < 32 或 == 127)。
        if isinstance(current, str):
            try:
                encoded = current.encode("utf-8")
            except UnicodeEncodeError as exc:
                raise ValueError(f"{label} contains non-UTF-8 text") from exc
            if any(byte < 32 or byte == 127 for byte in encoded):
                raise ValueError(f"{label} contains control characters")
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
        # 对象分支:键必须是字符串;键与值随后入栈,统一按上述规则检查。
        if isinstance(current, dict):
            for key, item in current.items():
                if not isinstance(key, str):
                    raise ValueError(f"{label} contains a non-string key")
                pending.append((key, depth + 1))
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
    """Decode and validate one LF-terminated request no larger than one MiB."""
    # 单行门禁:必须是 bytes、以单个终端 LF 结尾、总长不超过 1 MiB。
    if not isinstance(raw, bytes) or not raw.endswith(b"\n") or len(raw) > MAX_LINE_BYTES:
        raise ValueError(f"request line must be LF-terminated and at most {MAX_LINE_BYTES} bytes")
    # 行内禁止第二个 LF 与任何 CR:协议是严格的单行 LF 分隔。
    if b"\n" in raw[:-1] or b"\r" in raw:
        raise ValueError("request line must contain exactly one terminal LF")
    # object_pairs_hook 与 parse_constant 在解析阶段即拒绝重复键与非有限
    # 常量;解析阶段的任何失败统一包成 ValueError。
    try:
        value = json.loads(
            raw[:-1].decode("utf-8"),
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
# 与单帧协议不同,本协议所有 op(含 hello)都必须携带完整 context。
# 各 op 的 data 形状:hello/reset_batch/shutdown 必须为空对象;open_batch
# 携带 frames 帧数组(与 context 的关键帧+目标帧一一对应);add_mask 携带
# mask 描述符与 object_id;propagate 携带 count 与 object_id(count 必须等于
# context.propagation_count);cancel 携带 target_request_id。违反抛 ValueError。
def validate_request(value: object) -> dict[str, Any]:
    """Return a normalized defensive copy of one exact request."""
    source = _exact_object(value, _REQUEST_KEYS, "request")
    # protocol 必须逐字等于版本标识。
    if source["protocol"] != PROTOCOL:
        raise ValueError(f"protocol must be {PROTOCOL}")
    request_id = _request_id(source["request_id"])
    # op 必须是白名单内的字符串。
    op = source["op"]
    if not isinstance(op, str) or op not in _OPS:
        raise ValueError(f"unsupported operation: {op!r}")
    normalized_context = _context(source["context"])
    # 握手/释放批/关机:data 必须为空对象。
    if op in {"hello", "reset_batch", "shutdown"}:
        data = _empty_data(source["data"])
    # 打开批:frames 的数量与帧身份必须与 context 声明的关键帧+目标帧一致。
    elif op == "open_batch":
        data = _open_batch_data(source["data"], normalized_context)
    # 写入关键帧 mask:data 恰含 mask 描述符与固定 object_id。
    elif op == "add_mask":
        raw = _exact_object(source["data"], frozenset({"mask", "object_id"}), "data")
        data = {"mask": _mask(raw["mask"]), "object_id": _object_id(raw["object_id"])}
    # 向后传播:count 必须与 context.propagation_count 一致。
    elif op == "propagate":
        raw = _exact_object(source["data"], frozenset({"count", "object_id"}), "data")
        count = _integer(raw["count"], "data.count", minimum=1, maximum=MAX_TARGETS)
        # 载荷与上下文声明的帧数不一致即拒绝,防止两者脱节。
        if count != normalized_context["propagation_count"]:
            raise ValueError("data.count must equal context.propagation_count")
        data = {"count": count, "object_id": _object_id(raw["object_id"])}
    # 其余合法 op 即 cancel:指明要取消的目标请求 ID。
    else:
        raw = _exact_object(source["data"], frozenset({"target_request_id"}), "data")
        data = {"target_request_id": _request_id(
            raw["target_request_id"], "data.target_request_id"
        )}
    return {
        "protocol": PROTOCOL,
        "request_id": request_id,
        "op": op,
        "context": normalized_context,
        "data": data,
    }


# 构造成功响应(功能见英文 docstring)。
# 参数 request:此前 validate_request 产出的请求字典(内部会再复验一次,
# 并复用其中的 request_id 与 context);data:响应数据字典(具体结构由各
# op 的 backend 结果决定,这里只做通用检查)。
# 返回:固定六键信封 {protocol, request_id, ok=True, context, data,
# errors=[]}。异常:request 复验失败、data 不是 dict、data 树含非 JSON 值/
# 非有限数字/控制字符时抛 ValueError。
def success_response(request: dict[str, Any], data: dict[str, Any]) -> dict[str, Any]:
    """Build an exact success envelope without aliasing caller-owned data."""
    normalized = validate_request(request)
    # data 必须是 JSON 对象,且整棵树可安全序列化(有限、可编码)。
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
# 参数 request_id:原请求 ID(JSON 解析失败拿不到时由调用方兜底,如
# "invalid");context:原请求上下文或空对象;errors:一到十六条错误消息。
# 返回:固定六键信封 {protocol, request_id, ok=False, context, data={},
# errors=[...]}。异常:request_id 非法、context 不是 dict 或树不合法、
# errors 不在 1-16 条范围或含非法消息时抛 ValueError。
def error_response(request_id: str, context: dict[str, Any], errors: list[str]) -> dict[str, Any]:
    """Build an exact failure envelope with bounded finite JSON data."""
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
    """Validate the shared response envelope for service-side consumption."""
    source = _exact_object(value, _RESPONSE_KEYS, "response")
    if source["protocol"] != PROTOCOL:
        raise ValueError(f"protocol must be {PROTOCOL}")
    _request_id(source["request_id"])
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
