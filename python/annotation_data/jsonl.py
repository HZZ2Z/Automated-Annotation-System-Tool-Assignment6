# JSON Lines(JSONL)读写工具模块。
#
# 用途:为模型基线 model_output_v1.jsonl 这类「一行一条 JSON 记录」的文件
# 提供两件事:严格解析(拒绝 NaN/Infinity 等非标准 JSON 常量,并把坏行
# 定位到「文件:行号」)与崩溃安全写入(同级临时文件 + flush + fsync +
# 原子替换)。
#
# 角色与协作:validate_model_output.py 用 read_jsonl 读取模型基线;
# annotation_data.sample 用 write_jsonl_atomic 写出样例;「临时文件 + 原子
# 替换」的写法与 V3 审核会话的保存约定一致。
"""JSON Lines reading and crash-safe writing helpers."""

import json
import os
from pathlib import Path
from typing import Iterable


# json.loads 的 parse_constant 回调:解析器遇到 NaN/Infinity/-Infinity 等
# 非标准 JSON 常量时被调用;一律抛 ValueError,让该行按格式错误处理,
# 保证解析结果不会混入非有限数值。
# 参数 value:命中的常量字面量文本(如 "NaN")。
def reject_non_finite_constant(value: str) -> None:
    """Reject JSON's non-standard NaN and Infinity constants."""
    raise ValueError(f"non-finite JSON constant {value!r}")


# 逐行读取 JSONL 文件并返回解析结果。
# 参数 path:UTF-8 编码的 JSONL 文件路径。
# 返回:按出现顺序排列的记录列表;纯空白行被跳过。
# 异常:某行不是合法 JSON,或含非标准常量时抛 ValueError,消息带
# 「路径:行号」前缀以定位坏行;坏行不会静默丢弃。
def read_jsonl(path: Path) -> list[dict]:
    """Read non-blank JSONL records and identify malformed input lines."""
    records: list[dict] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if line.strip():
                try:
                    records.append(json.loads(line, parse_constant=reject_non_finite_constant))
                except json.JSONDecodeError as error:
                    raise ValueError(f"{path}:{line_number}: {error.msg}") from error
                except ValueError as error:
                    raise ValueError(f"{path}:{line_number}: {error}") from error
    return records


# 崩溃安全地把 records 写成 JSONL:先写同级临时文件,成功后原子替换 path。
# 参数 path:目标文件路径;records:可迭代的 dict 记录,每条独占一行。
# 序列化约定:ensure_ascii=False 保留非 ASCII 原文,sort_keys=True 保证键序
# 确定可复现,allow_nan=False 遇到非有限数值直接抛错。
# 副作用:先写「path 原后缀 + .tmp」临时文件,写完 flush + fsync 落盘,再用
# replace 原子替换目标文件;任何一步失败都会删除残留临时文件并原样抛出
# 异常,目标文件保持旧内容不变。
def write_jsonl_atomic(path: Path, records: Iterable[dict]) -> None:
    """Write records to a sibling temporary file, then atomically replace ``path``."""
    temp_path = path.with_suffix(path.suffix + ".tmp")
    try:
        with temp_path.open("w", encoding="utf-8", newline="\n") as handle:
            for record in records:
                handle.write(
                    json.dumps(record, ensure_ascii=False, sort_keys=True, allow_nan=False) + "\n"
                )
            handle.flush()
            os.fsync(handle.fileno())
        temp_path.replace(path)
    # 失败清理:删除可能残留的临时文件后原样抛出,不吞异常。
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise
