# RESULTS — 设计决策、测量与失败分析

按 Assignment Part 组织。所有数字均为本机实测,不外推到其他硬件;测量主机为 AMD Ryzen 9 7945HX · Ubuntu 22.04 · Godot 4.7.2-stable(软渲染 llvmpipe),另有标注处使用 RTX 5070 Ti Laptop GPU。逐条要求追踪见 [docs/requirements-traceability.md](docs/requirements-traceability.md)。

## 总览

| Part | 结论 | 证据锚点 |
|---|---|---|
| 1 契约/样本/插件 | PASS | 本文 §1 |
| 2.1 显示 | PASS | 本文 §2.1 |
| 2.2 编辑 | 自动化完成,人工复跑待记录 | 本文 §2.2 |
| 2.3 MITK 对照 | 完成 | 本文 §2.3 |
| 3.1 帧精确流 | PASS | 本文 §3.1 |
| 3.2/3.3 批量标注 | 自动协议/安全 PASS;真实视频精度/效率 NOT RUN | 本文 §3.2 |
| 4 持久化与交接 | 旧交接 PASS；新 COCO E01–E48 自动验收 PASS；训练未运行 | 本文 §4 |
| 5 测试与度量 | 当前 889 Python PASS；聚合脚本 28 次 Godot 调用全部通过 | 本文 §5 |

## 1. Part 1 — 数据契约、样本与插件架构

**数据契约。`core/schemas/model_output_v1.schema.json`** 是严格的 JSON Schema Draft 2020-12:每记录含 `source`/`frame`(原始帧 ID)/可选 `time_s`/`regions`;region 含 `id`、`class`、`kind`、box `[x,y,w,h]` 和/或单环 polygon、可选 `conf`、`track_id`。三处等价验证:Python CLI(`python/validate_model_output.py`)、Python API(`python/annotation_data/contracts.py`)、Godot(`client/domain/model_output_validator.gd`),全部以错误数组返回、绝不使 UI 崩溃。模型基线字节不可变、以 `model_output_vX` 版本化;人工修正以 `source: "human_corrected"` 落盘。

**确定性样本。** `python/make_sample_input.py --seed 6006` 生成 120 帧、每帧约 20 个区域,植入全部要求的缺陷:漂移(帧 12–13)、错误类别(帧 24)、一个漏检、一个幻觉、track-id 交换,以及帧 40–59 的连续近似段。每帧含一个 12 顶点凹多边形。同种子核心文件 SHA-256 一致,独立验证 0 错误。

**帧源。** `python/frame_source.py` 将任意 FFmpeg 可读视频解码为索引帧,覆盖旋转、负 PTS、多流与整段缺 PTS 的输入;视频与图片序列在客户端统一为"来自源的帧"。

**插件管线。** Registry 启动时扫描 `client/plugins`,校验 manifest、API version、Stage 类型与入口脚本。当前插件:Source ×4(`image_sequence_source`、`numeric_image_sequence_source`、`single_image_source`、`endoscapes_video_source`)、Render ×1、Edit ×1、Export/Feedback ×1。新增插件不改动 Registry 或 core,规范见 [docs/plugin-api.md](docs/plugin-api.md)。

## 2. Part 2 — 显示与编辑

### Part 2.1 坐标管线与渲染

`ViewportTransform` 持有唯一的 image↔viewport 变换:`T = Transform2D(scale, origin)`,其中 `scale = min(Vw/Iw, Vh/Ih) × z`,origin 由 letterbox + pan 组成,反向拾取用 `T.affine_inverse()`。绘制、命中测试、resize 手柄、指针坐标全部共用这一个变换;`Fit` 恢复 `z=1`、`p=0`。变换测试覆盖 0.1×–20× 缩放、非零视口原点、resize 中心保持,往返误差 `≤1e-5` image px。

渲染刻意保持 `CanvasItem` + `_draw()` 路线:geometry 快照只在 record 内容变化时重建,缩放/平移/选中只重建屏幕空间命令(dirty redraw),AABB 裁剪视口外区域。polygon 区域按 single-ring 非自交合同渲染。未引入着色器或预三角化——实测已远超阈值,无必要。

