# 自动标注系统 （禁止自动修改）

## 前端 0.0.1

![Automated Annotation Tool frontend](docs/image.png)

## 项目架构
Project/

├── client/                       # Godot客户端

│   ├── app/                      应用入口、主界面组装与流程协调
|   ├── domain/                   标注数据、数据校验、几何处理、撤销与重做等业务逻辑                     
│   ├── pipeline/                 插件接口、发现注册与数据源装配
│   ├── plugins/                  数据读取、标注绘制、编辑、反馈导出的具体插件
│   ├── services/                 播放控制、帧缓存、坐标变换、视频导入等辅助服务
|   ├── ui/                       界面组件：标注画布、时间轴、工具面板、侧边栏等
│   └── workspace/                工作区与媒体管理、标注文件读写及自动保存
|

├── core/                         # JSON Schema

    ├── frame_sourse/              规定数据集说明文件需要包含哪些信息
    ├── schemas/                   定义单张图像或单帧的模型标注合同
    ├── taxonomy/                  默认类别，可以为空
    └── workspace/                 规定一个媒体对应的标注存档文件怎么组织，包括媒体 ID、媒体类型、来源路径，以及按帧编号保存的标注。

├── python/                       # python脚本

|   ├── frame_source.py           帧源脚本，负责解析视频源至图像
│   ├── make_batch.py(demo)       相似度与标注修正脚本
|   ├── make_sample_input.py      实例生成脚本
│   └── validate_model_output.pu  模型输出验证脚本
|   └──annotation_data/           上述脚本的函数脚本文件夹

├── pyproject.toml                # Python依赖
             
├── tests/                        # 测试文件夹

├── README.md                     # Env, install, run, reviewer test script, keyboard table

└── RESULTS.md                    # Design note, measurements, failure analysis


本项目使用 Godot 客户端和 Python 工具链，实现版本化、插件化的图像与视频标注工作流。

## 开发环境

本项目已经在以下环境中完成验证：

| 组件 | 已验证版本 |
|---|---|
| 操作系统 | Ubuntu 22.04 |
| Godot | Godot 4.7.2-stable |
| Python | Python 3.14.7 |
| FFmpeg | FFmpeg 6.1.2（要求 FFmpeg 6.1+） |
| OpenCV | `opencv-python-headless==4.14.0.94` |

Python 包支持 `>=3.10,<3.15`。所有 Python 依赖的精确版本记录在 `requirements.lock` 中。视频解码要求可执行的 `ffmpeg` 和 `ffprobe`：程序优先使用项目内 `.tools/ffmpeg/bin/`，缺失时才查找系统 `PATH`；正式视频集成测试则强制使用项目内的固定工具，缺失时直接失败而不是 skip。如果使用其他兼容的 Python 小版本或操作系统，需要重新运行本文的完整测试门禁来确认可复现性。

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

推荐 source 项目环境入口。它不修改 `.bashrc` 或系统目录；只在当前终端设置 `PROJECT6_ROOT`、`PROJECT6_PYTHON`、项目 FFmpeg `PATH` 和 `GODOT_BIN`，并验证版本与可执行性。重复 source 不会重复追加 PATH。

```bash
source scripts/project_env.sh
"$GODOT_BIN" --version
"$PROJECT6_PYTHON" --version
ffmpeg -version
ffprobe -version
```

脚本会依次查找已有 `GODOT_BIN`、系统 `godot4`/`godot`，以及 Linux 常用的 `~/下载`、`~/Downloads` 位置。Godot 输出必须以 `4.7.2.stable` 开头，FFmpeg 和 FFprobe 两条检查命令都必须成功。自定义 Godot 位置可先执行 `export GODOT_BIN=/absolute/path/to/Godot_v4.7.2-stable_linux.x86_64` 再 source。

当前项目已经具备可用的 `.venv` 和 `.tools/ffmpeg`，不需要安装系统 FFmpeg。仅在新 checkout 的脚本提示项目工具缺失时，才需要使用 Conda 在项目目录中部署已验证版本；不要求管理员权限：

```bash
CONDA_PKGS_DIRS="$PWD/.tools/conda-pkgs" conda create --yes \
  --prefix "$PWD/.tools/ffmpeg" --override-channels --channel conda-forge \
  ffmpeg=6.1.2
source scripts/project_env.sh
```

Godot 视频导入器会优先直接使用项目内的 `.tools/ffmpeg/bin/ffmpeg` 和
`.tools/ffmpeg/bin/ffprobe`，因此从桌面或 Godot 编辑器启动客户端时不依赖终端的
`PATH`。项目内和系统工具都不存在时，CLI 会同时报告缺少的工具名、预期项目路径
和 `PATH` 回退条件，不再只显示不明确的 `[Errno 2]`。


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

