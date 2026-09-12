# Part 4 训练交接包(training package)独立校验器——Python 侧的独立复核入口。
#
# 用途:对 Godot 端导出的两种 Part 4 文件包做与生产者完全独立的复核:
#   training_update_v2:训练更新包,只含当前内容验证通过的帧(verified_only);
#   review_export_v1:  全帧评审快照包(all_frames_review)。
# 校验范围:包文件布局白名单、manifest schema 与身份摘要(package_id)、工件
# bytes/SHA-256 追溯、修正记录与 frame_map 推导字段、coverage 划分与计数、
# review_state 内容验证哈希、批量操作(Poly V2)溯源审计,以及 diff JSON/CSV
# 的完整重算对账。无需 Godot 可执行文件或活动会话;基线 SHA-256 仅作溯源
# (provenance),不认证不可得的原始模型数据集,基线摘要与原始不可变预测的
# 绑定由模型组独立完成。
#
# 角色与协作:被 python/part4.py(validate-package / demo / import-round 的父包
# 校验)调用,也可经 main() 作为独立 CLI 校验单个包目录;schema 加载与严格
# Draft 2020-12 校验复用 annotation_data.contracts,数值规范化复用
# annotation_data.review_session._normalized(对齐 Godot 把 JSON 数值按
# double 处理的内容摘要行为)。
#
# 输入:包目录(manifest.json + PATHS 白名单工件);输出:人可读错误消息列表
# (空列表即通过)。
"""Independent validation for worker-produced Part 4 file packages.

No Godot executable or active session is required. Baseline SHA256 is provenance,
not authentication of an unavailable original model dataset. Reports are recounted
and checked against corrected regions; the model team can independently bind the
baseline digest to its original immutable predictions.
"""
from __future__ import annotations

import csv
from datetime import datetime
import hashlib
import io
import json
from pathlib import Path
import re
from typing import Any

from referencing import Registry, Resource
from referencing.exceptions import CannotDetermineSpecification, Unresolvable
from referencing.jsonschema import UnknownDialect
from jsonschema.exceptions import SchemaError, UnknownType
from annotation_data.contracts import ROOT, SCHEMA_PATHS, StrictDraft202012Validator
from annotation_data.review_session import _normalized

# 包内固定工件白名单(相对包根的 POSIX 路径):manifest.json 之外只允许这五个
# 文件;顺序即 _validate 中 texts/PATHS[i] 的取用下标
# (0=修正标注 JSONL,1=frame_map JSONL,2=diff JSON,3=diff 事件 CSV,4=按类汇总 CSV)。
PATHS = (
    "data/corrected_annotations.jsonl", "data/frame_map.jsonl", "reports/diff.json",
    "reports/diff.csv", "reports/summary_by_class.csv",
)
# diff 事件的五种类型(与 annotation-diff-v1 schema 及 diff.csv 的 type 列对应)。
CATEGORIES = ("added", "deleted", "label_changed", "geometry_changed", "attributes_changed")
# 按类汇总(summary_by_class.csv 与 diff.by_class 行)的计数字段:
# added/deleted/geometry_changed/attributes_changed 直接按事件类型计数,
# label_changed 拆分为 reclassified_in(新类)与 reclassified_out(旧类)。
CLASS_COUNTS = ("added", "deleted", "reclassified_in", "reclassified_out", "geometry_changed", "attributes_changed")


