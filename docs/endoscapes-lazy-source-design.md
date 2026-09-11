# Endoscapes 按视频懒加载设计

日期：2026-09-10

## 目标

让 Project6 可以直接打开 Endoscapes2023 根目录，将 `${VIDEO_ID}_${FRAME_NUM}.jpg` 按 split 和视频号组织成逻辑视频，并按需读取当前视频的帧与官方标注。打开工作区时不得解码或缓存整套图像；切换视频后必须释放上一个视频持有的帧表、标注和纹理。

## 已确认的问题

当前通用工作区扫描会同步递归 Endoscapes 的约 16 万个目录项，把普通图像的文件名 stem 当作全局 `media_id`。原图 `train/165_23650.jpg` 与语义掩码 `semseg/165_23650.png` 因而冲突。Endoscapes 的复合文件名也不符合现有纯数字序列 Source，因此不能按视频播放。

## 范围

- 识别标准 Endoscapes2023 根目录及 `train`、`val`、`test` 来源帧。
- 每个 `(split, video_id)` 发布为一个逻辑 `image_sequence` 媒体。
- 工作区发现只建立视频级轻量索引，不读取图片像素或全库 mask。
- 选择媒体后才读取该视频的帧表、官方 COCO 标注和必要的 RLE mask。
- 将可用官方标注转换为 Model Output V1 基线；Project6 的人工编辑继续写入自己的版本化标签文件。
- 保留现有通用图片、数字序列、manifest 和视频来源行为。

## 非目标

- 不重排、复制、重命名或改写 Endoscapes 原文件。
- 不在数据集目录生成 201 套 manifest 或图片缓存。
- 不把 CVS 图像级评分伪装为区域标注。
- 不把多连通域、孔洞或触边 RLE 强制压缩成不真实的 V1 单环。
- 不预加载相邻视频，也不在后台无限预取。

## 方案

采用 Endoscapes Source 插件与通用可选工作区发现接口。Endoscapes 识别、分组和 COCO 解释全部留在插件边界；`WorkspaceCatalog` 和 `SourceFactory` 只理解经过校验的通用媒体条目，不包含数据集名称特例。

### 可选工作区发现接口

`WorkspaceCatalog.scan(root, token = null)` 先调用 `SourceFactory.discover_workspace_media(root, preferred_id, token)`；Factory 依次询问 Source 插件是否实现可选的 `discover_workspace_media(root, token)`。返回合同为：

```text
{
  claimed: bool,
  plugin_id: String,
  media: Array[Dictionary],
  errors: PackedStringArray
}
```

未实现该方法或 `claimed == false` 时继续现有通用递归扫描。某插件声明 `claimed == true` 后，其错误必须直接返回，不能静默回退到通用扫描并重新制造数万媒体条目。

Endoscapes 插件只在以下标记同时成立时声明根目录：存在 `all_metadata.csv`，存在可读的 `train`、`val`、`test` 目录，并且至少一个 split 同时存在 `${VIDEO_ID}_${FRAME_NUM}.jpg` 与 `annotation_coco.json`。

### 视频级媒体条目

发现阶段仅枚举三个来源 split 中的常规图片文件，解析严格正则 `^[0-9]+_[0-9]+\.(jpg|jpeg|png)$`。每个视频只保存：

```text
{
  display_name: "Video 065 (N frames)",
  media_id: "endoscapes_train_video_065",
  media_type: "image_sequence",
  source_path: "/absolute/path/train/65_11825.jpg",
  relative_path: "train/video-065",
  source_relative_path: "train/video-065",
  label_root: "/absolute/path/endoscapes",
  source_plugin_id: "endoscapes_video_source",
  baseline_kind: "imported_labels"
}
```

`source_path` 使用一个真实的代表帧作为插件 locator；插件从其父目录和文件名前缀恢复 split、视频号。插件拥有的 locator 只要求指向现有常规文件或目录，不再套用“image_sequence 必须是目录”的通用假设。`media_id` 包含 split，避免跨目录冲突。可选 `baseline_kind` 只接受 `empty`、`model` 或 `imported_labels`；SessionLoader 在没有 Project6 已保存标签时用它解释 Source 返回的种子记录。

### 后台工作区扫描

新增 `WorkspaceCatalogController`，用现有 `BackgroundJob` 执行纯数据扫描。Main 只负责显示“正在建立视频索引”、取消入口和最终原子替换：

1. 后台产生候选 Catalog 和错误；活动工作区保持不变。
2. 用户取消、扫描失败或返回陈旧 generation 时丢弃候选。
3. 成功后先完成现有保存/离开确认，再一次性替换 Catalog 与资源树。
4. 后台 callable 不访问 SceneTree、Control、Texture 或活动 Store。

扫描进度按已完成 split 和发现视频数限频报告。关闭应用或再次打开工作区时先取消并 drain 当前扫描。

## 当前视频 Source

`endoscapes_video_source.open(representative_frame)` 只构造代表帧所属视频：

1. 再次验证 locator 是标准 Endoscapes split 下的常规图片且不经过符号链接。
2. 只在当前 split 枚举并保留相同 `video_id` 的帧路径。
3. 按数值 `FRAME_NUM` 排序；播放 `frame` 保持连续，`frame_id` 保留原始帧号。
4. 读取当前 split 的 `annotation_coco.json`，只保留当前 `video_id` 的 image 和 annotation。
5. 为每帧生成一条 Model Output V1 记录；没有官方区域标注的帧使用空 `regions`。
6. `load_texture(index)` 延续上限 12 的 LRU，首次打开只解码第一帧。
7. `close()` 清空帧表、记录、COCO 临时对象和纹理缓存，不删除任何文件。

