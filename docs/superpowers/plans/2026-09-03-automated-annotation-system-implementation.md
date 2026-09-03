# 自动标注系统实施计划

> 本计划供开发人员和自动化开发代理使用。按 Task 顺序执行，并使用 `- [ ]` 复选框记录实际进度。代码、接口签名、插件 ID、命令和路径保持原文，不作翻译。

**目标：** 在老师 Assignment 规定的范围内，把 Godot 标注客户端和 Python 支持工具组成可靠的“加载 → 编辑 → 批处理 → 验证 → 自动保存 → 导出 → 训练交接”工作流。

**设计规范：** `docs/superpowers/specs/2026-09-03-automated-annotation-system-design.md`

**技术栈：** Godot 4.7.2-stable、GDScript、Compatibility 渲染器、Python 3.10–3.14、FFmpeg 6.1+、JSON Schema Draft 2020-12、NumPy、OpenCV headless、jsonschema、pytest 和 Mermaid。

## 1. 工程章程

### 1.1 约束优先级

1. 老师的原始 Assignment 是最高优先级需求来源。
2. 用户明确确认的范围和前端布局次之。
3. 设计规范约束系统架构，本计划约束实施顺序。
4. 单项开发任务的便利性不得覆盖以上约束。

如不同来源冲突，必须在审查门槛处停止并请求明确批准。内部测试通过不代表可以删除用户已批准的工作流。老师的文件 `docs/Project_6_Automated_Annotation_System_Assignment.md` 必须保持不变，只能作为只读需求来源。

### 1.2 MITK 交互参考

- 修改编辑行为前，阅读 MITK 官方交互与分割资料。
- 只借鉴适合本项目的 2D 交互范式，不复刻 MITK，也不增加 3D 功能。
- 保留可见工具箱、活动工具按下状态、明确模式切换、清晰选中状态，以及按下/移动/释放过程预览。
- 每个完整手势只生成一条可撤销命令。
- `Select` 是默认模式；切换工具、数据源、帧或焦点时取消临时预览，不提交编辑。
- 所有编辑操作都应可由键盘触达，并共享容量为 200 的有界命令历史。

### 1.3 模块化与维护性

- 每个场景、脚本、服务、命令和插件只承担一个主要职责。
- UI 场景只发出用户意图；Edit 插件把交互转换成命令；领域对象负责校验和变更；服务负责可复用状态或 IO。
- 不得把领域逻辑塞入 `client/app/main.gd` 或 UI 节点。
- 实现模块边界前，先记录公共方法签名、信号、返回值、错误行为、生命周期和可变状态所有权。
- 通过激活上下文或显式 setter 注入依赖，使用信号传递事件。
- 添加插件应新增插件目录和 `plugin.json`，不得修改注册表核心来特判某个插件。
- `plugin API version 1` 一旦验收，不兼容修改必须提升 API 版本并补充兼容性测试。
- 功能任务内不得进行大范围重构或全仓库格式化。
- 文件、函数、变量和信号使用 `snake_case`；类与场景节点使用 `PascalCase`；公共边界带类型。
- 接口变更必须在同一任务中同步更新测试和文档。

### 1.4 受保护的产品契约

未经用户明确批准，不得删除、重命名或移动下列节点及其布局位置：

- 顶部工具栏：Open、Save、Undo、Redo、Export
- 左侧工具面板：Select、Move、Box、Fill、Delete
- 中部：真实的 `AnnotationViewport`
- 右侧：`InspectorPanel`
- 底部：上一帧、播放/暂停、下一帧、明确帧号/时间、`Timeline`
- 状态栏：活动工具、数据源/保存状态和可恢复错误

Save 和 Export 的后端完成前可以禁用，但必须保持可见。Open 必须支持 PNG/JPG/JPEG 单帧图像、标准化数据源目录，以及通过异步标准化打开的视频。候选数据源加载失败时，必须保留当前活动数据集。

### 1.5 全局约束

