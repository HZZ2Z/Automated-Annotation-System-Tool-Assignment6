# Model Output V1 只读校验门面与 CLI(Part 1.1)。
#
# 用途:对模型输出文件做严格 schema 校验。唯一合同是
# core/schemas/model_output_v1.schema.json;本模块不改写、不归一化输入,
# 只把文件、JSON 与 schema 失败转成字段级错误消息。
#
# 输入:一个 .json(单条记录)或 .jsonl(按行多条记录)文件路径;
# 输出:stdout 打印字段级错误(每条一行),或固定的 "Validation errors: 0"。
# 退出码:0 校验通过;1 存在错误;预期错误不打印 traceback。
#
# 典型运行方式:
#   .venv/bin/python python/validate_model_output.py path/to/model_output_v1.jsonl
#
# 协作模块:annotation_data.contracts(合同注册表与字段级验证错误)、
# annotation_data.jsonl(JSONL 读取、NaN/Infinity 拒绝)。
"""Part 1.1 read-only Model Output V1 validator facade and CLI.

The JSON Schema in ``core/schemas/model_output_v1.schema.json`` is the sole
contract authority. This module exposes stable validation helpers and converts
file, JSON, and schema failures into field-specific messages without modifying
input or leaking a traceback from expected CLI errors.
"""

import argparse
import json
from pathlib import Path
from typing import Any, Sequence

from annotation_data.contracts import load_schema as load_named_schema
from annotation_data.contracts import validate_instance
from annotation_data.jsonl import read_jsonl, reject_non_finite_constant


# 唯一合同文件的逻辑名:全部校验路径都指向这一份 JSON Schema。
SCHEMA_NAME = "model_output_v1.schema.json"


# 加载唯一的 Model Output V1 JSON Schema(功能见下方英文 docstring)。
def load_schema() -> dict[str, Any]:
    """Return the sole authoritative Model Output V1 JSON Schema.

    This stable facade keeps callers independent of package-internal schema
    lookup while ensuring every validator uses the same contract authority.
    """
    return load_named_schema(SCHEMA_NAME)


# 校验单条记录(功能见下方英文 docstring)。
# 返回:字段路径级错误消息列表(已排序、顺序确定);空列表即通过。
def validate_record(record: object) -> list[str]:
    """Validate one record and return field-path errors, or ``[]`` if valid.

    The record is inspected only; this read-only helper never normalizes or
    mutates model output before passing it to the canonical schema validator.
    """
    return validate_instance(record, SCHEMA_NAME)


# 读取输入文件为记录列表,全程只读、不写输入(功能见下方英文 docstring)。
# 参数 path:输入路径;按后缀(忽略大小写)区分 JSONL 与普通 JSON。
# 返回:记录列表——JSONL 为逐条字典(保持文件行序),普通 JSON 恰好一个元素。
# 抛出 OSError(文件不可读)、ValueError(JSONL 某行解析失败或含非有限数,
#       消息带 "路径:行号")、json.JSONDecodeError(整体 JSON 语法错误)。
def _load_records(path: Path) -> list[object]:
    """Load one JSON record or ordered JSONL records without writing ``path``.

    Plain JSON contributes exactly one record. JSONL is read line by line in
    file order so downstream error indices identify the original record order.
    """
    if path.suffix.lower() == ".jsonl":
        return list(read_jsonl(path))
    payload = json.loads(
        path.read_text(encoding="utf-8"),
        parse_constant=reject_non_finite_constant,
    )
    return [payload]


# 校验一个 JSON/JSONL 文件并返回按记录编号的错误消息(功能见下方英文 docstring)。
# 参数 path:输入文件路径,只读。
# 返回:错误消息列表——文件/解析失败折叠为一条带路径前缀的消息;schema 失败
#       每条以 "record N:"(N 为 0 起始的记录序号)开头,可精确定位坏记录。
def validate_model_output(path: Path) -> list[str]:
    """Validate a read-only JSON or JSONL input and return record-indexed errors.

    JSON produces one record, while JSONL preserves line order. File and parse
    failures are returned as messages; schema failures are prefixed with their
    zero-based record index so callers can locate invalid model output exactly.
    """
    try:
        records = _load_records(path)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return [f"{path}: {error}"]
    return [
        f"record {index}: {error}"
        for index, record in enumerate(records)
        for error in validate_record(record)
    ]


# 解析 CLI:唯一的位置参数是模型输出文件路径(功能见下方英文 docstring)。
def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the single read-only model-output path accepted by the CLI."""
    parser = argparse.ArgumentParser(
        description="Validate Model Output V1 JSON or JSONL."
    )
    parser.add_argument("path", type=Path, help="model output JSON or JSONL path")
    return parser.parse_args(argv)


# CLI 主流程(功能见下方英文 docstring):打印结果并返回退出码。
def main(argv: Sequence[str] | None = None) -> int:
    """Print validation errors for expected CLI failures and return ``0`` or ``1``.

    Successful validation prints the fixed zero-error message and returns ``0``;
    unreadable, malformed, or schema-invalid input prints its returned errors
    and returns ``1`` without exposing an expected-error traceback.
    """
    args = parse_args(argv)
    errors = validate_model_output(args.path)
    if errors:
        for error in errors:
            print(error)
        return 1
    # 通过:打印固定的零错误提示,便于脚本断言。
    print("Validation errors: 0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
