# 自动标注系统

## 前端 0.0.1

![Automated Annotation Tool frontend](docs/前端标注.png)
![Automated Annotation Tool frontend](docs/批量.png)

## 项目架构
Project/

├── client/                       # Godot客户端

    ├── app/                      应用入口、主界面组装与流程协调
    ├── domain/                   标注数据、数据校验、几何处理、撤销与重做等业务逻辑                     
    ├── pipeline/                 插件接口、发现注册与数据源装配
    ├── plugins/                  数据读取、标注绘制、编辑、反馈导出的具体插件
    ├── services/                 播放控制、帧缓存、坐标变换、视频导入等辅助服务
    ├── ui/                       界面组件：标注画布、时间轴、工具面板、侧边栏等
    └── workspace/                工作区与媒体管理、标注文件读写及自动保存


├── core/                         # JSON Schema

    ├── frame_source/              规定数据集说明文件需要包含哪些信息
    ├── schemas/                   定义单张图像或单帧的模型标注合同
    ├── taxonomy/                  默认类别，可以为空
    └── workspace/                 规定一个媒体对应的标注存档文件怎么组织，包括媒体 ID、媒体类型、来源路径，以及按帧编号保存的标注。

├── python/                       # python脚本

    ├── frame_source.py           帧源脚本，负责解析视频源至图像
    ├── propagate_polygons.py    Poly 光流与边缘精修 worker
    ├── model_assist_worker.py   单帧 SAM 2 JSONL worker
    ├── model_assist_smoke.py    真实外部运行时验收驱动
    ├── make_sample_input.py      实例生成脚本
    ├── validate_model_output.py  模型输出验证脚本
    └── annotation_data/          可测试的 Python 领域实现

├── pyproject.toml                # Python包与唯一依赖配置
├── project_env.sh                # 本地工具版本检查与环境入口
             
├── tests/                        # 测试文件夹

├── README.md                     # Env, install, run, reviewer test script, keyboard table

└── RESULTS.md                    # Design note, measurements, failure analysis


本项目使用 Godot 客户端和 Python 工具链，实现版本化、插件化的图像与视频标注工作流。



本项目已经在以下环境中完成验证：

| 组件 | 已验证版本 |
|---|---|
| 操作系统 | Ubuntu 22.04 |
| Godot | Godot 4.7.2-stable |
| Python | Python 3.14.7 |
| FFmpeg | FFmpeg 6.1.2（要求 FFmpeg 6.1+） |
| OpenCV | `opencv-python-headless==4.14.0.94` |

Python 包支持 `>=3.12,<3.15`，`pyproject.toml` 是唯一的 Python 依赖配置，运行与开发依赖均固定为已验证版本。视频解码要求可执行的 `ffmpeg` 和 `ffprobe`：程序优先使用项目内 `.tools/ffmpeg/bin/`，缺失时才查找系统 `PATH`。



以下命令均从仓库根目录运行：

```bash
python3.14 -m venv .venv
.venv/bin/python -m pip install -e ".[dev]"
source project_env.sh
```

`project_env.sh` 只校验项目 Python、Godot 4.7.2-stable 以及 FFmpeg/FFprobe 6.1+，并为当前终端设置路径；它不安装 Python 包，也不修改系统环境。
# 正在开发和优化的功能

1. 大规模标注持久化的内存保护和尾延迟优化。
2. 单帧 Model Assist 工具已实现；待用户确认外部 Conda/SAM 2 安装与官方权重后完成真实模型验收。
3. Part 5 模型插件与更大数据集的稳健性评估。


# 已经完成的工作
# Part 1

## Part 2.1 显示

一、等比例适配_update_matrices()
设原图尺寸为 W_i,H_i，视口尺寸为 W_v,H_v。
代码采用：
s_fit=min(W_v/W_i,H_v/H_i)
这样横纵使用同一个比例，不会把图像拉伸变形。

二、渲染
1.状态没有变化，就不要求重绘。
    func set_record(record: Dictionary) -> void:
        if _record == record:
            return
2.分开缓存图像空间几何和屏幕绘制指令。
3.不绘制完全离开视口的区域。
    _primitive_is_visible() 把区域包围盒变换到视口坐标，再判断与视口是否相交。完全不可见的区域不生成绘制指令。