# 计算任意 JSON 值的规范化 SHA-256 摘要:先经 _normalized 数值规范化(所有
# 数值统一按 double 处理,对齐 Godot),再以紧凑分隔符、键排序、保留非 ASCII
# 序列化后取哈希。包身份与记录内容验证哈希都以它为基础。
# 异常:值含不可 JSON 序列化对象时抛 TypeError。
def canonical_digest(value: Any) -> str:
    data = json.dumps(_normalized(value), ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(data.encode()).hexdigest()


# 由 manifest 内容计算包身份:剔除 package_id、revision、created_at 三个发布
# 元数据字段后取规范化摘要。manifest 的 package_id 必须与该值一致,
# 保证包 ID 完全由内容决定。
def package_identity(manifest: dict) -> str:
    return canonical_digest({k: v for k, v in manifest.items() if k not in {"package_id", "revision", "created_at"}})


# 构建本次校验使用的全部 schema 校验器:contracts 登记的合同(model_output_v1
# 等)加上 Part 4 反馈合同(annotation-diff-v1 与 training-package-v2,位于
# core/feedback/),全部以逻辑文件名注册进 referencing registry,使 schema 间
# $ref 只在内存中解析。
# 返回:逻辑文件名 -> StrictDraft202012Validator 的字典。
# 异常:registry 无法构建(无法判定 spec 或未知方言)时抛 ValueError。
def _schema_validators() -> dict[str, Any]:
    """本次校验共用合同与 registry；下次调用重新读取，避免任务间可变缓存。"""
    paths = dict(SCHEMA_PATHS)
    paths.update({n: ROOT / "core/feedback" / n for n in ("annotation-diff-v1.schema.json", "training-package-v2.schema.json")})
    schemas = {n: _json(p.read_text(encoding="utf-8")) for n, p in paths.items()}
    try:
        registry = Registry().with_resources((n, Resource.from_contents(s)) for n, s in schemas.items())
    except (CannotDetermineSpecification, UnknownDialect) as exc:
        raise ValueError(f"schema registry unavailable or invalid: {exc}") from exc
    return {n: StrictDraft202012Validator(schema, registry=registry) for n, schema in schemas.items()}


# 用指定 schema 校验一个值,返回 "文件名:字段路径: 消息" 格式的错误列表。
# 参数 value:待校验值;name:schema 逻辑文件名;validators:复用的校验器集合
# (None 时临时重建一套)。任何加载/校验异常(文件读不到、schema 无效、
# $ref 不可解析等)都折叠为一条 "schema unavailable or invalid" 消息返回,
# 不向外抛出。
def _schema_errors(value: Any, name: str, validators: dict[str, Any] | None = None) -> list[str]:
    try:
        validator = (validators if validators is not None else _schema_validators())[name]
        return [f"{name}:{'.'.join(map(str, e.path))}: {e.message}" for e in validator.iter_errors(value)]
    except (OSError, ValueError, TypeError, KeyError, SchemaError, UnknownType, Unresolvable) as exc:
        return [f"{name}: schema unavailable or invalid: {exc}"]


# 校验 manifest 的 created_at:必须严格匹配 YYYY-MM-DDTHH:MM:SSZ 的 UTC 时间戳
# 格式,且各段能构成真实的公历日期时间(拒绝 2 月 30 日之类)。返回 bool。
def _valid_created_at(value: Any) -> bool:
    if not isinstance(value, str) or re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value) is None:
        return False
    try:
        datetime(int(value[:4]), int(value[5:7]), int(value[8:10]), int(value[11:13]), int(value[14:16]), int(value[17:19]))
    except ValueError:
        return False
    return True


# 严格 JSON 解析:object_pairs_hook 拒绝重复键,parse_constant 拒绝
# NaN/Infinity/-Infinity;其余行为同 json.loads。
# 异常:重复键、非有限数字或非法 JSON 均抛 ValueError。
def _json(text: str) -> Any:
    # object_pairs_hook 回调:按出现顺序收集键值对,发现重复键即抛 ValueError。
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError(f"duplicate JSON key: {key}")
            result[key] = value
        return result
    # parse_constant 回调:遇到 NaN/Infinity/-Infinity 字面量即抛 ValueError。
    def constant(value):
        raise ValueError(f"nonfinite JSON number: {value}")
    return json.loads(text, object_pairs_hook=pairs, parse_constant=constant)


# 按行解析 JSONL 文本为对象列表(语义细节见英文 docstring:LF 分行、可选末尾
# LF、不允许空行;CRLF 中的 CR 属于合法 JSON 空白;字符串内的 Unicode 行分隔
# 符是内容,不能用 str.splitlines)。每行经 _json 严格解析。
def _jsonl(text: str) -> list[Any]:
    """Match Godot JSONL: LF boundaries, optional terminal LF, no blank rows.

    CR in CRLF remains valid JSON whitespace. Unicode line separators inside
    strings are content, so str.splitlines() must not be used here.
    """
    return [_json(line) for line in _jsonl_lines(text)]


