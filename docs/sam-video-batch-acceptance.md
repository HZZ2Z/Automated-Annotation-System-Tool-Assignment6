# SAM 2 Video Batch 有界验收

本页只记录单 region、向后传播的 SAM 2 Video Batch 证据。候选始终先进入临时预览；这里的 smoke 不写工作区标签，也不把模型分数当作 `conf` 或 verified。

## 可执行入口

- [SAM Video smoke](../python/sam_video_smoke.py)：`--frames DIR --mask PNG --count N --json-out PATH`
- [验收 runner](../tests/acceptance/run_sam_video_acceptance.py)：只消费显式 case allowlist；可选 `--visible-ui-evidence ABSOLUTE_JSON`
- [case allowlist](../tests/acceptance/sam_video_cases.json)：当前不包含任何用户媒体路径

smoke 仅使用以下既有环境变量，不安装包、不下载 checkpoint，也不替换显式 device：

```text
PROJECT6_MODEL_PYTHON
PROJECT6_SAM2_CONFIG
PROJECT6_SAM2_CHECKPOINT
PROJECT6_SAM2_DEVICE=auto|cpu|cuda
```

示例（`frames` 必须是用户明确授权的连续 PNG 目录，`mask` 是与首帧同尺寸的二值起始 mask）：

```bash
"$PROJECT6_MODEL_PYTHON" python/sam_video_smoke.py \
  --frames /absolute/allowlisted/frames \
  --mask /absolute/allowlisted/key-mask.png \
  --count 5 \
  --json-out /tmp/project6-sam-video-smoke.json
```

输入帧只按数字文件名 stem 排序；报告保存精确 frame ID、playback index、SHA-256、实际 device、checkpoint digest，以及 load/open/propagate 整批耗时。验收 runner 会从每个明示 `case.frames` 目录独立重新发现 key + target 顺序，并要求 smoke 的文件名、frame ID、playback index、尺寸和 SHA-256 全部与本地发现值精确相等；仅“报告内部自洽”不是真实证据。SAM 版本先读取 distribution metadata，若值缺失或非法再读取 `sam2.__version__`；两者都不是最长 64 字符的 portable version 时，环境只记 `NOT RUN`。输出 candidate 是有界 PNG，并逐个记录单连通、无孔、3–2048 顶点、无重复顶点或非相邻边接触/自交的简单 V1 环，以及回栅格化 IoU ≥ 0.99 的拓扑结果。对角接触而在轮廓中重复顶点的 mask 不是可审阅 V1 candidate。临时 job 会被清理，源帧目录及其中的标签文件保持只读。

Box 和 Poly 坐标接受 Model Output V1 的有限整数或浮点数，均在原图空间按像素中心判定后栅格化；非有限、越界、退化或未覆盖任何像素中心的几何会被拒绝。报告和 PNG 都以排他创建方式写入，已有路径不覆盖。

## allowlist 合同

默认 allowlist 只有 schema、四个必需 case tag 和空 `cases`。每个 `case.id` 必须是最长 64 字符的严格 `portable basename`，不能含 `/`、反斜线、`.`/`..` 或任何父目录跳转。若要运行真实手术 case，必须逐项填写绝对 `frames` 路径、Box、Poly；独立真值必须逐帧列出绝对 mask 路径，不能只给一个待扫描目录。人工接受/轻修/重画、重新锚定、停止位置、静默漂移以及成对计时也必须来自实际记录，不能由 runner 推断。派生起始 mask 与单次 smoke report 都必须是私有临时目录的直接子项，并以独占写入创建。

四类 tag 为：

- `stable`
- `fast_motion`
- `low_contrast_or_glare`
- `occlusion_or_disappearance`

## 五分区判定合同

`functional` 内部把真实命令行闭环记为 `runtime_smoke`，把人工界面闭环记为 `visible_ui`。顶层 `functional=PASS` 必须同时满足全部 24 个固定真实 smoke（四个 case × Box/Poly × 1/5/30）为 PASS，且显式可见 UI 证据为 PASS。每份 smoke JSON 先拒绝重复 key、NaN/Infinity 及 `1e309` 等解析后非有限数；顶层与嵌套容器必须在取值、计数或集合聚合前通过形状校验，否则只记可控 FAIL，不中断整个验收。每次声明 PASS 的真实 run 还必须产生至少一个通过上述生产拓扑门的可审阅 candidate；candidate descriptor 必须只含固定字段，且 local/playback/frame/object 身份（object 固定为 1）、有限 score、ROI、直接子 PNG 路径、小写 SHA-256 与文件字节、以及重算的 topology 必须在精确字段与类型校验后再比较；布尔值不得冒充整数或数值。case/tag/start/count、输入帧描述符、candidate 连续前缀、`generated_count` 与 structured stop 也必须互相一致。完整前缀的 stop 必须为 null；部分前缀的 stop 必须且只能含 `kind=candidate_topology`、下一个本地目标的 frame/playback 身份和一个 `status=FAIL` 的已知、有界 topology 原因/计数结构。第一个目标就发生拓扑 stop 时，单次 smoke 可作为“模型已执行并结构化停止”的有效运行记录，但其零 candidate 绝不得升级为 `runtime_smoke=PASS` 或功能 PASS。真实 smoke 失败或 PASS 报告缺损/自相矛盾时顶层为 FAIL；真实 smoke 全过但未提供 UI 证据时，`runtime_smoke=PASS`、`visible_ui=NOT RUN`、顶层仍为 NOT RUN。