## Part 2.3 交互设计说明

本项目参考 MITK Segmentation View，借鉴了区域选择与高亮、绘制过程中的可视反馈、标签命名与建议列表，以及可撤销的编辑流程。用户能够明确看到当前编辑对象和操作结果，未确认的草稿可以取消。
针对二维视频中的框和多边形，本项目增加了拖动移动、八柄缩放及 1/5/10 px 键盘微移。重标注通过双击右侧标签行打开，支持列表、自由文本和滚轮选择；橡皮擦无需预选区域，可一次处理多个对象，并将整笔操作作为一次撤销。Fill 支持近闭合轮廓修补，先显示填充和修补预览，再由用户确认。
本项目未实现三维体数据编辑、切片插值、Region Growing 和 Live Wire；已保留多边形原始点的可见顶点编辑。持久化数据保持 Model Output V1；产生孔洞、多连通分量等无法表示的结果时，整体拒绝并说明原因。
报告已列出自动化测试和性能证据，明确保留“人工 reviewer 尚未完成”的状态。本次 15 项文档测试通过。

## 单帧 Model Assist

`Model Assist` 是标注页的第八个单帧工具，不是 Batch 算法。无选区时它生成待分类新 Poly；选中已有 Box/Poly 时只修正该区域的几何，保留 ID、类别和属性。按无修饰键 `M` 进入；左键添加正点，Shift+左键添加负点，Ctrl+拖动设置唯一 box，Backspace 撤销最后一个提示。侧栏动作可切换 candidate、Apply、Cancel、Retry 或重新检查运行时。

首个提示会冻结原始帧 ID、连续播放索引、图像 SHA-256、record SHA-256 和修正目标。过期或已取消结果不能写 Store；候选 mask 必须是 worker 目录内的有哈希二值 PNG，并转换为无孔、单连通、非自交的 Model Output V1 Poly。创建与修正都只以一条命令进入 undo/redo。

运行时只从 `PROJECT6_MODEL_PYTHON`、`PROJECT6_SAM2_CONFIG`、`PROJECT6_SAM2_CHECKPOINT` 和 `PROJECT6_SAM2_DEVICE=auto|cpu|cuda` 读取显式配置。工具只做非阻塞 preflight，显示 CPU/CUDA badge，不会为用户安装 `sam2` 或下载 checkpoint。可复用的 `model-assist-v1` 真实模型驱动是 `python/model_assist_smoke.py`，完整 smoke 命令和人工 UI 闭环见 [Model Assist 真实 SAM 2 验收](docs/model-assist-acceptance.md)；当前 fake-worker 自动证据已通过，real SAM 仍为 NOT RUN，不能混为真实模型 PASS。

## Part 3.1 如何处理帧索引和标注记录的一致性问题

视频首先通过 FFmpeg 无丢帧解码为零起、连续编号的图像序列，并在 manifest 中为每帧记录唯一的 frame、time_s 和 image_path。载入时，系统严格检查帧数量、索引连续性、图像文件以及标注记录的数量和顺序，并要求每条标注的 frame 与对应 manifest 索引一致。客户端始终使用同一索引同时读取图像、时间戳和标注，三者全部加载成功后才切换当前帧。播放过程每次只前进一个明确索引，不通过追帧跳过中间帧，从而避免图像与标注错位。

## Part 3.2 相似帧判断与自动标注

默认算法是 `poly-sim-flow-edge-v1`。当前流程为：修正带 Poly 的参考帧 → 分析相似且连续的实际帧 → 用光流传播轮廓并在其附近尝试边缘精修 → 预览、必要时缩小范围 → 以覆盖或合并模式一次应用 → 人工逐帧检查并确认。固定坐标复制仍保留为兼容选项，但不是默认算法。

每张实际 Source 图像先由 Godot 保存为本任务的冻结 PNG；Python 对同一批快照用 OpenCV `INTER_AREA` 缩小到 64×64 灰度图，计算归一化平均绝对差。目标帧与相邻帧、目标帧与固定人工参考帧的两个 MAD 必须都严格小于界面可见阈值，默认 `0.02`，否则该方向停止且不进入光流或边缘处理。