**测量(1280×800,20 regions,10 s 采样,AMD Ryzen 9 7945HX with Radeon Graphics,llvmpipe (LLVM 15.0.7, 256 bits) 软渲染):**

| 指标 | 数值 | 阈值 |
|---|---:|---|
| 编辑视图平均帧率 | **175.27 fps**(p95 帧间隔 9.572 ms) | ≥30 fps,p95 ≤40 ms |
| 拖动坐标误差 | 0.0 image px | ≤1e-5 |
| 拖动/缩放/平移(编辑基准) | 186.86 / 234.12 fps | 同上 |

### Part 2.2 编辑能力

八个工具:Add Box、Subtract、Lasso、Fill、Paint、Eraser、Select、Match(区域合并)。SAM 不属于 Edit 工具，只从 Batch 进入。要点:

- **几何编辑**:选中拖动、八柄缩放、1/5/10 px 键盘微调;Lasso 内可直接拖动已存 polygon 顶点、双边插点、`Backspace` 删点,全部经 `ReplaceRegionGeometryCommand` 进入全局撤销。
- **Fill**:严格闭合优先,0–3 px 形态学闭合作 proposes 修复(绿色候选/粉色修复需 Enter 确认);WorkingMask 支持连续多洞填充,最终一条命令提交。
- **撤销/重做**:200 条已提交命令;失败编辑不改数据不留栈;修复预览取消不进历史。
- **原子拒绝**:自交、多连通、含洞、超限 ROI 均以可读原因拒绝,无静默损坏。

**编辑可见性能(1280×800,20 regions,8 px 笔刷,2 s 预热 + 10 s 采样):**

| 场景 | 平均 fps | p95 帧间隔 | 提交耗时 |
|---|---:|---:|---:|
| Select 拖动 | 186.86 | 8.181 ms | 1.087 ms |
| Paint | 174.49 | 8.775 ms | 82.052 ms |
| Eraser | 180.16 | 8.643 ms | 91.566 ms |
| 缩放/平移 | 234.12 | 6.848 ms | — |

笔刷提交 82–92 ms 是轮廓转换+校验+命令的一次性成本,不计入实时预览帧率。微基准:区域并/差从 349.5/347.0 ms 降至 0.259/0.087 ms(限制变更区域扫描 + 复用纹理)。

### Part 2.3 MITK 编辑范式对照

参考 MITK Segmentation View 与 ContourTool 文档(2026-09-06 查证)。编辑单元是"单帧上带 ID 的 box/单环 polygon",因此保留可见目标、直接操纵、可逆编辑与显式反馈,不声称与 MITK 等价。

| MITK 行为 | 决策 | 本实现 |
|---|---|---|
| 选中高亮 + 边缘辅助 | 仿照 | 共享变换命中;6 viewport-px 边缘容差、8 px 手柄容差 |
| 轮廓实时反馈、释放时写入 | 仿照 | Lasso/Paint 草稿可见可取消,释放时校验并成命令 |
| 标签命名与建议 | 改造 | 双击列表项直接重命名;滚轮切换建议并同步颜色 |
| Add/Subtract/笔刷修正 | 改造 | Eraser 免选中影响所有触及区域;多目标笔画为一条原子命令 |
| Fill / Close Gaps | 改造 | 空白区填充 + 小间隙修复预览,不把 RGB 强度当分割边界 |
| Undo/redo | 仿照并扩展 | 200 条命令 + 草稿独立历史 + 文本框自有撤销 |
| Region Growing / Live Wire | 舍弃 | 手术 RGB 帧上强度阈值与边缘跟随不可靠,聚焦模型区域修正 |
| 3D 体数据 / 切片插值 / 标签锁定 | 舍弃 | 帧是时间观测,不用插值做自动传播;以校验+撤销替代锁定 |

## 3. Part 3 — 视频流与批量标注

### 3.1 帧精确流

视频经 `VideoImportController` 用 `OS.create_process()` 调 FFmpeg 后台解码为归一化帧目录,导入期间 UI 心跳不阻塞(90 帧导入实测 107 次心跳),发布为同目录原子 rename,取消只清理自有 staging。播放侧 `PlaybackController` 每 tick 至多前进 1 帧、不追钟跳帧,`Time` 来自已提交帧的不可变 `time_s` 而非挂钟。