# 把 JSONL 文本切成行列表:空文本得空列表;否则去掉末尾一个 LF 后按 LF 切分
# (行内可能残留的 CR 交给 JSON 解析按空白处理)。
def _jsonl_lines(text: str) -> list[str]:
    if not text:
        return []
    return text.removesuffix("\n").split("\n")


# 生成一条修正记录在内容验证时可能出现的全部候选 SHA-256(细节见英文
# docstring):候选一是把导出的 source 投影(human_corrected 替换为实际
# source)后按 Python 规范化重算的摘要;候选二是生产者(Godot)导出行原文
# (仅替换 source 字段、去掉行尾 CR 后)直接哈希的结果——Godot 与 Python 对
# 同一 binary64 值的最短十进制拼写可能不同,因此两个候选都要纳入。
# 参数 record:导出的修正记录;line:其所在的原始 JSONL 行;source:manifest
# 声明的媒体来源。返回:十六进制摘要字符串集合。
def _record_digest_candidates(record: dict, line: str, source: str) -> set[str]:
    """Reproduce both independent-Python and producer-Godot record hashes.

    JSONL written by Project6 is already recursively sorted and normalized.  Keep
    its original numeric lexemes because Godot and Python can choose different,
    equally short spellings for the same binary64 value (for example a final
    decimal digit of 3 versus 2).  Only the exported source projection differs
    from the internal record that was accepted by the reviewer.
    """
    internal = dict(record, source=source)
    candidates = {canonical_digest(internal)}
    marker = ',"source":"human_corrected"'
    position = line.rfind(marker)
    if position >= 0:
        replacement = ',"source":' + json.dumps(source, ensure_ascii=False, separators=(",", ":"))
        producer_text = line[:position] + replacement + line[position + len(marker):]
        candidates.add(hashlib.sha256(producer_text.removesuffix("\r").encode("utf-8")).hexdigest())
    return candidates


# 公开入口:校验一个训练包/评审包目录,返回错误消息列表(空列表即通过)。
# 参数 directory:包目录路径(str 或 Path)。
# 行为:_validate 抛出的任何预期内异常(IO、解析、schema、类型等)都折叠为
# 一条 "malformed package" 消息,保证调用方总能拿到错误列表而不是异常。
def validate_training_package(directory: str | Path) -> list[str]:
    """Return checked errors for either training_update_v2 or review_export_v1."""
    try:
        return _validate(Path(directory))
    except (OSError, ValueError, TypeError, KeyError, AttributeError, OverflowError, SchemaError, UnknownType, Unresolvable) as exc:
        return [f"malformed package: {exc}"]


