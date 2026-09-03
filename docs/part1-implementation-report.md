# Part 1.1 数据契约具体实现报告

## 1. 报告范围

本报告严格限定在老师 Assignment 的 Part 1.1，不把 Part 1.2 的样本生成、Part 1.3 的帧源清单、Part 1.4 的插件流水线或后续审核流程算作数据契约交付物。

Part 1.1 的两项要求是：

1. 提供 JSON Schema，以及 Python 和客户端都能使用的验证器；错误记录必须被清楚拒绝，界面不得崩溃。
2. 对契约进行版本管理；原始模型输出必须不可变，并使用 `model_output_vX` 形式进行版本化。

当前实现版本是 V1，唯一权威 Schema 为：

`core/schemas/model_output_v1.schema.json`

## 2. Assignment 到实现的逐项映射

| 老师要求 | 当前实现 | 主要证据 |
|---|---|---|
| 每张图像一条标注记录 | JSON/JSONL 中每条对象对应一个 `frame` | Assignment 示例 fixture、逐行验证测试 |
| 图像/帧 ID，包含来源和索引 | `source` + `frame` | Schema 顶层必填字段 |
| 可选时间戳 | 可选 `time_s` | Schema 非必填、非负数 |
| 区域列表 | `regions` 数组 | Schema 必填字段 |
| 区域 ID、类别、种类 | `id`、`class`、`kind` | 每个 region 必填 |
| box 和/或 polygon | `anyOf` 至少要求其一，也允许二者同时存在 | Assignment 原例可直接通过 |
| 可选 confidence | `conf`，范围 0–1 | Schema 与两端验证器 |
| 可选 track/instance ID | `track_id`，字符串或 `null` | Schema 与两端验证器 |
| Python 可用验证器 | `python/validate_model_output.py` | 可导入 API + 独立 CLI |
| 客户端可用验证器 | `client/domain/model_output_validator.gd` | GDScript 返回错误数组 |
| 清楚拒绝，不崩溃 | 字段路径错误；读取/解析错误转成返回值 | Python/Godot 负例测试 |
| 版本化 `model_output_vX` | V1 Schema、V1 JSONL、`schema_version: 1` | 命名与 Source 选择测试 |
| 模型输出不可变 | 文件 SHA-256 前后不变；Store 分离模型基线与修正副本 | Python 和 Godot 测试 |

## 3. Schema 的来源与设计

### 3.1 来源

Schema 不是从第三方数据集或项目内部旧设计推导出来的。字段集合直接来自老师 Part 1.1 的文字和示例。实现时采用以下优先级：

1. 老师 Assignment 的明确文字；
2. 老师给出的 JSON 示例；
3. 仅在前两项未规定时，使用保证 JSON 可验证和错误可读的最小约束。

因此没有把项目内部的 `dataset_id`、`image_size`、`filled`、审核状态或数据清单字段加入模型输出 Schema。

### 3.2 Schema 文件

文件：`core/schemas/model_output_v1.schema.json`

