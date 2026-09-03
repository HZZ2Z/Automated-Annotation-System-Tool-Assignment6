# Part 1.1 模型输出数据契约 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 严格按老师 Assignment Part 1.1 重做模型输出数据契约，交付 `model_output_v1.schema.json`、Python/Godot 双端验证、`model_output_vX` 版本管理和可证明的原始模型输出不可变性。

**Architecture:** `core/schemas/model_output_v1.schema.json` 是唯一的 Part 1.1 权威 Schema；Python 独立脚本直接消费该 Schema，Godot 使用原生 adapter 并与 Python 共用 fixtures 做一致性门禁。Source 按 manifest 中的 `model_output_vX` 选择同名 JSONL，AnnotationStore 分离不可变 model truth 和可编辑副本，所有加载、编辑和导出都不写回原模型文件。

**Tech Stack:** JSON Schema Draft 2020-12、Python 3.10–3.14、`jsonschema>=4.26,<5`、pytest 8、Godot 4.7.2/GDScript、JSON/JSONL、SHA-256。

**Spec:** `docs/superpowers/specs/2026-09-03-part1-1-model-output-contract-design.md`

## Global Constraints

- 实施与评审时优先级为：`docs/Project_6_Automated_Annotation_System_Assignment.md` Part 1.1 → 已确认 spec → 现有架构文档与旧测试。
- 不修改或翻译老师 Assignment 文件。
- Part 1.1 Schema 只描述 per-image model output，不加入 `dataset_id`、`image_size`、`filled`、review state 或 manifest 字段。
- 顶层必需字段仅为 `schema_version`、`source`、`frame`、`regions`；`time_s` 可选。
- region 必需字段仅为 `id`、`class`、`kind`；必须有 `box` 或 `polygon`，两者可同时存在。
- `kind` 是非空字符串；`region`、`anatomy`、`instrument` 是老师示例，不是封闭枚举。
- `source` 是图像/视频/帧序列来源，例如 `sample_v1`；不存储模型版本，也不改成 `human_corrected`。
- Schema、JSONL 和 record 版本必须对齐：`model_output_v1.schema.json` ↔ `model_output_v1.jsonl` ↔ `schema_version: 1`。
- 后续模型输出版本始终使用 `model_output_vX`，X 是从 1 开始、不带前导 0 的十进制整数。
- 最终状态不保留 `annotation-v1`、`validate_annotations.py`、`annotation_validator.gd` 或无版本 `model_output.jsonl` 的兼容别名。
- 模型输出从磁盘加载后只读；对外 getter 返回 deep copy；编辑只改 corrected working state；导出使用不同路径。
- `filled` 可以作为客户端短期显示状态存在于 corrected working copy，但在进入 model-output validator 与规范化 snapshot 前必须被去除，不得出现在原模型 JSONL。
- 验证失败返回可读字段路径；Python CLI 不输出 traceback；Godot 不因 malformed Variant 中断 UI。
- 文档使用中文（代码标识符、文件名和必要技术术语保留原文）。
- 保留工作树中与本计划无关的用户修改；每次提交只 stage 当前任务的文件。

---

## 需求与任务对应

| Part 1.1 需求 | 实施任务 |
|---|---|
| 老师示例字段与 box and/or polygon | Task 1 |
| 独立 Python validator、清晰错误、无 traceback | Task 2 |
| 可复现 sample 生成 `model_output_v1.jsonl` | Task 3 |
| Godot 客户端 validator、malformed input 不崩溃 | Task 4 |
| Source 版本选择、store 隔离、原输出不可变 | Task 5 |
| 删除旧契约并把辅助 schema 移出主目录 | Task 6 |
| 中文文档、实现报告、完整门禁 | Task 7 |

## 文件边界

| 文件/目录 | 唯一职责 |
|---|---|
| `core/schemas/model_output_v1.schema.json` | Part 1.1 model output 权威 JSON Schema |
| `core/fixtures/valid/` / `core/fixtures/invalid/` | Python/Godot 共享 model-output 契约样例 |
| `core/frame_source/dataset-manifest-v1.schema.json` | Part 1.3 数据源内部 manifest 契约，不作为 Part 1.1 证据 |
| `python/annotool/contracts.py` | Schema 加载、有限数 type checker 和内部 manifest 语义校验 |
| `python/validate_model_output.py` | 独立可运行的 Part 1.1 Python validator |
| `python/annotool/sample.py` | 生成符合 v1 contract 的版本化模型输出 |
| `client/domain/model_output_validator.gd` | Godot 原生 model-output 校验 adapter |
| `client/domain/annotation_store.gd` | immutable model truth、corrected working copy 和契约边界 |
| `client/domain/taxonomy.gd` | UI relabel 需要的 class → kind 查询，不污染 Schema validator |
| `client/plugins/source/*` | 建立 frame/source 与 `model_output_vX.jsonl` 之间的加载关系 |
| `tests/python/test_part1_1_data_contract.py` | Python Schema/CLI/不可变证据 |
| `tests/godot/test_model_output_validator.gd` | Godot 校验与共享 fixtures 一致性 |
| `tests/godot/test_model_output_immutability.gd` | 客户端加载、编辑、导出前后文件 hash 不变 |

---

### Task 1: 建立 `model_output_v1` Schema 和共享 fixtures

**Files:**
- Create: `core/schemas/model_output_v1.schema.json`
- Create: `core/fixtures/valid/assignment-model-output-v1.json`
- Create: `core/fixtures/valid/model-output-v1-box-only.json`
- Create: `core/fixtures/valid/model-output-v1-polygon-only.json`
- Create: `core/fixtures/valid/model-output-v1-empty-regions.json`
- Create: `core/fixtures/invalid/model-output-v1-missing-top-level.json`
- Create: `core/fixtures/invalid/model-output-v1-bad-top-level-values.json`
- Create: `core/fixtures/invalid/model-output-v1-missing-region-fields.json`
- Create: `core/fixtures/invalid/model-output-v1-bad-box.json`
- Create: `core/fixtures/invalid/model-output-v1-bad-polygon.json`
- Create: `core/fixtures/invalid/model-output-v1-bad-optional-and-extra.json`
- Create: `tests/python/test_part1_1_data_contract.py`

**Interfaces:**
- Consumes: Assignment Part 1.1 lines 65–98 and approved spec sections 4–6.
- Produces: `load_schema("model_output_v1.schema.json") -> dict[str, Any]` and shared valid/invalid JSON fixtures used by both runtimes.

- [ ] **Step 1: 重读老师的字段与版本原文**

Run:

```bash
sed -n '65,99p' docs/Project_6_Automated_Annotation_System_Assignment.md
```

Expected: 可见 `source`、`frame`、可选 `time_s`、`regions`、box and/or polygon 以及 `model_output_vX`；本任务不引用 Assignment 其他 Part 扩展字段。

- [ ] **Step 2: 先写新 Schema 的失败测试**

Create `tests/python/test_part1_1_data_contract.py` with the following core tests:

```python
import json
from copy import deepcopy
from pathlib import Path

import pytest

from annotool.contracts import validate_instance


ROOT = Path(__file__).resolve().parents[2]
VALID = ROOT / "core/fixtures/valid"
INVALID = ROOT / "core/fixtures/invalid"
SCHEMA = "model_output_v1.schema.json"


def load(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"))


def validate(record: object) -> list[str]:
    return validate_instance(record, SCHEMA)


def test_assignment_example_is_preserved_and_valid() -> None:
    record = load(VALID / "assignment-model-output-v1.json")
    assert record == {
        "schema_version": 1,
        "source": "sample_v1",
        "frame": 128,
        "time_s": 4.27,
        "regions": [
            {
                "id": "reg-003",
                "class": "grasper",
                "kind": "instrument",
                "box": [585, 26, 268, 176],
                "polygon": [[585, 26], [853, 26], [853, 202], [585, 202]],
                "conf": 0.92,
                "track_id": "T02",
            },
            {
                "id": "reg-004",
                "class": "cystic_duct",
                "kind": "anatomy",
                "box": [361, 224, 254, 150],
                "conf": 0.87,
                "track_id": None,
            },
        ],
    }
    assert validate(record) == []


@pytest.mark.parametrize(
    "name",
    [
        "model-output-v1-box-only.json",
        "model-output-v1-polygon-only.json",
        "model-output-v1-empty-regions.json",
    ],
)
def test_valid_shared_fixtures_pass(name: str) -> None:
    assert validate(load(VALID / name)) == []


@pytest.mark.parametrize("path", sorted(INVALID.glob("model-output-v1-*.json")))
def test_invalid_shared_fixtures_fail(path: Path) -> None:
    assert validate(load(path)), path.name


def test_box_and_polygon_may_appear_together() -> None:
    record = load(VALID / "model-output-v1-box-only.json")
    record["regions"][0]["polygon"] = [[10, 20], [50, 20], [50, 50], [10, 50]]
    assert validate(record) == []


def test_kind_is_open_non_empty_text() -> None:
    record = load(VALID / "model-output-v1-box-only.json")
    record["regions"][0]["kind"] = "future_custom_kind"
    assert validate(record) == []
    record["regions"][0]["kind"] = ""
    assert any(error.startswith("regions.0.kind:") for error in validate(record))


@pytest.mark.parametrize("field", ["schema_version", "source", "frame", "regions"])
def test_required_top_level_fields_have_paths(field: str) -> None:
    record = load(VALID / "model-output-v1-box-only.json")
    del record[field]
    assert any(error.startswith(f"{field}:") for error in validate(record))


def test_assignment_does_not_add_project_only_fields() -> None:
    for field, value in (
        ("dataset_id", "dataset"),
        ("image_size", [640, 360]),
        ("filled", False),
    ):
        record = deepcopy(load(VALID / "model-output-v1-box-only.json"))
        if field == "filled":
            record["regions"][0][field] = value
            expected_path = "regions.0.filled:"
        else:
            record[field] = value
            expected_path = f"{field}:"
        assert any(error.startswith(expected_path) for error in validate(record))
```

