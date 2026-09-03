# 自动标注系统

本项目使用 Godot 客户端和 Python 工具链，实现版本化、插件化的手术图像标注工作流。当前仓库只声明完成作业的 **Part 1 基础部分**：可复现输入、共享数据契约、数据源归一化、插件发现、每个必需阶段的工作插件，以及可运行的集成外壳。

## 开发原则

以下原则先于功能开发，也是后续各 Part 的约束：

1. **以 MITK 为交互参考。** 将其明确选择/编辑、可见状态、取消和 undo/redo 思路转化到 2D 视频工具，不复制无关的 3D 功能。
2. **按所有权组织代码。** 场景组装界面，领域对象拥有标注状态和命令，服务负责变换、缓存与进程边界，插件负责可替换的阶段行为。
3. **保持清晰接口。** 跨模块调用经过已记录的数据源、渲染、编辑和导出/回传契约；应用不得依赖插件私有字段。
4. **优先可维护、可测试的变更。** 每个改变状态的编辑都是一条已验证命令；输入输出使用防御性拷贝，失败可读且相互隔离。
5. **遵守 Part 1 边界。** 本检查点只实现 Part 1.4 要求的最小范围传播和本地训练交接包；不声明近似段自动发现、autosave、差异审阅、远程训练提交、性能测量或最终 MITK 设计评估已完成。Save 保持禁用，Export 在数据源成功打开后启用。

详细拓扑见 [docs/architecture.md](docs/architecture.md)，稳定扩展契约见 [docs/plugin-api.md](docs/plugin-api.md)。

## 当前前端布局

应用采用可调整宽度的三栏标注工作区。左栏是当前已接受数据集的只读浏览器，只显示真实帧和确实存在的元数据文件；它不是通用文件管理器，不负责重命名、删除、拖拽、写入或独立打开文件。中央是实际的 `AnnotationViewport`。右栏上方是可滚动的区域属性 Inspector，下方固定一个无分类、四列平铺的 `2D Tools` 工具区。

工作 Edit 插件按固定顺序提供十二个工具描述：Add Box、Subtract、Lasso、Fill、Erase、Close、Paint、Wipe、Region Growing、Live Wire、Selection、Move / Resize。其中只有 **Add Box、Fill、Erase、Selection、Move / Resize** 接入当前交互。其余七项只是明确的预留控件；点击后只显示 `待开发`，不会改变当前工具或标注状态。ToolPanel 本身不保存这些具体 ID，新 Edit 插件可以提供自己的描述而不修改核心。

该布局只调整客户端组合和导航呈现，不改变 Plugin API version 1，也不改变 Part 1 的 Source、Render、Edit、Feedback、Schema、Store、History 和 Python 契约。

## 支持的环境

已核对的参考环境为：

- **Godot 4.7.2-stable**，官方构建号 `ed1daf0bf`，使用 GDScript 和 GL 兼容渲染器。
- **Python 3.14.7**；软件包支持 Python `>=3.10,<3.15`。
- **FFmpeg 6.1+**，要求 `ffmpeg` 和 `ffprobe` 都在 `PATH` 中。视频集成测试和视频归一化必须使用 FFmpeg。
- Python 软件包版本锁定在 `requirements.lock`。

只有在明确记录版本和命令时，才接受等价环境。FFmpeg 测试被跳过表示环境检查未完成，不算通过。

## 快速开始

以下命令都必须从仓库根目录运行。

```bash
python3 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements.lock
.venv/bin/python -m pip install --no-deps -e .
```

将 `GODOT_BIN` 指向评审机器上安装的官方 Godot 4.7.2 可执行文件。如果 `godot` 已指向该版本，使用 `export GODOT_BIN=godot`。

```bash
export GODOT_BIN=/absolute/path/to/Godot_v4.7.2-stable_linux.x86_64
"$GODOT_BIN" --version
python3 --version
ffmpeg -version
ffprobe -version
```

Godot 版本输出必须以 `4.7.2.stable` 开头。只有两条 FFmpeg 命令都成功后，才接受完整测试结果。

在没有管理员权限的机器上，可以使用 Conda 在当前 checkout 内提供锁定版本的视频工具，无需修改 Python 虚拟环境：