插件打开工作通过 `WorkspaceMediaController` 的 `BackgroundJob` 执行；完成后 Main 才在主线程创建第一张 `ImageTexture`。取消或切换 generation 后返回的旧 Source 必须立即 `close()`，不能覆盖新选择。

## 官方标注转换

类别映射来自 COCO `categories`，并加入 Project6 taxonomy：`cystic_plate`、`calot_triangle`、`cystic_artery`、`cystic_duct`、`gallbladder` 为 `anatomy`，`tool` 为 `instrument`。

每个 COCO annotation 产生稳定 ID `endoscapes-{split}-{image_id}-{annotation_id}`：

- 合法 COCO `bbox=[x,y,width,height]` 转为 V1 `box`。
- 仅为当前视频包含 `segmentation={size,counts}` 的 annotation 解码 COCO compressed RLE。
- compressed counts 按 COCO `maskApi.c` 的 ASCII-48、signed 5-bit 变长整数和 `counts[i-2]` delta 规则解码；不应对大于 40 的 code 执行额外减一。尺寸、截断、负 run、溢出和总长必须在分配 mask 前受限验证。
- RLE mask 交给现有单外环 polygonize 安全门。单连通域、无孔洞、非退化且在顶点预算内时增加 `polygon`。
- RLE 缺失、畸形、多组件、有孔、触边或转换失真时保留合法 `box`，不生成 polygon，并累计可见降级摘要。
- 如果 annotation 同时没有合法 box 和可接受 polygon，则跳过该区域并报告；不能产生违反 V1 的记录。
- COCO 原始 JSON、`semseg` 和 `insseg` 始终只读。`semseg`/`insseg` 作为可追溯 artifact，不作为媒体条目再次扫描。

官方基线只在不存在 Project6 已保存标签时使用。已有 Project6 标签继续优先，防止每次打开覆盖人工修改。基线类型记录为 `imported_labels`，模型置信度与人工验证状态不得凭空补写。

## 缓存与内存边界

- 工作区常驻：至多约 201 个视频条目及少量 split 汇总，不保留全库逐帧路径。
- 当前视频常驻：该视频的有序帧路径、V1 记录和最多 12 张纹理。
- 转换临时数据：当前 split COCO 解析对象与当前视频 RLE mask；转换完成即释放。
- 切换视频：先完成保存/放弃协议，再关闭旧 Source，随后发布新 Source。
- 失败或取消：关闭候选 Source，保留旧工作区或当前媒体，不留下半初始化状态。

## 错误与可见反馈

- 根目录不像 Endoscapes：插件不声明，正常进入通用扫描。
- 标记存在但 split/文件名/COCO 合同损坏：明确报告 Endoscapes 错误，不回退。
- 单个视频缺帧、重复帧号或首帧无法解码：只拒绝该视频，工作区仍可选其他视频。
- 标注降级不阻止视频打开；状态栏显示 `已导入 X 个区域，Y 个 mask 退回 box，Z 个区域跳过`。
- 后台扫描和媒体准备均可取消，并拒绝陈旧完成信号。

## 测试与验收

自动测试必须先失败再实现，覆盖：

1. 两个 split、多个视频和同名 `semseg` mask 的合成 Endoscapes 根目录只产生视频级条目。
2. media ID 跨 split 唯一，复合文件名按数值帧号排序，稀疏原始 `frame_id` 不被重编号。
3. 工作区发现不调用图片解码，不保留全库逐帧路径，取消后不替换活动 Catalog。
4. Source 打开只保留当前视频；纹理 LRU 不超过 12；切换后旧 Source 缓存为空。
5. COCO bbox、类别、稳定 region ID 和空帧记录正确转换。
6. compressed RLE 的单环成功转换；多组件、孔洞、触边和畸形输入安全退回 box 或跳过。
7. 已保存 Project6 标签优先于官方 COCO 基线。
8. 通用 manifest、数字序列、单图、视频导入和工作区扫描回归不变。
9. 真实 Endoscapes 只读验收发现 201 个逻辑视频且 media ID 冲突为 0（旧通用递归扫描的失败证据为 493 个冲突）；记录扫描耗时、当前视频帧数、区域数、降级原因和缓存上限。
10. 1280×800 UI 验收确认扫描期间可响应/取消、资源树只显示视频级节点、切换视频后图像与标签对齐。

真实数据性能结果只描述本机证据，不替代普通笔记本验收。自动 PASS 也不替代真实视频人工查看和标注对齐确认。

### 2026-09-10 真实数据只读结果

- Catalog 发现 201 个逻辑视频，0 个 media ID 冲突，最终复跑扫描 0.428190 s，且工作区持有的逐帧路径为 0。
- `endoscapes_train_video_004` 为 633 帧，只持有这 633 条路径；导入 98 个区域，其中 39 polygon、59 box fallback、0 跳过。fallback 原因为触边 43、多连通域 15、孔洞 1。
- `endoscapes_train_video_001` 为 153 帧，导入 28 个 box-only 区域；切换后旧 Source 的帧路径和纹理缓存均为 0。
- 15/15 次纹理加载成功，LRU 峰值 12/12。扫描前后源数据集元数据指纹一致，报告未写入数据集绝对路径。
- 仍未完成 1280×800 可见 UI 人工验收；自动证据不声称人工已观察扫描取消、切换或逐帧标注对齐。

## 兼容性与交付边界

SourceStage V1 的必需方法签名不变；工作区发现是可选扩展。Model Output V1 Schema 不增加 Endoscapes 专用字段。现有标签路径、原子保存、撤销/重做和导出合同不变。实现不得清理本地数据、改写 Endoscapes、提交或推送用户未授权的其他改动。