- 只实现设计规范和老师要求的必需功能。
- 不增加模型训练/推理、HTTP 服务、数据库、云功能、账号、协作、Web/移动客户端、3D、光流、绘制多边形或编辑多边形顶点。
- 原始模型输出文件及内存中的模型记录不可变。
- 图像坐标以左上角为原点；帧索引从零开始且连续。
- 每个 region 恰好包含一种几何：`box` 或 `polygon`。
- JSONL 是修正标注的标准导出格式。
- 训练侧唯一交付方式是版本化文件包。
- 所有持久化标注变更都必须经过容量为 200 的命令历史。
- 长数据源使用有界缓存，禁止全部载入内存。
- Python 与 Godot 必须运行同一组有效/无效契约夹具。
- 行为变更必须先写测试。
- 修改 `client/app/main.tscn` 时，必须运行受保护节点测试并进行 1280 × 800 人工视觉检查。
- 修改数据源打开逻辑时，必须测试直接图像、标准化目录和失败替换。
- 生成样例、Godot 导入文件、Python 环境、构建输出和凭据不得提交。
- 只有代码、自动化测试、人工检查、文档和产物均在 `docs/requirements-traceability.md` 中有证据且标为 `PASS`，对应阶段才算完成。

## 2. 当前状态与强制顺序

“已实现”只表示仓库中存在代码，不代表已完成老师要求或产品验收。当前状态以本表和需求可追溯性矩阵为准。

| 工作项 | 当前状态 | 尚需证据 |
|---|---|---|
| Task 1–3：脚手架、schema、校验器、样例 | 代码已实现；环境文档尚不完整 | 明确 Godot 4.7.2 命令、补齐 Part 1 文档、通过可追溯性门槛 |
| Task 4：视频标准化与相似度 | 代码已实现；环境门槛尚未完成 | 文档路径上的 FFmpeg 可用，并重跑此前跳过的检查 |
| Task 5–6：存储、注册表、图像序列数据源、缓存 | 已实现 | 通过 Part 1 插件/API/文档门槛 |
| Task 7：视口与渲染器 | 已实现 | 记录 25–30 FPS 实测结果并完成视觉检查 |
| Task 8：命令与编辑插件 | 核心行为已实现；可见 UX 尚不完整 | 恢复工具面板和活动模式，通过焦点/键盘人工审查 |
| Task 9：主场景、播放、时间线 | **产品验收拒绝** | 由 Task 9R 恢复受保护 UI 和直接图像打开能力 |
| Task 10–14 | 未验收或尚未开始 | 只能在下列门槛通过后执行 |

**停止点：** Task 9R 与 Task 9P1 均通过前，不得开始 Task 10 或任何更后的功能任务。即使后续部分已有代码，Part 1 仍不能据此判定完成。

| 作业阶段 | 必需验收内容 | 当前状态 | 下一项权威任务 |
|---|---|---|---|
| Part 1 | 脚手架、schema/校验器、确定性样例、视频帧数据源、注册表、每阶段一个可用插件、架构、插件 API、README、零错误校验 | 部分完成 | 先 Task 9R，再 Task 9P1 |
| Part 2 | 图像/区域显示、坐标变换、流畅渲染、MITK 风格编辑、键盘可达性、审查脚本、MITK 设计说明 | 部分完成 | 先 Task 9R，再 Task 13–14 |
| Part 3 | 按索引播放、有界缓存、相似度、传播/验证 UX、测量 | 部分完成 | 先 Task 10，再 Task 13–14 |
| Part 4 | 自动保存、修正导出、差异、版本化交接、接口约定、非阻塞 IO | 尚未开始 | 先 Task 11–12，再 Task 14 |
| Part 5 | 完整测试、健壮性、测量、真实失败分析、运行手册 | 部分完成 | Task 13–14 |

## 3. 模块与目录规划

每个文件只承担一个主要职责；实际位置和修改入口以 `docs/architecture.md` 为准。

