# Part 1.1 模型输出数据契约修正设计

> 状态：已确认；尚未进入实现。

## 1. 设计目的

本设计只处理老师 Assignment 的 **Part 1.1 Data contract**，不根据现有项目总设计规范推导额外字段，也不提前实现 Part 2–5 的数据结构。

实施每个步骤前必须重新查看：

`docs/Project_6_Automated_Annotation_System_Assignment.md`

如果现有代码、旧设计文档或测试与 Assignment 冲突，以 Assignment 为准。

## 2. 老师要求

Part 1.1 要求定义一个经过 JSON Schema 校验的 per-image annotation record，最低包含：

- image/frame id，由 source 和 frame index 表示；
- 可选 timestamp；
- regions 数组；
- 每个 region 的 id、class label、kind；
- 2D extent：box and/or polygon；
- 可选 confidence；
- 可选 track/instance id。

同时必须：

1. 提交 JSON Schema；
2. 提交可供客户端和 Python 使用的 validator；
3. malformed record 返回清晰错误，不能使 UI 崩溃；
4. 对 contract 进行版本管理；
5. 原始模型输出保持不可变；
6. 模型输出使用 `model_output_vX` 版本格式。

## 3. 范围

### 3.1 本设计包含

- `model_output_v1.schema.json`；
- 老师示例对应的有效 fixture；
- 独立 Python validator；
- Godot 客户端 validator；
- 两端共享 fixture 的一致性测试；
- `model_output_vX.jsonl` 文件命名和选择规则；
- 原始模型输出不可变规则与测试；
- 与 Part 1.1 直接冲突的现有代码和文档修正。

### 3.2 本设计不包含

- dataset manifest 的业务设计；
- review state、verified 或 batch marker；
- Region Display 和 MITK 编辑功能；
- 相似帧批量传播；
- 自动保存；
- diff report；
- 完整 training handoff package；
- v1 到 v2 的迁移器。

这些内容只有在执行到 Assignment 对应部分时，重新回看老师要求后再设计。

## 4. 命名与语义

### 4.1 Schema 文件

Part 1.1 的唯一老师要求 Schema 为：

```text
core/schemas/model_output_v1.schema.json
```

不再使用 `annotation-v1.schema.json` 名称。

### 4.2 模型输出文件

模型输出必须使用：

```text
model_output_v1.jsonl
model_output_v2.jsonl
model_output_v3.jsonl
...
```

所有后续模型版本都必须以 `model_output_v` 为前缀，后接从 1 开始的十进制整数。

### 4.3 三种不同含义

| 名称 | 含义 | 示例 |
|---|---|---|
| `schema_version` | 当前 record 遵循的数据契约版本 | `1` |
| `source` | 图像、视频或帧序列来源 | `sample_v1` |
| `model_output_vX` | 模型输出文件版本 | `model_output_v1.jsonl` |

`source` 不得再用来表示模型版本，也不得改成 `human_corrected`。

### 4.4 X 的一致性

`model_output_vX` 中的 X 同时标识这份模型输出所遵循的 contract 版本：

| Schema | 数据文件 | record 内部版本 |
|---|---|---|
| `model_output_v1.schema.json` | `model_output_v1.jsonl` | `"schema_version": 1` |
| `model_output_v2.schema.json` | `model_output_v2.jsonl` | `"schema_version": 2` |

本次只实现第一行。加载器不能用 v1 Schema 默默接受标成 v2 的文件，也不能通过改文件名伪造版本升级。

## 5. Model Output V1 Schema

### 5.1 顶层字段

| 字段 | 必需 | 规则 | 来源 |
|---|---:|---|---|
| `schema_version` | 是 | 必须为整数 `1` | Assignment 示例与 contract version 要求 |
| `source` | 是 | 非空字符串 | Assignment 的 source + frame id |
| `frame` | 是 | 从 0 开始的非负整数 | Assignment 的 frame index |
| `time_s` | 否 | 非负有限数 | Assignment 的 optional timestamp |
| `regions` | 是 | region 数组，可以为空 | Assignment 的 list of regions |

顶层不包含：

- `dataset_id`；
- `image_size`；
- 人工状态字段；
- manifest 字段。

### 5.2 Region 字段

| 字段 | 必需 | 规则 | 来源 |
|---|---:|---|---|
| `id` | 是 | 非空字符串 | Assignment |
| `class` | 是 | 非空字符串 | Assignment |
| `kind` | 是 | 非空字符串；当前示例值为 `region`、`anatomy`、`instrument` | Assignment 使用“e.g.”列举示例，未要求封闭枚举 |
| `box` | 条件必需 | `[x, y, width, height]` | Assignment 示例 |
| `polygon` | 条件必需 | 至少三个 `[x, y]` 顶点 | Assignment 示例 |
| `conf` | 否 | 0–1 的有限数 | Assignment optional confidence |
| `track_id` | 否 | string 或 null | Assignment optional track/instance id |