| 测量 | 数值 |
|---|---:|
| 90 帧 640×360 FFV1 MKV 后台导入 + 打开 | **0.789 s** |
| 360 帧播放(请求 30 fps,软渲染) | 实际 15.26 fps,**0 跳帧**,p95 交付间隔 74.116 ms |
| 单帧同步加载 | p95 8.639 ms;纹理缓存 12/12 |
| 10,000 帧源打开 | 1.048 s;精确 seek p95 2.691 ms;像素内存恒有界(纹理 ≤12) |

慢加载只降低播放速度、绝不跳过显式索引——zero skipped frames,这是设计取舍而非隐藏丢帧。播放控件提供 explicit frame/time 与 read-only actual FPS(`PlaybackFpsMeter` 只统计已提交帧);节奏档位为 Custom、`1 s/frame`、3 s/frame 与 Max,末帧自动暂停,不循环。

## Part 3.2 / 3.3 批量标注与测量

**默认路径:SAM 2 Video。** 关键帧上提交一个 Box/Poly region，按 Source 顺序向后传播 1–30 帧(关键帧不计入)，无需额外锚点确认。候选只存在于内部冻结与安全校验阶段；用户点击“生成并保存标注”后，应用以一条 `ApplyPropagationCommand` 自动合并合法结果、写入 review 与 v3 batch audit 并保存，一次 undo/redo 同时恢复三者。无法表达为 V1 单环 Poly 的帧在该帧分段停止、合法前缀自动保存，界面跳到异常帧用普通工具修正；协议/hash/会话不一致使整批作废。**SAM 失败绝不静默回退**，`poly-sim-flow-edge-v1` 与 `copy` 仅是显式备选(overwrite/merge 语义与 schema-v2 audit marker 见 [docs/poly-propagation.md](docs/poly-propagation.md))。

**备选路径:Poly 光流 + 边缘精修**(`poly-sim-flow-edge-v1`,用户显式选择)。64×64 灰度 MAD 相似度门(默认阈值 0.10)→ DIS 光流 → 局部 GrabCut 边缘精修,每帧独立可编辑 polygon。独立真值合成基准(已知变换渲染,种子 27):

| 场景 | 固定复制 IoU | 光流最终 IoU |
|---|---:|---:|
| 平移 / 反向平移 | 0.5236 | 0.99985 |
| 旋转 | 0.7535 | 0.98588 |
| 局部形变 | 0.6773 | 0.99463(边缘精修接受) |
| 边界偏移 | 0.8517 | 0.99924 |

**批量覆盖测量(assignment 3.3)**:单批上限 30 帧;历史 COPY 基线(阈值 0.02)在样本 40–59 相似段上,1 次关键帧修正传播 19 帧,等价人工逐帧标注的 1/19。边界定性检查:Endoscapes 真实视频上,门禁只在质量达标帧接受(5 帧窗口仅接受 1 帧),证明分段停止先于批量上限生效。`T_manual`/`T_batch` 配对计时未做,不声称节省比例。

**漂移累积风险与缓解(assignment 3.2.4)**:长相似段即使有固定关键帧对照仍会累积 mask 误差。已实现的缓解:① 邻接 + 固定关键帧双相似度门,亮度漂移直接拒绝;② 每帧独立光流质量门(质量分数 ≥0.25、锚点一致性 IoU ≥0.85),首帧不可靠即停止该方向;③ SAM 候选只在一次点击后的内部冻结与校验阶段存在,合法前缀随正式写入自动记录审核摘要;显式 Poly/copy 备选仍保留人工检查流程;④ v3/v2 batch audit 记录停止原因与逐帧参照矩阵,保存/重开不失效。

**证据分类(诚实边界)**:自动协议/安全 **PASS**;真实 SAM Video 功能、可见 UI、独立真值精度、配对人工效率、CUDA 性能均 **NOT RUN**。单帧真实 SAM smoke(CPU 9.67 s;CUDA:加载 2.42 s、embedding 0.32 s、predict 0.19 s,RTX 5070 Ti)只是单帧证据,不能转用为视频结论。机器可读状态:`real SAM smoke: PASS`;`visible real-model UI loop: NOT RUN`;`CUDA performance: NOT RUN`。smoke 使用 Meta 官方 SAM 2.1 Tiny,checkpoint SHA-256 `7402e0d864fa82708a20fbd15bc84245c2f26dff0eb43a4b5b93452deb34be69`。