PASS smoke 的环境必须且只能包含版本、CUDA 可用性、请求/实际 device、config/checkpoint 摘要这八个字段，并与验收器独立 preflight 和磁盘字节精确绑定；计时只接受有限非负浮点数。CUDA 字典同样使用固定三字段与精确类型，CPU 运行不得携带 CUDA 测量，畸形或旧版字段不能进入功能、质量或 CUDA PASS 聚合。JSON 嵌套超过有界深度时只生成受控 FAIL。

可见 UI 输入必须是显式指定的绝对、普通、非链接 JSON 文件，schema 为 `project6-sam-video-visible-ui-v1`。它严格绑定一个 allowlisted `case_id`、Python/Torch/SAM 运行时版本、checkpoint SHA-256 和该 case 六次 smoke 的实际 `cpu|cuda` device；`checks` 必须且只能包含以下八项，且全部为 `PASS`：

```json
{
  "schema": "project6-sam-video-visible-ui-v1",
  "case_id": "stable-case-01",
  "runtime": {
    "python_version": "3.14.7",
    "torch_version": "2.8.0",
    "sam2_version": "1.1.0"
  },
  "checkpoint_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
  "device": "cpu",
  "checks": {
    "preview": "PASS",
    "early_stop": "PASS",
    "cancel": "PASS",
    "prefix_confirm": "PASS",
    "undo_redo": "PASS",
    "save_reopen": "PASS",
    "reanchor": "PASS",
    "new_batch": "PASS"
  }
}
```

`quality=PASS` 只评估每个 case 唯一的 30-target Poly run。每个 case 必须提供非空独立真值，真值 frame ID 集合必须精确等于实际发布的 candidate frame ID 及 smoke report 所声明的 candidate 前缀；缺一帧、多一帧或身份矛盾均为 FAIL。`direct_accept + minor_correction + redraw` 必须等于实测 candidate 数，`silent_drift` 不得超过该数，人工 `stop_frame` 必须与真实 structured stop 一致（包括两者都为 null）。完全缺少真值或人工记录属于 NOT RUN。

smoke 的同步 `timings_ms.propagate` 是整批总时长，不是逐帧样本；传播结束后再调用 cancel 也不是运行中取消。smoke 因此保留 `cuda.per_frame_propagate_ms=[]` 和 `cuda.inflight_cancel_latency_ms=null`，绝不以总时长除以帧数估算。`cuda_performance=PASS` 只接受实际 `actual_device=cuda`、峰值显存、非空真实 `per_frame_propagate_ms` 和真实运行中 `inflight_cancel_latency_ms`；否则保持 NOT RUN，不发布 p50/p95。

持久报告 reason 只使用最长 160 字符的稳定类别，不写入底层 OSError 文本、外部 probe stderr 或其中的绝对路径。

## 当前证据边界（2026-09-11）

| 分区 | 状态 | 边界 |
|---|---|---|
| `environment` | NOT RUN | 本轮只读预检缺少 `PROJECT6_MODEL_PYTHON`、`PROJECT6_SAM2_CONFIG`、`PROJECT6_SAM2_CHECKPOINT`、`PROJECT6_SAM2_DEVICE`；因此没有加载模型。 |
| `functional` | NOT RUN | 环境预检未满足，且 allowlist 为空；未运行真实 SAM 2 Video，也没有显式绑定的可见 UI 证据。 |
| `quality` | NOT RUN | 没有四类 case 的独立目标帧真值和人工判定。 |
| `efficiency` | NOT RUN | 没有同范围纯手工与 SAM Batch 成对计时。 |
| `cuda_performance` | NOT RUN | 没有实际 CUDA load/open、真实逐帧 p50/p95、峰值显存和运行中取消延迟。 |

fake predictor 自动测试只证明 CLI、backend 复用、身份映射、取消、清理和 JSON 合同；它不升级任何真实分区。CPU 功能结果不能填入 CUDA，合法 mask 也不能代替真实手术视频精度或人工节时证据。