输出目录必须不存在。同一 seed 会产生相同文件和 SHA-256。样本每帧约含 20 个 regions，包括一个 12 顶点凹 complex polygon；同时包含 drifted regions、wrong class labels、一个 missed region、一个 hallucinated region、一次 track-id swap，以及第 40–59 帧的 near-identical segment。

### 2. 验证样本

```bash
.venv/bin/python python/validate_model_output.py sample/assignment_v1/model_output_v1.jsonl
```

成功时命令退出状态为 `0`，并输出：

```text
Validation errors: 0
```

权威 Schema 位于 `core/schemas/model_output_v1.schema.json`，Godot 等价验证器位于 `client/domain/model_output_validator.gd`。

### 3. 导入视频或使用 CLI 转换

客户端推荐流程：点击 **Open** 选择视频，明确选择输出父目录并输入一个尚不存在的新目录名，然后点击 **Start import**。Godot 使用项目固定的 `.venv/bin/python` 在后台执行归一化；进度窗口显示 `probe`、`extract`、`validate`、`publish`，可以安全取消。成功后客户端自动打开新目录；失败或取消不会替换当前数据集。

也可以直接使用兼容的原有 CLI：

```bash
.venv/bin/python python/frame_source.py input.mp4 --output sample/normalized_video
```

该命令把任意 FFmpeg 可读取的视频转换为带显式索引和时间戳的归一化目录。客户端将视频转换结果与原生图像序列统一视为 frames-from-a-source。GUI 不回退到系统 Python；如果 `.venv/bin/python`、`ffmpeg` 或 `ffprobe` 缺失，先按“开发环境”修复，不要绕过已验证工具链。

Part 3.1 已验证的播放控件为 **Previous**、**Play**、**Pause** 和 **Next**；时间显示采用 `HH:MM:SS.mmm`。其真实导入、连续播放与 10,000 帧压力测试证据见 [RESULTS.md](RESULTS.md)，不依赖 Part 2.2/2.3 的待验证重建。

### 4. 启动客户端

首次运行或新增 Godot 资源后，先生成本地导入缓存：

```bash
"$GODOT_BIN" --headless --editor --quit --path .
```

然后启动 Godot 编辑器并点击 **Run Project**：

```bash
"$GODOT_BIN" --editor --path .
```

## Part 2.1 流畅渲染实现

`AnnotationViewport` 只使用一个共享的 image↔viewport `Transform2D`，让等比显示、zoom/pan、overlay 绘制与鼠标 picking 遵守同一套坐标契约。Part 2.1 已验证的 **Overlay opacity** 与 **Fit** 保持在该显示路径中。视口实行 dirty redraw：只在 texture、record、selection、opacity 或变换真正改变后调用 `queue_redraw()`，重复设置同一状态不会再次入队。

Renderer 仅在 annotation record 改变时解析并缓存 image-space primitives，包括 geometry、class color、label 和 bounds。zoom、pan、selection 与 opacity 只重建 screen-space draw commands，不重新解析原始字典；变换后的 AABB 完全离开视口时，该 region 不会生成绘制指令。拖动预览会修改当前 record snapshot，因此需要重建 geometry，但预览不写入 Store，释放鼠标后才通过单个 command 提交。

可见 1280×800 基准在 20 个 box/polygon regions 上执行 2 s 预热和 10 s pan、zoom、真实 Selection region drag，记录为平均 `175.27 fps`、p95 帧间隔 `9.572 ms`、拖动坐标误差 `0.0` image px。该次 X11 / Godot 4.7.2 GL Compatibility 会话使用 `llvmpipe`软件适配器；这是当前实测配置的证据，不是对所有笔记本或硬件 GPU 的性能承诺。原始数据见 `benchmarks/part2_1_display.json`，完整限制见 [RESULTS.md](RESULTS.md)。当前路径未使用 shader、texture atlas、mesh batching 或 polygon 预三角化；只有后续 profiler 证明高顶点 polygon 成为瓶颈时才应升级该局部路径。

## Part 2.3 交互设计说明