通过相似度门后，OpenCV DIS 在相邻帧间估计双向光流，把上一步 mask 传播到目标帧；非相邻目标还与固定参考帧直接估计，检查传播 mask 的一致性、纹理、外观、面积和锚点 IoU。任何 Poly 未通过固定质量门，该方向就在当前帧停止，不跳帧，也不生成自动确认结果。

通过光流门的候选在原始 mask 周围 6 image-px 的带状区域内运行三次迭代的 GrabCut，并用 Sobel 边界强度评价。仅当候选仍为一个无孔简单连通区域、未触碰裁剪边界、与原 mask 的 IoU `>=0.85`、面积比例在 `[0.80,1.25]`、Hausdorff 距离 `<=6` image px，且边缘分数至少提升 `0.01` 时接受精修；预期性拒绝会精确保留光流 mask，并在 UI/audit 中标为“光流回退”。运行时或协议异常则丢弃整份计划，不把异常当作安全回退。

每批最多包含 30 个连续原始帧号；已确认帧、帧号缺口、尺寸变化、读图失败和 Source/标注/确认状态变化都会停止或使计划失效。预览和提交消费同一份逐帧冻结候选，提交是一次可撤销/重做的命令，目标帧仍为待检查。覆盖只保留传播得到的参考 Poly；合并按同一 region ID 更新 Poly并保留目标帧独有区域。批量 provenance 使用 v2 marker，Model Output V1 几何协议保持不变。

使用、算法边界、复现命令和 Endoscapes 定性验收见 [Poly 轮廓运动传播](docs/poly-propagation.md)；量化结果和不能外推的边界见 [RESULTS.md](RESULTS.md)。Endoscapes fixture 只复制或链接显式选定帧，记录源文件 SHA-256；数据集图像、mask、绝对本地路径和本地验收产物均不进入 Git。

## Part 4 持久化、差异审计与训练交接

客户端分别保留模型基线、人工修正和内容验证状态。工作区及直接打开的 Source 均支持后台自动保存、Save / Ctrl+S 和未保存提示；旧 V1/V2 标签以备份方式迁移到 V3。Export 默认生成仅含已验证帧的训练包，另可生成全帧评审快照，附带帧映射、JSON/CSV diff 和 SHA-256 校验。模型返回经校验后进入独立轮次，旧轮次保留。

从仓库根运行完整演示，输出目录须为新目录：

```bash
source project_env.sh
"$PROJECT6_PYTHON" python/part4.py demo --output output/part4-demo
```

演示使用真实编辑与验证命令，等待自动保存，重开并导出 6 帧训练包和 120 帧评审快照，再导入模拟的新模型轮次；不依赖本地 `tests/` 或已有 `sample/`，不执行训练。`evidence.json` 记录文件路径和结果。CLI 另提供 `export`、`validate-package`、`import-round`。

输出到仓库 `output/` 时会自动保留或创建 `.gdignore`，使 CSV 报告避开 Godot 资源导入。也可输出到项目外目录；其他项目内目标需要已有 `.gdignore` 祖先文件，详见评审步骤。

[设计规范](docs/part4-design.md) · [任务清单](docs/part4-development-plan.md) · [协作协议](docs/part4-protocol.md) · [CLI/UI 评审步骤](docs/part4-review.md) · [测量与故障证据](RESULTS.md)

# 其他

## 开发环境

## Plugin API 概览

Registry 在启动时扫描 `client/plugins`，验证插件 manifest、API version、Stage 继承关系和方法参数。当前四个扩展点均至少有一个工作插件：

- **Source：**`image_sequence_source` 读取归一化目录，`numeric_image_sequence_source` 保留稀疏原始帧号，`single_image_source` 将单张图像适配为一个索引帧。
- **Render：**`canvas_region_renderer` 使用共享视口变换绘制图像和 regions。
- **Edit tools：**`basic_edit_tools` 保留 Add Box、Subtract、Lasso、Fill、Paint、Eraser 和 Select 七个 Assignment 工具，并追加单帧 Model Assist；实现已通过自动化门禁，真实 SAM/UI 验收边界单独保留。
- **Export / Feedback：**`file_training_handoff` 验证修正记录并原子生成本地训练交接包。

新增插件只需在相应 stage 目录中添加 `plugin.json` 和 Stage 实现，不需要修改 Registry 或 core。完整 manifest 字段、方法签名、生命周期、深拷贝和错误隔离规则见 [docs/plugin-api.md](docs/plugin-api.md)。