```bash
CONDA_PKGS_DIRS="$PWD/.tools/conda-pkgs" conda create --yes \
  --prefix "$PWD/.tools/ffmpeg" --override-channels --channel conda-forge \
  ffmpeg=6.1.2
export PATH="$PWD/.tools/ffmpeg/bin:$PATH"
ffmpeg -version
ffprobe -version
```

`.tools/` 已被忽略，不得提交。

## 生成并验证必需样本

输出目录必须不存在。不传参数时，默认输出到 `sample/assignment_v1`，并使用固定种子 `6006`，确定性生成 120 帧 640×360 图像、模型标注、数据清单、哈希和缺陷清单：

```bash
.venv/bin/python python/make_sample_input.py
```

如需显式指定参数，等价命令为：

```bash
.venv/bin/python python/make_sample_input.py --output sample/assignment_v1 --seed 6006
.venv/bin/python python/validate_model_output.py sample/assignment_v1/model_output_v1.jsonl
```

生成器和独立验证器都必须输出 `Validation errors: 0` 并以状态 0 退出。`model_output_v1.jsonl` 的名称表示模型输出契约版本；每条记录里的 `source: "sample_v1"` 表示图像/帧来源，二者不能混用。生成器还会在 `hashes.json` 中记录包括模型输出在内的 SHA-256，用于证明输入文件未被验证器或客户端改写。

Part 1.1 只有一个权威 Schema：`core/schemas/model_output_v1.schema.json`。Python 独立入口是 `python/validate_model_output.py`，客户端等价验证器是 `client/domain/model_output_validator.gd`。数据清单属于帧源内部契约，不是 Part 1.1 的模型输出 Schema，也没有对外提供混合验证命令。

植入的样本情形包括区域漂移、错误类别、漏检区域、幻觉区域、track ID 交换和 40–59 近似相同帧段。

要将任意 FFmpeg 可读视频归一化为相同的索引目录契约，运行：

```bash
.venv/bin/python python/frame_source.py input.mp4 --output sample/normalized_video
```

之后客户端会像处理生成图像序列一样处理 `sample/normalized_video`。系统不以编解码器播放位置作为标注真值；manifest 帧索引和时间戳才是权威值。

规范化保留 FFmpeg 的默认显示方向变换，因此 manifest 宽高总是实际输出 PNG 的像素宽高，不是旋转前的编码宽高。合法的负起始时间戳会使用同一偏移整体平移到 `0`，保留原始可变帧率间隔；仅当所有帧都没有时间戳时，才按 `frame_index / nominal_fps` 合成时间。部分帧缺失时间戳会被明确拒绝，避免混用真实时间与推测时间。

## 运行测试

全新 clone 或新增 Godot 资源后，先执行一次无界面编辑器扫描，让 Godot 建立本地导入缓存：

```bash
"$GODOT_BIN" --headless --editor --quit --path .
.venv/bin/python -m pytest tests/python -q
"$GODOT_BIN" --headless --path . --script tests/godot/test_runner.gd
```

第一条命令只生成被 `.gitignore` 排除的 `.godot/` 导入缓存，不产生提交文件。只有在摘要中没有 failure，且没有跳过 FFmpeg 检查时，才接受 Python 门禁。Godot 测试会故意打开损坏的图像 fixture 来验证可恢复错误，因此可能出现引擎解码警告；最后必须输出 `PASS: complete Godot test suite`，且进程退出状态必须为 0。

## 运行客户端

```bash
"$GODOT_BIN" --editor --path .
```

在 Godot 中点击 Run，然后按以下 Part 1 评审路径操作：

