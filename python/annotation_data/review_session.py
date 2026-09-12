# Media Label V3 审核会话(review session)独立校验模块。
#
# 用途:校验 V3 审核会话 JSON——在同一文档中合并不可变模型基线
# (baseline_records)、人工修正副本(frames)、verification(review_state)
# 与批量操作元数据(batch_operations)的格式;先做 media-label-v3.schema.json
# 结构校验,再做跨记录/跨帧/工作流不变量检查。
#
# 角色与协作:被 workspace.validate_media_label_semantics 在 schema_version==3
# 时委托调用;training_package 复用本模块的 _normalized 做数值规范化;
# 数值规范化的原因见下方模块 docstring(Godot 内容摘要把 JSON 数值一律按
# double 处理)。不依赖文件系统与 UI,输入输出均为纯 Python 对象。
"""Independent Media Label V3 validation; no filesystem or UI dependencies.

Godot's existing content digest normalizes all JSON numbers to doubles. Keep
source identity internal when validating records; persistent corrections project
that identity to human_corrected without changing the immutable baseline.
"""
import hashlib
import json
from typing import Any

from annotation_data.contracts import validate_instance


# 递归规范化 JSON 值:重建 dict/list(得到新容器),所有 int/float 统一转成
# float(0 归一为 0.0);bool 等其余类型原样保留。
# 用途:对齐 Godot 内容摘要把所有 JSON 数值按 double 处理的行为,使摘要
# 在 Python 侧可复现。
def _normalized(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: _normalized(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_normalized(item) for item in value]
    if type(value) in (int, float):
        return float(value) if value != 0 else 0.0
    return value


# 计算 V3 全精度规范化摘要:基线记录按原始帧号(frame 字段)排序后,序列化
# 为紧凑、键序确定、保留非 ASCII 的 JSON 文本,再取 SHA-256。
# 参数 records:基线记录列表,每条必须含 frame 字段。
# 返回:64 位十六进制摘要字符串,用于与会话声明的 baseline_digest 比对,
# 证明模型基线字节未被改动(基线不可变)。
# 异常:记录缺 frame 字段抛 KeyError;含不可序列化对象抛 TypeError。
def baseline_digest(records: list[dict]) -> str:
    """V3 full precision canonical digest, with records ordered by original frame ID."""
    text = json.dumps(_normalized(sorted(records, key=lambda r: r["frame"])),
                      sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


# 校验一个 V3 审核会话对象,返回错误消息列表(空列表即通过)。
# 参数 payload:待校验的 JSON 值(通常是 label 文件的解析结果)。
# 校验分两层:先做 media-label-v3.schema.json 结构校验,结构不合法时直接
# 返回 schema 错误;结构合法后再检查以下跨记录不变量——
#   frame_entries:playback 索引必须等于数组下标、frame_id 不得重复、
#       time_s(如有)必须按播放顺序非递减;
#   explicit_frames / frames:显式帧必须都已知,frames 字典的键必须与
#       显式帧集合完全一致;
#   baseline_records:baseline_kind 为 model/imported_labels 时,基线必须
#       恰好覆盖全部显式帧且 frame 不重复,baseline_digest 必须与基线
#       实际内容一致(不可变基线);
#   frames(人工修正副本):每条记录的 frame/source 身份必须正确(source
#       固定为 human_corrected),time_s 必须原样保留基线时间戳(包括
#       缺失这一事实),region ID 不得重复;
#   review_state:已审核帧必须是显式帧;
#   batch_operations:v1/v2 Poly 记录按数值范围校验；v3 SAM Video 记录按
#       Source 播放顺序校验精确的前向目标、停止帧和有界风险摘要。
# 副作用:无(纯函数,不访问文件系统)。
def validate_review_session(payload: object) -> list[str]:
    """Validate structure first, then cross-record/frame/workflow invariants."""
    # 第一层:schema 结构校验;不合法时直接返回 schema 错误,不做后续检查。
    errors = validate_instance(payload, "media-label-v3.schema.json")
    if errors:
        return errors
    assert isinstance(payload, dict)
    # frame_entries:playback 索引必须等于数组下标,frame_id 不得重复,
    # time_s(如有)必须按播放顺序非递减(允许相等);同时建立
    # frame_id -> 条目映射,供后续身份与时间戳校验使用。
    entries = payload["frame_entries"]
    frame_map = {}
    previous_time = -1.0
    for index, entry in enumerate(entries):
        frame = entry["frame_id"]
        if entry["frame"] != index:
            errors.append(f"frame_entries.{index}.frame: expected playback index {index}")
        if frame in frame_map:
            errors.append(f"frame_entries.{index}.frame_id: duplicate frame")
        if "time_s" in entry:
            if entry["time_s"] < previous_time:
                errors.append(f"frame_entries.{index}.time_s: timestamps must be ordered")
            previous_time = entry["time_s"]
        frame_map[frame] = entry
    # explicit_frames 必须都是已知帧,且 frames 字典的键(人工修正副本)
    # 必须与显式帧集合完全一致。
    explicit = set(payload["explicit_frames"])
    if not explicit <= frame_map.keys():
        errors.append("explicit_frames: unknown original frame")
    if set(map(int, payload["frames"])) != explicit:
        errors.append("frames: must exactly match explicit_frames")
    # 基线门禁:baseline_kind 为 model/imported_labels(已知来源)时,基线
    # 必须恰好覆盖全部显式帧且 frame 不重复,摘要必须与基线实际内容一致。
    baseline = payload["baseline_records"]
    known = payload["baseline_kind"] in ("model", "imported_labels")
    baseline_ids = [record["frame"] for record in baseline]
    if known:
        if len(baseline_ids) != len(set(baseline_ids)) or set(baseline_ids) != frame_map.keys():
            errors.append("baseline_records: expected exact complete frame set")
        if baseline_digest(baseline) != payload["baseline_digest"]:
            errors.append("baseline_digest: differs from immutable baseline")
    # 基线记录保留会话内部的模型身份;人工修正副本必须投影为 human_corrected。
    for record in baseline:
        errors.extend(_record_identity(record, record["frame"], payload["source"], frame_map, "baseline_records"))
    baseline_by_frame = {record["frame"]: record for record in baseline}
    for key, record in payload["frames"].items():
        errors.extend(_record_identity(record, int(key), "human_corrected", frame_map, f"frames.{key}"))
        # 人工副本必须原样保留基线时间戳,包括「基线没有 time_s」这一事实。
        original = baseline_by_frame.get(int(key))
        if known and original is not None and (
            ("time_s" in record) != ("time_s" in original)
            or record.get("time_s") != original.get("time_s")
        ):
            errors.append(f"frames.{key}.time_s: must preserve baseline timestamp including absence")
    # 已审核(review_state)的帧必须是显式帧,不能审核未选择的帧。
    for key in payload["review_state"]:
        if int(key) not in explicit:
            errors.append(f"review_state.{key}: reviewed frame must be explicit")
    # 批量操作元数据门禁:关键帧/起止帧必须是已知原始帧且 start<=end,
    # 受影响帧必须是已知帧、落在 [start, end] 内且不等于关键帧。
    for index, operation in enumerate(payload["batch_operations"]):
        prefix = f"batch_operations.{index}"
        if operation["schema_version"] == 3:
            errors.extend(_validate_sam_video_operation(operation, entries, prefix))
            continue
        keyframe, start, end = (operation[k] for k in ("keyframe", "start_frame", "end_frame"))
        if any(frame not in frame_map for frame in (keyframe, start, end)) or start > end:
            errors.append(f"{prefix}: invalid original frame range")
        affected = operation["affected_frames"]
        if any(frame not in frame_map or not start <= frame <= end or frame == keyframe for frame in affected):
            errors.append(f"{prefix}.affected_frames: invalid target")
        # 带 metric_id(v2 算法审计字段)时,覆盖计数必须自洽:covered 等于
        # 端点差 +1、不超过 max_frames,changed 等于受影响帧数且严格小于
        # covered,且关键帧在范围之内。
        if "metric_id" in operation:
            if not start <= keyframe <= end:
                errors.append(f"{prefix}: range must contain keyframe")
            if (operation["start_index"] > operation["end_index"]
                or operation["covered_count"] != operation["end_index"] - operation["start_index"] + 1
                or operation["covered_count"] > operation["max_frames"]
                or operation["changed_count"] != len(affected)
                or operation["changed_count"] >= operation["covered_count"]):
                errors.append(f"{prefix}: inconsistent covered range or changed count")
        # v2 批次还必须匹配声明的 frame_step:期望帧集合是从 start 起按 step
        # 递推 covered 个帧;关键帧、受影响帧与 edge_refinement 条目都必须
        # 属于该集合(条目且不得是关键帧)。
        if operation["schema_version"] == 2:
            step = operation.get("frame_step", 1)
            covered = operation["covered_count"]
            expected = {start + offset * step for offset in range(covered)}
            if (end - start != (covered - 1) * step
                or keyframe not in expected
                or not expected <= frame_map.keys()
                or any(frame not in expected for frame in affected)
                or any(item["frame_id"] not in expected or item["frame_id"] == keyframe
                       for item in operation["edge_refinement"]["items"])):
                errors.append(f"{prefix}: frames do not match declared frame_step")
    return errors


def _validate_sam_video_operation(
    operation: dict[str, Any], entries: list[dict[str, Any]], prefix: str
) -> list[str]:
    """Validate SAM v3 provenance against the trusted Source playback order."""
    errors: list[str] = []
    order = [int(entry["frame_id"]) for entry in entries]
    key_index = int(operation["keyframe_playback_index"])
    requested = int(operation["requested_count"])
    generated = int(operation["generated_count"])
    affected = [int(frame) for frame in operation["affected_frames"]]
    indices = [int(index) for index in operation["target_playback_indices"]]

    if (
        generated > requested
        or len(affected) != generated
        or len(indices) != generated
    ):
        errors.append(f"{prefix}: inconsistent bounded target counts")
        return errors
    if (
        key_index >= len(order)
        or key_index + generated >= len(order)
        or order[key_index] != int(operation["keyframe"])
    ):
        errors.append(f"{prefix}: key/playback identity or target range differs from Source")
        return errors

    expected_indices = list(range(key_index + 1, key_index + generated + 1))
    expected_frames = [order[index] for index in expected_indices]
    if indices != expected_indices or affected != expected_frames:
        errors.append(f"{prefix}: targets must be the exact ordered forward Source prefix")
    if (
        int(operation["start_frame"]) != int(operation["keyframe"])
        or int(operation["end_frame"]) != affected[-1]
    ):
        errors.append(f"{prefix}: range must exactly cover key and accepted targets")

    stop_reason = operation["stop_reason"]
    stop_frame = operation["stop_frame"]
    if generated == requested:
        if stop_frame is not None or stop_reason != "":
            errors.append(f"{prefix}: complete request cannot have a stop")
    elif stop_reason == "source_end":
        if stop_frame is not None or key_index + generated != len(order) - 1:
            errors.append(f"{prefix}: Source end must follow the last accepted Source frame")
    elif stop_reason in {"verified_target", "model_topology", "quality_threshold", "user_range"}:
        next_index = key_index + generated + 1
        if next_index >= len(order) or stop_frame != order[next_index]:
            errors.append(f"{prefix}: stop must name the first excluded Source frame")
    else:
        errors.append(f"{prefix}: truncated request needs a stop category")

    previous_risk_index = -1
    for risk_index, item in enumerate(operation["risk_summary"]):
        try:
            target_index = affected.index(int(item["frame_id"]))
        except ValueError:
            target_index = -1
        if target_index <= previous_risk_index:
            errors.append(
                f"{prefix}.risk_summary.{risk_index}: unique accepted targets must be ordered"
            )
        previous_risk_index = target_index
    return errors


# 校验单条记录的身份不变量,返回错误列表(空列表即通过)。
# 参数 record:一条 Model Output V1 记录;frame:该记录应归属的原始帧号;
#      source:该记录应有的 source 身份(基线记录为会话内部的模型身份,
#      人工修正副本为 "human_corrected");entries:frame_id -> frame_entries
#      条目映射;prefix:错误消息前缀。
# 检查项:record.frame 与 frame 一致且是已知帧、record.source 匹配;带
#      time_s 时必须与 frame_entries 中该帧的时间戳精确相等;regions 的
#      region ID 不得重复。
def _record_identity(record: dict, frame: int, source: str, entries: dict, prefix: str) -> list[str]:
    errors = []
    if record["frame"] != frame or frame not in entries or record["source"] != source:
        errors.append(f"{prefix}: wrong source or original frame identity")
    elif "time_s" in record and (
        "time_s" not in entries[frame] or record["time_s"] != entries[frame]["time_s"]
    ):
        errors.append(f"{prefix}.time_s: provided timestamp must exactly match source")
    ids = [region["id"] for region in record["regions"]]
    if len(ids) != len(set(ids)):
        errors.append(f"{prefix}.regions: duplicate region ID")
    return errors
