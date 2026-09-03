# 自动标注系统

## 前端 0.0.1

![Automated Annotation Tool frontend](docs/image.png)

本项目使用 Godot 客户端和 Python 工具链，实现版本化、插件化的图像与视频标注工作流。当前仓库完成 Assignment Part 1：数据契约、可复现样本、视频帧源、插件注册表，以及每个必需扩展点的工作插件。

## 当前交付范围

- 已完成 Part 1.1–1.4，并提供 Python 与 Godot 自动测试。
- 原始模型输出以 `model_output_vX` 命名并保持只读；编辑结果保存在独立副本中。
- 当前客户端提供 Part 1 所需的最小编辑与本地训练交接能力。
- 前端的大概雏形

详细设计见 [架构说明](docs/architecture.md)，扩展规范见 [Plugin API version 1](docs/plugin-api.md)。

## 开发原则

- 以 MITK 作为 2D 标注交互参考。
- 明确数据和状态所有权，保持模型输出不可变。
- 通过清晰接口连接 Source、Render、Edit 和 Feedback。
- 优先保证可维护、可测试，并遵守 Part 1 边界。

## 开发环境

本项目已经在以下环境中完成验证：

| 组件 | 已验证版本 |
|---|---|
| 操作系统 | Ubuntu 22.04 |
| Godot | Godot 4.7.2-stable |
| Python | Python 3.14.7 |
| FFmpeg | FFmpeg 6.1.2（要求 FFmpeg 6.1+） |
| OpenCV | `opencv-python-headless==4.14.0.94` |

Python 包支持 `>=3.10,<3.15`。所有 Python 依赖的精确版本记录在 `requirements.lock` 中；视频解码同时要求 `ffmpeg` 和 `ffprobe` 位于 `PATH`。如果使用其他兼容的 Python 小版本或操作系统，需要重新运行本文的完整测试门禁来确认可复现性。

## 环境搭建

以下命令均从仓库根目录运行。

### 1. 创建 Python 环境

```bash
python3.14 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
```

如果系统使用其他受支持的 Python 版本，请将 `python3.14` 替换成相应命令，并确认版本满足 `>=3.10,<3.15`。

### 2. 下载依赖

以下两条命令需要依次执行：

```bash
.venv/bin/python -m pip install -r requirements.lock
.venv/bin/python -m pip install --no-deps -e .
```

第一条安装锁定的第三方依赖；第二条安装当前项目，但不会重新解析依赖版本。

### 3. 配置必要工具

将 `GODOT_BIN` 指向 Godot 4.7.2-stable 可执行文件。如果系统中的 `godot` 已是正确版本，可以使用 `export GODOT_BIN=godot`。

```bash
export GODOT_BIN=/absolute/path/to/Godot_v4.7.2-stable_linux.x86_64
"$GODOT_BIN" --version
.venv/bin/python --version
ffmpeg -version
ffprobe -version
```

Godot 输出必须以 `4.7.2.stable` 开头，FFmpeg 和 FFprobe 两条检查命令都必须成功。没有管理员权限时，可以使用 Conda 在项目目录中安装已验证的 FFmpeg：

```bash
CONDA_PKGS_DIRS="$PWD/.tools/conda-pkgs" conda create --yes \
  --prefix "$PWD/.tools/ffmpeg" --override-channels --channel conda-forge \
  ffmpeg=6.1.2
export PATH="$PWD/.tools/ffmpeg/bin:$PATH"
```


## 快速开始

### 1. 生成可复现样本

默认命令使用固定种子 `6006`，将 120 帧合成图像和匹配标注生成到 `sample/assignment_v1`：

```bash
.venv/bin/python python/make_sample_input.py
```

等价的显式命令为：

```bash
.venv/bin/python python/make_sample_input.py --output sample/assignment_v1 --seed 6006
```

输出目录必须不存在。同一 seed 会产生相同文件和 SHA-256。样本包含 drifted regions、wrong class labels、一个 missed region、一个 hallucinated region、一次 track-id swap，以及第 40–59 帧的 near-identical segment。

### 2. 验证样本

```bash
.venv/bin/python python/validate_model_output.py sample/assignment_v1/model_output_v1.jsonl
```

成功时命令退出状态为 `0`，并输出：

```text
Validation errors: 0
```

权威 Schema 位于 `core/schemas/model_output_v1.schema.json`，Godot 等价验证器位于 `client/domain/model_output_validator.gd`。