## 4. Part 4 — 持久化、审计与交接

**会话与保存。** V3 会话分离不可变模型基线、人工修正、verification 与 batch metadata;修正记录以 `human_corrected` 落盘,旧格式迁移保持字节不变。保存 = 同目录临时文件 → flush → 回读校验 → 与冻结输入等值比较 → 原子替换;300 ms 空闲调度,连续编辑 2 s 内必定发起保存请求。

**崩溃安全(SIGKILL 注入,4 个边界):**

| 终止点 | 恢复结果 |
|---|---|
| 临时文件写到一半 | 完整旧 V3 |
| 回读校验中 | 完整旧 V3 |
| 原子替换前一瞬 | 完整旧 V3 |
| 原子替换后一瞬 | 完整新 V3 |

**diff 审计。** 生产 demo(120 帧、8 条真实编辑命令)与 assignment 夹具逐项一致:geometry=2、label=1、added=1、deleted=1、attributes=2,共 6 个变更帧/7 个变更区域;数值 12 与 12.0 等价、撤销归零、CSV 引号/逗号/Unicode 独立解析通过。

**交接包与轮次。** `training_update_v2`(verified-only,含已确认未改动帧与确认阴性帧)与 `review_export_v1`(全帧评审快照)各含固定六文件,manifest 列 SHA-256;UI 与 CLI 产物字节一致。模型返回 `model_round_v1` 必须指向真实父训练包,预览后创建独立新轮次,旧轮次字节归档、verification/batch/undo 重置。协议见 [docs/Part 4 模型组接口协议/part4-protocol.md](docs/Part%204%20模型组接口协议/part4-protocol.md),复现见 [docs/Part 4 设计与复现/part4-review.md](docs/Part%204%20设计与复现/part4-review.md)。训练本身是模拟返回,不是真实重训。

**Endoscapes 自包含 COCO。** `training_coco_v1` 在不修改 review state 的前提下消费已保存冻结快照，按字节复制原图，输出单一 `labels/annotation_coco.json`、manifest 和 diff。E01–E48 自动矩阵通过；真实 test/video-162 检测包为 4 图、24 annotation、6 类，移动式独立 loader 与四帧叠加抽查通过。同一会话的 24 个对象均仅有 bbox，因此真实实例分割以 `SEGMENTATION_REQUIRED` 正确阻断。完整证据见 [training-coco-v1-acceptance.md](docs/Part%204%20设计与复现/training-coco-v1-acceptance.md)。

COCO 新路径的 120/10,000 帧峰值 RSS 为 59.707/141.285 MiB，最大同时解码均为 1 张，UI dispatch p95 为 8.982/97.973 ms，cancel p95 为 294.905/264.781 ms。10,000 帧 prepare/publish/独立回读为 4.170/25.149/2.401 s；磁盘耗时仅代表本机。

**资源测量:**

| 指标 | 120 帧 ×20 regions | 10,000 帧 ×20 regions |
|---|---:|---:|
| 编辑→autosave 完成 | p95 **785.2 ms**(目标 ≤1 s) | ~40 s/次(单次观测) |
| 保存/导出期间输入响应 | p95 13.26 ms(目标 ≤100 ms) | p95 13.4 ms,峰值内存 1,606.97 MiB |
| 全评审导出 | 482.9 ms | ~41 s |
| 峰值内存(优化前→后) | 157.4 → 130.3 MiB | 4,969 → 1,607 MiB |

内存优化(共享不可变帧、去除纯校验 Store、64 KiB 分块写、顺序流式导出)在 1,000/3,000 帧夹具上分别降 48.3%/56.2%,且不减少任何校验、不改变文件内容。

## 5. Part 5 — 测试、健壮性与失败分析

本节记录完整本地开发工作区的验证证据；`tests/`、两个真实模型 smoke 驱动及运行输出按发布边界不随 GitHub 版本上传。