- [ ] **Step 3: 运行测试并确认因新 Schema/fixtures 不存在而失败**

Run:

```bash
.venv/bin/python -m pytest tests/python/test_part1_1_data_contract.py -q
```

Expected: FAIL，首个失败明确指向 `model_output_v1.schema.json` 或新 fixture 缺失，不是测试收集错误。

- [ ] **Step 4: 写入权威 JSON Schema**

Create `core/schemas/model_output_v1.schema.json` exactly as follows:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "model_output_v1.schema.json",
  "title": "Model Output V1 Per-Image Annotation Record",
  "type": "object",
  "additionalProperties": false,
  "required": ["schema_version", "source", "frame", "regions"],
  "properties": {
    "schema_version": {"const": 1},
    "source": {"type": "string", "minLength": 1},
    "frame": {"type": "integer", "minimum": 0},
    "time_s": {"type": "number", "minimum": 0},
    "regions": {
      "type": "array",
      "items": {"$ref": "#/$defs/region"}
    }
  },
  "$defs": {
    "region": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "class", "kind"],
      "properties": {
        "id": {"type": "string", "minLength": 1},
        "class": {"type": "string", "minLength": 1},
        "kind": {"type": "string", "minLength": 1},
        "box": {
          "type": "array",
          "minItems": 4,
          "prefixItems": [
            {"type": "number", "minimum": 0},
            {"type": "number", "minimum": 0},
            {"type": "number", "exclusiveMinimum": 0},
            {"type": "number", "exclusiveMinimum": 0}
          ],
          "items": false
        },
        "polygon": {
          "type": "array",
          "minItems": 3,
          "items": {
            "type": "array",
            "minItems": 2,
            "prefixItems": [
              {"type": "number", "minimum": 0},
              {"type": "number", "minimum": 0}
            ],
            "items": false
          }
        },
        "conf": {"type": "number", "minimum": 0, "maximum": 1},
        "track_id": {"type": ["string", "null"]}
      },
      "anyOf": [
        {"required": ["box"]},
        {"required": ["polygon"]}
      ]
    }
  }
}
```

- [ ] **Step 5: 写入共享 fixtures**

Use these exact payloads; pretty-print with UTF-8 and a final newline:

```text
valid/assignment-model-output-v1.json
  使用老师示例去掉 JSONC 注释后的完整内容，数值和字段顺序与 Step 2 断言一致。

valid/model-output-v1-box-only.json
  {"schema_version":1,"source":"sample_v1","frame":0,"regions":[{"id":"reg-box","class":"grasper","kind":"instrument","box":[10,20,40,30]}]}

valid/model-output-v1-polygon-only.json
  {"schema_version":1,"source":"sample_v1","frame":1,"time_s":0.033,"regions":[{"id":"reg-poly","class":"cystic_duct","kind":"anatomy","polygon":[[10,10],[60,10],[40,50]],"conf":0.87,"track_id":null}]}

valid/model-output-v1-empty-regions.json
  {"schema_version":1,"source":"sample_v1","frame":2,"regions":[]}

invalid/model-output-v1-missing-top-level.json
  {}

invalid/model-output-v1-bad-top-level-values.json
  {"schema_version":2,"source":"","frame":-1,"time_s":-0.1,"regions":"bad"}

invalid/model-output-v1-missing-region-fields.json
  {"schema_version":1,"source":"sample_v1","frame":0,"regions":[{}]}

invalid/model-output-v1-bad-box.json
  {"schema_version":1,"source":"sample_v1","frame":0,"regions":[{"id":"short","class":"grasper","kind":"instrument","box":[0,0,1]},{"id":"zero","class":"grasper","kind":"instrument","box":[0,0,0,1]}]}

invalid/model-output-v1-bad-polygon.json
  {"schema_version":1,"source":"sample_v1","frame":0,"regions":[{"id":"few","class":"duct","kind":"anatomy","polygon":[[0,0],[1,1]]},{"id":"vertex","class":"duct","kind":"anatomy","polygon":[[0,0],[1,0],[0,1,2]]}]}

invalid/model-output-v1-bad-optional-and-extra.json
  {"schema_version":1,"source":"sample_v1","frame":0,"unexpected":true,"regions":[{"id":"bad","class":"grasper","kind":"instrument","box":[0,0,1,1],"conf":1.1,"track_id":7,"filled":false}]}
```

- [ ] **Step 6: 运行 Schema 自校验和定向测试**

Run:

```bash
jq empty core/schemas/model_output_v1.schema.json
.venv/bin/python -m pytest tests/python/test_part1_1_data_contract.py -q
```

Expected: `jq` exit 0 and all tests PASS.

- [ ] **Step 7: 提交 Schema 和 fixtures**

```bash
git add core/schemas/model_output_v1.schema.json core/fixtures/valid core/fixtures/invalid tests/python/test_part1_1_data_contract.py
git commit -m "feat: define model output v1 contract"
```

---

### Task 2: 实现独立 Python model-output validator

**Files:**
- Create: `python/validate_model_output.py`
- Modify: `tests/python/test_part1_1_data_contract.py`
- Retain temporarily: `python/validate_annotations.py` until Task 6 removes all callers

**Interfaces:**
- Consumes: `annotool.contracts.load_schema(name)` and `validate_instance(data, name)` from Task 1.
- Produces: `load_schema() -> dict[str, Any]`, `validate_record(record: object) -> list[str]`, `validate_model_output(path: Path) -> list[str]`, `main(argv: Sequence[str] | None = None) -> int`.

- [ ] **Step 1: 先写 public API、CLI 和文件不可变失败测试**

Append these tests to `tests/python/test_part1_1_data_contract.py`:

```python
import hashlib
import subprocess
import sys

from validate_model_output import (
    load_schema,
    main,
    validate_model_output,
    validate_record,
)


def test_validator_public_api_uses_v1_schema() -> None:
    assert load_schema()["$id"] == "model_output_v1.schema.json"
    record = load(VALID / "assignment-model-output-v1.json")
    assert validate_record(record) == []


def test_jsonl_errors_include_record_index_and_field_path(tmp_path: Path) -> None:
    valid = load(VALID / "model-output-v1-box-only.json")
    invalid = deepcopy(valid)
    del invalid["regions"][0]["class"]
    path = tmp_path / "model_output_v1.jsonl"
    path.write_text(
        json.dumps(valid) + "\n" + json.dumps(invalid) + "\n",
        encoding="utf-8",
    )
    errors = validate_model_output(path)
    assert any(error.startswith("record 1: regions.0.class:") for error in errors)