region 不包含 `filled`。

### 5.3 Geometry 规则

“box and/or polygon”解释为：

- 只有 box：有效；
- 只有 polygon：有效；
- 同时有 box 和 polygon：有效；
- 两者都没有：无效。

因此使用 JSON Schema `anyOf`，不使用 `oneOf`。

box 中：

- x、y 是非负数；
- width、height 必须大于 0；
- 数组必须恰好四项。

polygon 中：

- 至少三个顶点；
- 每个顶点必须恰好包含 x、y 两个非负数。

Assignment record 没有 image size，因此 Part 1.1 Schema 不负责判断 geometry 是否超过图像右边界或下边界。需要图像尺寸的检查应在后续相关功能中结合 Frame Source 上下文重新设计。

### 5.4 完整 Schema

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

## 6. Assignment 示例 Fixture

老师提供的 JSONC 示例去掉注释后，保存为：

```text
core/fixtures/valid/assignment-model-output-v1.json
```

内容字段和值保持与 Assignment 一致。该 fixture 必须同时通过 Python 和 Godot validator。

另外保留最小 box-only、polygon-only 和 empty-regions 有效 fixture，用来验证 “and/or” 和空检测结果。

无效 fixtures 至少覆盖：

- 缺少 `schema_version`；
- 不支持的 schema version；
- 缺少 `source`；
- 缺少 `frame`；
- frame 为负数或非整数；
- 缺少 `regions`；
- region 缺少 id/class/kind；
- id/class/kind 为空字符串；
- box 和 polygon 都不存在；
- box 长度错误或宽高非正；
- polygon 少于三个点或顶点格式错误；
- conf 不在 0–1；
- track_id 不是 string/null；
- 未声明字段。

旧的 `annotation-*` fixtures 是围绕错误的 annotation schema 建立的，实施时直接删除并换成 `model-output-v1-*` fixtures，不保留双套契约。

## 7. 独立 Python Validator

文件：

```text
python/validate_model_output.py
```

该脚本是 Part 1.1 的独立命令行验证器。它直接读取 `model_output_v1.schema.json`，不把 schema 规则复制进脚本。

旧的 `python/validate_annotations.py` 在所有调用点替换完成后删除，不保留一个指向新脚本的兼容别名。

公开函数：

```python
load_schema() -> dict
validate_record(record: object) -> list[str]
validate_model_output(path: Path) -> list[str]
main(argv: Sequence[str] | None = None) -> int
```

行为：

- 接受一个 JSON record 或 JSONL 文件；
- JSONL 每个非空行是一条 per-image record；
- 错误包含 record index 和字段路径；
- malformed JSON 返回清晰错误；
- NaN 和 Infinity 被拒绝；
- 全部记录通过时返回 0；
- 任一记录失败时返回 1；
- 不输出 Python traceback；
- 关键实现处使用简短中文注释。

独立运行方式：

```bash
.venv/bin/python python/validate_model_output.py \
  sample/assignment_v1/model_output_v1.jsonl
```

## 8. Godot Client Validator

文件：

```text
client/domain/model_output_validator.gd
```

Godot validator 为客户端原生验证入口，不能要求 UI 每次编辑时同步启动 Python 进程。

公共入口保持：

```gdscript
func validate_record(record: Variant) -> PackedStringArray
```

规则必须与 `model_output_v1.schema.json` 一致：

- 删除 dataset_id、image_size 和 filled 的必需/允许规则；
- source 只要求非空字符串；
- 同时存在 box 和 polygon 时通过；
- 两者都不存在时拒绝；
- 所有错误返回字段路径；
- malformed Variant 不抛出导致 UI 退出的异常。

Python 和 Godot 分别实现运行时 adapter，但共享同一批 fixtures。两端对每个 valid/invalid fixture 必须得到一致的通过/拒绝结果。

旧的 `client/domain/annotation_validator.gd` 在引用全部替换后删除，不同时维护两个名称不同的 validator。

## 9. 模型输出版本管理

### 9.1 v1

样例生成器输出：

```text
model_output_v1.jsonl
```

不再输出或读取：

```text
model_output.jsonl
```

### 9.2 后续版本

所有后续模型输出使用正则语义：

```text
^model_output_v[1-9][0-9]*\.jsonl$
```

示例：

```text
model_output_v2.jsonl
model_output_v10.jsonl
```

不得使用：

```text
model-v2.jsonl
real-model-v2.jsonl
model_output.jsonl
model_output_v01.jsonl
```

### 9.3 Schema 升级