**先前 COCO checkout 的失败快照（保留原始结论）:** 按契约先生成 Godot 跨语言夹具后，**872 Python tests passed in 60.07 s**。COCO 聚焦 72/72，旧 Part 4 包/CLI 47/47。Part 4 严格 Godot 矩阵 30 项中 28 项完整通过；`ui_session` 和 `coco_export_ui` 行为断言完成，但严格日志审计捕获改造前已存在的 `SamVideoService._notification` 空 `shutdown` 错误。当前本地全量 Godot 汇总也因未提供第 9 个 Model Assist tool descriptor 先出现索引错误，随后产生同类退出错误；这与该轮 COCO 实现无关，该轮未修改用户当时的本地插件变更。日志位于 `output/coco-export-acceptance-20260912/full-godot.godot.log`。

**当前 SAM Batch 与 COCO 导出收尾回归（2026-09-13）:** 最终 checkout 上 `tests/run_tests.sh` 串行完成 **889 Python tests passed in 56.60 s**，并且脚本中的 **28 次 Godot 调用全部退出 0 且通过严格日志审计**；其中 aggregate 完整通过，editor socket 与四组损坏 PNG 只按固定预期 profile 放行。新增回归覆盖默认全 Source 帧、显式未审核子集、上版基线和无标注物化、零目标 COCO 语义、逐帧 `review_status` / `label_source`、警告一致性、训练包可编辑导入与独立校验器篡改拒绝；同时保留 SAM schema-v3 批次审计、播放顺序/停止帧语义、质量门槛参数与停止类别、图像警告去重、自由文本类别确定性追加及实例分割缺 mask 范围错误。另有 Batch/SAM/Poly 定向调用覆盖 1/5/30 帧一键保存、自动审核、单次 undo/redo、合法前缀、停止帧普通编辑修正、provider/service teardown 与显式备选，结束后未发现 `model_assist_worker.py` 或 `sam_video_worker.py` 残留。先前 OOM 相关的退出错误已通过 owner 显式 `shutdown()`、provider 替换时先关闭旧 service，以及 PREDELETE 内联应急清理修复；这仍不等于真实 SAM Video/CUDA 可见 UI 验收。

**失败分析(踩到的代表性缺陷与修复):**

1. **Godot 原生 JSON 改写 binary64(1 ULP)**——部分十进制(含 `7/30` 时间戳)被 ±1 ULP 改写,digest/时间戳精确匹配失效。修复:共享 ExactJson 读取器(精确舍入 + 受限嵌套),12,230 个数值跨语言位级对照回归。
2. **autosave p95 一度 >1 s**——每次保存重复完整语义解码;大导出因字符串反复拼接超线性变慢。修复:回读改为一次等值比较、JSONL/CSV 单次 join,p95 降至 785 ms,故障测试保持原有耐久性保护。
3. **旧导出路径阻塞主线程**——同步执行 2 s 慢 IO 时事件循环 0 tick(实测阻塞 2,086.573 ms)。修复:删除同步路径,UI 与 CLI 共用 `TrainingExportController` 工作线程,同等慢 IO 下事件循环推进 343 次。
4. **Godot 编辑器把导出的 CSV 当翻译资源**——重扫描生成 `.translation`/`.import` sidecar 并触发原生导入器崩溃。修复:包外层创建 `.gdignore` + 严格清单校验,旧包字节原样保留。
5. **大会话内存 4.85 GiB 两次触发 OOM 保护**——修复见 §4 内存优化行,优化后同负载 1.61 GiB 三次重复完成。

## 6. 边界与未完成

- 真实 SAM Video 的功能、可见 UI、独立真值精度、配对人工效率、CUDA 性能:**NOT RUN**;单图 smoke 不构成视频证据。
- Part 2 人工 reviewer 复跑:待正式记录。单帧 Model Assist UI 已退役，不再作为当前待验收功能。
- COCO 新路径的检测契约、真实图片包和独立回读已验收；真实会话没有当前 mask，因此不声称实例分割真实交付。
- 无 3D/真实训练服务；模型返回仍是模拟；Real surgical video 的人工工时节省未测量。
- 早期按日期记录的完整证据日志(含全部原始数据路径)见 [历史内容/RESULTS.旧版备份.md](历史内容/RESULTS.旧版备份.md)。
