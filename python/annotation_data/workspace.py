# 工作区(workspace)媒体身份与单文件标注(label)校验模块。
#
# 用途:把源文件/目录名规范成可移植媒体 ID(portable media ID)、拼出训练
# 样本 ID 与唯一的 label 文件路径,并对 label 文件做 schema 之外的跨字段
# 语义校验(frame 键形态、record.frame/source 与 media 身份一致性)。
#
# 角色与协作:复用 contracts.validate_instance 做 Model Output V1 schema
# 校验;schema_version==3 时把整个对象委托给 review_session 模块。可移植 ID
# 规则与 Godot 客户端保持一致(仅 ASCII 字母数字与下划线、不做音译),
# 客户端在 client/workspace/ 下有对应的 GDScript 实现。
"""Workspace media identity and single-file label validation."""

from pathlib import Path
import re
from typing import Any

from annotation_data.contracts import validate_instance


# 把文件名主干中连续的非 ASCII 字母数字字符折叠成单个 "_"。
_PORTABLE_SEPARATOR = re.compile(r"[^A-Za-z0-9]+")
# 可移植 ID 的合法形态:总长 1-64,首尾必须是字母或数字,中间可含下划线。
_PORTABLE_ID = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9_]{0,62}[A-Za-z0-9])?$")
# 合法 frame 键:不带前导零的十进制整数字符串,取值 0..999999。
_FRAME_KEY = re.compile(r"^(0|[1-9][0-9]{0,5})$")


# 把源文件/目录的文件名主干(stem)规范成稳定的可移植媒体 ID。
# 参数 stem:文件或目录的 stem(不含扩展名)。
# 返回:非 ASCII 字母数字段折叠为 "_"、去掉首尾下划线、截断到 64 字符后
#      再去尾部下划线的 ID;若折叠后为空(如纯中文输入),回退为 "media"。
#      非 ASCII 字符不做音译,直接折叠,与 Godot 客户端的 ASCII 规则一致。
# 异常:stem 不是 str 时抛 TypeError。
def portable_media_id(stem: str) -> str:
    """Return a stable portable ID from a source file or directory stem."""
    if not isinstance(stem, str):
        raise TypeError("media stem must be text")
    # Apply the same ASCII-only rule as the Godot client. Do not transliterate.
    value = _PORTABLE_SEPARATOR.sub("_", stem).strip("_")[:64].rstrip("_")
    return value or "media"


# 拼接训练样本 ID:media_id + 6 位零填充帧号,字典序即帧号序。
# 参数 media_id:必须通过可移植 ID 校验;frame_id:必须是 int 类型
#      (bool 会被 type 精确检查拒绝),范围 0..999999。
# 返回:形如 "<media_id>_000042" 的字符串。
# 异常:media_id 或 frame_id 不合法时抛 ValueError。
def sample_id(media_id: str, frame_id: int) -> str:
    """Build the training identity for one original media frame."""
    _require_portable_id(media_id)
    if type(frame_id) is not int or not 0 <= frame_id <= 999_999:
        raise ValueError("frame_id must be an integer from 0 through 999999")
    return f"{media_id}_{frame_id:06d}"


# 返回某媒体项在工作区中唯一的原生标注文件路径:<root>/label/<media_id>.json。
# 参数 workspace_root:工作区根目录;media_id:必须通过可移植 ID 校验。
# 返回:Path;只拼路径,不检查文件是否存在。
# 异常:media_id 不合法时抛 ValueError。
def label_path(workspace_root: Path, media_id: str) -> Path:
    """Return the sole native label path for a workspace media item."""
    _require_portable_id(media_id)
    return Path(workspace_root) / "label" / f"{media_id}.json"


# 对单文件标注(label)整体做跨字段语义校验,返回错误消息列表(空列表即通过)。
# 参数 value:label 文件解析出的 JSON 值;既可能是 Model Output V1 的 media
#      根对象(含 frames 字典),也可能是 schema_version==3 的 V3 审核会话。
# 分派:V3 对象整体委托 review_session.validate_review_session(延迟导入);
#      其余按 Model Output V1 语义逐帧校验。
# 返回:错误字符串列表,前缀定位到 frames.<key>;结构问题也以错误项形式
#      返回,不抛校验异常。
def validate_media_label_semantics(value: object) -> list[str]:
    """Validate Model Output V1 records against their media and frame keys."""
    if not isinstance(value, dict):
        return ["$: expected object"]
    # V3 会话的校验规则独立在 review_session 模块,这里按需委托(延迟导入)。
    if value.get("schema_version") == 3:
        from annotation_data.review_session import validate_review_session
        return validate_review_session(value)
    errors: list[str] = []
    media_id_value = value.get("media_id")
    frames = value.get("frames")
    if not isinstance(frames, dict):
        return errors

    # 按帧键排序逐帧校验:帧键必须是不带前导零的十进制整数字符串;record
    # 内的 frame 字段必须等于帧键数值、source 字段必须等于本文件声明的
    # media_id(记录身份与所在文件一致)。
    for frame_key, record in sorted(frames.items(), key=lambda item: str(item[0])):
        prefix = f"frames.{frame_key}"
        if not isinstance(frame_key, str) or _FRAME_KEY.fullmatch(frame_key) is None:
            errors.append(f"{prefix}: expected an unpadded decimal frame key")
            continue
        frame_id = int(frame_key)
        # 单条记录先过 Model Output V1 schema,再把 JSON Pointer 错误路径
        # 拼接到当前帧键前缀下。
        for error in validate_instance(record, "model_output_v1.schema.json"):
            suffix = error[2:] if error.startswith("$:") else f".{error}"
            errors.append(f"{prefix}{suffix}")
        if not isinstance(record, dict):
            continue
        if record.get("frame") != frame_id:
            errors.append(
                f"{prefix}.frame: expected frame {frame_id}, got {record.get('frame')!r}"
            )
        if isinstance(media_id_value, str) and record.get("source") != media_id_value:
            errors.append(
                f"{prefix}.source: expected {media_id_value!r}, "
                f"got {record.get('source')!r}"
            )
    return errors


# 内部校验:值必须是符合 _PORTABLE_ID 形态的 str,否则抛 ValueError。
def _require_portable_id(value: str) -> None:
    if not isinstance(value, str) or _PORTABLE_ID.fullmatch(value) is None:
        raise ValueError("media_id must be a portable workspace identifier")