`model_output_v1.schema.json` 发布后冻结。破坏兼容的数据结构修改必须新增带 `model_output_v` 前缀的下一版 Schema，不覆盖 v1。

本任务只实现和支持 v1，不提前实现 v2 migration。

## 10. 原始模型输出不可变

客户端加载 `model_output_v1.jsonl` 后：

1. 文件只读；
2. 内存 model records 与 corrected working records 分开；
3. 所有 getter 返回 deep copy；
4. 编辑只写 corrected store；
5. corrected export 使用不同文件路径；
6. validator、编辑和导出都不得覆盖、重命名或删除原模型输出。

自动化测试在加载前记录 `model_output_v1.jsonl` 的 SHA-256，在读取、内存编辑和 corrected export 后再次计算，前后必须一致。

corrected record 保留原始 `source`。不再执行：

```text
source = human_corrected
```

模型输出与人工修正状态通过文件角色和 store ownership 区分，不复用 `source` 字段。

## 11. 辅助 Schema 的处理

`dataset-manifest-v1.schema.json` 不是老师 Part 1.1 要求的 per-image model output schema。实施时将它从主 Schema 目录移到数据源自己的内部位置：

```text
core/frame_source/dataset-manifest-v1.schema.json
```

同时只修正现有 Part 1.3 代码的引用路径，不在 Part 1.1 中重新设计 manifest 字段。等执行 Part 1.3 时再重新对照 Assignment。

`review-state-v1.schema.json` 不属于 Part 1.1，且当前还没有对应的已实现持久化模块。实施时删除该文件及 Part 1.1 文档中对它的完成声明，后续到老师要求审查状态的部分时再重新设计。

老师审查 Part 1.1 时，唯一主 Schema 是：

```text
core/schemas/model_output_v1.schema.json
```

## 12. 测试设计

### 12.1 Python

新建或整理：

```text
tests/python/test_part1_1_data_contract.py
```

必须验证：

- Assignment 示例通过；
- box-only、polygon-only、box+polygon 都通过；
- 两种 geometry 都没有时失败；
- 所有必需/可选字段规则；
- schema version 1 通过，其他版本失败；
- `source: sample_v1` 通过；
- malformed JSON/JSONL 给出字段或行号；
- CLI 成功返回 0、失败返回 1且无 traceback；
- `model_output_v1.jsonl` 文件命名；
- 不再生成 `model_output.jsonl`；
- 模型文件 hash 在验证后不变。

### 12.2 Godot

整理：

```text
tests/godot/test_model_output_validator.gd
```

必须验证：

- 与 Python 读取同一批 fixtures；
- Assignment 示例通过；
- malformed Variant 返回错误而不崩溃；
- source、geometry 和版本规则与 Schema 一致；
- model/corrected store 分离；
- getter 的 deep copy 不影响内部 model truth。

### 12.3 集成

更新 sample 和 Source tests，验证：

- sample 只生成 `model_output_v1.jsonl`；
- Source 根据明确版本加载该文件；
- 后续 `model_output_v2.jsonl` 命名能够被识别为合法版本名称，但本任务不要求支持 v2 schema；
- 缺少声明版本文件时返回清晰错误并保留当前 source；
- corrected export 不修改 model output hash。

## 13. 文档修正

实施完成后同步更新：

- `README.md`；
- `docs/architecture.md`；
- `docs/plugin-api.md`；
- `docs/requirements-traceability.md`；
- `docs/part1-implementation-report.md`；
- Part 1 实施计划中涉及旧 schema 名称和旧模型文件名的内容。

删除以下错误描述：

- `annotation-v1.schema.json` 是最终 Part 1.1 Schema；
- record source 是 `model_output_v1`；
- corrected record source 是 `human_corrected`；
- box 和 polygon 必须二选一；
- dataset_id、image_size、filled 是老师 Part 1.1 必需 annotation 字段；
- 模型输出文件名是 `model_output.jsonl`。

## 14. 验收标准

只有以下条件全部满足，Part 1.1 才能标为 PASS：

1. `core/schemas/model_output_v1.schema.json` 是唯一老师要求的主 Schema；
2. Schema 字段与 Assignment 要求和示例一致；
3. Assignment 示例同时通过 Python 和 Godot；
4. Python validator 可独立运行并有中文注释；
5. malformed record 返回清晰错误且 CLI 无 traceback；
6. Godot malformed input 不崩溃 UI；
7. sample 输出文件为 `model_output_v1.jsonl`；
8. 不再生成或依赖无版本的 `model_output.jsonl`；
9. 所有后续模型输出名称以 `model_output_v` 开头；
10. 原模型文件在加载、编辑、验证和导出后 SHA-256 不变；
11. Python 和 Godot Part 1.1 测试全部通过；
12. README、架构、API、追踪表和实现报告不再包含旧错误语义。
