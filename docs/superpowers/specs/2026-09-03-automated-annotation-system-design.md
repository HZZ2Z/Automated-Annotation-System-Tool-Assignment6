# 自动标注系统设计规范

> **修订版 2——纠正基线。** 本版保留已批准的前端，恢复直接打开图像，并在继续开发功能前，
> 将老师对 MITK、组件化、接口、可维护性和证据的要求设为强制约束。

## 0. 强制开发章程

本节优先于本文档后续内容或实施计划中的冲突解释。设置它的原因是：当可见评审流程或老师要求的边界发生回退时，仅仅通过内部测试还不够。

老师明确要求：研究 MITK 交互范式、建立清晰的组件化插件流水线、记录扩展接口、保证 AI 辅助代码对人可读，并且可以后续扩展。以下命名、行长、受保护节点和验收规则，是本项目从上述要求中推导并批准的实施规则，不是老师原话。

### 0.1 真值来源优先级

所有设计和实施决策都遵循以下优先级：

1. 老师原始 Assignment：`docs/Project_6_Automated_Annotation_System_Assignment.md`；
2. 用户明确的范围决策和已批准前端基线；
3. 本设计规范；
4. 实施计划；
5. 任务内部的实施选择。

低优先级来源不得静默删除、重命名、移动或重新解释高优先级要求。发生冲突时，必须停在设计/评审门禁并获得用户明确批准。老师的 Assignment 是只读要求来源，不是实施文件。

### 0.2 MITK-first 的 2D 交互风格