@pytest.mark.parametrize("constant", ["NaN", "Infinity", "-Infinity"])
def test_non_finite_json_is_rejected_without_traceback(
    tmp_path: Path, constant: str
) -> None:
    path = tmp_path / "model_output_v1.jsonl"
    path.write_text(
        '{"schema_version":1,"source":"sample_v1","frame":0,'
        f'"time_s":{constant},"regions":[]}}\n',
        encoding="utf-8",
    )
    result = subprocess.run(
        [sys.executable, str(ROOT / "python/validate_model_output.py"), str(path)],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 1
    assert "non-finite JSON constant" in result.stdout
    assert "Traceback" not in result.stdout + result.stderr


def test_validator_does_not_modify_model_file(tmp_path: Path) -> None:
    source = VALID / "assignment-model-output-v1.json"
    path = tmp_path / "model_output_v1.json"
    path.write_bytes(source.read_bytes())
    before = hashlib.sha256(path.read_bytes()).hexdigest()
    assert validate_model_output(path) == []
    after = hashlib.sha256(path.read_bytes()).hexdigest()
    assert after == before


def test_main_returns_one_for_malformed_json_and_no_traceback(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = tmp_path / "model_output_v1.json"
    path.write_text("{bad", encoding="utf-8")
    assert main([str(path)]) == 1
    captured = capsys.readouterr()
    assert str(path) in captured.out
    assert "Traceback" not in captured.out + captured.err
```

- [ ] **Step 2: 运行测试并确认缺失新模块**

Run:

```bash
.venv/bin/python -m pytest tests/python/test_part1_1_data_contract.py -q
```

Expected: FAIL during import with `ModuleNotFoundError: No module named 'validate_model_output'`.

- [ ] **Step 3: 实现独立脚本**

Create `python/validate_model_output.py` with this complete control flow and short Chinese comments:

```python
"""Validate Model Output V1 JSON/JSONL without modifying the input file."""

import argparse
import json
from pathlib import Path
from typing import Any, Sequence

from annotool.contracts import load_schema as load_named_schema
from annotool.contracts import validate_instance
from annotool.jsonl import read_jsonl, reject_non_finite_constant


SCHEMA_NAME = "model_output_v1.schema.json"


def load_schema() -> dict[str, Any]:
    """读取唯一的 Model Output V1 Schema。"""
    return load_named_schema(SCHEMA_NAME)


def validate_record(record: object) -> list[str]:
    """返回带字段路径的错误；空列表表示通过。"""
    return validate_instance(record, SCHEMA_NAME)


def _load_records(path: Path) -> list[object]:
    if path.suffix.lower() == ".jsonl":
        return list(read_jsonl(path))
    payload = json.loads(
        path.read_text(encoding="utf-8"),
        parse_constant=reject_non_finite_constant,
    )
    return [payload]


def validate_model_output(path: Path) -> list[str]:
    """校验单条 JSON 或逐行 JSONL，不向 path 写入任何内容。"""
    try:
        records = _load_records(path)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return [f"{path}: {error}"]
    return [
        f"record {index}: {error}"
        for index, record in enumerate(records)
        for error in validate_record(record)
    ]


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate Model Output V1 JSON or JSONL."
    )
    parser.add_argument("path", type=Path, help="model output JSON or JSONL path")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    errors = validate_model_output(args.path)
    if errors:
        for error in errors:
            print(error)
        return 1
    print("Validation errors: 0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: 运行定向测试和真实示例 CLI**

Run:

```bash
.venv/bin/python -m pytest tests/python/test_part1_1_data_contract.py -q
.venv/bin/python python/validate_model_output.py core/fixtures/valid/assignment-model-output-v1.json
```

Expected: tests PASS; CLI prints `Validation errors: 0` and exits 0.

- [ ] **Step 5: 提交 Python validator**

```bash
git add python/validate_model_output.py tests/python/test_part1_1_data_contract.py
git commit -m "feat: add standalone model output validator"
```

---

### Task 3: 让 sample 生成器产出规范的 `model_output_v1.jsonl`

**Files:**
- Modify: `python/annotool/sample.py:20-140,217-345`
- Modify: `tests/python/test_sample.py:1-125`
- Modify: `tests/expected/sample-defects.json`

**Interfaces:**
- Consumes: `validate_instance(record, "model_output_v1.schema.json")`.
- Produces: deterministic `model_output_v1.jsonl`; each record has only Part 1.1 fields and `source == "sample_v1"`; manifest declares `model_version == "model_output_v1"`.

- [ ] **Step 1: 先改 sample 测试为新命名和字段**

Replace the model-output assertions in `tests/python/test_sample.py` with:

```python
from validate_model_output import validate_model_output


def test_sample_is_deterministic(samples: tuple[Path, dict[str, str], Path]) -> None:
    first_dir, first_hashes, second_dir = samples
    assert json.loads((first_dir / "hashes.json").read_text(encoding="utf-8")) == first_hashes
    assert json.loads((second_dir / "hashes.json").read_text(encoding="utf-8")) == first_hashes
    assert "model_output_v1.jsonl" in first_hashes
    assert "model_output.jsonl" not in first_hashes
    assert not (first_dir / "model_output.jsonl").exists()
    for relative_path, digest in first_hashes.items():
        assert hashlib.sha256((first_dir / relative_path).read_bytes()).hexdigest() == digest


def test_sample_model_output_matches_assignment_contract(
    samples: tuple[Path, dict[str, str], Path],
) -> None:
    sample_dir, _, _ = samples
    model_path = sample_dir / "model_output_v1.jsonl"
    assert validate_model_output(model_path) == []
    records = read_jsonl(model_path)
    assert len(records) == 120
    for frame, record in enumerate(records):
        assert record["schema_version"] == 1
        assert record["source"] == "sample_v1"
        assert record["frame"] == frame
        assert set(record) == {"schema_version", "source", "frame", "time_s", "regions"}
        assert all("filled" not in region for region in record["regions"])
        assert "dataset_id" not in record
        assert "image_size" not in record
    manifest = json.loads((sample_dir / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["source_name"] == "sample_v1"
    assert manifest["model_version"] == "model_output_v1"
```

Update every read of `model_output.jsonl` in this test file to `model_output_v1.jsonl`.

- [ ] **Step 2: 运行 sample 测试并确认旧产出导致失败**

Run:

```bash
.venv/bin/python -m pytest tests/python/test_sample.py -q
```

Expected: FAIL because the generator still writes `model_output.jsonl`, still uses `source: model_output_v1`, and still emits extra fields.

- [ ] **Step 3: 修正 sample 常量、record 和 manifest**

Apply these exact structural changes in `python/annotool/sample.py`:

```python
DATASET_ID = "annotool-sample"          # 仅供 manifest/defect metadata
SOURCE_ID = "sample_v1"                 # 图像/帧序列来源
MODEL_VERSION = "model_output_v1"       # 契约与文件版本
TAXONOMY_VERSION = "sample-taxonomy-v1"
```

Build every per-image record as:

```python
ground_truth.append(
    {
        "schema_version": 1,
        "source": SOURCE_ID,
        "frame": frame,
        "time_s": frame / FPS,
        "regions": regions,
    }
)
```

Remove `filled` from `_clean_regions()` and the hallucinated region, then set manifest/file values as:

```python
manifest["source_name"] = SOURCE_ID
manifest["model_version"] = MODEL_VERSION
annotation_path = output_dir / f"{MODEL_VERSION}.jsonl"
```

Validate generated records only against the canonical Schema:

```python
for frame, record in enumerate(records):
    errors = validate_instance(record, "model_output_v1.schema.json")
    if errors:
        raise ValueError(
            f"invalid generated model output at frame {frame}: " + "; ".join(errors)
        )
```

- [ ] **Step 4: 更新缺陷期望数据**

In `tests/expected/sample-defects.json`, remove only the hallucinated region's `filled` member. Keep `dataset_id` in this defect-report file because it is report metadata, not a model-output record.

- [ ] **Step 5: 验证可复现性和新 CLI 链路**

Run:

```bash
.venv/bin/python -m pytest tests/python/test_sample.py tests/python/test_part1_1_data_contract.py -q
sample_root="$(mktemp -d /tmp/annotool-part1-1-sample-XXXXXX)"
.venv/bin/python python/make_sample_input.py --output "$sample_root/assignment_v1" --seed 6006
.venv/bin/python python/validate_model_output.py "$sample_root/assignment_v1/model_output_v1.jsonl"
```

Expected: all tests PASS; generator and validator both exit 0; generated directory contains `model_output_v1.jsonl` and no `model_output.jsonl`.

- [ ] **Step 6: 提交 sample 切换**

```bash
git add python/annotool/sample.py tests/python/test_sample.py tests/expected/sample-defects.json
git commit -m "feat: version generated model output as v1"
```

---

### Task 4: 实现 Godot `ModelOutputValidator` 并与 Python 共享 fixtures

**Files:**
- Create: `client/domain/model_output_validator.gd`
- Create: `client/domain/model_output_validator.gd.uid`
- Create: `tests/godot/test_model_output_validator.gd`
- Create: `tests/godot/test_model_output_validator.gd.uid`
- Modify: `tests/godot/test_runner.gd:5,31`
- Retain temporarily: old validator/test until Task 6 removes all callers

**Interfaces:**
- Consumes: files matching `core/fixtures/valid/*model-output-v1*.json` and `core/fixtures/invalid/model-output-v1-*.json`.
- Produces: `ModelOutputValidator.validate_record(record: Variant) -> PackedStringArray`.

- [ ] **Step 1: 先写 Godot 共享 fixture 和 malformed Variant 测试**

Create `tests/godot/test_model_output_validator.gd` with these required checks:

```gdscript
extends RefCounted

const VALIDATOR_PATH := "res://client/domain/model_output_validator.gd"


static func run(support: TestSupport) -> void:
	var script := ResourceLoader.load(VALIDATOR_PATH, "Script") as Script
	support.expect(script != null, "ModelOutputValidator script should exist")
	if script == null:
		return
	var validator = script.new()
	_test_shared_fixtures(validator, support)
	_test_assignment_semantics(validator, support)
	_test_field_paths(validator, support)
	_test_malformed_variants(validator, support)


static func _test_shared_fixtures(validator, support: TestSupport) -> void:
	for filename: String in DirAccess.get_files_at("res://core/fixtures/valid"):
		if "model-output-v1" in filename and filename.ends_with(".json"):
			var record: Variant = JSON.parse_string(
				FileAccess.get_file_as_string("res://core/fixtures/valid/%s" % filename)
			)
			support.expect(
				validator.validate_record(record).is_empty(),
				"valid shared fixture rejected: %s" % filename,
			)
	for filename: String in DirAccess.get_files_at("res://core/fixtures/invalid"):
		if filename.begins_with("model-output-v1-") and filename.ends_with(".json"):
			var record: Variant = JSON.parse_string(
				FileAccess.get_file_as_string("res://core/fixtures/invalid/%s" % filename)
			)
			support.expect(
				not validator.validate_record(record).is_empty(),
				"invalid shared fixture accepted: %s" % filename,
			)


static func _test_assignment_semantics(validator, support: TestSupport) -> void:
	var record: Dictionary = _read_valid("assignment-model-output-v1.json")
	support.expect_equal(record.get("source"), "sample_v1", "source identifies the frame source")
	support.expect(record["regions"][0].has("box") and record["regions"][0].has("polygon"), "assignment example carries both geometries")
	support.expect(validator.validate_record(record).is_empty(), "assignment example should pass")
	var open_kind: Dictionary = _read_valid("model-output-v1-box-only.json")
	open_kind["regions"][0]["kind"] = "future_custom_kind"
	support.expect(validator.validate_record(open_kind).is_empty(), "kind examples must not become a closed enum")


static func _test_field_paths(validator, support: TestSupport) -> void:
	var record: Dictionary = _read_valid("model-output-v1-box-only.json")
	record["regions"][0].erase("box")
	var errors: PackedStringArray = validator.validate_record(record)
	support.expect(_has_path(errors, "regions.0"), "missing geometry should identify regions.0")
	record = _read_valid("model-output-v1-box-only.json")
	record["regions"][0]["box"] = [-1, 0, 2, 2]
	errors = validator.validate_record(record)
	support.expect(_has_path(errors, "regions.0.box.0"), "negative x should identify its coordinate")


static func _test_malformed_variants(validator, support: TestSupport) -> void:
	for malformed: Variant in [null, true, 1, "record", [], PackedInt32Array([1, 2])]:
		var errors: PackedStringArray = validator.validate_record(malformed)
		support.expect(not errors.is_empty(), "malformed input should return errors")
		support.expect(_has_path(errors, "$"), "malformed input should identify the root")


static func _read_valid(filename: String) -> Dictionary:
	return JSON.parse_string(
		FileAccess.get_file_as_string("res://core/fixtures/valid/%s" % filename)
	)


static func _has_path(errors: PackedStringArray, path: String) -> bool:
	for error: String in errors:
		if error.begins_with(path + ":") or error.begins_with(path + "."):
			return true
	return false
```

Replace the old validator test entry in `tests/godot/test_runner.gd`:

```gdscript
const MODEL_OUTPUT_VALIDATOR_TEST = preload("res://tests/godot/test_model_output_validator.gd")
# ...
MODEL_OUTPUT_VALIDATOR_TEST.run(support)
```

- [ ] **Step 2: 运行 Godot 测试并确认新 script 缺失**

Run:

```bash
"$GODOT_BIN" --headless --path . --script tests/godot/test_runner.gd
```

Expected: non-zero exit and a load error naming `client/domain/model_output_validator.gd`.

- [ ] **Step 3: 实现与 Schema 对齐的 Godot adapter**

Create `client/domain/model_output_validator.gd` with this structure; all helpers append errors and return instead of asserting or throwing:

```gdscript
class_name ModelOutputValidator
extends RefCounted

const TOP_LEVEL_FIELDS := {
	"schema_version": true, "source": true, "frame": true,
	"time_s": true, "regions": true,
}
const REQUIRED_TOP_LEVEL_FIELDS := ["schema_version", "source", "frame", "regions"]
const REGION_FIELDS := {
	"id": true, "class": true, "kind": true, "box": true,
	"polygon": true, "conf": true, "track_id": true,
}
const REQUIRED_REGION_FIELDS := ["id", "class", "kind"]


func validate_record(record: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	if not record is Dictionary:
		errors.append("$: expected object, got %s" % type_string(typeof(record)))
		return errors
	for key: Variant in record.keys():
		if typeof(key) != TYPE_STRING or not TOP_LEVEL_FIELDS.has(key):
			errors.append("%s: additional field is not allowed" % str(key))
	for field: String in REQUIRED_TOP_LEVEL_FIELDS:
		if not record.has(field):
			errors.append("%s: required field missing" % field)
	if record.has("schema_version"):
		var value: Variant = record["schema_version"]
		if not _is_json_integer(value) or int(value) != 1:
			errors.append("schema_version: expected integer 1")
	if record.has("source"):
		var value: Variant = record["source"]
		if typeof(value) != TYPE_STRING or String(value).is_empty():
			errors.append("source: expected non-empty string")
	if record.has("frame"):
		var value: Variant = record["frame"]
		if not _is_json_integer(value) or value < 0:
			errors.append("frame: expected non-negative integer")
	if record.has("time_s"):
		var value: Variant = record["time_s"]
		if not _is_finite_number(value) or value < 0:
			errors.append("time_s: expected finite non-negative number")
	var regions: Variant = record.get("regions")
	if not regions is Array:
		if record.has("regions"):
			errors.append("regions: expected array")
		return errors
	for index in range(regions.size()):
		_validate_region(regions[index], index, errors)
	return errors


func _validate_region(region: Variant, index: int, errors: PackedStringArray) -> void:
	var path := "regions.%d" % index
	if not region is Dictionary:
		errors.append("%s: expected object" % path)
		return
	for key: Variant in region.keys():
		if typeof(key) != TYPE_STRING or not REGION_FIELDS.has(key):
			errors.append("%s.%s: additional field is not allowed" % [path, str(key)])
	for field: String in REQUIRED_REGION_FIELDS:
		if not region.has(field):
			errors.append("%s.%s: required field missing" % [path, field])
		elif typeof(region[field]) != TYPE_STRING or String(region[field]).is_empty():
			errors.append("%s.%s: expected non-empty string" % [path, field])
	var has_box := region.has("box")
	var has_polygon := region.has("polygon")
	if not has_box and not has_polygon:
		errors.append("%s: expected box and/or polygon" % path)
	if has_box:
		_validate_box(region["box"], path, errors)
	if has_polygon:
		_validate_polygon(region["polygon"], path, errors)
	if region.has("conf"):
		var conf: Variant = region["conf"]
		if not _is_finite_number(conf) or conf < 0 or conf > 1:
			errors.append("%s.conf: expected finite number between 0 and 1" % path)
	if region.has("track_id"):
		var track_id: Variant = region["track_id"]
		if track_id != null and typeof(track_id) != TYPE_STRING:
			errors.append("%s.track_id: expected string or null" % path)


func _validate_box(box: Variant, region_path: String, errors: PackedStringArray) -> void:
	var path := "%s.box" % region_path
	if not box is Array or box.size() != 4:
		errors.append("%s: expected exactly [x, y, width, height]" % path)
		return
	for index in range(4):
		if not _is_finite_number(box[index]):
			errors.append("%s.%d: expected finite number" % [path, index])
			continue
		if index < 2 and box[index] < 0:
			errors.append("%s.%d: expected non-negative coordinate" % [path, index])
		if index >= 2 and box[index] <= 0:
			errors.append("%s.%d: expected positive extent" % [path, index])


func _validate_polygon(polygon: Variant, region_path: String, errors: PackedStringArray) -> void:
	var path := "%s.polygon" % region_path
	if not polygon is Array:
		errors.append("%s: expected array of vertices" % path)
		return
	if polygon.size() < 3:
		errors.append("%s: expected at least three vertices" % path)
	for index in range(polygon.size()):
		var vertex: Variant = polygon[index]
		var vertex_path := "%s.%d" % [path, index]
		if not vertex is Array or vertex.size() != 2:
			errors.append("%s: expected exactly [x, y]" % vertex_path)
			continue
		for coordinate in range(2):
			if not _is_finite_number(vertex[coordinate]) or vertex[coordinate] < 0:
				errors.append("%s.%d: expected finite non-negative number" % [vertex_path, coordinate])


func _is_json_integer(value: Variant) -> bool:
	return _is_finite_number(value) and float(value) == floorf(float(value))


func _is_finite_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value))
```

Generate/import the two `.uid` files once through Godot and keep the generated stable UIDs with their scripts.

- [ ] **Step 4: 运行 Godot 完整测试**

Run:

```bash
"$GODOT_BIN" --headless --path . --script tests/godot/test_runner.gd
```

Expected: exit 0 and final line `PASS: complete Godot test suite`; corrupt-image warnings from explicit recovery tests are permitted.

- [ ] **Step 5: 提交 Godot validator**

```bash
git add client/domain/model_output_validator.gd client/domain/model_output_validator.gd.uid tests/godot/test_model_output_validator.gd tests/godot/test_model_output_validator.gd.uid tests/godot/test_runner.gd
git commit -m "feat: validate model output in Godot"
```

---

### Task 5: 切换客户端契约边界、版本加载和不可变性

**Files:**
- Create: `client/domain/taxonomy.gd`
- Create: `client/domain/taxonomy.gd.uid`
- Create: `tests/godot/test_model_output_immutability.gd`
- Create: `tests/godot/test_model_output_immutability.gd.uid`
- Modify: `client/domain/annotation_store.gd`
- Modify: `client/domain/commands/add_box_command.gd`
- Modify: `client/domain/commands/relabel_region_command.gd`
- Modify: `client/plugins/edit/basic_edit_tools/plugin.gd`
- Modify: `client/plugins/source/image_sequence_source/plugin.gd`
- Modify: `client/plugins/source/single_image_source/plugin.gd`
- Modify: `client/plugins/feedback/file_training_handoff/plugin.gd`
- Modify: `tests/godot/test_annotation_store.gd`
- Modify: `tests/godot/test_source_plugin.gd`
- Modify: `tests/godot/test_single_image_source.gd`
- Modify: `tests/godot/test_feedback_plugin.gd`
- Modify: `tests/godot/test_edit_commands.gd`
- Modify: `tests/godot/test_keyboard_editing.gd`
- Modify: `tests/godot/test_edit_integration.gd`
- Modify: `tests/godot/fixtures/integration_plugins/counting_source.gd`
- Modify: `tests/godot/test_runner.gd`

**Interfaces:**
- Consumes: `ModelOutputValidator.validate_record(record)` and manifest `model_version`/`source_name`.
- Produces: strict model load, editable corrected copies, canonical `snapshot_corrected()`, version-derived file selection, and SHA-256 immutability evidence.

- [ ] **Step 1: 先改 store/source/feedback 测试为新语义**

Use `core/fixtures/valid/model-output-v1-box-only.json` as the base record in store tests. Add these assertions:

```gdscript
var original := _read_model_fixture()
support.expect(store.load_model_records([original]).is_empty(), "canonical model record should load")
var model_before: Dictionary = store.get_model_record(0)
var corrected: Dictionary = store.get_corrected_record(0)
corrected["regions"][0]["class"] = "reviewed_grasper"
corrected["regions"][0]["filled"] = true
support.expect(store.replace_corrected_record(0, corrected).is_empty(), "known UI-only fill state should not contaminate model validation")
support.expect_equal(store.get_model_record(0), model_before, "editing must preserve immutable model truth")
var snapshot: Array = store.snapshot_corrected()
support.expect_equal(snapshot[0].get("source"), "sample_v1", "corrected snapshot preserves frame source")
support.expect(not snapshot[0]["regions"][0].has("filled"), "canonical snapshot strips UI-only fill state")
support.expect(ModelOutputValidator.new().validate_record(snapshot[0]).is_empty(), "canonical snapshot must satisfy model-output shape")
```

In `tests/godot/test_source_plugin.gd`, add concrete version-selection cases using its existing temporary-directory helpers:

```gdscript
static func _test_versioned_model_output_selection(support: TestSupport) -> void:
	var valid_root := _new_temp_path("versioned-model")
	_make_one_frame_source(valid_root, 8, 6)
	var manifest := _base_manifest("versioned-model", "model_output_v1", 8, 6)
	manifest["source_name"] = "sample_v1"
	_write_json(valid_root.path_join("manifest.json"), manifest)
	_write_text(valid_root.path_join("model_output_v1.jsonl"), JSON.stringify(_model_record("sample_v1")) + "\n")
	var source = SOURCE_SCRIPT.new()
	support.expect_equal(source.open(valid_root), PackedStringArray(), "model_output_v1 should load its same-named JSONL")
	support.expect_equal(source.get_model_records()[0].get("source"), "sample_v1", "record source should identify the frame source")

	var unversioned_root := _new_temp_path("unversioned-model")
	_make_one_frame_source(unversioned_root, 8, 6)
	_write_json(unversioned_root.path_join("manifest.json"), manifest)
	_write_text(unversioned_root.path_join("model_output.jsonl"), JSON.stringify(_model_record("sample_v1")) + "\n")
	var errors: PackedStringArray = source.open(unversioned_root)
	support.expect(_contains(errors, "model_output_v1.jsonl"), "unversioned fallback must be refused")

	var future_root := _new_temp_path("future-model")
	_make_one_frame_source(future_root, 8, 6)
	var future_manifest := _base_manifest("future-model", "model_output_v2", 8, 6)
	future_manifest["source_name"] = "sample_v1"
	_write_json(future_root.path_join("manifest.json"), future_manifest)
	errors = source.open(future_root)
	support.expect(_contains(errors, "unsupported") and _contains(errors, "model_output_v2"), "legal future name must not be validated as v1")


static func _model_record(source_id: String) -> Dictionary:
	return {
		"schema_version": 1,
		"source": source_id,
		"frame": 0,
		"time_s": 0.0,
		"regions": [],
	}
```

In Feedback tests, replace the old source assertion with:

```gdscript
const MODEL_OUTPUT_VALIDATOR := preload("res://client/domain/model_output_validator.gd")

support.expect_equal(parsed.get("source"), "sample_v1", "Feedback must preserve the frame source")
support.expect(not parsed.has("dataset_id") and not parsed.has("image_size"), "Feedback must not reintroduce removed model fields")
support.expect_equal(MODEL_OUTPUT_VALIDATOR.new().validate_record(parsed), PackedStringArray(), "canonical corrected snapshot should remain structurally valid")
```

- [ ] **Step 2: 新增磁盘文件 hash 不变的客户端失败测试**

Create `tests/godot/test_model_output_immutability.gd` with a complete one-frame load/edit/export/hash test:

```gdscript
extends RefCounted

const SOURCE_SCRIPT := preload("res://client/plugins/source/image_sequence_source/plugin.gd")
const STORE_SCRIPT := preload("res://client/domain/annotation_store.gd")
const FEEDBACK_SCRIPT := preload("res://client/plugins/feedback/file_training_handoff/plugin.gd")
const TEMP_PREFIX := "/tmp/annotool-part1-1-immutability-"


static func run(support: TestSupport) -> void:
	var root := "%s%d-%d" % [TEMP_PREFIX, OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(root.path_join("frames"))
	var image := Image.create(8, 6, false, Image.FORMAT_RGBA8)
	image.fill(Color.DARK_GREEN)
	support.expect_equal(image.save_png(root.path_join("frames/frame_000000.png")), OK, "fixture frame should save")
	var manifest := {
		"schema_version": 1,
		"dataset_id": "immutability-fixture",
		"source_name": "sample_v1",
		"source_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
		"width": 8,
		"height": 6,
		"frame_count": 1,
		"nominal_fps": 30.0,
		"frames": [{"frame": 0, "time_s": 0.0, "image_path": "frames/frame_000000.png"}],
		"model_version": "model_output_v1",
		"taxonomy_version": "none",
	}
	var model_record := {
		"schema_version": 1,
		"source": "sample_v1",
		"frame": 0,
		"time_s": 0.0,
		"regions": [{"id": "reg-1", "class": "grasper", "kind": "instrument", "box": [1, 1, 2, 2]}],
	}
	_write_text(root.path_join("manifest.json"), JSON.stringify(manifest, "  ") + "\n")
	var model_path := root.path_join("model_output_v1.jsonl")
	_write_text(model_path, JSON.stringify(model_record) + "\n")
	var before_hash := FileAccess.get_sha256(model_path)
	var source = SOURCE_SCRIPT.new()
	support.expect_equal(source.open(root), PackedStringArray(), "versioned model output should open")
	var store = STORE_SCRIPT.new()
	support.expect_equal(store.load_model_records(source.get_model_records()), PackedStringArray(), "source records should load")
	var corrected := store.get_corrected_record(0)
	corrected["regions"][0]["class"] = "reviewed"
	support.expect_equal(store.replace_corrected_record(0, corrected), PackedStringArray(), "corrected edit should apply")
	var feedback = FEEDBACK_SCRIPT.new()
	support.expect_equal(
		feedback.export({"records": store.snapshot_corrected(), "output_path": root.path_join("corrected.jsonl")}),
		PackedStringArray(),
		"corrected export should succeed at a different path",
	)
	support.expect_equal(FileAccess.get_sha256(model_path), before_hash, "load, edit and export must not modify model_output_v1.jsonl")
	_remove_tree(root)


static func _write_text(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(value)


static func _remove_tree(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file_name: String in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file_name))
	for child_name: String in directory.get_directories():
		_remove_tree(path.path_join(child_name))
	DirAccess.remove_absolute(path)
```

Register this test in `tests/godot/test_runner.gd` and call it immediately after the store test.

- [ ] **Step 3: 运行 Godot 测试并确认旧客户端语义失败**

Run:

```bash
"$GODOT_BIN" --headless --path . --script tests/godot/test_runner.gd
```

Expected: FAIL with references to `human_corrected`, `model_output.jsonl`, removed record fields, or the missing immutability test dependencies.

- [ ] **Step 4: 将 AnnotationStore 切换到新 validator**

In `client/domain/annotation_store.gd`, replace `load_model_records()` with the complete transactional implementation below:

```gdscript
const VALIDATOR_SCRIPT := preload("res://client/domain/model_output_validator.gd")


func load_model_records(records: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	if not records is Array:
		errors.append("$: expected array of model output records")
		return errors
	var next_model := {}
	var seen_frames := {}
	for index in range(records.size()):
		var record: Variant = records[index]
		var record_errors: PackedStringArray = _validator.validate_record(record)
		for error: String in record_errors:
			errors.append(_prefix_record_error(index, error))
		if not record is Dictionary:
			continue
		var frame_value: Variant = record.get("frame")
		if _is_logical_integer(frame_value) and frame_value >= 0:
			var frame := int(frame_value)
			if seen_frames.has(frame):
				errors.append("records.%d.frame: duplicate frame %d" % [index, frame])
			else:
				seen_frames[frame] = true
			if record_errors.is_empty() and not next_model.has(frame):
				next_model[frame] = record.duplicate(true)
	if not errors.is_empty():
		return errors
	_model_records = next_model
	_corrected_records = next_model.duplicate(true)
	_dirty_frames.clear()
	return errors
```

Add one narrow working-copy projection and replace `replace_corrected_record()` and `snapshot_corrected()` with:

```gdscript
func _model_output_projection(record: Variant) -> Variant:
	if not record is Dictionary:
		return record
	var result: Dictionary = record.duplicate(true)
	var regions: Variant = result.get("regions")
	if regions is Array:
		for value: Variant in regions:
			if value is Dictionary:
				value.erase("filled")
	return result


func replace_corrected_record(frame: int, record: Variant) -> PackedStringArray:
	var errors: PackedStringArray = _validator.validate_record(_model_output_projection(record))
	if not _corrected_records.has(frame):
		errors.append("frame: frame %d does not exist" % frame)
	if record is Dictionary:
		var record_frame: Variant = record.get("frame")
		if not _is_logical_integer(record_frame) or int(record_frame) != frame:
			errors.append("frame: record frame must match key %d" % frame)
	if not errors.is_empty():
		return errors
	_corrected_records[frame] = record.duplicate(true)
	_dirty_frames[frame] = true
	return errors


func snapshot_corrected() -> Array:
	var result: Array = []
	for record: Dictionary in _sorted_record_copies(_corrected_records):
		result.append(_model_output_projection(record))
	return result
```

- [ ] **Step 5: 让 Source 由 `model_output_vX` 推导文件名**

In `client/plugins/source/image_sequence_source/plugin.gd`, validate and resolve the manifest version with:

```gdscript
func _is_model_output_version(value: String) -> bool:
	const PREFIX := "model_output_v"
	if not value.begins_with(PREFIX):
		return false
	var digits := value.substr(PREFIX.length())
	if digits.is_empty() or digits.unicode_at(0) < 49 or digits.unicode_at(0) > 57:
		return false
	for index in range(1, digits.length()):
		var code := digits.unicode_at(index)
		if code < 48 or code > 57:
			return false
	return true
```

Replace `_read_model_records()` with the following complete version:

```gdscript
func _read_model_records(root: String, manifest: Dictionary, errors: PackedStringArray) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	var model_version := str(manifest["model_version"])
	var filename := ""
	if model_version == "none":
		for index in range(int(manifest["frame_count"])):
			var entry: Dictionary = manifest["frames"][index]
			records.append({
				"schema_version": 1,
				"source": manifest["source_name"],
				"frame": index,
				"time_s": entry["time_s"],
				"regions": [],
			})
	elif not _is_model_output_version(model_version):
		errors.append("manifest.model_version: expected none or model_output_vX")
		return records
	elif model_version != "model_output_v1":
		errors.append("unsupported model output contract: %s" % model_version)
		return records
	else:
		filename = "%s.jsonl" % model_version
		var link_error := _path_link_error(root, filename)
		if not link_error.is_empty():
			errors.append("%s: %s" % [filename, link_error])
			return records
		var model_path := root.path_join(filename)
		if not FileAccess.file_exists(model_path):
			errors.append("%s is required when model_version is %s" % [filename, model_version])
			return records
		var file := FileAccess.open(model_path, FileAccess.READ)
		if file == null:
			errors.append("%s cannot be read" % filename)
			return records
		var line_number := 0
		while not file.eof_reached():
			var line := file.get_line()
			line_number += 1
			if line.strip_edges().is_empty():
				continue
			var parser := JSON.new()
			if parser.parse(line) != OK:
				errors.append("%s:%d: invalid JSON: %s" % [filename, line_number, parser.get_error_message()])
				continue
			if not parser.data is Dictionary:
				errors.append("%s:%d: expected object" % [filename, line_number])
				continue
			records.append(parser.data)

	var store = STORE_SCRIPT.new()
	var contract_errors: PackedStringArray = store.load_model_records(records)
	for error: String in contract_errors:
		errors.append("model_output.%s" % error)
	var frame_count := int(manifest["frame_count"])
	if records.size() != frame_count:
		errors.append("model_output: expected %d records, got %d" % [frame_count, records.size()])
	for index in range(mini(records.size(), frame_count)):
		var record: Dictionary = records[index]
		if not _is_logical_integer(record.get("frame")) or int(record.get("frame")) != index:
			errors.append("model_output.%d.frame: expected frame %d" % [index, index])
		if record.get("source") != manifest["source_name"]:
			errors.append("model_output.%d.source: must match manifest source_name" % index)
		if record.has("time_s") and (not _is_finite_number(record["time_s"]) or not is_equal_approx(float(record["time_s"]), float(manifest["frames"][index]["time_s"]))):
			errors.append("model_output.%d.time_s: must match manifest frame time" % index)
	if not errors.is_empty():
		return []
	var validated: Array[Dictionary] = []
	for index in range(frame_count):
		validated.append(store.get_model_record(index))
	return validated
```

The v1 branch opens only `FileAccess.READ`; the function contains no fallback to `model_output.jsonl` and no record-level `dataset_id`/`image_size` checks.

- [ ] **Step 6: 修正 single-image Source 和 Feedback 边界**

Build the single-image record as:

```gdscript
var candidate_record := {
	"schema_version": 1,
	"source": absolute.get_file(),
	"frame": 0,
	"time_s": 0.0,
	"regions": [],
}
```

The single-image manifest keeps its Part 1.3 metadata and uses `model_version: "none"`, because no model-output file exists for a standalone image.

In Feedback, switch the preload to `model_output_validator.gd` and replace the record loop with:

```gdscript
var corrected_records: Array[Dictionary] = []
var validator = VALIDATOR_SCRIPT.new()
var input_records: Array = context["records"]
for index in range(input_records.size()):
	var corrected: Dictionary = (input_records[index] as Dictionary).duplicate(true)
	var record_errors: PackedStringArray = validator.validate_record(corrected)
	for error: String in record_errors:
		errors.append("records.%d.%s" % [index, error])
	corrected_records.append(corrected)
```

This loop preserves the existing `source`, mutates neither the caller array nor the model file, and publishes only after all records pass.

- [ ] **Step 7: 将 taxonomy 查询从 Schema validator 拆出**

Create `client/domain/taxonomy.gd` with cached `core/taxonomy/classes.json` loading and:

```gdscript
class_name AnnotationTaxonomy
extends RefCounted

const TAXONOMY_PATH := "res://core/taxonomy/classes.json"
static var _loaded := false
static var _class_kinds: Dictionary = {}


static func kind_for_class(class_label: String) -> String:
	_ensure_loaded()
	return str(_class_kinds.get(class_label, ""))


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_class_kinds = {}
	if not FileAccess.file_exists(TAXONOMY_PATH):
		return
	var payload: Variant = JSON.parse_string(FileAccess.get_file_as_string(TAXONOMY_PATH))
	if not payload is Dictionary:
		return
	var classes: Variant = payload.get("classes")
	if not classes is Array:
		return
	for item: Variant in classes:
		if not item is Dictionary:
			continue
		var class_id: Variant = item.get("id")
		var kind: Variant = item.get("kind")
		if typeof(class_id) == TYPE_STRING and not String(class_id).is_empty() and typeof(kind) == TYPE_STRING and not String(kind).is_empty():
			_class_kinds[class_id] = kind
```

This helper ignores malformed entries and never validates a model-output record. In `relabel_region_command.gd`, preload this module and replace the old call with:

```gdscript
var taxonomy_kind := TAXONOMY_SCRIPT.kind_for_class(String(class_label))
if not taxonomy_kind.is_empty():
	after["regions"][index]["kind"] = taxonomy_kind
```

- [ ] **Step 8: 保留 Fill UI，但不把 `filled` 写入新 model record**

Remove `"filled": false` from `add_box_command.gd` and `_append_preview_box()` in the edit plugin. Keep `toggle_fill_command.gd` unchanged so it can add temporary working state after load. Change keyboard box sizing from the removed record field to the configured viewport transform:

```gdscript
var transform: Variant = _viewport.get_image_transform()
if not transform is Object or not transform.has_method("is_configured") or not transform.is_configured():
	_report("Current frame has no valid image size")
	return
var dimensions: Vector2 = transform.image_size
_keyboard_box = [0.0, 0.0, minf(20.0, dimensions.x), minf(20.0, dimensions.y)]
```

Update store/edit test fixture records to contain only `schema_version`, `source`, `frame`, optional `time_s`, and `regions`; initial model regions must not contain `filled`. Renderer/Inspector-only unit fixtures may retain `filled` because they represent transient display state rather than model-output JSON.

- [ ] **Step 9: 运行 Python sample tests和 Godot 完整套件**

Run:

```bash
.venv/bin/python -m pytest tests/python/test_sample.py tests/python/test_part1_1_data_contract.py -q
"$GODOT_BIN" --headless --path . --script tests/godot/test_runner.gd
```

Expected: both exit 0; Godot ends with `PASS: complete Godot test suite`; immutability test confirms unchanged SHA-256.

- [ ] **Step 10: 提交客户端切换**

```bash
git add client/domain/annotation_store.gd client/domain/commands/add_box_command.gd client/domain/commands/relabel_region_command.gd client/domain/taxonomy.gd client/domain/taxonomy.gd.uid client/plugins/edit/basic_edit_tools/plugin.gd client/plugins/source/image_sequence_source/plugin.gd client/plugins/source/single_image_source/plugin.gd client/plugins/feedback/file_training_handoff/plugin.gd tests/godot/test_annotation_store.gd tests/godot/test_source_plugin.gd tests/godot/test_single_image_source.gd tests/godot/test_feedback_plugin.gd tests/godot/test_edit_commands.gd tests/godot/test_keyboard_editing.gd tests/godot/test_edit_integration.gd tests/godot/test_model_output_immutability.gd tests/godot/test_model_output_immutability.gd.uid tests/godot/fixtures/integration_plugins/counting_source.gd tests/godot/test_runner.gd
git commit -m "feat: load immutable versioned model output"
```

Before committing, inspect `git diff --cached --name-only` and unstage any client/test file unrelated to the paths listed in this task.

---

### Task 6: 删除旧契约并隔离 Frame Source 辅助 schema

**Files:**
- Create: `core/frame_source/dataset-manifest-v1.schema.json`
- Create: `core/frame_source/fixtures/valid/dataset-manifest.json`
- Create: `core/frame_source/fixtures/invalid/manifest-frame-gap.json`
- Create: `tests/python/test_frame_source_contract.py`
- Create: `tests/python/test_jsonl.py`
- Modify: `python/annotool/contracts.py`
- Delete: `core/schemas/annotation-v1.schema.json`
- Delete: `core/schemas/dataset-manifest-v1.schema.json`
- Delete: `core/schemas/review-state-v1.schema.json`
- Delete: old `core/fixtures/valid/annotation-*.json`
- Delete: old `core/fixtures/invalid/annotation-*.json`
- Delete: `core/fixtures/valid/dataset-manifest.json`
- Delete: `core/fixtures/invalid/manifest-frame-gap.json`
- Delete: `python/validate_annotations.py`
- Delete: `tests/python/test_contracts.py`
- Delete: `client/domain/annotation_validator.gd`
- Delete: `client/domain/annotation_validator.gd.uid`
- Delete: `tests/godot/test_annotation_validator.gd`
- Delete: `tests/godot/test_annotation_validator.gd.uid`

**Interfaces:**
- Consumes: all callers already switched in Tasks 2–5.
- Produces: one-file `core/schemas/` directory for teacher review and an explicit internal path map for the untouched Part 1.3 manifest contract.

- [ ] **Step 1: 先写目录隔离失败测试**

Add to `tests/python/test_part1_1_data_contract.py`:

```python
def test_part1_1_schema_directory_has_only_model_output_v1() -> None:
    schema_files = sorted((ROOT / "core/schemas").glob("*.json"))
    assert [path.name for path in schema_files] == ["model_output_v1.schema.json"]


def test_removed_contract_aliases_do_not_exist() -> None:
    removed = [
        ROOT / "core/schemas/annotation-v1.schema.json",
        ROOT / "core/schemas/review-state-v1.schema.json",
        ROOT / "python/validate_annotations.py",
        ROOT / "client/domain/annotation_validator.gd",
    ]
    assert not [path for path in removed if path.exists()]
```

- [ ] **Step 2: 运行测试并确认旧文件被检出**

Run:

```bash
.venv/bin/python -m pytest tests/python/test_part1_1_data_contract.py -q
```

Expected: exactly the two cleanup tests fail because the old schema/script still exist.

- [ ] **Step 3: 移动 manifest schema/fixtures，不修改其业务内容**

Move the existing files byte-for-byte to:

```text
core/frame_source/dataset-manifest-v1.schema.json
core/frame_source/fixtures/valid/dataset-manifest.json
core/frame_source/fixtures/invalid/manifest-frame-gap.json
```

Replace unrestricted `SCHEMA_DIR / name` lookup in `python/annotool/contracts.py` with an explicit map:

```python
SCHEMA_PATHS = {
    "model_output_v1.schema.json": ROOT / "core/schemas/model_output_v1.schema.json",
    "dataset-manifest-v1.schema.json": ROOT / "core/frame_source/dataset-manifest-v1.schema.json",
}


@lru_cache(maxsize=None)
def load_schema(name: str) -> dict[str, Any]:
    """Load a known contract by logical filename."""
    try:
        path = SCHEMA_PATHS[name]
    except KeyError:
        raise ValueError(f"unknown schema: {name}") from None
    return json.loads(path.read_text(encoding="utf-8"))
```

Delete these annotation-specific objects from `python/annotool/contracts.py` because they encode fields or semantics that are not in the Part 1.1 Schema:

```text
TAXONOMY_PATH
_load_taxonomy_class_kinds
validate_annotation_semantics
_valid_image_size
_valid_box
_box_within_bounds
_valid_vertex
_valid_polygon
_vertex_within_bounds
```

Keep `_is_finite_number()` because `validate_manifest_semantics()` still uses it for the internal Part 1.3 manifest.

- [ ] **Step 4: 把混合的 Python 旧测试拆分为单一职责**

Create `tests/python/test_frame_source_contract.py` containing the current manifest tests, with:

```python
FIXTURES = ROOT / "core/frame_source/fixtures"

def test_valid_manifest_passes_schema_and_semantics() -> None:
    manifest = load(FIXTURES / "valid/dataset-manifest.json")
    assert validate_instance(manifest, "dataset-manifest-v1.schema.json") == []
    assert validate_manifest_semantics(manifest) == []

def test_manifest_frame_gap_is_rejected_semantically() -> None:
    errors = validate_manifest_semantics(load(FIXTURES / "invalid/manifest-frame-gap.json"))
    assert any("frames.1.frame" in error for error in errors)
```

Move these existing test functions byte-for-byte from `tests/python/test_contracts.py` into the new file, changing only `FIXTURES` to the new path:

```text
test_manifest_similarity_scores_must_be_finite_and_match_transitions
test_manifest_semantics_compares_integral_float_frame_count
test_manifest_requires_an_exact_integer_frame_count
test_manifest_schema_rejects_non_relative_image_paths
```

They remain Part 1.3 regression tests; their assertions are not broadened as part of Part 1.1.

Create `tests/python/test_jsonl.py` with the two current helper behaviors written explicitly:

```python
import math
from pathlib import Path

import pytest

from annotool.jsonl import read_jsonl, write_jsonl_atomic


def test_jsonl_round_trip_and_invalid_line_number(tmp_path: Path) -> None:
    path = tmp_path / "records.jsonl"
    records = [{"frame": 0}, {"frame": 1}]
    write_jsonl_atomic(path, records)
    assert read_jsonl(path) == records
    path.write_text('{"frame": 0}\nnot-json\n', encoding="utf-8")
    with pytest.raises(ValueError, match=f"{path}:2:"):
        read_jsonl(path)


def test_jsonl_rejects_non_finite_and_preserves_target(tmp_path: Path) -> None:
    invalid_input = tmp_path / "invalid.jsonl"
    invalid_input.write_text('{"value": Infinity}\n', encoding="utf-8")
    with pytest.raises(ValueError, match="non-finite JSON constant"):
        read_jsonl(invalid_input)
    target = tmp_path / "records.jsonl"
    target.write_text('{"existing": true}\n', encoding="utf-8")
    with pytest.raises(ValueError):
        write_jsonl_atomic(target, [{"value": math.nan}])
    assert target.read_text(encoding="utf-8") == '{"existing": true}\n'
    assert not target.with_suffix(".jsonl.tmp").exists()
```

Delete `tests/python/test_contracts.py` only after the focused manifest and JSONL files pass.

- [ ] **Step 5: 删除已替换的旧文件**

Delete the files listed in this task's **Delete** section. Do not delete the newly created `model-output-v1-*` fixtures. Confirm the only JSON file under `core/schemas/` is the new model schema:

```bash
find core/schemas -maxdepth 1 -type f -name '*.json' -printf '%f\n' | sort
```

Expected:

```text
model_output_v1.schema.json
```

- [ ] **Step 6: 扫描代码和测试中的旧引用**

Run:

```bash
rg -n "annotation-v1|annotation_validator|validate_annotations|model_output\.jsonl|human_corrected" python client tests core
```

Expected: no matches. `model_output_v1.jsonl` does not match the escaped unversioned filename pattern.

- [ ] **Step 7: 运行全部自动化测试**

Run:

```bash
.venv/bin/python -m pytest tests/python -q
"$GODOT_BIN" --headless --path . --script tests/godot/test_runner.gd
```

Expected: Python retains all non-Part-1.1 coverage and passes; Godot exits 0 with final PASS line.

- [ ] **Step 8: 提交清理和目录隔离**

```bash
git add core/frame_source python/annotool/contracts.py tests/python/test_frame_source_contract.py tests/python/test_jsonl.py tests/python/test_part1_1_data_contract.py
git add -u -- core/schemas core/fixtures python/validate_annotations.py tests/python/test_contracts.py client/domain/annotation_validator.gd client/domain/annotation_validator.gd.uid tests/godot/test_annotation_validator.gd tests/godot/test_annotation_validator.gd.uid
git commit -m "refactor: remove obsolete annotation contract"
```

Inspect the staged list before committing so no unrelated dirty-worktree files are included.

---

### Task 7: 更新中文文档、实现报告并执行 Part 1.1 最终门禁

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/plugin-api.md`
- Modify: `docs/requirements-traceability.md`
- Modify: `docs/part1-implementation-report.md`
- Modify: `docs/superpowers/specs/2026-09-03-automated-annotation-system-design.md`
- Modify: `docs/superpowers/plans/2026-09-03-automated-annotation-system-implementation.md`
- Modify: `docs/superpowers/specs/2026-09-03-dataset-explorer-mitk-toolbar-design.md`
- Modify: `docs/superpowers/plans/2026-09-03-dataset-explorer-mitk-toolbar.md`
- Modify: `tests/python/test_documentation.py`
- Do not modify: `docs/Project_6_Automated_Annotation_System_Assignment.md`

**Interfaces:**
- Consumes: tested file names, commands, functions and outputs from Tasks 1–6.
- Produces: teacher-facing Chinese implementation report and executable reviewer runbook with no obsolete contract claims.

- [ ] **Step 1: 先改文档测试为新命令和语义**

In `tests/python/test_documentation.py`, replace old validator commands with:

```python
for command in (
    "python/make_sample_input.py --output sample/assignment_v1 --seed 6006",
    "python/validate_model_output.py sample/assignment_v1/model_output_v1.jsonl",
    ".venv/bin/python -m pytest tests/python -q",
    "tests/godot/test_runner.gd",
):
    assert command in readme
```

Add a dedicated Part 1.1 documentation test:

```python
def test_part1_1_documents_match_the_implemented_contract() -> None:
    text = "\n".join(
        [
            _read("README.md"),
            _read("docs/architecture.md"),
            _read("docs/plugin-api.md"),
            _read("docs/requirements-traceability.md"),
            _read("docs/part1-implementation-report.md"),
        ]
    ).lower()
    for required in (
        "core/schemas/model_output_v1.schema.json",
        "python/validate_model_output.py",
        "client/domain/model_output_validator.gd",
        "model_output_v1.jsonl",
        "sample_v1",
        "sha-256",
    ):
        assert required.lower() in text
    for removed_claim in (
        "core/schemas/annotation-v1.schema.json",
        "python/validate_annotations.py",
        "source = human_corrected",
    ):
        assert removed_claim not in text
```

- [ ] **Step 2: 运行文档测试并确认旧文档失败**

Run:

```bash
.venv/bin/python -m pytest tests/python/test_documentation.py -q
```

Expected: FAIL because active documents still contain old filenames/semantics.

- [ ] **Step 3: 更新 README 审查命令与契约说明**

The reviewer path must contain:

```bash
.venv/bin/python python/make_sample_input.py --output sample/assignment_v1 --seed 6006
.venv/bin/python python/validate_model_output.py sample/assignment_v1/model_output_v1.jsonl
```

Explain in Chinese that `source: sample_v1` identifies the frame source, while `model_output_v1` names the contract/model-output file version. Remove the public manifest-validator command because `validate_model_output.py` validates only Part 1.1 model records; manifest validation remains an internal Part 1.3 concern.

- [ ] **Step 4: 更新架构和插件 API 文档**

The architecture ownership table must point to:

```text
core/schemas/model_output_v1.schema.json          Part 1.1 model output
python/validate_model_output.py                   standalone Python validator
client/domain/model_output_validator.gd           Godot adapter
core/frame_source/dataset-manifest-v1.schema.json internal Frame Source contract
```

Document these boundaries:

- Source reads `<manifest.model_version>.jsonl` only when the version is `model_output_vX` and v1 is supported.
- model records are immutable deep copies; corrected working state is separate.
- `source` remains the image/video/frame-sequence identity during correction/export.
- `filled` is transient UI display state and is removed at the model-output validation/snapshot boundary.
- Feedback never rewrites the original model JSONL.

- [ ] **Step 5: 重写实现报告的 Part 1.1 章节**

In `docs/part1-implementation-report.md`, keep the report scope tied to teacher Part 1, but replace the full Part 1.1 chapter with evidence from the real implementation:

1. 老师原文到 Schema 字段的逐项映射；
2. `model_output_v1.schema.json` 中 `required`、`anyOf`、`conf`、`track_id` 的真实代码段；
3. `validate_model_output.py` 的 `load_schema`、`validate_record`、`validate_model_output`、`main` 职责和实际错误输出；
4. `model_output_validator.gd::validate_record()` 如何返回路径化错误而不崩溃；
5. Source 如何从 `model_output_v1` 推导 `model_output_v1.jsonl`；
6. AnnotationStore 如何 deep-copy model/corrected records；
7. SHA-256 测试如何证明加载、编辑、导出后原文件不变；
8. Python/Godot 共享 fixture 列表、测试命令和实测结果。

Do not present dataset manifest or review state as Part 1.1 schemas. Do not claim v2 support or a migration tool exists.

- [ ] **Step 6: 更新追踪表和历史设计/计划中的冲突文本**

Mark Part 1.1 PASS only when both runtime test suites have passed. Replace obsolete positive claims in active project documents:

```text
annotation-v1.schema.json  -> model_output_v1.schema.json
model_output.jsonl         -> model_output_v1.jsonl
record source model_output_v1 -> record source sample_v1 or the actual frame source
source human_corrected     -> preserve original frame source
exactly one geometry       -> box and/or polygon
```

Do not alter the approved Part 1.1 spec's historical-removal examples or the teacher Assignment. Update dataset-explorer design/plan examples only where they name the old unversioned model file.

- [ ] **Step 7: 执行旧语义文档扫描**

Run:

```bash
rg -n "annotation-v1\.schema|python/validate_annotations\.py|human_corrected|model_output\.jsonl" README.md docs --glob '!Project_6_Automated_Annotation_System_Assignment.md' --glob '!2026-09-03-part1-1-model-output-contract-design.md' --glob '!2026-09-03-part1-1-model-output-contract-implementation.md'
```

Expected: no matches. The two excluded approved documents intentionally describe names that must be removed and therefore are not stale implementation claims.

- [ ] **Step 8: 执行最终 Part 1.1 验收链**

Run from repository root:

```bash
jq empty core/schemas/model_output_v1.schema.json
.venv/bin/python -m pytest tests/python -q
"$GODOT_BIN" --headless --path . --script tests/godot/test_runner.gd
review_root="$(mktemp -d /tmp/annotool-part1-1-review-XXXXXX)"
.venv/bin/python python/make_sample_input.py --output "$review_root/assignment_v1" --seed 6006
.venv/bin/python python/validate_model_output.py "$review_root/assignment_v1/model_output_v1.jsonl"
find core/schemas -maxdepth 1 -type f -name '*.json' -printf '%f\n' | sort
```

Expected:

- Schema parses;
- Python suite passes (FFmpeg skips are not accepted as video-environment evidence, but do not invalidate the Part 1.1-only checks);
- Godot suite exits 0 and prints `PASS: complete Godot test suite`;
- generator prints `Validation errors: 0`;
- standalone validator prints `Validation errors: 0`;
- schema listing contains only `model_output_v1.schema.json`;
- immutability test reports no hash difference;
- generated sample contains no unversioned `model_output.jsonl`.

- [ ] **Step 9: 检查实际 diff 并提交文档**

```bash
git diff --check
git status --short
git add README.md docs/architecture.md docs/plugin-api.md docs/requirements-traceability.md docs/part1-implementation-report.md docs/superpowers/specs/2026-09-03-automated-annotation-system-design.md docs/superpowers/plans/2026-09-03-automated-annotation-system-implementation.md docs/superpowers/specs/2026-09-03-dataset-explorer-mitk-toolbar-design.md docs/superpowers/plans/2026-09-03-dataset-explorer-mitk-toolbar.md tests/python/test_documentation.py
git diff --cached --check
git commit -m "docs: document completed part 1.1 contract"
```

Before the commit, compare the staged paths with this task's Files list and unstage every unrelated pre-existing user change.

## 最终交付检查表

- [ ] `core/schemas/` 中唯一 JSON 为 `model_output_v1.schema.json`。
- [ ] 老师示例通过 Python 和 Godot。
- [ ] box-only、polygon-only、box+polygon 通过，两者都无时拒绝。
- [ ] `dataset_id`、`image_size`、`filled` 不属于 model-output Schema。
- [ ] `source` 保留帧来源语义，样例为 `sample_v1`。
- [ ] Python validator 可独立运行，失败信息有 record/行号与字段路径，不有 traceback。
- [ ] Godot malformed Variant 只返回错误，不中断测试或 UI。
- [ ] sample 只产出 `model_output_v1.jsonl`，manifest 声明 `model_output_v1`。
- [ ] Source 不读取 `model_output.jsonl`，不用 v1 Schema 默默接受 v2。
- [ ] model/corrected 内存状态分离，所有 getter 为 deep copy。
- [ ] 加载、编辑、导出前后 `model_output_v1.jsonl` SHA-256 相同。
- [ ] 旧 schema、validator、fixture 和无版本文件名已删除，无兼容别名。
- [ ] README、架构、插件 API、追踪表和实现报告与真实代码一致。
- [ ] Python 与 Godot 完整测试套件通过。