顶层定义的真实代码：

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "model_output_v1.schema.json",
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
  }
}
```

区域定义的关键部分：

```json
{
  "required": ["id", "class", "kind"],
  "properties": {
    "id": {"type": "string", "minLength": 1},
    "class": {"type": "string", "minLength": 1},
    "kind": {"type": "string", "minLength": 1},
    "box": {"type": "array", "minItems": 4},
    "polygon": {"type": "array", "minItems": 3},
    "conf": {"type": "number", "minimum": 0, "maximum": 1},
    "track_id": {"type": ["string", "null"]}
  },
  "anyOf": [
    {"required": ["box"]},
    {"required": ["polygon"]}
  ]
}
```

`anyOf` 的含义是 box、polygon 或二者同时存在都合法。这一点与老师示例中第一个 region 同时具有两种几何完全一致。

`kind` 只要求非空字符串。Assignment 中的 `region`、`anatomy`、`instrument` 是示例而不是封闭枚举，所以没有擅自禁止后续合法种类。

### 3.3 V1 的完整字段规则

| 路径 | 是否必填 | 规则 |
|---|---|---|
| `schema_version` | 是 | 必须是整数 `1` |
| `source` | 是 | 非空字符串，表示图像/帧来源 |
| `frame` | 是 | 非负整数 |
| `time_s` | 否 | 非负有限数 |
| `regions` | 是 | 数组，可以为空 |
| `regions[].id` | 是 | 非空字符串 |
| `regions[].class` | 是 | 非空字符串 |
| `regions[].kind` | 是 | 非空字符串 |
| `regions[].box` | 二选一或同时 | `[x, y, w, h]`；x/y 非负，w/h 为正 |
| `regions[].polygon` | 二选一或同时 | 至少三个 `[x, y]` 顶点，坐标非负 |
| `regions[].conf` | 否 | 0–1 的有限数 |
| `regions[].track_id` | 否 | 字符串或 `null` |

所有层级都拒绝未知字段，从而尽早发现模型输出拼写错误或其他模块字段泄漏。

## 4. Python 验证器

### 4.1 独立脚本

文件：`python/validate_model_output.py`

该脚本与 Schema 分开，职责清楚：

- Schema 文件只声明数据格式；
- 脚本负责加载 JSON/JSONL、调用校验、格式化错误和设置退出码；
- 既可以独立运行，也可以由其他 Python 代码导入。

公开函数：

| 函数 | 用途 |
|---|---|
| `load_schema()` | 加载唯一的 Model Output V1 Schema |
| `validate_record(record)` | 返回单条记录的字段级错误 |
| `validate_model_output(path)` | 校验 JSON 或 JSONL 文件 |
| `parse_args(argv)` | 解析命令行参数 |
| `main(argv)` | 输出结果并返回 0/1 |

真实入口代码：

```python
def validate_record(record: object) -> list[str]:
    """返回带字段路径的错误；空列表表示通过。"""
    return validate_instance(record, SCHEMA_NAME)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    errors = validate_model_output(args.path)
    if errors:
        for error in errors:
            print(error)
        return 1
    print("Validation errors: 0")
    return 0
```

### 4.2 严格 JSON 类型

文件：`python/annotool/contracts.py`

这里使用 Draft 2020-12，并重新定义 JSON 数字检查：

```python
StrictDraft202012Validator = extend(
    Draft202012Validator,
    type_checker=(
        Draft202012Validator.TYPE_CHECKER
        .redefine("integer", _is_exact_integer)
        .redefine("number", _is_finite_json_number)
    ),
)
```

这样可以避免 Python 的 `bool` 被当成整数，并拒绝 `NaN`、`Infinity` 和 `-Infinity`。错误经过 `_validation_error_path()` 处理，必填字段和未知字段会指向真实路径，例如：

```text
record 1: regions.0.class: 'class' is a required property [required]
```

### 4.3 不崩溃行为

`validate_model_output(path)` 捕获文件读取、JSON 解析和非有限数错误，将它们转为字符串列表。CLI 对错误返回状态码 1，不打印 Python traceback；合法输入返回 0 并输出：

```text
Validation errors: 0
```

## 5. Godot 客户端验证器

文件：`client/domain/model_output_validator.gd`

主接口：

```gdscript
func validate_record(record: Variant) -> PackedStringArray:
    var errors := PackedStringArray()
    if not record is Dictionary:
        errors.append("$: expected object, got %s" % type_string(typeof(record)))
        return errors
    # 继续检查字段、类型、几何和范围
    return errors