### 3. 将视频转换为统一帧源

```bash
.venv/bin/python python/frame_source.py input.mp4 --output sample/normalized_video
```

该命令把任意 FFmpeg 可读取的视频转换为带显式索引和时间戳的归一化目录。客户端将视频转换结果与原生图像序列统一视为 frames-from-a-source。

### 4. 启动客户端

首次运行或新增 Godot 资源后，先生成本地导入缓存：

```bash
"$GODOT_BIN" --headless --editor --quit --path .
```

然后启动 Godot 编辑器并点击 **Run Project**：

```bash
"$GODOT_BIN" --editor --path .
```

## Reviewer test script

1. 点击 **Open**，选择一张 `.png`、`.jpg` 或 `.jpeg` 单张图像。确认左侧显示 `Frames (1)`，中央显示 `Frame 0 (1 total)`。
2. 依次激活 Add Box、Fill、Erase、Selection 和 Move / Resize，确认切换工具会取消未完成的预览。
3. 点击 Subtract、Lasso、Close、Paint、Wipe、Region Growing 和 Live Wire，确认状态栏显示 `待开发`，且标注状态不变。
4. 再次点击 **Open**，选择归一化目录 `sample/assignment_v1`。确认帧数与 manifest 一致，第 0 帧和模型区域正常显示。
5. 使用 Previous、Play、Next 和 timeline 导航，确认显式帧号与图像、时间和 annotation 保持一致。
6. 尝试打开损坏或不支持的文件，确认状态栏给出可读错误，当前数据和历史仍然可用。
7. 确认顶部包含 Open、Save、Undo、Redo 和 Export。当前 Save 保持禁用；成功打开数据源后 Export 启用。
8. 选择 Export 的父目录，确认生成新的 `training_update_v1/`，并且已有同名目标不会被覆盖。

## 当前键盘快捷键

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
| 缩放视口 | 鼠标滚轮或 `Zoom -` / `Zoom +` |

文本字段获得焦点时会消费键盘输入，因此编辑 Inspector 值不会触发画布快捷键。

## Plugin API 概览

Registry 在启动时扫描 `client/plugins`，验证插件 manifest、API version、Stage 继承关系和方法参数。当前四个扩展点均至少有一个工作插件：

- **Source：**`image_sequence_source` 读取归一化目录，`single_image_source` 将单张图像适配为一个索引帧。
- **Render：**`canvas_region_renderer` 使用共享视口变换绘制图像和 regions。
- **Edit tools：**`basic_edit_tools` 提供选择、移动/缩放、重分类、添加、删除、填充和 `range_propagate` 等动作。
- **Export / Feedback：**`file_training_handoff` 验证修正记录并原子生成本地训练交接包。

新增插件只需在相应 stage 目录中添加 `plugin.json` 和 Stage 实现，不需要修改 Registry 或 core。完整 manifest 字段、方法签名、生命周期、深拷贝和错误隔离规则见 [docs/plugin-api.md](docs/plugin-api.md)。

## 运行测试

```bash
"$GODOT_BIN" --headless --editor --quit --path .
.venv/bin/python -m pytest tests/python -q
"$GODOT_BIN" --headless --path . --script tests/godot/test_runner.gd
```

Python 测试必须没有 failure，也不能因为缺少 FFmpeg/FFprobe 而跳过视频集成测试。Godot 测试可能因故意打开损坏图片 fixture 而打印解码警告，但最后必须输出 `PASS: complete Godot test suite`，并以状态 `0` 退出。

## 仓库布局与文档

```text
client/                  Godot app、pipeline、Stage 和 plugins
core/                    JSON Schema、taxonomy 和共享 fixtures
python/                  样本生成、数据验证和视频帧源工具
tests/godot/             Godot headless 单元与集成测试
tests/python/            Python 合同、样本、视频和文档测试
docs/                    Assignment、架构、Plugin API 和追踪文档
```

- [Architecture diagram](docs/architecture.md)
- [Plugin API version 1](docs/plugin-api.md)
- [Part 1 requirements traceability](docs/requirements-traceability.md)
- [Part 1 implementation report](docs/part1-implementation-report.md)

生成样本、Godot import cache、虚拟环境、本地工具和大型二进制资产均不得提交。仓库也不得包含 API key、凭据或私有配置。
