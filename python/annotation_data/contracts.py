# JSON Schema 合同的集中加载与字段级校验入口(annotation_data 包核心库)。
#
# 用途:集中登记仓库内全部 JSON Schema 合同(model_output_v1、
# dataset-manifest-v1、media-label v1/v2/v3),提供带缓存的按名加载、
# 本地 $ref 注册表,以及基于扩展版 Draft 2020-12 校验器的实例校验
# (bool 不算数字、NaN/Infinity 拒绝、错误按字段路径排序输出);另含
# 数据集清单(manifest)的跨实体语义校验。只读加载 schema,不写入任何内容。
#
# 角色与协作:被包内 sample、review_session、workspace、frame_source、
# endoscapes_fixture、training_package、polygon_propagation 以及
# python/validate_model_output.py 使用;校验与 $ref 解析依赖
# jsonschema / referencing 库。
"""规范化JSON Schema加载与合同校验"""

from functools import lru_cache
import json
import math
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator
from jsonschema.validators import extend
from referencing import Registry, Resource


# 仓库根目录(本文件位于 <root>/python/annotation_data/ 下),SCHEMA_PATHS
# 与 training_package 等外部脚本都以它定位文件。
ROOT = Path(__file__).resolve().parents[2]
# 逻辑文件名 -> schema 文件路径。load_schema、$ref 注册表与调用方都以
# 逻辑名为键,不直接拼接路径。
SCHEMA_PATHS = {
    "model_output_v1.schema.json": ROOT / "core/schemas/model_output_v1.schema.json",
    "dataset-manifest-v1.schema.json": ROOT
    / "core/frame_source/dataset-manifest-v1.schema.json",
    "media-label-v1.schema.json": ROOT / "core/workspace/media-label-v1.schema.json",
    "media-label-v2.schema.json": ROOT / "core/workspace/media-label-v2.schema.json",
    "media-label-v3.schema.json": ROOT / "core/workspace/media-label-v3.schema.json",
    "training-coco-v1.schema.json": ROOT / "core/feedback/training-coco-v1.schema.json",
    "coco-export-context-v1.schema.json": ROOT / "core/feedback/coco-export-context-v1.schema.json",
}


# 判断值是否符合 JSON Schema 的 integer 语义:精确类型为 int(排除 bool),
# 或为整数值的有限 float(如 1.0)。返回 bool。
def _is_integral_json_number(instance: Any) -> bool:
    """Match JSON Schema integer semantics without accepting booleans."""
    if type(instance) is int:
        return True
    return type(instance) is float and math.isfinite(instance) and instance.is_integer()


# jsonschema 类型检查器回调:把 integer 判定替换为上面的严格语义;
# 第一个参数是库传入的 checker,此处不使用。
def _is_json_schema_integer(_checker: Any, instance: Any) -> bool:
    return _is_integral_json_number(instance)


# number 类型的严格判定:精确类型为 int(排除 bool)或有限 float,
# NaN/Infinity 一律非法。返回 bool。
def _is_finite_json_number(_checker: Any, instance: Any) -> bool:
    if type(instance) is int:
        return True
    return type(instance) is float and math.isfinite(instance)


# 扩展版 Draft 2020-12 校验器:重定义 integer/number 类型检查(见上两个
# 回调),使整值 float 计为 integer、bool 与非有限浮点一律非法。
# 包内所有合同校验统一使用它。
StrictDraft202012Validator = extend(
    Draft202012Validator,
    type_checker=(
        Draft202012Validator.TYPE_CHECKER
        .redefine("integer", _is_json_schema_integer)
        .redefine("number", _is_finite_json_number)
    ),
)


@lru_cache(maxsize=None)
# 按逻辑文件名加载合同 schema(功能见英文 docstring)。
# 参数 name:SCHEMA_PATHS 的键;未知名字抛 ValueError(from None,不携带
#   KeyError 链路)。
# 返回:解析后的 schema 字典;lru_cache 缓存,重复调用共享同一份结果。
def load_schema(name: str) -> dict[str, Any]:
    """Load a known contract by logical filename."""
    try:
        path = SCHEMA_PATHS[name]
    except KeyError:
        raise ValueError(f"unknown schema: {name}") from None
    return json.loads(path.read_text(encoding="utf-8"))


@lru_cache(maxsize=1)
# 构建全局 referencing 注册表(lru_cache 单例):把 SCHEMA_PATHS 中全部
# schema 以逻辑文件名注册,使 schema 之间的 $ref 引用只在内存注册表中
# 解析,不发起任何网络查找。
def _schema_registry() -> Registry:
    return Registry().with_resources(
        (name, Resource.from_contents(load_schema(name))) for name in SCHEMA_PATHS
    )