## 运行测试

```bash
tests/run_tests.sh
"$GODOT_BIN" --headless --editor --quit --path .
.venv/bin/python -m pytest tests/python -q
"$GODOT_BIN" --headless --path . --script tests/godot/test_runner.gd
"$GODOT_BIN" --headless --path . --script tests/godot/test_polygon_ops.gd
"$GODOT_BIN" --headless --path . --script tests/godot/test_image_region_algorithms.gd
"$GODOT_BIN" --headless --path . --script tests/godot/test_advanced_edit_tools.gd
"$GODOT_BIN" --headless --path . --script tests/godot/test_keyboard_reachability.gd
"$GODOT_BIN" --path . --script tests/godot/display_benchmark.gd -- \
  --output /tmp/part2_1_display.json --warmup 2 --duration 10
.venv/bin/python tests/benchmarks/make_part3_sources.py \
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

基准的 `/tmp` 源目录、视频和输出目录都必须预先不存在；如需重跑，请换用新的临时名称。`tests/run_tests.sh` 是权威回归入口：它把拥有外部进程的 Model Assist service 测试与纯组件套件分开运行，并审核每个 Godot 日志。聚合套件只接受四组故意损坏 PNG fixture 的精确解码错误；受限主机上的 editor-only 探针只接受两次固定的本地调试 socket 失败对。任何 `SCRIPT ERROR`、未处理异常、计数或文本变化及其他 `ERROR:` 都使门禁失败。Python 测试不能有 failure，也不能因缺少 FFmpeg/FFprobe 而跳过视频集成测试。Part 3.1 可见播放基准要求索引严格连续且零跳帧；性能不足时允许实际播放率低于 nominal FPS，但必须在 `RESULTS.md` 如实记录。真实 SAM 运行时不属于默认回归，必须用显式外部配置单独验收。

## Python 环境配置

## 快捷键

一、工具选择与启动
快捷键	对应工具	实际作用
V	Select / Selection	切换到选择工具，用于选择、移动、缩放区域
A	Add Box	开始键盘新建矩形框，出现待调整的框
L	Lasso	没有选中 polygon 时，开始键盘绘制多边形；选中了已有 polygon 时，进入其顶点编辑
S	Subtract	开始键盘绘制扣除轮廓
F	Fill	进入键盘填充模式，使用方向键移动填充种子点
P	Paint	开始键盘画笔绘制
Shift + P	Eraser	开始键盘橡皮擦操作
M	Model Assist	切换到当前帧 SAM 2 Poly 创建/修正工具；不自动发起推理


这些绑定来自编辑插件的 handle_key()。其中 A / S / L / F / P / Shift+P 不只是选中工具按钮，还会进入对应的键盘操作流程；M 只选中 Model Assist，首个鼠标提示才冻结上下文并发起请求。若你准备使用鼠标绘制，可以直接点击工具按钮。
正在绘制时，草稿会优先接管按键。切换操作前，应先完成当前绘制，或者按 Esc 取消。
二、选择、移动、缩放与删除
1. 选择和删除对象
快捷键	功能	生效条件
[	选择上一个区域	普通空闲编辑状态，不处于绘制或顶点编辑中
]	选择下一个区域	同上，按当前帧的区域列表循环选择
Delete 或 Backspace	删除整个选中区域	Select 工具处于空闲状态
Esc	清除当前选择	Select 工具处于空闲状态
R	打开选中区域的类别修改窗口	已选中区域，且没有正在进行的拖动或绘制


R 由 main.gd 处理，其他操作主要由编辑插件处理。正在拖动区域时，R 不会中断拖动去打开重分类窗口。
2. 移动与缩放
下表的像素单位都是原图像素，不是缩放后屏幕上的像素。
快捷键	功能
↑ / ↓ / ← / →	沿对应方向移动 1 px
Shift + 方向键	沿对应方向移动 5 px
Ctrl + Shift + 方向键	沿对应方向移动 10 px
Alt + 方向键	调整区域大小，步长 1 px
Alt + Shift + 方向键	调整区域大小，步长 5 px
Ctrl + Alt + Shift + 方向键	调整区域大小，步长 10 px


这些移动、缩放操作适用于 Select 中的已选中对象，也适用于 A 创建的待确认矩形框。对于矩形，Alt+←/→ 减小/增大宽度，Alt+↑/↓ 减小/增大高度；对于 Select 中的 polygon，会通过包围盒调整其几何大小。
你的步长判断明确是：
10.0 if event.ctrl_pressed and event.shift_pressed \
else (5.0 if event.shift_pressed else 1.0)
所以，10 px 是 Ctrl+Shift+方向键，不是单独的 Ctrl+方向键。
三、键盘绘制过程中怎么操作
当前操作	调整方式	完成方式	回退或取消
A：新建矩形框	方向键移动；Alt+方向键 调整宽高	Enter 确认几何，进入类别确认窗口	Esc 取消
L：新建多边形	方向键移动光标并追加路径点	Space 空格闭合轮廓，合法后进入类别确认	Backspace 删除最后一点；Esc 取消
S：扣除轮廓	方向键绘制扣除路径	Space 空格闭合并尝试执行扣除	Backspace 删除最后一点；Esc 取消
P / Shift+P：画笔或擦除	方向键移动并形成笔画	Enter 结束笔画并尝试提交	Esc 取消
F：填充	方向键移动填充种子点	Enter 在当前种子位置执行填充	Esc 取消当前操作
Fill 缺口修补预览	检查候选填充和修补位置	Enter 接受修补候选	Esc 拒绝候选，返回之前的草稿


绘制中的方向键同样支持 1 / 5 / 10 px 步长。Lasso 和 Subtract 的完成键是空格；代码会接收 Enter，但不会用它完成轮廓。
新建对象的几何完成后，还需要确认类别，才会形成正式标注；不能把第一次 Enter 或空格理解为已经完成全部保存流程。
四、多边形顶点编辑
已保存的 polygon
先选中已有多边形，再按 L 进入顶点编辑。
快捷键或操作	功能
[ / ]	切换到上一个 / 下一个顶点
方向键	移动当前顶点 1 px
Shift + 方向键	移动当前顶点 5 px
Ctrl + Shift + 方向键	移动当前顶点 10 px
Insert	在“当前顶点与下一个顶点”的边中点插入新顶点
Delete / Backspace	删除当前顶点，至少保留三个顶点
Esc	退出当前顶点编辑并清除选择
鼠标拖动顶点	直接移动该顶点
双击多边形边	在点击位置对应的边上插入顶点


这部分由 polygon_vertex_editor.gd 实现。删除或移动后如果产生自交、越界、零面积等非法几何，操作会被拒绝。
鼠标逐点绘制、尚未完成的 Lasso
这一状态与“编辑已保存 polygon”还有一个区别：
按键	作用
Backspace	删除最后添加的点
Delete	删除当前选中的草稿顶点
[ / ]	切换当前草稿顶点
方向键及步长组合	微调当前草稿顶点
空格或鼠标双击	尝试闭合轮廓


因此，Backspace 在不同状态下可能删除整个区域、删除当前顶点，也可能删除最后一个绘制点。
五、撤销、重做与类别窗口
1. 撤销与重做
快捷键	功能
Ctrl + Z	撤销
Ctrl + Shift + Z	重做
Ctrl + Y	重做，与上一项作用相同


你的代码按照文本输入 → 活动草稿 → 已提交标注命令分配撤销操作：
在文本框中，快捷键留给文本编辑；存在 WorkingMask 等活动草稿时，先操作草稿历史；没有这些局部状态时，才操作正式标注历史。因此，修改类别文字时按 Ctrl+Z，不应该撤销画布上的标注。
2. 类别修改窗口
快捷键或操作	功能与条件
R	对当前选中区域打开重分类窗口
右侧标注列表中的 Enter	列表获得焦点且选中区域行时，打开该区域的重分类窗口
↑ / ↓	类别建议列表获得焦点时，选择上一项 / 下一项
Enter	确认类别修改；Class 和 Kind 不能为空
Esc	取消类别修改或新对象的类别确认
建议列表上的鼠标滚轮	切换上一项 / 下一项建议，同步更新 Class 和 Kind
双击类别建议	选择并确认该建议


注意：上下方向键选择建议要求焦点位于建议列表，不是只要窗口打开就必然生效。
Tab / Shift+Tab 用于前后切换界面焦点；项目文档也明确保留了从键盘空间工具进入 Fill 确认、取消控件的焦点路径。


##  -


 **Endoscapes2023** — images, bounding boxes and segmentation masks. You can download on [https://github.com/CAMMA-public/Endoscapes](https://github.com/CAMMA-public/Endoscapes). This is the technical report of this dataset, maybe you will find this useful: [The Endoscapes Dataset for Surgical Scene Segmentation, Object Detection, and Critical View of Safety Assessment: Official Splits and Benchmark](https://arxiv.org/abs/2312.12429).
  - **Endoscapes-SG201** — the aligned structured-annotation extension that adds `⟨instrument, verb, target⟩` **triplet** labels, 6 instrument sub-classes and hand-identity labels on top of the Endoscapes2023 images. Download it from the official SSG-Com **project page** (which hosts the Dataset Download): [https://ailab-kyunghee.github.io/SSG-Com/](https://ailab-kyunghee.github.io/SSG-Com/) (code repo: [https://github.com/ailab-kyunghee/SSG-Com](https://github.com/ailab-kyunghee/SSG-Com), MICCAI 2025). Note: SG201 provides only the annotations; you still need the Endoscapes2023 images above.

  https://cirl.lcsr.jhu.edu/research/hmm/datasets/jigsaws_release/

## 开发原则

项目参考 MITK 将界面、数据和算法职责分开的思路，为每个模块规定明确的所有权和清晰接口，以保持可维护性。Part 1 边界包括版本化数据合同、数据源适配、标注渲染、编辑与训练交接；各模块只通过公开契约协作。

## 快速开始

已验证环境为 Godot 4.7.2-stable、Python 3.14.7 和 FFmpeg 6.1+。从仓库根目录依次执行：

```bash
ffmpeg -version
python3 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -e '.[dev]'
.venv/bin/python python/make_sample_input.py --output sample/assignment_v1 --seed 6006
.venv/bin/python python/validate_model_output.py sample/assignment_v1/model_output_v1.jsonl
tests/run_tests.sh
```

测试与基准入口包括 `tests/benchmarks/godot/display_benchmark.gd`、`tests/benchmarks/godot/playback_benchmark.gd`、`tests/benchmarks/godot/long_source_benchmark.gd`、`tests/benchmarks/godot/video_import_benchmark.gd` 和 `tests/benchmarks/make_part3_sources.py`。

### 数据源与插件边界

`single_image_source` 负责单张图像，`image_sequence_source` 负责带清单的归一化目录，`numeric_image_sequence_source` 负责保留原始帧号的数字图像序列。SourceFactory 选择数据源插件，SourceSessionBuilder 校验并生成会话快照；`playback_index` 表示连续播放位置，`frame_id` 保留数据集原始帧号。

其他公开插件包括 `canvas_region_renderer`、`basic_edit_tools` 和 `file_training_handoff`。当前编辑器保留 7 个工具；Close Gaps、Region Growing 和 Live Wire 不在这 7 个工具中。Eraser 使用 Shift+P，Lasso/Subtract 使用 Space 闭合，画布使用鼠标中键平移；预览保持实时，未人工复核的路径标记为待验证。

| 操作 | 快捷键 |
|---|---|
| 撤销 / 重做 | Ctrl+Z / Ctrl+Shift+Z |
| 缩放区域 | Alt+Arrow |
| 强制闭合轮廓 | Space |
| 取消当前操作 | Escape |
| 切换区域或顶点 | `[` / `]` |

### 显示实现摘要

`AnnotationViewport` 保留 Overlay opacity 和 Fit，通过 dirty redraw 避免状态未变时重复入队。Renderer 缓存 image-space primitives，并用 AABB 过滤离开视口的区域；complex polygon 只在记录改变时重新解析。实测会话在 llvmpipe 上记录平均 175.27 fps 和 p95 9.572 ms，原始结果见 RESULTS.md。

### Part 3.1 导入与播放

Part 3.1 整体为 **PASS**。用户从 Start import 导入视频；速度控件提供 Custom、3 s/frame、1 s/frame 和 Max，运行条显示 actual FPS 与 Time HH:MM:SS.mmm。Previous、Play、Pause 和 Next 均按连续索引工作；10,000 帧压测使用有界 LRU 缓存和虚拟时间轴，不为每帧创建界面节点。