| 层级 | 主要目录 | 职责 |
|---|---|---|
| 契约层 | `core/schemas/`、`core/fixtures/`、`core/taxonomy/` | schema、跨运行时夹具、类别体系 |
| Python 支持层 | `python/annotool/`、`python/*.py` | 样例、视频标准化、相似度、校验、diff、交接包 |
| Godot 领域层 | `client/domain/` | 不可变模型数据、修正数据、命令与历史 |
| Godot 服务层 | `client/services/` | 坐标变换、缓存、传播、验证、自动保存、外部进程 |
| 插件基础设施 | `client/pipeline/` | 插件 API 和注册表 |
| 插件实现 | `client/plugins/{source,render,edit,feedback}/` | 四阶段可替换实现 |
| UI 层 | `client/ui/`、`client/app/` | 视口、工具面板、检查器、时间线和应用编排 |
| 测试层 | `tests/python/`、`tests/godot/`、`tests/smoke/` | 单元、契约、集成、烟雾与性能测试 |
| 文档层 | `README.md`、`docs/`、`RESULTS.md` | 运行手册、架构、API、证据和结果 |

## 4. 逐项实施任务

### Task 1：可复现的项目基础

**主要文件：** `.gitignore`、`pyproject.toml`、`requirements.lock`、`project.godot`、`python/annotool/__init__.py`、`tests/python/test_environment.py`、`tests/godot/test_runner.gd`、`tests/godot/test_support.gd`。

**接口与产物：** 提供可导入的 `annotool` 包、pytest 命令、Godot 无头测试命令，以及后续任务共用的固定依赖版本。

- [ ] 检查 Python 3.10–3.14、Godot 4.7.2-stable、FFmpeg 6.1+ 和 Git。
- [ ] 先编写会因包缺失而失败的 Python 环境测试。
- [ ] 配置 `pyproject.toml`、`project.godot` 和 `.gitignore`。
- [ ] 创建虚拟环境、安装依赖并生成 `requirements.lock`。
- [ ] 运行 Python 与 Godot 两条基线测试命令。

```bash
python3 --version
godot --version
ffmpeg -version
.venv/bin/python -m pytest tests/python/test_environment.py -v
godot --headless --path . --script tests/godot/test_runner.gd
```

### Task 2：Model Output V1 Schema 与 Python 校验

**主要文件：** `core/schemas/model_output_v1.schema.json`、`core/fixtures/{valid,invalid}/`、`python/annotool/contracts.py`、`python/annotool/jsonl.py`、`python/validate_model_output.py`、`tests/python/test_part1_1_data_contract.py`。

**公共接口：** `load_schema`、`validate_record`、`validate_model_output`、`validate_instance`、`read_jsonl`、`write_jsonl_atomic`。

- [ ] 先编写有效/无效契约测试。
- [ ] Model Output V1 Schema 声明 Draft 2020-12，拒绝未知字段，并要求 `schema_version = 1`。
- [ ] `box` 宽高必须为正；`polygon` 至少三个二维顶点；通过 `oneOf` 保证二者只出现一种。
- [ ] `conf` 限制为 0–1；`track_id` 允许字符串或 null。
- [ ] 允许 box、polygon 或二者同时出现，与 Assignment 示例一致。
- [ ] JSONL 写入采用同目录临时文件和原子替换。
- [ ] CLI 按行输出字段路径；只有全部记录通过才以状态码 0 退出。

```bash
.venv/bin/python -m pytest tests/python/test_part1_1_data_contract.py -v
.venv/bin/python python/validate_model_output.py core/fixtures/valid/assignment-model-output-v1.json
```

### Task 3：确定性合成样例

**主要文件：** `python/annotool/sample.py`、`python/make_sample_input.py`、`tests/python/test_sample.py`、`tests/expected/sample-defects.json`。

**公共接口：** `generate_sample(output_dir: Path, seed: int = 6006) -> dict[str, str]`。

- [ ] 生成 120 帧、640×360、30 FPS 的确定性图像。
- [ ] 使用 20 个 instrument/anatomy/region 区域；第 40–59 帧构成相似帧区间。
- [ ] 在固定位置植入 geometry drift、wrong class、missed region、hallucinated region 和 track-id swap。
- [ ] 模型输出必须从真实标注 deep copy 后修改，不得反向改变真实标注。
- [ ] 写出 `frames/`、`model_output_v1.jsonl`、`manifest.json`、`expected_defects.json` 和 `hashes.json`。
- [ ] 对所有输出进行 schema/语义校验和 SHA-256 哈希。
- [ ] 目标目录已存在时拒绝覆盖并返回简短错误。