修改编辑行为前，应研究官方 [MITK 仓库](https://github.com/MITK/MITK) 和其交互/分割文档中相关的手工交互模式。只采用对本 Assignment 有用的 2D 行为：

- 保持工具面板可见，并将活动工具显示为按下状态；
- 明确切换工具，`Select` 是安全默认值；
- 将鼠标按下、移动和释放视为一次交互；
- 拖动时显示短期预览，释放时只提交一条可撤销命令；
- 在移动、缩放、重标签、填充或删除前清晰显示选中状态；
- 提供键盘访问和应用级有界 undo/redo；
- 在工具、帧、数据源或焦点变化时安全取消短期状态。

MITK 是设计参考，不是项目依赖。体积、3D、多平面、高级轮廓和完整 MITK 行为不在范围内。Assignment 将 polygon 绘制和顶点编辑定义为可选功能，第一版明确不包含它们。

### 0.3 结构化组件和显式接口

- 每个 scene、script、service、command 和 plugin 只有一个主要职责。
- UI scene 发出意图；domain command 验证并修改；service 拥有可复用状态或 I/O；plugin 实现已记录的 stage contract。UI node 不吸收 domain logic。
- 每个公开边界明确记录方法名、参数/返回类型、signal、lifecycle、验证失败以及可变状态的所有权。
- 必需依赖通过 activation context 或显式 setter 注入。组件通过接口和 signal 通信，不使用隐藏的 sibling-node lookup。
- 新 plugin 通过新增 plugin directory 和 manifest 添加；不为每个 plugin 修改 Registry core。
- 在接受 `docs/plugin-api.md` 前稳定 Interface version 1。后续不兼容变更需要升级版本并添加兼容性测试。
- 不仅因为风格原因重写现有大脚本。只有当必需功能暴露出稳定职责和测试边界时，才提取聚焦组件。

### 0.4 可维护性和代码风格

- 除非当前要求明确改变，保留已批准 scene-node contract 和现有行为。
- 功能任务内避免大范围重构；先组合现有 scene、service、command 和 plugin。
- 文件、函数、signal 和变量使用 `snake_case`；命名 class 和 scene node 使用 `PascalCase`；GDScript 使用 tab 并为公开边界标注类型。
- 在实际可行时，新增或修改行不超过 100 字符。不为满足局部变更而运行全仓库 formatter。
- UI 显示简洁、可执行的错误；原始 stack trace 只保留在开发者输出中。
- 保持 model record 不可变，frame index 从 0 开始，图像像素坐标显式化。
- 任何接口变更都在同一受评审任务中更新 contract test 和文档。

### 0.5 范围、测试和验收纪律

- 老师必需交付物优先于可选功能。必需 phase gate 未完成时，不开始可选扩展。
- 每个带行为的变更从失败测试开始，以聚焦测试、完整相关套件和产品级验收证据结束。
- 自动化套件全绿只能证明它包含的 assertion。它不能覆盖已批准可见工作流，也不能替代手工评审。
- 只有 code、test、documentation、manual reviewer step 和必需 artifact 全部通过，并在要求追踪表中建立链接后，phase 才完成。
- 模型训练/推理、云服务、账户、协作、Web/移动客户端、3D、optical flow 和无关打磨不在第一版范围内。

### 0.6 受保护产品契约

未经用户明确批准，不得删除、重命名或移动以下可见外壳：

- 顶部工具栏：`Open`、`Save`、`Undo`、`Redo`、`Export`；
- 左侧工具面板：`Select`、`Move`、`Box`、`Fill`、`Delete`；
- 中心：真实 `AnnotationViewport`；
- 右侧：`InspectorPanel`；
- 底部：上一帧、播放/暂停、下一帧、frame/time 显示和 `Timeline`；
- 状态栏：当前工具、数据源状态、保存状态和可恢复错误。

必需 backend 未存在时，按钮可以禁用，但必须保持可见。Tool button 互斥，active button 保持按下，启动后 `Select` 为 active。

`Open` 必须接受三种与老师要求一致的 Source：

- PNG/JPG/JPEG：作为 frame 0 的单帧数据源打开；没有配套 annotation 时使用空 region list；
- 归一化图像序列目录：通过现有 Source plugin 打开 manifest 和 annotations；
- 视频：通过 `ProcessService` 异步归一化，然后打开生成的 frame source。

无效替换数据源不得丢弃当前有效数据集。修改 `main.tscn` 或该 Source-opening contract 时，需要 structure test、单图/目录打开测试和手工 1280×800 可视检查。

### 0.7 强制恢复门禁

当时 Task 9 实现在技术上已集成，但产品验收被拒绝：它删除了受保护的左侧工具面板和顶层 `Save`/`Export` 控件，并拒绝直接图像文件。在 Task 9R 恢复这些行为，且 Part 1 closure gate 确认所有必需 Part 1 artifact 之前，不得开始 Task 10 或之后的功能工作。

## 1. 目的

构建一个可靠、本地、单用户的 2D 标注应用。评审者可以打开单张图像、图像序列或已解码视频；在存在时载入模型标注；修正标注；将关键帧修正传播到连续相似帧；验证结果；导出版本化 training-update package。

本产品是标注和反馈工具，不训练或运行 perception model。

## 2. 强制范围

### 2.1 包含

- 使用 GDScript 实现的 Godot 4.x 桌面客户端。
- Python 3.10+ 支持工具链：确定性样本生成、视频解码、Schema 验证、相似度计算和导出验证。
- 任意时刻只打开一个本地数据集。
- 单图、图像序列和任意 FFmpeg 支持视频都通过同一 indexed-frame Source contract 表示。
- 在 2D 图像上渲染 box 和 polygon region。
- 完整 box 编辑：选择、移动、缩放、键盘微调、重标签、track-ID 修正、新增、删除和填充。
- Polygon 显示、选择、移动、删除、重标签和填充；不包含 polygon 顶点编辑或绘制。
- 所有改变 annotation 的操作都支持有界 undo/redo。
- 帧播放、暂停、seek、单步、显式 frame index 和 timestamp。
- 有界 frame cache，防止长数据源一次性载入 RAM。
- 使用下采样灰度 mean absolute difference 计算连续帧相似度。
- 支持显式 overwrite/merge 模式的 keyframe propagation。
- 每帧 verified/unverified 状态、Timeline 提示和跳到下一个 unverified 帧。
- 崩溃安全 autosave、未保存变更保护、corrected annotation 导出、diff 生成和版本化文件 training handoff package。
- 目录发现 plugin registry，且 Source、Render、Edit Tools 和 Export/Feedback 每个必需 stage 都有一个工作插件。
- Python test、Godot headless test、端到端 scripted smoke test、测量、文档、架构图和 reviewer runbook。

### 2.2 不包含

- 模型训练、推理、权重管理或评估。
- 实时摄像头输入。
- 云服务、数据库、用户账户或多人协作。
- Web 或移动客户端。
- 3D annotation 或体积医学成像。
- 完整 MITK 复制。
- Polygon 顶点编辑或 polygon 绘制。
- Optical flow、学习型相似度、插值或自动追踪。
- 同时打开多个数据集。
- Plugin hot reload 或远程 plugin 安装。
- 格式泛滥。规范 annotation export 是 JSONL，diff report 是 JSON 加 CSV summary。
- 模拟 HTTP training service。选定的 Assignment-compliant handoff 是文件形式。

## 3. 固定技术方向

- 客户端：Godot 4.x、GDScript、Compatibility renderer。实施前在 `README.md` 和项目元数据中锁定确切 Godot 4.x build。
- Python：Python 3.10+，测试版本锁定在 `README.md` 和 `pyproject.toml`。
- 视频解码：由 `python/frame_source.py` 调用 FFmpeg。
- 图像生成和相似度：NumPy 和 OpenCV headless。
- Contract 验证：JSON Schema Draft 2020-12 和 Python `jsonschema`。
- Python 测试：pytest。
- Godot 测试：仓库自有 headless GDScript test runner，不依赖 test framework plugin。
- 文档图：以文本形式提交 Mermaid。

当时 shell 中 Python 为 3.14.7，Godot GUI 报告 4.7.2-stable，但 shell path 中尚无 Godot 和 FFmpeg。解决并记录这些 executable path 是环境验收任务，不是修改架构或将 skipped check 计为 pass 的理由。

## 4. 用户工作流

1. 评审者选择 PNG/JPG/JPEG、归一化图像序列目录或视频。
2. 单图成为单帧 Source。视频由 Python frame-source 工具解码成 indexed image sequence 并写入 manifest。客户端之后通过同一 indexed-frame contract 处理所有输入。
3. 客户端验证 manifest 和 annotation record。无效输入产生可读错误，不替换当前已打开数据集。
4. 第一帧与不可变 model annotation overlay 一起显示。
5. 评审者导航、播放、暂停、seek 并修正 region。
6. 每个已接受 edit 创建一条 command，更新 corrected working copy，将 frame 标记为 dirty，并支持 undo/redo。
7. 评审者可在 keyframe 上查看连续 similar-frame run，并用 merge 或 overwrite 传播 corrected region。
8. 传播目标帧在人工检查前保持 unverified。
9. Autosave 原子写入 corrected working state。
10. Export 验证所有 corrected record，生成 JSONL annotation 和 diff report，并写入版本化 training-update package。

## 5. UI 边界

应用只有一个固定、受保护的主布局：

- 顶部工具栏：Open、Save、Undo、Redo、Export。
- 左侧工具面板：互斥 Select、Move、Box、Fill、Delete mode。
- 中央视口：图像、region overlay、选中状态、resize handle 和 pan/zoom 交互。
- 右侧 Inspector：region ID、class、kind、confidence、track ID、geometry、annotation opacity、relabel control 和验证信息。
- 底部 transport 和 Timeline：上一帧、播放/暂停、下一帧、显式 frame/time、frame position、current frame、similar-run 指示、batch marker 和 verified/unverified 状态。
- 状态栏：active tool、autosave state、source state 和非致命错误。

在后续 stage 实现前，Save 和 Export 保持可见但禁用，并通过清晰状态说明原因。Resize 保持为选中 box handle 交互；第一版不显示 polygon drawing tool。

不包含 docking system、theming system、animation framework 或备选布局。

## 6. 坐标与渲染模型

图像坐标是权威坐标：

- 原点：图像左上角；
- x 正方向：向右；
- y 正方向：向下；
- 单位：图像像素；
- Box：`[x, y, width, height]`，width 和 height 严格大于 0；
- Polygon：至少三个不同顶点，首顶点不重复，渲染时隐式闭合。

一个 `ViewportTransform` service 拥有 image/viewport 正向和逆向映射。Rendering、hit testing、dragging、resize handle 和键盘 geometry update 使用同一 transform。

Renderer 保持 aspect ratio 并处理 letterboxing。Region 显示 class color、label、可选 confidence、selected state 和可配置 opacity。Box 和 polygon 都可填充；polygon fill 始终连接最后一点与第一点，无需顶点编辑就能覆盖近似闭合轮廓。

Rendering 使用一个自定义 canvas drawing surface，cache class style，只在 frame、annotation state、selection、opacity 或 viewport transform 变化时重绘；不为每个 region 创建独立 scene subtree。

性能验收目标：在文档记录的测试机上，使用可见 region 约 20 个的样本或 benchmark fixture 缩放/拖动时至少 25 FPS。

## 7. Data Contract

### 7.1 Dataset manifest

Manifest 包含：

- `schema_version`、`dataset_id`、`source_name`、`source_sha256`；
- `width`、`height`、`frame_count`、`nominal_fps`；
- 按顺序排列的 frame entry，含 `frame`、`time_s` 和相对 image path；
- `model_version`、`taxonomy_version`。

Frame index 从 0 开始并连续，且在 manifest、annotation JSONL、UI、diff report 和 training package 中完全一致。

### 7.2 每帧模型输出记录

Part 1.1 唯一权威定义为 `core/schemas/model_output_v1.schema.json`。每条记录只包含老师要求的 `schema_version`、`source`、`frame`、可选 `time_s` 和 `regions`；`dataset_id`、`image_size` 与界面字段不属于该 Schema。

每个 region 包含：

- frame 内唯一 `id`；
- 非空 `class`；
- 非空字符串 `kind`；
- 至少一种几何：`box` 或 `polygon`，也允许二者同时存在；
- `[0, 1]` 内可选 `conf`；
- 可选、可为 null 的 `track_id`；
- 不包含 `filled`；该字段只允许作为界面临时状态存在。

`source` 表示帧来源，例如 `sample_v1`。模型输出通过 `model_output_v1.schema.json`、`model_output_v1.jsonl` 和 `schema_version: 1` 进行版本化。模型记录载入不可变 Store，修正数据保存为独立深拷贝，原始文件不被覆盖。

### 7.3 Review state

工具专用审核元数据与模型输出契约分开保存，包含：每帧验证状态、批次标记、关键帧索引、传播模式/范围和相似度阈值。

这种分离使 training annotation 保持精简，并防止 UI workflow field 成为模型组必填字段。

### 7.4 验证一致性

Part 1.1 的权威 Schema 是 `core/schemas/model_output_v1.schema.json`。Python 通过 `python/validate_model_output.py` 执行完整 JSON Schema 校验，Godot 通过 `client/domain/model_output_validator.gd` 执行等价的加载时/编辑时检查。两个运行环境执行同一批合法/非法 JSON fixture，使测试可以发现规则漂移。

无效 record 以字段级信息拒绝。加载无效数据不得使 UI 崩溃，也不丢弃当前已打开有效数据集。

## 8. 确定性样本

`python/make_sample_input.py` 使用固定种子 `6006` 生成：120 帧、640×360、名义 30 FPS、表示 instrument/anatomy class 的移动彩色形状、性能 fixture 中约 20 个可见 region，以及第 40–59 帧的连续近似相同段。

Model-output annotation 包含机器可读 expected-defects manifest，其中植入：多帧 geometry drift、wrong class、missed region、hallucinated region 和 track-ID swap。

使用同一 seed 运行两次必须产生相同 manifest、annotation、expected-defects manifest 和 frame-content hash。体积较大的可复现二进制帧不提交；generator 和小 fixture 提交。

## 9. Frame Source

`python/frame_source.py` 接收视频路径和输出目录，使用 FFmpeg 生成有序帧图像，并为 manifest 推导显式 frame timestamp。验证拒绝缺帧、重复 index、不连续 index、无效尺寸或 annotation/frame-count 不匹配。

`single_image_source` plugin 将 PNG/JPG/JPEG 适配到同一 Source-stage 接口，在 frame 0 创建一个 manifest entry。没有 annotation 时返回一条合法空 annotation record。`image_sequence_source` 继续拥有归一化目录；两个 plugin 都不改变权威 annotation Schema。

客户端选择视频时，Source plugin 以 child process 启动工具并非阻塞监控。进度和失败在状态栏报告。只有转换和验证成功后，归一化 Source 才替换当前 Source。

Godot 在提交替换状态前，根据候选路径选择 Source plugin。所有 Source plugin 暴露相同 indexed-frame interface，通过有界 LRU cache 加载，不将完整序列加载到内存。越界 seek、缺失 frame、损坏图像和空 annotation 产生可见可恢复错误。

## 10. 编辑模型

所有持久 annotation 变更使用 command：移动 region、缩放 box、键盘微调、重标签、修改 track ID、新增 box、删除 region、切换 fill 和传播 batch。Select 是短期状态，不进入 undo history。

Edit plugin 在 `select`、`move`、`box`、`fill` 和 `delete` 中显式暴露一个 active mode。改变 mode 取消所有 transient preview，更新 `ToolPanel` pressed state，且不自身创建 history entry。`ToolPanel` 只发出 intent；Edit plugin 拥有 tool behavior 并产生 domain command。

每条 command 实现 `apply`（包含修改前验证）和 `revert`。Undo/redo 保存最近 200 条已接受 command；undo 后的新 command 清空 redo branch。

Relabel 同时提供 taxonomy list 和 free-text entry。非空自由文本在 Schema 验证后被接受并原样保留。Pointer drag 可更新 transient preview，但 mouse release 只提交一条 command。Schema-invalid command 在修改前被拒绝，并显示说明信息。

必须支持键盘访问：

- `Tab`/`Shift+Tab` 循环选择控件和 region list item；
- `Arrow`、`Shift+Arrow`、`Ctrl+Shift+Arrow` 分别微调 1/5/10 像素；
- `Alt+Arrow` 缩放 box 1 像素，结合 Shift 和 Ctrl+Shift 时为 5/10 像素；
- `Enter` 确认 add/relabel；`Delete` 删除选中 region；
- `Ctrl+Z`/`Ctrl+Shift+Z` 执行 undo/redo；
- 一个已记录 shortcut 无需 pointer 就能打开 add-box workflow。

## 11. 播放与帧缓存

播放由 frame index 而不是 codec time 驱动。Manifest 将每个 frame index 映射到 timestamp。Play/pause 通过显式 index 前进；previous、next 和 seek 选择显式 index。

客户端显示当前 frame index、总 frame count 和 timestamp。有界 cache 保留当前 frame 和小型相邻 window；cache size 可配置，但具有有限的已记录默认值。

## 12. 相似度和批量传播

连续帧相似度计算：

1. 将每张图像缩放到 64×64；
2. 转为灰度；
3. 计算归一化 mean absolute pixel difference。

默认阈值为 `0.02`。记录 score 和 threshold，使交付样本测量可复现。样本生成器保证第 40–59 帧构成连续候选 run，且在已记录 threshold 下边界可区分。

评审者从当前 keyframe 显式启动 propagation，并确认目标 range 和 mode。

Overwrite：用 corrected keyframe region 的 deep copy 替换每个目标帧的全部 region。

Merge：

- 首先按非 null 且相等的 track ID 匹配；
- 否则以 IoU 最高且超过 `0.5` 的 same-class region 匹配；
- 已匹配目标 region 接收 keyframe class 和 geometry；
- 未匹配 keyframe region 以 frame-unique region ID 新增；
- 未匹配现有 target region 保留。

每个 target frame 都直接从 keyframe 接收数据，绝不从上一个 propagated frame 接收，以防止 propagation-chain drift。Propagated frame 标记为 unverified。Timeline 显示 batch range；next-unverified action 选择第一个之后的 unverified frame，并允许绕回开头一次。

## 13. 持久化、Diff 与 Handoff

Corrected working data 在变更后按已记录 timer 自动保存，也支持显式 Save。Save 在同一目录写临时文件，关闭后原子重命名以覆盖之前 autosave。Save failure 保留内存 edit 和 dirty state；dirty 状态下退出需要明确确认。

Autosave、export、hashing 和 package creation 不在 UI update path 中运行。完成和错误以 message 返回 main thread；任何 file operation 都不得卡住 pointer interaction 或 playback。

Export 写入：corrected annotation JSONL、per-frame diff JSON、aggregate diff CSV、review-state/batch-audit JSON、package manifest 和 SHA-256 checksum。

Diff category 包括 added、deleted、label changed、geometry changed 和 track ID changed；geometry comparison 使用已记录的一像素容差。Aggregate diff 按 change category 和 class 统计。

文件型 training handoff package 命名为 `training_update_v1__<dataset_id>__<model_version>__<UTC timestamp>`，包含 corrected annotation、diff report、audit data、manifest 和 checksum。创建过程不阻塞 UI，成功时显示最终本地路径。这是第一版唯一 training-delivery mechanism。

相同的 validation、diff 和 package-building service 也通过 Python CLI 暴露，因此可以不打开 UI 就验证和打包已保存 corrected working copy，而正常评审流程在客户端执行同样的操作。

## 14. 插件架构

客户端启动时扫描 `client/plugins/*/plugin.json`。Plugin manifest 包含 `id`、`version`、`api_version`、`stage` 和 `entry`。未知 stage、不兼容 API version、重复 ID、缺失 entry 和 script load failure 在不使 startup 崩溃的情况下报告。

必需扩展点：

- Source：打开归一化 Source，并提供 indexed frame 和 model annotation；
- Render：使用共享 viewport transform 绘制图像和 annotation；
- Edit Tools：注册必需 interaction tool 并产生 edit command；
- Export/Feedback：验证并写入 training handoff package。

初始工作 plugin：`single_image_source`、`image_sequence_source`、`canvas_region_renderer`、`basic_edit_tools`、`file_training_handoff`。

新增 plugin 只需添加 plugin directory，不修改 Registry core。

## 15. 错误处理

以下预期用户/数据错误以简洁信息显示，不显示原始 stack trace：缺失/无效 manifest、Schema-invalid annotation、缺失/损坏 frame、annotation/frame mismatch、空 annotation list、越界 seek、plugin load failure、autosave/export failure 和无效 edit geometry。

打开替换数据源失败时，当前已加载有效数据集仍可使用。

## 16. 测试策略

Python test 覆盖：Schema valid/invalid fixture、确定性 sample hash、植入 defect manifest、video/frame manifest alignment、similarity score/contiguous range detection、export/diff correctness 和 training-package manifest/checksum。

Godot headless test 覆盖：

- Schema/domain validation parity fixture；
- 坐标正/逆变换和变换后 hit testing；
- 每条 command 的 execute/undo/redo 和有界 command history；
- merge/overwrite、verification navigation 和 plugin discovery/failure isolation；
- frame-cache bound 和 autosave recovery；
- 受保护 toolbar、tool panel、Inspector、transport、Timeline 和 status bar node；
- 互斥 edit-tool state 和 transient-preview cancellation；
- 直接 PNG/JPG/JPEG、归一化目录和 transactional failure recovery。

Headless smoke test 执行端到端 scripted session：加载 sample、选择 frame、移动/缩放/重标签/新增/删除、undo/redo、传播 keyframe、验证 frame、autosave、export，并比较生成的 diff/package 预期。

手工评审覆盖：1280×800 受保护布局、单图/样本目录打开、pointer interaction、纯键盘交互、focus traversal、visual correctness、playback、error message 和最终 handoff workflow。

## 17. 文档和测量

仓库包含：

- `README.md`：环境、安装、样本重生成、运行命令、键盘表和 reviewer script；
- `RESULTS.md`：MITK 交互的采用/调整/删除、渲染方法、测量、batch coverage、boundary check、autosave 和 failure analysis；
- 架构图、plugin API document、模型组 interface agreement、demonstration video script/link。

模型组接口协议声明 Schema/taxonomy version、必填字段、coverage、package naming/checksum、重训练后返回什么 refreshed `model_output_vN`，以及如何在不替换之前 round 的情况下重新导入新 model-output round。

记录的测量包含：load time、frame delivery/playback rate、约 20 region 下的 drag/zoom FPS、editing response time、batch coverage、实测 manual-per-frame labeling baseline、batch 两端的 propagation result 检查和 autosave 行为。每项测量附带方法和测试机细节。Failure analysis 记录 2–3 个具体 bug 和修复方法。

最终演示不超过 3 分钟，顺序为：打开 sample、展示植入 defect、修正每个必需 defect type、传播 similar-frame range、verify、export、展示 training handoff package。

## 18. 完成标准

只有满足以下全部条件，项目才完成：

- 干净环境可按 README 生成/验证样本并启动客户端；
- 编辑/导出会话中 model output 始终逐字节不变；
- 必需 box edit、polygon display/fill、键盘访问和 undo/redo 全部工作；
- zoom/pan 后 hit testing 仍正确；
- playback、step、seek、frame index 和 timestamp 与 manifest 对齐；
- 长 Source 通过 frame cache 使用有界内存；
- merge/overwrite 符合文档语义且可撤销；
- verified/unverified navigation 和 Timeline 指示工作；
- autosave 原子化，失败 Save 不丢失内存 edit；
- export、diff 和 package count 一致，所有 package checksum 可验证；
- 每个必需 extension point 都有一个工作 plugin，Registry failure 被隔离；
- 所有 Python、Godot headless 和 smoke test 通过；
- `RESULTS.md`、reviewer runbook、interface agreement、架构图和 demonstration 完成；
- 私有提交仓库不包含 credential、private configuration、build output 或大型可复现 asset，并可添加必需 reviewer 为 collaborator；
- 受保护 UI shell 和三种 Source-opening route 通过自动/手工检查；
- 每条老师要求在 traceability table 中都有 implementation、automated evidence、需要时的 manual evidence、status 和下一个 corrective task。

Part 1 只有在 Schema/validator、确定性样本、video frame source、plugin registry、工作的 Source/Render/Edit/Feedback plugin、架构图、plugin API、README 和零错误样本验证全部存在并通过后才完成。后续实现不会追溯性免除缺失 Part 1 artifact。

本规范之外的任何内容都推迟到 Assignment 被接受之后。