```

实现把错误作为 `PackedStringArray` 返回，不使用断言处理用户数据，也不让预期内格式错误变成未捕获异常。调用方先检查错误数组；只有空数组才安装新数据。

主要内部函数：

| 函数 | 检查内容 |
|---|---|
| `validate_record()` | 顶层字段、版本、来源、帧、时间和 regions |
| `_validate_region()` | 区域必填字段、未知字段、几何存在性、conf、track_id |
| `_validate_box()` | 四个数及坐标/尺寸范围 |
| `_validate_polygon()` | 顶点数量、二维形状和坐标范围 |
| `_is_json_integer()` | JSON 逻辑整数 |
| `_is_finite_number()` | 有限整数或浮点数 |

Godot 测试直接读取与 Python 相同的 `core/fixtures/valid` 和 `core/fixtures/invalid`，并额外验证 Assignment 原例、box+polygon 同时存在、开放 `kind` 和错误字段路径。

## 6. 版本管理

V1 使用三处一致标识：

| 层级 | V1 值 |
|---|---|
| Schema 文件 | `model_output_v1.schema.json` |
| 模型输出文件 | `model_output_v1.jsonl` |
| 记录内容 | `"schema_version": 1` |

通用版本前缀固定为 `model_output_v`。当前代码只实现 V1，不声称已经实现其他版本或迁移工具。

`source` 不承担版本职责。例如：

```json
{
  "schema_version": 1,
  "source": "sample_v1",
  "frame": 128,
  "regions": []
}
```

其中 `sample_v1` 是帧源身份，不是 Schema 或模型版本。

样本生成器 `python/annotool/sample.py` 明确定义：

```python
MODEL_VERSION = "model_output_v1"
```

并使用：

```python
annotation_path = output_dir / f"{MODEL_VERSION}.jsonl"
```

因此不会再生成无版本前缀的模型输出文件。

目录 Source 从内部帧源清单的 `model_version` 推导文件名；V1 只读取 `model_output_v1.jsonl`。帧源清单只是帮助 Source 定位文件，不属于 Part 1.1 的 Schema。

## 7. 不可变模型输出

不可变性在文件层和客户端状态层分别实现。

### 7.1 文件层

`python/validate_model_output.py` 只读取输入文件，从不写回。Python 测试在验证前后计算同一文件的 SHA-256，并要求完全一致。

样本生成器也把 `model_output_v1.jsonl` 的 SHA-256 写入 `hashes.json`，便于复核生成产物。

### 7.2 客户端状态层

文件：`client/domain/annotation_store.gd`

加载成功后建立两个深拷贝容器：

```gdscript
_model_records = next_model
_corrected_records = next_model.duplicate(true)
```

- `_model_records` 是原始模型基线；
- `_corrected_records` 是人工修改的工作副本；
- `get_model_record()`、`get_corrected_record()` 和 `snapshot_corrected()` 都返回深拷贝；
- `replace_corrected_record()` 只更新修正容器；
- 加载或替换验证失败时，原状态不变。

`model_digest()` 对规范化模型基线计算 SHA-256：

```gdscript
func model_digest() -> String:
    var canonical_records: Array = _canonicalize(
        _sorted_record_copies(_model_records)
    )
    return JSON.stringify(canonical_records).sha256_text()