# 包校验主体:按「文件布局 → manifest 结构 → 身份与基线 → 工件哈希 → 记录与
# coverage → review_state → 批量溯源 → diff/CSV 重算」分层检查。
# 返回策略:结构层问题(布局、schema、哈希、帧序)会让后续检查失去前提,
# 一经发现即提前返回已积累错误;语义类错误则持续累积,最后一并返回。
def _validate(root: Path) -> list[str]:
    errors: list[str] = []
    # 包根门禁:必须是真实目录,符号链接或非目录直接拒绝。
    if root.is_symlink() or not root.is_dir():
        return ["package must be a real directory"]
    expected_files = {"manifest.json", *PATHS}
    actual_files = set()
    # 扫描包内全部条目:禁止符号链接与特殊文件系统条目;目录只允许 data/ 与
    # reports/;文件集合必须与白名单(manifest.json + PATHS)完全一致。
    for item in root.rglob("*"):
        if item.is_symlink():
            return ["package symlinks are forbidden"]
        if item.is_file():
            actual_files.add(item.relative_to(root).as_posix())
        elif item.is_dir():
            if item.relative_to(root).as_posix() not in {"data", "reports"}:
                return ["package contains a foreign directory"]
        else:
            return ["package contains a special filesystem entry"]
    if actual_files != expected_files:
        return ["package files must exactly match the fixed artifact allowlist"]
    # 严格解析 manifest 并做 training-package-v2 schema 校验;结构不过时
    # 不再继续,避免在未知结构上做语义判断。
    manifest = _json((root / "manifest.json").read_text(encoding="utf-8"))
    validators = _schema_validators()
    errors.extend(_schema_errors(manifest, "training-package-v2.schema.json", validators))
    if errors:
        return errors
    # created_at 可选;出现时必须是真实公历 UTC 时间戳。
    if "created_at" in manifest and not _valid_created_at(manifest["created_at"]):
        return ["created_at: expected a real Gregorian UTC timestamp YYYY-MM-DDTHH:MM:SSZ"]
    # 包身份自洽:package_id 必须等于剔除发布元数据后的 manifest 规范化摘要。
    if manifest["package_id"] != package_identity(manifest):
        errors.append("package_id: canonical content identity mismatch")
    # 包类型与 schema 版本对应:training_update_v2 配 schema v2,其余
    # (review_export_v1)配 v1;训练包还要求基线已知(非 unknown)。
    training = manifest["package_type"] == "training_update_v2"
    if manifest["schema_version"] != (2 if training else 1):
        errors.append("package type/schema mismatch")
    if training and manifest["baseline"]["kind"] == "unknown":
        errors.append("training package requires known baseline")
    # baseline.kind 与 baseline.digest 必须同生同灭:empty/unknown 时 digest
    # 为 None,真实模型基线时必须提供 digest。
    baseline = manifest["baseline"]
    if (baseline["kind"] in {"empty", "unknown"}) != (baseline["digest"] is None):
        errors.append("baseline kind/digest mismatch")
    # manifest.artifacts 必须不重复且恰好列全白名单工件。
    listed = [a["path"] for a in manifest["artifacts"]]
    if len(set(listed)) != len(PATHS) or set(listed) != set(PATHS):
        return errors + ["artifact names must be unique and complete"]
    texts = {}
    # 逐工件核对声明的 bytes 与 SHA-256 是否与磁盘实际字节一致(哈希追溯),
    # 并把 UTF-8 文本缓存到 texts 供后续解析与 CSV 对账。
    for artifact in manifest["artifacts"]:
        raw = (root / artifact["path"]).read_bytes()
        if len(raw) != artifact["bytes"] or hashlib.sha256(raw).hexdigest() != artifact["sha256"]:
            errors.append(f"{artifact['path']}: bytes/SHA256 mismatch")
        texts[artifact["path"]] = raw.decode("utf-8")
    if errors:
        return errors
    # 解析工件文本:逐条修正记录、frame_map 与 diff;先做各自 schema 校验
    # (diff 过 annotation-diff-v1,修正记录逐条过 model_output_v1),
    # 不过则不进入语义对账。
    record_lines = _jsonl_lines(texts[PATHS[0]])
    records = [_json(line) for line in record_lines]
    mapping = _jsonl(texts[PATHS[1]])
    diff = _json(texts[PATHS[2]])
    errors.extend(_schema_errors(diff, "annotation-diff-v1.schema.json", validators))
    for record in records:
        errors.extend(_schema_errors(record, "model_output_v1.schema.json", validators))
    if errors:
        return errors
    # coverage 一致性:Source 帧条目、included/excluded/verified/explicit 的
    # 集合划分与顺序、以及 coverage / manifest.summary / diff.summary 三处
    # 计数字段必须互相吻合。
    coverage = manifest["coverage"]
    entries = manifest["source_frame_entries"]
    entry_map = {int(e["frame_id"]): e for e in entries}
    source_ids = [int(e["frame_id"]) for e in entries]
    included = coverage["included_frame_ids"]
    excluded = coverage["excluded_frame_ids"]
    verified = coverage["verified_frame_ids"]
    explicit = coverage["explicit_frame_ids"]
    # Schema 已拒绝重复项；集合仅用于查找，数组继续保留 Source 顺序。
    source_set, included_set, excluded_set, verified_set, explicit_set = map(set, (source_ids, included, excluded, verified, explicit))
    # Source 帧身份:frame_id 不得重复,播放下标必须等于数组下标。
    if len(entry_map) != len(entries) or [e["frame"] for e in entries] != list(range(len(entries))):
        errors.append("source frame identity/playback indices invalid")
    # Source 时间戳必须非递减(允许部分条目缺失 time_s)。
    times = [e["time_s"] for e in entries if "time_s" in e]
    if times != sorted(times):
        errors.append("source timestamps not ordered")
    if coverage["source_frame_ids"] != source_ids:
        errors.append("coverage source frame identity mismatch")
    if (included_set & excluded_set or included_set | excluded_set != source_set
            or not verified_set <= explicit_set <= source_set):
        errors.append("invalid coverage partition/verification/explicit sets")
    if included != [f for f in source_ids if f in included_set] or excluded != [f for f in source_ids if f in excluded_set]:
        errors.append("coverage order differs from Source")
    for key, values in (("total_frames", source_ids), ("included_frames", included), ("excluded_frames", excluded)):
        if coverage[key] != len(values) or manifest["summary"][key] != len(values) or diff["summary"][key] != len(values):
            errors.append(f"{key}: incorrect count")
    # coverage 策略必须与包类型匹配:训练包 verified_only,评审包 all_frames_review。
    if coverage["policy"] != ("verified_only" if training else "all_frames_review"):
        errors.append("coverage policy does not match package type")
    # 训练包:included 必须恰好等于非空的 verified 帧,排除原因固定为
    # not_content_verified;评审包(else 分支):必须包含全部 Source 帧且无排除。
    if training:
        if not included or included != verified or coverage["exclusion_reason"] != "not_content_verified":
            errors.append("training coverage must exactly equal nonempty current verified frames")
    elif included != source_ids or excluded or coverage["exclusion_reason"] != "none":
        errors.append("review export must include all source frames")
    # 工件帧序:修正记录与 frame_map 必须按 included 帧序一一对应;
    # 帧序不符时无法逐帧对账,直接返回。
    if [r["frame"] for r in records] != included or [m.get("frame_id") for m in mapping] != included:
        errors.append("artifact frame order/coverage mismatch")
        return errors
    by_frame = {int(r["frame"]): r for r in records}
    # 逐帧对账:修正记录身份与时间戳、frame_map 推导字段、review_state
    # 内容验证哈希三方必须互相印证。
    for index, (record, mapped) in enumerate(zip(records, mapping)):
        frame = int(record["frame"])
        entry = entry_map[frame]
        if record["source"] != "human_corrected":
            errors.append(f"frame {frame}: corrected source must be human_corrected")
        if len({r["id"] for r in record["regions"]}) != len(record["regions"]):
            errors.append(f"frame {frame}: duplicate region id")
        # Model Output V1 timestamps are optional independently of Source timing.
        # Preserve a record's absence; any supplied timestamp must match Source.
        if "time_s" in record and ("time_s" not in entry or record["time_s"] != entry["time_s"]):
            errors.append(f"frame {frame}: provided annotation timestamp differs from source")
        # frame_map 必须原样保留 Source 时间戳的有无与取值。
        if ("time_s" in mapped) != ("time_s" in entry) or mapped.get("time_s") != entry.get("time_s"):
            errors.append(f"frame {frame}: frame map source timestamp value/presence mismatch")
        # frame_map 条目的期望值完全由 manifest 推导:样例 ID(media_id_帧号)、
        # explicit/verified 标记、review_status,以及 annotation_status
        # (显式帧按有无 region 区分 annotated/negative,未显式帧为 unannotated)。
        expected = dict(entry, sample_id=f"{manifest['media']['media_id']}_{frame:06d}", explicit=frame in explicit_set,
                        verified=frame in verified_set, review_status="verified" if frame in verified_set else "unverified",
                        annotation_status=("negative" if not record["regions"] else "annotated") if frame in explicit_set else "unannotated")
        if any(type(mapped.get(k)) is not bool for k in ("verified", "explicit")) or mapped != expected:
            errors.append(f"frame {frame}: frame map/sample ID/status mismatch")
        # 内容验证:review_state 记录的 accepted_digest 必须能对应当前记录
        # 内容(候选哈希见 _record_digest_candidates),且「有 accepted 哈希」
        # 与「帧已 verified」互为充要条件。
        accepted = manifest["review_state"].get(str(frame), {}).get("accepted_digest")
        if (accepted in _record_digest_candidates(record, record_lines[index], manifest["media"]["source"])) != (frame in verified_set):
            errors.append(f"frame {frame}: current content verification mismatch")
    # review_state 只允许引用显式(explicit)Source 帧。
    if not set(map(int, manifest["review_state"])) <= explicit_set:
        errors.append("review state must refer to explicit source frames")
    # 逐条校验批量操作溯源:关键帧/起止帧/受影响帧必须是已知 Source 帧,
    # 帧范围顺序正确;带 metric_id 的指标批量还要求关键帧落在范围内、
    # 覆盖/变更计数自洽(变更数必须少于覆盖数,即至少保留关键帧)。
    for operation in manifest["batch_operations"]:
        if any(operation[k] not in entry_map for k in ("keyframe", "start_frame", "end_frame")):
            errors.append("batch provenance contains unknown source frame")
        if operation["start_frame"] > operation["end_frame"]:
            errors.append("batch provenance has reversed frame range")
        if "metric_id" in operation:
            if not operation["start_frame"] <= operation["keyframe"] <= operation["end_frame"]:
                errors.append("batch metric range must contain keyframe")
            if (operation["start_index"] > operation["end_index"]
                    or operation["covered_count"] != operation["end_index"] - operation["start_index"] + 1
                    or operation["covered_count"] > operation["max_frames"]
                    or operation["changed_count"] != len(operation["affected_frames"])
                    or operation["changed_count"] >= operation["covered_count"]):
                errors.append("batch metric range/coverage/changed counts inconsistent")
        if any(f not in entry_map or f == operation["keyframe"] or not operation["start_frame"] <= f <= operation["end_frame"] for f in operation["affected_frames"]):
            errors.append("batch provenance contains invalid target")
        # 旧版(schema_version==1)批量溯源不得声称拥有 Poly V2 审计字段,
        # 其余字段到此检查完毕,直接跳过。
        if operation["schema_version"] == 1:
            if "frame_step" in operation or "edge_refinement" in operation:
                errors.append("legacy batch provenance cannot claim Poly V2 audit fields")
            continue
        # Poly V2(schema_version==2)审计:必须带齐全部审计字段;随后依据
        # frame_step(缺省 1)重推被覆盖帧集合 expected(从 start_frame 起按
        # 步长数出 covered_count 个,end_frame 必须恰在网格上),再核对
        # edge_refinement 明细——受影响帧 ⊆ expected 且不含关键帧,items 的
        # frame_id 全部落在去关键帧后的 targets 内,items 必须是
        # targets × region_id 的无重复全组合,attempted/accepted/fallback
        # 计数互相吻合;任何一处不符即判审计不一致。
        required = {
            "metric_id", "threshold", "max_frames", "keyframe_digest", "created_at",
            "start_index", "end_index", "left_stop", "right_stop", "changed_count",
            "covered_count", "edge_refinement",
        }
        if not required <= operation.keys():
            errors.append("Poly V2 batch provenance is missing required audit fields")
            continue
        step = int(operation.get("frame_step", 1))
        covered = int(operation["covered_count"])
        start = int(operation["start_frame"])
        end = int(operation["end_frame"])
        keyframe = int(operation["keyframe"])
        expected = {start + offset * step for offset in range(covered)}
        targets = expected - {keyframe}
        items = operation["edge_refinement"]["items"]
        reference_ids = {item["region_id"] for item in items}
        identities = {(item["frame_id"], item["region_id"]) for item in items}
        accepted = sum(item["accepted"] for item in items)
        summary = operation["edge_refinement"]
        if (operation["metric_id"] != "poly-sim-flow-edge-v1"
                or end - start != (covered - 1) * step
                or keyframe not in expected
                or not expected <= entry_map.keys()
                or any(frame not in expected for frame in operation["affected_frames"])
                or any(item["frame_id"] not in targets for item in items)
                or not reference_ids
                or len(identities) != len(items)
                or len(items) != len(targets) * len(reference_ids)
                or summary["attempted"] != len(items)
                or summary["accepted"] != accepted
                or summary["fallback"] != len(items) - accepted):
            errors.append("Poly V2 batch provenance audit is inconsistent")
    # verified 帧数必须与 coverage 一致;最后把 diff JSON/CSV 与当前修正记录
    # 完整重算对账(见 _validate_diff)。
    if manifest["summary"]["verified_frames"] != len(verified):
        errors.append("verified_frames count mismatch")
    errors.extend(_validate_diff(diff, manifest, by_frame, texts))
    return errors