# 用 StrictDraft202012Validator 校验单个数据实例(功能见英文 docstring)。
# 参数 data:待校验对象(只读);schema_name:SCHEMA_PATHS 中的逻辑文件名。
# 返回:字段路径级错误消息列表,按错误路径排序保证输出确定;空列表即通过。
# 副作用:无;schema 与注册表均走缓存,未知 schema 名抛 ValueError。
def validate_instance(data: object, schema_name: str) -> list[str]:

    """返回确定的、针对具体字段的 JSON Schema 验证错误。"""
    # Resolve versioned record references from the local contract registry only.
    validator = StrictDraft202012Validator(load_schema(schema_name), registry=_schema_registry())
    errors = sorted(validator.iter_errors(data), key=lambda item: list(item.path))
    return [
        f"{_validation_error_path(error)}: "
        f"{error.message} [{error.validator}]"
        for error in errors
    ]


# 把单条 jsonschema 错误归一到具体字段路径(功能见英文 docstring)。
# required 错误:从 message 解析出缺失属性名并追加到路径;
# additionalProperties 错误:用实例键减去 schema 声明的 properties,
#   追加排序后的第一个多余键;其余错误按 absolute_path 逐段拼接,
#   根级错误返回 "$"。
def _validation_error_path(error: Any) -> str:
    """将‘必填/附加属性’错误精准定位到具体字段。"""
    parts = [str(part) for part in error.absolute_path]
    if error.validator == "required":
        missing = error.message.split("'", 2)[1:2]
        if missing:
            parts.append(missing[0])
    elif error.validator == "additionalProperties" and isinstance(error.instance, dict):
        properties = error.schema.get("properties", {})
        unexpected = sorted(set(error.instance) - set(properties))
        if unexpected:
            parts.append(unexpected[0])
    return ".".join(parts) or "$"


# 校验数据集清单(manifest)中 JSON Schema 覆盖不到的跨实体语义约束
# (功能见英文 docstring)。
# 参数 record:manifest 字典;frames 不是列表时直接返回空列表(类型错误
#   交给 schema 校验),非字典的 frame 条目同样跳过逐帧检查。
# 检查项:frame_count 为整数且等于 frames 条数;similarity_scores(存在且
#   为列表时)长度必须是 frame_count - 1(相邻帧相似度),每项为 [0, 1]
#   内的有限数字;frames[i].frame 必须等于 i;image_path 不得重复;
#   time_s 为有限数字时必须非递减。
# 返回:人可读错误消息列表,空列表即通过;无副作用。
def validate_manifest_semantics(record: dict[str, Any]) -> list[str]:
    """校验跨实体数据集清单的约束条件"""
    errors: list[str] = []
    frames = record.get("frames")
    if not isinstance(frames, list):
        return errors

    # frame_count 必须是整数(整值 float 也算)且与 frames 实际条数一致。
    frame_count = record.get("frame_count")
    if not _is_integral_json_number(frame_count):
        errors.append("frame_count: must be an integer")
    elif int(frame_count) != len(frames):
        errors.append(
            f"frame_count: expected {len(frames)} entries, got {frame_count}"
        )

    # similarity_scores 可选;存在且为列表时,长度必须恰为 frame_count - 1。
    similarity_scores = record.get("similarity_scores")
    if "similarity_scores" in record and isinstance(similarity_scores, list):
        if (
            _is_integral_json_number(frame_count)
            and len(similarity_scores) != int(frame_count) - 1
        ):
            errors.append(
                "similarity_scores: expected "
                f"{frame_count - 1} entries, got {len(similarity_scores)}"
            )
        # 每个相似度分数都必须是 [0, 1] 内的有限数字。
        for index, score in enumerate(similarity_scores):
            if (
                not _is_finite_number(score)
                or not 0.0 <= score <= 1.0
            ):
                errors.append(
                    f"similarity_scores.{index}: must be a finite number between 0 and 1"
                )

    # 逐帧检查:frame 下标一致性、image_path 全局唯一、time_s 非递减。
    seen_paths: set[str] = set()
    previous_time: float | int | None = None
    for index, entry in enumerate(frames):
        if not isinstance(entry, dict):
            continue
        frame = entry.get("frame")
        if frame != index:
            errors.append(f"frames.{index}.frame: expected {index}, got {frame!r}")

        image_path = entry.get("image_path")
        if isinstance(image_path, str):
            if image_path in seen_paths:
                errors.append(f"frames.{index}.image_path: duplicate path {image_path!r}")
            seen_paths.add(image_path)

        # time_s 只在为有限数字时参与比较;previous_time 也仅由合法值推进,
        # 无效值不会污染递增检查。
        time_s = entry.get("time_s")
        if _is_finite_number(time_s):
            if previous_time is not None and time_s < previous_time:
                errors.append(
                    f"frames.{index}.time_s: must be non-decreasing "
                    f"(previous {previous_time})"
                )
            previous_time = time_s
    return errors


# 判断值是否为有限数字:精确类型为 int(排除 bool)或有限 float;
# 仅服务于本文件的 manifest 语义校验。
def _is_finite_number(value: Any) -> bool:
    return type(value) is int or (type(value) is float and math.isfinite(value))