```

测试覆盖三种攻击面：修改 getter 返回值、修改嵌套 box、编辑 corrected record。三者都不能改变模型记录或 `model_digest()`。

### 7.3 UI 临时字段隔离

`filled` 是界面显示状态，不属于老师的模型输出字段。Store 的 `_model_output_projection()` 在验证修正记录和生成规范快照时删除它。这样 UI 可以保留显示能力，同时输出仍严格满足 Model Output V1。

导出插件保留 `source`，并由调用方提供与模型基线分开的输出路径。当前 Part 1 界面没有启用该导出入口；Part 1.1 自身只有读取和验证路径，不会重写 `model_output_v1.jsonl`。

## 8. 共享样例与测试

### 8.1 Assignment 原例

`core/fixtures/valid/assignment-model-output-v1.json` 保存老师示例的标准 JSON 形式，包括：

- `source: "sample_v1"`；
- `frame: 128`；
- 第一个区域同时包含 box 和 polygon；
- `conf`；
- 字符串和 `null` 两种 `track_id`。

Python 测试先断言 fixture 内容与老师示例逐字段一致，再断言验证通过。

### 8.2 合法样例

- `core/fixtures/valid/model-output-v1-box-only.json`
- `core/fixtures/valid/model-output-v1-polygon-only.json`
- `core/fixtures/valid/model-output-v1-empty-regions.json`

### 8.3 非法样例

`core/fixtures/invalid/` 中以 `model-output-v1-` 开头的文件覆盖：

- 缺少必填字段；
- 未提供任何几何；
- box 长度或尺寸错误；
- polygon 顶点数量或形状错误；
- confidence 越界；
- 非法 track ID；
- 空字符串；
- 未知顶层或 region 字段。

### 8.4 自动化测试文件

| 文件 | 重点 |
|---|---|
| `tests/python/test_part1_1_data_contract.py` | Schema、Assignment 原例、字段路径、JSONL、非有限数、CLI、不改文件、唯一 Schema |
| `tests/python/test_sample.py` | 生成文件名、`sample_v1` 来源、V1 清单引用、哈希 |
| `tests/godot/test_model_output_validator.gd` | 客户端等价校验与共享 fixtures |
| `tests/godot/test_annotation_store.gd` | 深拷贝、事务加载、模型摘要不变、临时字段隔离 |
| `tests/godot/test_source_plugin.gd` | 版本化文件选择、来源对齐、错误恢复 |
| `tests/godot/test_feedback_plugin.gd` | 来源保留、独立导出、原子发布 |

2026-09-04 最终门禁的实际结果：

```text
Python：74 passed，0 skipped
Godot：PASS: complete Godot test suite
样本生成：Validation errors: 0
独立验证：Validation errors: 0
core/schemas：仅 model_output_v1.schema.json
生成目录：包含 model_output_v1.jsonl，不含无版本文件
```

## 9. 错误处理示例

| 错误 | 行为 |
|---|---|
| 缺少 `class` | 返回 `regions.0.class` 路径 |
| 多条 JSONL 的第二条错误 | 加上 `record 1` 前缀 |
| 文件 JSON 损坏 | 返回包含文件路径的解析错误，CLI 状态码 1 |
| `NaN` 或 `Infinity` | 明确拒绝非有限 JSON 常量 |
| Godot 收到非 Dictionary | 返回根路径 `$` 错误 |
| Source 收到错误 V1 文件 | 不安装候选数据，保留此前有效数据 |
| corrected replacement 不合法 | 不写入 Store，不产生半更新状态 |

## 10. 复现方法

从仓库根目录运行：

```bash
.venv/bin/python python/make_sample_input.py --output sample/assignment_v1 --seed 6006
.venv/bin/python python/validate_model_output.py sample/assignment_v1/model_output_v1.jsonl
.venv/bin/python -m pytest tests/python -q
"$GODOT_BIN" --headless --path . --script tests/godot/test_runner.gd
```

独立验证器的成功输出必须是：

```text
Validation errors: 0
```

还应确认：

```bash
find core/schemas -maxdepth 1 -type f -printf '%f\n'
find sample/assignment_v1 -maxdepth 1 -type f -printf '%f\n'
```

前者应只列出 `model_output_v1.schema.json`；后者必须包含 `model_output_v1.jsonl`，不得生成无版本名称。

## 11. 修改导航

如果要修改 Schema，先改：

`core/schemas/model_output_v1.schema.json`

然后同步检查：

1. `python/validate_model_output.py`；
2. `python/annotool/contracts.py`；
3. `client/domain/model_output_validator.gd`；
4. `core/fixtures/valid/` 和 `core/fixtures/invalid/`；
5. Python 与 Godot 的 Part 1.1 测试；
6. 模型生产方和 Source 消费方。

如果要增加或修改“数据是否合法”的审查条件，结构性规则优先写入 Schema，并同步 Godot 验证器。只有 JSON Schema 无法表达的运行时边界才放在消费模块中。

如果要增加“人工审核流程”的条件，例如 verified、批量传播或自动跳帧，应修改后续独立审核模块，不能把这些字段加入 Part 1.1 模型输出 Schema。

## 12. 结论

Part 1.1 已形成一个边界明确的模块：

- 一个且只有一个 Model Output V1 JSON Schema；
- 一个可导入、可独立运行的 Python 验证脚本；
- 一个不会因格式错误导致界面崩溃的 Godot 验证器；
- 与老师示例一致的 box 和/或 polygon 行为；
- `model_output_v1.schema.json`、`model_output_v1.jsonl`、`schema_version: 1` 三层一致版本标识；
- 文件 SHA-256 与客户端双 Store 共同保证模型输出不可变；
- 共享 fixtures 和双端测试防止 Python/Godot 规则漂移。

数据清单、审核状态、UI 临时字段和训练交接都被明确排除在 Part 1.1 Schema 外，避免再次混淆老师要求与项目内部设计。