```bash
.venv/bin/python -m pytest tests/python/test_sample.py -v
.venv/bin/python python/make_sample_input.py --output /tmp/annotool-sample --seed 6006
.venv/bin/python python/validate_model_output.py /tmp/annotool-sample/model_output_v1.jsonl
```

### Task 4：视频标准化与相似度

**主要文件：** `python/annotool/similarity.py`、`python/annotool/frame_source.py`、`python/frame_source.py`、`tests/python/test_similarity.py`、`tests/python/test_frame_source.py`。

**公共接口：** `normalized_mad`、`contiguous_run`、`decode_video`。

- [ ] 先测试相同帧距离为 0，以及相似区间在阈值处停止。
- [ ] 用 ffprobe JSON 读取宽高、标称帧率和逐帧时间戳。
- [ ] 以参数列表调用 FFmpeg，禁止 `shell=True`。
- [ ] 提取无损 PNG，并把从 1 开始的文件名转换为从 0 开始的 manifest 索引。
- [ ] 拒绝帧索引不连续或时间戳数量不匹配的输出。
- [ ] `--result-file` 采用原子 JSON 结果，供 Godot 非阻塞监控。
- [ ] 在 seed 6006 样例上确认阈值 0.02 得到区间 `(40, 59)`。

```bash
.venv/bin/python -m pytest tests/python/test_similarity.py tests/python/test_frame_source.py -v
```

### Task 5：Godot 契约校验与不可变标注存储

**主要文件：** `client/domain/model_output_validator.gd`、`client/domain/annotation_store.gd`、`client/domain/command.gd`、`client/domain/command_history.gd` 和对应 Godot 测试。

- [ ] Godot 对有效/无效夹具的判断必须与 Python 一致。
- [ ] `get_model_record` 的返回值被外部修改后，内部模型记录保持不变。
- [ ] 非法 corrected replacement 必须被拒绝且不改变现有状态。
- [ ] `snapshot_corrected` 按帧索引返回记录并保留原始帧 `source`；修正内容与模型基线分开保存。
- [ ] 成功的新命令清空 redo；超过 200 条时丢弃最早的 undo 项。
- [ ] 命令失败时不得进入历史记录。

### Task 6：插件注册表、Source 插件与有界帧缓存

**主要文件：** `client/pipeline/plugin_api.gd`、`client/pipeline/plugin_registry.gd`、`client/services/frame_cache.gd`、`client/plugins/source/image_sequence_source/` 和对应测试。

- [ ] 注册表扫描直接子目录中的 `plugin.json`。
- [ ] 校验 `id`、`version`、`api_version`、`stage` 和 `entry`。
- [ ] 同一阶段重复 ID 被拒绝；坏插件不得阻止其他插件加载。
- [ ] LRU 缓存严格遵守 `max_size`。
- [ ] 图像序列插件只在完整校验候选目录后替换当前状态。
- [ ] 路径必须为相对路径并保持在数据源根目录内。
- [ ] 缺失目录、越界帧或损坏输入返回可读错误，并保留原有有效状态。

### Task 7：视口坐标变换与区域渲染器

**主要文件：** `client/services/viewport_transform.gd`、`client/plugins/render/canvas_region_renderer/`、`client/ui/annotation_viewport.*` 和对应测试。

- [ ] 坐标正反变换必须互为逆运算。
- [ ] `zoom_at` 保持光标下图像点不动；`pan_by` 同时影响绘制与反向映射。
- [ ] box 和凹 polygon 的命中测试在图像坐标中进行，视觉最上层区域优先。
- [ ] 使用单个 canvas 绘制，不为每个区域创建节点。
- [ ] `AnnotationViewport` 只在纹理、记录、选择、透明度或变换变化时重绘。
- [ ] 本任务不得修改标注数据。

### Task 8：标注命令与基础 Edit 插件

**主要文件：** `client/domain/commands/`、`client/plugins/edit/basic_edit_tools/`、`client/ui/inspector_panel.*` 和对应测试。