本项目参考 MITK Segmentation View，借鉴了区域选择与高亮、绘制过程中的可视反馈、标签命名与建议列表，以及可撤销的编辑流程。用户能够明确看到当前编辑对象和操作结果，未确认的草稿可以取消。
针对二维视频中的框和多边形，本项目增加了拖动移动、八柄缩放及 1/5/10 px 键盘微移。重标注通过双击右侧标签行打开，支持列表、自由文本和滚轮选择；橡皮擦无需预选区域，可一次处理多个对象，并将整笔操作作为一次撤销。Fill 支持近闭合轮廓修补，先显示填充和修补预览，再由用户确认。
本项目未实现三维体数据编辑、切片插值、Region Growing、Live Wire 和可选的多边形顶点编辑，范围集中于现有模型区域的人工修正。持久化数据保持 Model Output V1；产生孔洞、多连通分量等无法表示的结果时，整体拒绝并说明原因。
报告已列出自动化测试和性能证据，明确保留“人工 reviewer 尚未完成”的状态。本次 12 项文档测试通过。

## Part 3.1 如何处理帧索引和标注记录的一致性问题

视频首先通过 FFmpeg 无丢帧解码为零起、连续编号的图像序列，并在 manifest 中为每帧记录唯一的 frame、time_s 和 image_path。载入时，系统严格检查帧数量、索引连续性、图像文件以及标注记录的数量和顺序，并要求每条标注的 frame 与对应 manifest 索引一致。客户端始终使用同一索引同时读取图像、时间戳和标注，三者全部加载成功后才切换当前帧。播放过程每次只前进一个明确索引，不通过追帧跳过中间帧，从而避免图像与标注错位。

## Plugin API 概览

Registry 在启动时扫描 `client/plugins`，验证插件 manifest、API version、Stage 继承关系和方法参数。当前四个扩展点均至少有一个工作插件：

- **Source：**`image_sequence_source` 读取归一化目录，`single_image_source` 将单张图像适配为一个索引帧。
- **Render：**`canvas_region_renderer` 使用共享视口变换绘制图像和 regions。
- **Edit tools：**`basic_edit_tools` 的 Part 2.2 十工具重建仍待验证；其目标由上节定义，当前旧运行时不作为交付证据。
- **Export / Feedback：**`file_training_handoff` 验证修正记录并原子生成本地训练交接包。

新增插件只需在相应 stage 目录中添加 `plugin.json` 和 Stage 实现，不需要修改 Registry 或 core。完整 manifest 字段、方法签名、生命周期、深拷贝和错误隔离规则见 [docs/plugin-api.md](docs/plugin-api.md)。

## 运行测试

```bash
"$GODOT_BIN" --headless --editor --quit --path .
.venv/bin/python -m pytest tests/python -q
"$GODOT_BIN" --headless --path . --script tests/godot/test_runner.gd
"$GODOT_BIN" --headless --path . --script tests/godot/test_polygon_ops.gd
"$GODOT_BIN" --headless --path . --script tests/godot/test_image_region_algorithms.gd
"$GODOT_BIN" --headless --path . --script tests/godot/test_advanced_edit_tools.gd
"$GODOT_BIN" --headless --path . --script tests/godot/test_keyboard_reachability.gd
"$GODOT_BIN" --path . --script tests/godot/display_benchmark.gd -- \
  --output /tmp/part2_1_display.json --warmup 2 --duration 10
.venv/bin/python benchmarks/make_part3_sources.py \
  --playback-output /tmp/annotool-part3-playback \
  --stress-output /tmp/annotool-part3-stress
"$GODOT_BIN" --path . --script tests/godot/playback_benchmark.gd -- \
  --source /tmp/annotool-part3-playback --output /tmp/part3_1_playback.json --duration 10
"$GODOT_BIN" --headless --path . --script tests/godot/long_source_benchmark.gd -- \
  --source /tmp/annotool-part3-stress --output /tmp/part3_1_long_source.json
ffmpeg -hide_banner -loglevel error -f lavfi \
  -i testsrc=size=640x360:rate=30 -t 3 -c:v ffv1 /tmp/part3_input.mkv
"$GODOT_BIN" --headless --path . --script tests/godot/video_import_benchmark.gd -- \
  --input /tmp/part3_input.mkv --output /tmp/part3_normalized \
  --result /tmp/part3_1_import.json
```

基准的 `/tmp` 源目录、视频和输出目录都必须预先不存在；如需重跑，请换用新的临时名称。Python 测试必须没有 failure，也不能因为缺少 FFmpeg/FFprobe 而跳过视频集成测试。Godot 测试可能因故意打开损坏图片 fixture 而打印解码警告，但最后必须输出 `PASS: complete Godot test suite`，并以状态 `0` 退出。Part 3.1 可见播放基准要求索引严格连续且零跳帧；性能不足时允许实际播放率低于 nominal FPS，但必须在 `RESULTS.md` 如实记录。