1. 点击 **Open** 并选择单张图像（`.png`、`.jpg` 或 `.jpeg`）。确认左侧浏览器显示真实图像和 `Frames (1)`，没有虚构元数据；中央显示图像和 `Frame 0 (1 total)`。
2. 在右下工具区依次激活 Add Box、Fill、Erase、Selection 和 Move / Resize。任意时刻只允许一个可用工具保持按下，切换工具会取消未完成的预览。
3. 依次点击 Subtract、Lasso、Close、Paint、Wipe、Region Growing 和 Live Wire，确认状态栏精确显示 `待开发`。这些是不可用的预留控件，不是已实现功能。
4. 再次点击 **Open**，选择归一化目录 `sample/assignment_v1`。确认左侧帧数与 manifest 一致，只显示真实元数据文件；中央显示第 0 帧及模型区域，右侧 Inspector 可滚动，播放和时间线控件位于底部。
5. 尝试打开损坏或不支持的文件。状态栏必须说明拒绝原因，之前的浏览器、图像、标注、帧位置和历史记录仍可使用。
6. 调整工作区的两个分隔条，确认中央视口仍可用，并且没有引入停靠或文件管理行为。
7. 确认顶部仍包含 Open、Save、Undo、Redo 和 Export。Save 保持禁用；打开有效数据源后 Export 启用，选择父目录后生成新的 `training_update_v1/`，已有同名目录不会被覆盖。

### 当前键盘快捷键

| 操作 | 快捷键 |
|---|---|
| 向前/向后循环选择区域 | `Tab` / `Shift+Tab` |
| 将选中区域移动 1/5/10 图像像素 | `Arrow` / `Shift+Arrow` / `Ctrl+Shift+Arrow` |
| 将选中 box 缩放 1/5/10 图像像素 | `Alt+Arrow` / `Alt+Shift+Arrow` / `Alt+Ctrl+Shift+Arrow` |
| 开始键盘创建 box | `A` |
| 确认键盘 box | `Enter` |
| 删除选中区域 | `Delete` 或 `Backspace` |
| 撤销/重做 | `Ctrl+Z` / `Ctrl+Shift+Z` |
| 取消当前预览或手势 | `Escape` |
| 临时平移视口 | 按住 `Space` 并拖动，或中键拖动 |
| 缩放视口 | 鼠标滚轮或底部 `Zoom −` / `Zoom +` 控件 |

文本字段获得焦点时会消费键盘输入，因此编辑 Inspector 值不会触发画布快捷键。

## 插件概览

启动时，Registry 扫描 Main 的 `plugin_roots`（默认为 `client/plugins`），并按 API version 1 验证 manifest、抽象 Stage 继承和方法参数。Source 默认按 priority 路由，只有显式配置 `source_plugin_id` 才优先指定插件。

- Source：`image_sequence_source` 读取归一化目录；`single_image_source` 将 PNG/JPG/JPEG 适配为一个索引帧。Main 调用插件的 `can_open` 路由，通过 `get_presentation` 获取文件或服务器来源的浏览信息，不硬编码扩展名、`image_path` 或产物文件名分支。
- Render：`canvas_region_renderer` 通过共享视口变换绘制图像坐标中的区域。
- Edit：`basic_edit_tools` 提供工具描述和通用 `invoke` 动作，实现 Add Box、Fill、Erase、Selection、Move / Resize 以及可撤销的 `range_propagate`；其余七个工具保持明确的 `待开发` 边界。
- 导出/回传：`file_training_handoff` 验证修正快照并原子发布 `training_update_v1/`。包内 manifest 记录源数据/模型摘要、范围操作和 corrected JSONL 的字节数与 SHA-256；它不会覆盖 `model_output_v1.jsonl`。

新增插件只需要新插件目录、七字段 `plugin.json` 和对应 Stage 实现；独立团队目录追加到 `plugin_roots`，不应修改 Registry、Main 或 ToolPanel 的分支。精确方法、生命周期、所有权规则和兼容性测试见 [docs/plugin-api.md](docs/plugin-api.md)。

## 仓库布局

```text
client/                  Godot 场景、domain object、service 和 plugin
core/                    JSON Schema 和共享 taxonomy
python/                  样本生成、验证和视频归一化
tests/godot/             Godot headless 合同和集成测试
tests/python/            Python 合同、样本、视频和文档测试
docs/                    架构、插件 API、要求追踪和 Assignment
```

生成样本、Godot import、虚拟环境和大型资产不是源码产物，不得提交。Part 1 证据台账见 [docs/requirements-traceability.md](docs/requirements-traceability.md)，完整开发过程、文件、脚本、函数和提交前风险见 [docs/part1-implementation-report.md](docs/part1-implementation-report.md)。