- [ ] 每类命令都测试 apply → undo → redo，且模型记录始终不变。
- [ ] 宽度为 0 或越界移动必须被拒绝，且不进入历史。
- [ ] 拖动只更新临时预览，释放时提交一条命令；Escape 取消。
- [ ] AddBoxCommand 的 ID 在当前帧唯一，会话中不复用已删除 ID。
- [ ] `SetTrackIdCommand` 是唯一允许修改 `track_id` 的编辑路径。
- [ ] InspectorPanel 只发出请求，不直接修改记录。
- [ ] 覆盖鼠标选择/拖动及 Tab、方向键、Delete、Ctrl+Z、Ctrl+Shift+Z 等键盘路径。

### Task 9：主应用、播放与时间线

> 修正状态：本任务已有实现提交，但产品验收未通过。旧布局删除了受保护控件，并拒绝直接打开图像。Task 9R 是强制修复任务。

**主要文件：** `client/app/main.*`、`client/ui/timeline.*` 和对应测试。

- [ ] 主场景保留顶部工具栏、左侧 ToolPanel、中间 AnnotationViewport、右侧 InspectorPanel、底部播放/时间线和状态栏。
- [ ] PNG/JPG/JPEG 走单帧 Source；目录走图像序列 Source；视频走异步标准化。
- [ ] 以 manifest 帧索引作为标注依据，不依赖编解码器播放时间。
- [ ] 上一帧/下一帧在边界处钳制；越界 seek 不改变当前帧；最后一帧自动暂停。
- [ ] Timeline 使用缓存状态数组，不为长视频的每一帧创建按钮。
- [ ] 数据源错误显示在状态栏，不暴露原始堆栈。

### Task 9R：恢复受保护前端与直接图像打开

**门槛：** 保留现有 renderer、viewport、inspector、store、command history、playback、timeline 和事务式数据源替换，不得重写。全部步骤通过前，Task 10 继续阻塞。

**主要文件：** `client/ui/tool_panel.*`、`client/plugins/source/single_image_source/`、`client/app/main.*`、`client/pipeline/plugin_api.gd`、`client/plugins/edit/basic_edit_tools/plugin.gd` 及对应测试。

- [ ] 先用受保护节点测试暴露当前回归。
- [ ] ToolPanel 只负责按钮分组和活动状态，不包含标注变更逻辑。
- [ ] Select、Move、Box、Fill、Delete 五个按钮必须互斥，重复点击仍保持活动。
- [ ] 工具切换取消临时拖动/添加状态，不创建历史记录。
- [ ] 单图 Source 支持 PNG/JPG/JPEG，生成一帧、时间 0.0、空 regions 的有效内存契约。
- [ ] 缺失、损坏、目录或不支持文件返回错误，插件保持关闭。
- [ ] `open_source` 完整校验候选对象并成功加载第 0 帧后，才替换当前状态。
- [ ] Save/Export 保持可见，在后端完成前禁用并提供说明 tooltip。

人工产品验收必须在 1280 × 800 下确认顶部五个按钮、左侧五种工具、单图和样例目录、活动工具与选择高亮、底部 Timeline、右侧 Inspector，以及无效替换后的原状态保留。

### Task 9P1：补齐全部 Part 1 必需交付物

**门槛：** Task 9R 后、宣告 Part 1 完成前，只允许执行本任务。Feedback 插件、README、架构图和插件 API 都是老师要求的交付物。

**主要文件：** `client/plugins/feedback/file_training_handoff/`、`README.md`、`docs/architecture.md`、`docs/plugin-api.md`、`docs/requirements-traceability.md` 及文档/插件测试。

- [ ] Feedback 插件输出标准 UTF-8 JSONL，每条记录通过 Model Output V1 校验并保留原始帧 `source`。
- [ ] 输入记录先 deep copy；失败必须保留旧的有效输出。
- [ ] 文档测试覆盖环境、命令、架构流、manifest 字段、插件方法、生命周期、错误规则和可追溯性列。
- [ ] README 给出从仓库根目录运行的准确命令，不把跳过测试描述为通过。
- [ ] Mermaid 图表达 Source → Render → Edit → Export/Feedback → corrected store → training handoff。
- [ ] 新插件只需增加目录和 manifest，不修改注册表核心。
- [ ] 可追溯性矩阵只使用 `PASS`、`FAIL` 或 `BLOCKED`。
- [ ] 环境、测试、样例、双运行时校验和 whitespace 检查均通过。
- [ ] 从干净检出只按 README 完成人工审查，并为每个 Part 1 行补充证据。

