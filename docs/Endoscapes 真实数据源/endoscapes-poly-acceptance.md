# Endoscapes Poly 验收流程

这套流程只为本地定性验收准备 5–30 帧工作区，不发布 Endoscapes 图片、mask、数据集绝对路径或生成的叠加图。所有输出必须放在被忽略的 `.local-acceptance/`。

## 准备夹具

```bash
.venv/bin/python python/prepare_endoscapes_poly_fixture.py \
  --dataset-root /absolute/endoscapes \
  --output .local-acceptance/endoscapes-poly-65 \
  --video-id 65 --start-frame 11775 --end-frame 11875 \
  --key-frame 11800 --instance-index 0 --copy
```

构建器要求原始帧按 25 递增、总数为 5–30、图片尺寸一致、关键帧 `.npy` 与 `.csv` 实例数一致，并在同级 staging 完成后原子改名。默认使用符号链接以避免复制私有图片；严格 Source 插件会拒绝链接，所以需要在 Main 中打开时显式使用 `--copy`。目标目录已存在时构建器拒绝覆盖，源数据只读。

`manifest.json` 只保存连续播放索引 `0..N-1`。原始 Endoscapes 帧号、逐帧 SHA-256、mask/CSV 摘要、类别 ID 和转换声明保存在独立 `provenance.json`。每个播放帧都有一条 Model Output V1 记录，只有关键帧含种子 Poly。

视频 65 的实例 0 是类别 ID 5（`gallbladder`，`anatomy`），原 mask 在图像上下边界被裁切，不能直接表示成可验证的 V1 单环。构建器明确移除外围 2 像素：这是 Godot 解码后传播仍不触边的最小实测余量；1 像素在真实 UI 快照上会被光流推回边界，3 像素则会额外扩大候选范围。`provenance.json` 因此记录 `lossless: false`、`boundary_inset_pixels: 2`、原/种子像素数、保留 IoU 和 polygon 回栅格 IoU，不能把该种子描述为原 mask 的无损等价物。

## 运行算法证据

```bash
.venv/bin/python python/run_endoscapes_poly_acceptance.py \
  --fixture .local-acceptance/endoscapes-poly-65 \
  --output .local-acceptance/endoscapes-poly-65-evidence \
  --threshold 0.10
```

报告记录候选范围、所有相邻/关键帧 MAD、停止原因、每帧/区域的边缘接受或 raw-flow fallback、有限诊断值和运行时间。`overlays/` 用红色显示 raw flow、绿色显示最终候选；fallback 时两张几何必须一致。报告不保存数据集绝对路径。

2026-09-10 以阈值 `0.10` 重新运行本地 5 帧夹具，得到候选播放帧 `[2]`（原帧 11825），候选范围 `1..2`；两侧候选因触及图像边界停止。报告中的传播模式与边缘接受/回退必须分开读取。

## Main 验收边界

用 `--copy` 夹具打开 Main，在播放索引 1 分析默认 `Poly 光流 + 边缘精修`，阈值保持 `0.10`。逐帧查看候选及 `flow`、`bright-template fallback`、`fixed fallback` 标记后执行一次 Apply、一次 undo、一次 redo，等待保存，重开同一来源，再确认帧 2 并检查自动前进与再次重开。当前 mounted UI 验收覆盖上述状态转换、v2 audit marker、原始 `model_output_v1.jsonl` 不变和 1280×800 布局截图。

只有关键帧 11800 具有实例 mask。其他帧没有独立密集真值，因此本流程只能证明真实数据路径闭环和人工可审查性；它不能声明目标帧 IoU、普遍精修收益或自动验证。定量 IoU 结论只来自独立合成基准。