# diff/CSV 重算对账:不信任包内报告,从 manifest 与当前修正记录出发独立重放
# 全部 diff 事件,重算每帧/每类/汇总计数,并把两份 CSV 重新解析后与 JSON
# 审计逐行比对。
# 参数 diff:reports/diff.json 的解析结果;records:frame_id(int) -> 当前修正
# 记录的映射;texts:工件路径 -> 原始文本(diff.csv 与 summary_by_class.csv
# 由此重新解析)。
# 返回:错误消息列表,空列表即通过;无副作用。
def _validate_diff(diff: dict, manifest: dict, records: dict, texts: dict) -> list[str]:
    errors = []
    # 审计可用性必须与基线种类一致(unknown 基线没有可 diff 的对象,此时
    # summary.audit_available 也必须为 False),diff 帧集合必须恰为 included
    # 帧排序结果。
    available = manifest["baseline"]["kind"] != "unknown"
    if diff["available"] != available or manifest["summary"]["audit_available"] != available:
        errors.append("audit availability inconsistent with baseline kind")
    expected_ids = sorted(manifest["coverage"]["included_frame_ids"]) if available else []
    if [f["frame_id"] for f in diff["frames"]] != expected_ids:
        errors.append("audit frame coverage mismatch")
    counts = dict.fromkeys(CATEGORIES, 0)
    changed_frames = changed_regions = 0
    classes = {}
    csv_events = []
    # 逐帧重放 diff 事件,与当前修正记录对账并累计全局计数。
    for frame in diff["frames"]:
        local = dict.fromkeys(CATEGORIES, 0)
        seen = set()
        changed = set()
        grouped = {}
        current = {r["id"]: r for r in records[int(frame["frame_id"] )]["regions"]}
        # empty 基线:diff 必须恰好把当前全部 region(按 region_id 排序)记为
        # added、before 为 None,多一个少一个都不行。
        if manifest["baseline"]["kind"] == "empty":
            expected_events = [{"region_id": rid, "type": "added", "before": None, "after": current[rid]}
                               for rid in sorted(current)]
            if frame["events"] != expected_events:
                errors.append("empty baseline audit must exactly add every current region")
        for event in frame["events"]:
            rid, kind = event["region_id"], event["type"]
            before, after = event["before"], event["after"]
            # 同一 (region_id, type) 组合不得重复;事件归属的 region id 必须与
            # before/after 自身的 id 一致,且 after 必须等于当前 region。
            if (rid, kind) in seen:
                errors.append("duplicate audit event")
            seen.add((rid, kind)); changed.add(rid)
            grouped.setdefault(rid, []).append(event)
            if ((before is not None and before["id"] != rid) or (after is not None and after["id"] != rid)
                    or after != current.get(rid)):
                errors.append("audit event region identity/current after mismatch")
            # 每种事件类型的形状约束:added 必须无 before 有 after,deleted
            # 相反;三种 changed 类型要求 before/after 都存在,且在对应字段上
            # 确实不同(label 看 class,geometry 看 box/polygon,
            # attributes 看 kind/track_id/conf)。
            if kind == "added":
                valid = before is None and after is not None
            elif kind == "deleted":
                valid = before is not None and after is None
            else:
                fields = {"label_changed": ("class",), "geometry_changed": ("box", "polygon"), "attributes_changed": ("kind", "track_id", "conf")}[kind]
                valid = before is not None and after is not None and {k:before[k] for k in fields if k in before} != {k:after[k] for k in fields if k in after}
            if not valid:
                errors.append("audit event does not describe its claimed change")
            # 计数与留痕:本地/全局事件计数累加,事件压入 csv_events 供 CSV
            # 对账;label_changed 额外拆分计入旧类 reclassified_out 与新类
            # reclassified_in,其余事件计入该 region 的 class 行
            # (added 取 after,deleted 取 before,见下方 assignments)。
            local[kind] += 1; counts[kind] += 1
            csv_events.append((int(frame["frame_id"]), rid, kind, before, after))
            assignments = [(before["class"], "reclassified_out"), (after["class"], "reclassified_in")] if kind == "label_changed" and before and after else [((before if kind == "deleted" else after or before or {}).get("class", ""), kind)]
            for label, key in assignments:
                row = classes.setdefault(label, {"class":label, **dict.fromkeys(CLASS_COUNTS,0)})
                if key in row: row[key] += 1
        # 同一 region 的全部事件必须共享同一对 before/after,且事件类型集合
        # 恰好等于由这对 before/after 派生出的变化类别(不多不少)。
        for events in grouped.values():
            before, after = events[0]["before"], events[0]["after"]
            if any(e["before"] != before or e["after"] != after for e in events):
                errors.append("same-region audit events have inconsistent before/after")
            expected = set()
            if before is None: expected.add("added")
            elif after is None: expected.add("deleted")
            else:
                for kind, keys in (("label_changed",("class",)),("geometry_changed",("box","polygon")),("attributes_changed",("kind","track_id","conf"))):
                    if {k:before[k] for k in keys if k in before} != {k:after[k] for k in keys if k in after}: expected.add(kind)
            if expected != {e["type"] for e in events}: errors.append("audit omits or adds a category for a changed region")
        # 每帧 counts/changed_regions 必须与重放结果一致;随后累加全局统计。
        if frame["counts"] != local or frame["changed_regions"] != len(changed):
            errors.append("audit per-frame counts mismatch")
        changed_regions += len(changed); changed_frames += bool(changed)
    # 按类汇总行按 class 名排序后与 diff.by_class 逐行比对;各事件类型总数与
    # changed_frames/changed_regions 必须同时匹配 diff.summary 与
    # manifest.summary。
    expected_classes = [classes[k] for k in sorted(classes)]
    if diff["by_class"] != expected_classes:
        errors.append("audit per-class counts mismatch")
    for key, count in {**counts, "changed_frames":changed_frames,"changed_regions":changed_regions}.items():
        if diff["summary"][key] != count or manifest["summary"][key] != count:
            errors.append(f"audit {key} total mismatch")
    # 两份 CSV 必须与 JSON 审计逐行一致:事件 CSV 表头固定为
    # frame_id/region_id/type/before/after(before/after 列为 region 的 JSON
    # 文本,无值时为 null),逐行解析后与重放出的 csv_events 比对;
    # 按类 CSV 表头为 class + CLASS_COUNTS,数值行与 expected_classes 比对。
    event_reader = csv.DictReader(io.StringIO(texts[PATHS[3]]))
    if event_reader.fieldnames != ["frame_id","region_id","type","before","after"]:
        errors.append("event CSV header mismatch")
    parsed = [(int(row["frame_id"]),row["region_id"],row["type"],_json(row["before"]),_json(row["after"])) for row in event_reader]
    if parsed != csv_events:
        errors.append("event CSV differs from JSON audit")
    class_reader = csv.DictReader(io.StringIO(texts[PATHS[4]]))
    if class_reader.fieldnames != ["class", *CLASS_COUNTS]:
        errors.append("class CSV header mismatch")
    rows = [{"class":row["class"], **{k:int(row[k]) for k in CLASS_COUNTS}} for row in class_reader]
    if rows != expected_classes:
        errors.append("class CSV differs from JSON audit")
    return errors


# 命令行入口:校验参数指定的包目录,向 stdout 打印一行 JSON
# {"success": bool, "errors": [...]}(保留非 ASCII 字符)。
# 返回:0 = 无错误;1 = 存在错误(错误只体现在输出与退出码,不抛异常)。
def main() -> int:
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    args = parser.parse_args()
    errors = validate_training_package(args.package)
    print(json.dumps({"success": not errors, "errors": errors}, ensure_ascii=False))
    return int(bool(errors))


# 以脚本方式运行:退出码即校验结果(供 CI 或独立校验使用)。
if __name__ == "__main__":
    raise SystemExit(main())