```bash
.venv/bin/python -m pytest tests/python -v
godot --headless --path . --script tests/godot/test_runner.gd
.venv/bin/python python/make_sample_input.py --output /tmp/annotool-sample --seed 6006
.venv/bin/python python/validate_model_output.py /tmp/annotool-sample/model_output_v1.jsonl
git diff --check
```

**强制停止点：** 本任务提交后，报告 Part 1 证据并等待用户明确批准。不得在同一执行阶段开始 Task 10。

### Task 10：相似帧传播与验证工作流

**主要文件：** `client/domain/commands/batch_replace_command.gd`、`client/services/propagation_service.gd`、`client/services/verification_service.gd`、`client/app/main.gd`、`client/ui/timeline.gd` 及对应测试。

- [ ] overwrite 保留目标帧的 frame、time、image_size 和 dataset_id，只复制关键帧 regions。
- [ ] 批量替换先校验全部目标；任何一帧失败时不修改任何帧。
- [ ] 无论批次长度多大，整批只占一条历史记录。
- [ ] merge 先按非空 `track_id` 匹配，再对 box 使用同类 IoU；polygon 不使用 IoU 后备。
- [ ] 未匹配的关键帧区域加入目标帧，未匹配的目标区域保留。
- [ ] 传播目标重置为未验证；batch marker 只在命令成功后写入。
- [ ] Next Unverified 从当前帧之后开始，最多环绕一次；仅在全部验证时返回 -1。
- [ ] 确认对话框显示关键帧、范围、阈值 0.02 和 merge/overwrite 选择。

### Task 11：抗崩溃自动保存与外部进程隔离

**主要文件：** `client/services/autosave_service.gd`、`client/services/process_service.gd`、`client/app/main.gd` 及对应测试。

- [ ] corrected 与 review state 写入同目录 `.tmp` 后原子替换。
- [ ] 成功后不残留 `.tmp`；重命名前失败时保留原正式文件。
- [ ] worker 线程只处理序列化副本，不访问场景节点或修改 AnnotationStore。
- [ ] 默认每 5 秒自动保存；不启动重叠写线程。
- [ ] 只有保存期间没有更新编辑代次时才清除 dirty。
- [ ] `ProcessService` 使用 `OS.create_process` 和轮询，不在主线程调用 `OS.execute`，也不调用 shell。
- [ ] 视频转换期间 UI 和播放保持响应；失败时当前数据集保持不变。
- [ ] 退出时若 dirty 或保存进行中，提供 Save and Exit、Exit Without Saving、Cancel。

### Task 12：差异报告与文件式训练交接

**主要文件：** `core/schemas/training-package-v1.schema.json`、`python/annotool/diff.py`、`python/annotool/package.py`、`python/build_update_package.py`、`client/plugins/feedback/file_training_handoff/` 及对应测试。

- [ ] diff 识别 added、deleted、label change、geometry change 和 track ID change。
- [ ] 最大绝对坐标差不超过 1.0 像素时视为未变。
- [ ] diff 前后模型输入字典保持不变。
- [ ] 交接包包含 manifest、corrected JSONL、review state、diff summary 和 `checksums.sha256`。
- [ ] 在相邻临时目录构建并校验后原子重命名，不覆盖已有包。
- [ ] CLI 支持终端使用和 `--result-file` 非阻塞调用；失败不输出 traceback。
- [ ] 保持插件 ID `file_training_handoff`、stage `feedback`、API version 1 和既有 `export` 边界。
- [ ] 哈希和目录复制不得在 Godot 主线程执行。

### Task 13：端到端烟雾测试、健壮性与性能测量

**主要文件：** `tests/smoke/edit_session.gd`、`tests/python/test_cli_failures.py`、`tests/godot/test_error_recovery.gd`、`tests/godot/test_performance.gd`、`tests/run_all.sh`。

端到端脚本必须依次完成：打开样例、修正五类植入缺陷、undo/redo、传播第 40–59 帧、验证、自动保存、导出交接包并核对 diff。

- [ ] 缺失 manifest、畸形 JSON、schema 无效标注、缺失/损坏图像均返回可读错误。
- [ ] 空 regions、越界 seek、帧数不匹配、重复插件 ID、不可写目标均有恢复测试。
- [ ] 10,000 帧 synthetic manifest 不得使缓存超过上限。
- [ ] 所有 CLI 无效输入均非零退出，stderr 有简短领域错误且不含 `Traceback`。
- [ ] 性能测试记录 FPS、绘制/预览耗时、样例加载时间和帧交付吞吐量。
- [ ] 约 20 个区域时估算 FPS 低于 25 必须失败。
- [ ] 从重新生成的干净样例运行一键测试，并检查输出卫生。

### Task 14：完整文档、审查手册与提交包

**主要文件：** `README.md`、`RESULTS.md`、`docs/architecture.md`、`docs/plugin-api.md`、`docs/requirements-traceability.md`、`docs/model-team-interface.md`、`docs/reviewer-script.md`、`docs/demo-script.md`、`tests/python/test_documentation.py`。

- [ ] README 覆盖环境、安装、运行、样例重建、快捷键、审查顺序和插件概览。
- [ ] RESULTS 记录 MITK 借鉴、坐标变换、渲染性能、相似度阈值、批处理覆盖、人工基线、边界检查、自动保存和真实失败分析。
- [ ] architecture 解释不可变模型存储、修正存储、共享变换、命令历史、有界缓存、注册表、自动保存和文件交接。
- [ ] plugin API 包含 manifest 字段、四阶段方法、错误行为、版本规则和新增插件示例。
- [ ] 模型组接口文档明确 Schema 版本、帧对齐、坐标约定、字段、不可变模型输出、修正副本、命名、校验和、覆盖率与新版本回传。
- [ ] reviewer script 可从干净检出执行，不依赖开发者捷径。
- [ ] demo 不超过三分钟，展示样例、五类修改、批量传播、验证、导出和 diff/交接包。
- [ ] 实测数据来自真实命令输出，不虚构事件或指标。
- [ ] 最终验证通过，暂存区不含秘密、大型生成资产或构建输出。

## 5. 需求覆盖索引

| Assignment 要求 | 实现与验证任务 |
|---|---|
| 版本化契约、双运行时校验、不可变模型输出 | Task 2、5 |
| 确定性样例与植入缺陷 | Task 3 |
| 任意视频标准化与帧对齐 | Task 4 |
| 受保护前端与直接单图打开 | Task 9R |
| 插件注册表和四阶段可用插件 | Task 6、7、8、9P1；Task 12 扩展 Feedback |
| Part 1 架构、插件 API、README、可追溯性 | Task 9P1 |
| 图像渲染、缩放/平移、坐标变换、命中、多边形、透明度、FPS | Task 7、13 |
| 选择、移动、缩放、微调、改类、新增、删除、填充、track 修正 | Task 8、9R |
| undo/redo 与非法编辑拒绝 | Task 5、8 |
| MITK 风格模式、键盘编辑、快捷键文档 | Task 8、9R、14 |
| 播放、逐帧、seek、明确帧/时间、有界内存 | Task 6、9 |
| 相似度阈值与连续区间 | Task 4、10 |
| merge/overwrite 传播、batch marker、漂移缓解 | Task 10 |
| 验证时间线与 Next Unverified | Task 9、10 |
| 自动保存、恢复、未保存提示、非阻塞 IO | Task 11 |
| corrected JSONL、diff、分类汇总、训练包 | Task 12 |
| CLI/UI 可复现性 | Task 4、11、12、13 |
| 无头烟雾、健壮性、性能与失败分析 | Task 13、14 |
| MITK 设计说明、架构、插件 API、接口约定 | Task 14 |
| 审查手册、私有仓库说明、演示 | Task 14 |

## 6. 最终验收门槛

宣告任何阶段完成前，必须核对工程章程、阶段台账和 `docs/requirements-traceability.md`。宣告整个 Assignment 完成前，必须从全新检出和重新生成的样例运行完整测试，执行 `docs/reviewer-script.md`，校验导出包 checksum，并把设计规范第 18 节的每一项与通过的自动化测试或人工检查证据对应。任何必需要求缺少证据时，都不得宣告完成。
