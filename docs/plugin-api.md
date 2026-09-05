# Plugin API version 1

本文档是 Part 1.4 的团队扩展规范。可执行契约位于 `client/pipeline/stages/`，注册与兼容性规则位于 `client/pipeline/plugin_api.gd` 和 `plugin_registry.gd`。插件属于受信任的仓库代码，但所有外部数据仍必须验证；预期内错误用 `PackedStringArray` 返回，空数组表示成功。所有 stage 都必须明确生命周期、深拷贝边界和故障隔离方式。

## 1. 目录与 manifest

每个插件放在 `client/plugins/<stage>/<plugin_name>/`，至少包含 `plugin.json` 和入口脚本。manifest 只允许七个字段：

- `id`：stage 内唯一的小写 snake_case 标识。
- `version`：严格 SemVer，例如 `1.0.0`。
- `api_version`：当前固定为整数 `1`。
- `stage`：`source`、`render`、`edit` 或 `feedback`。
- `entry`：插件目录内安全的 POSIX 相对脚本路径。
- `priority`：整数；自动选择时数值高者优先，相同则按 ID 排序。
- `capabilities`：非空、无重复的能力标识数组。

```json
{
  "id": "example_source",
  "version": "1.0.0",
  "api_version": 1,
  "stage": "source",
  "entry": "plugin.gd",
  "priority": 20,
  "capabilities": ["frames", "model_annotations", "locator.example"]
}
```

Registry 在启动时扫描 Main 的 `plugin_roots`（默认只有 `client/plugins`，可追加团队插件目录）。损坏 JSON、未知字段/阶段、路径穿越、重复 ID、API 不兼容、未继承对应抽象 Stage、不可实例化脚本、缺方法或参数数量错误只会拒绝相应插件。`list_plugins(stage)` 和 `get_descriptor(stage, id)` 只返回元数据；`create_plugin(stage, id)` 每次产生独立实例，Registry 不保存有状态单例。Source 的 `resolve_source_plugin_id(locator, preferred_id)` 调用各插件的 `can_open`；默认不固定 preferred ID，而按 `priority` 降序、ID 升序确定重叠来源。只有显式配置 `source_plugin_id` 才覆盖该顺序，因此新增格式不需要修改 Main 的扩展名分支。

Godot 导出包默认不会自动携带普通 JSON。仓库的 `export_presets.cfg` 明确包含 `client/plugins/**/*.json`；不得删除该规则，否则导出后的启动发现会缺少 manifest。

## 2. Stage interfaces

入口脚本必须继承对应抽象基类，而不是仅靠约定拼写方法；Registry 会沿脚本继承链强制检查。

### SourceStage

继承 `client/pipeline/stages/source_stage.gd` 并实现：

- `can_open(locator: String) -> bool`：只判断自己是否接受该 locator，不修改实例状态。
- `open(locator: String) -> PackedStringArray`：完整验证后才提交内部状态。
- `get_frame_count() -> int`
- `get_frame_entry(index: int) -> Dictionary`
- `get_model_records() -> Array[Dictionary]`
- `get_manifest() -> Dictionary`
- `get_presentation() -> Dictionary`
- `load_texture(index: int) -> Texture2D`
- `close() -> void`

帧、frame entry 和模型记录必须按同一显式索引对齐。manifest、presentation 与记录 getter 返回深拷贝。`get_presentation` 由 Source 自己把文件、localhost 或远程 locator 投影为格式无关的浏览数据：`display_name`、`source_path`、连续的 `frames[{index,label,path}]` 和 `artifacts[{label,path}]`；Main 只校验并消费这些字段，不猜测 `manifest.json`、`image_path` 或模型文件名。现有工作插件是 `image_sequence_source` 和 `single_image_source`；视频先经 `python/frame_source.py` 归一化后，与原生图像序列使用同一个 Source API。

工作区数字图片序列是兼容的应用层 Source：entry 中的 `frame` 仍是连续播放索引，可选 `frame_id` 保留原始稀疏帧号。这不修改 SourceStage V1 的方法签名。工作区发现、单媒体 `label/<media_id>.json`、自动保存和训练 `sample_id` 属于应用协调层，不是插件 API；新插件不应读写这些私有文件。

### RenderStage

继承 `client/pipeline/stages/render_stage.gd` 并实现：

- `set_state(texture, record, transform, selected_id, opacity) -> void`
- `draw(canvas: CanvasItem) -> void`
- `hit_test(image_point: Vector2) -> Dictionary`

Renderer 只持有短期绘制快照，不拥有标注真值。`AnnotationViewport` 初始只依赖无业务绘制逻辑的 `null_renderer.gd`，启动后由 Main 注入所选 Render 插件。现有工作插件是 `canvas_region_renderer`。

`set_hovered_region_id(region_id: String) -> void` 是可选的表现层扩展，不属于 RenderStage v1 的必需签名。`AnnotationViewport` 会在支持该方法的 renderer 上转发当前列表悬停区域，并在悬停变化时请求重绘；未实现该扩展的合法 v1 renderer 仍然可以正常工作。该状态只影响临时高亮，不进入 Store、History 或 Model Output V1。

### EditStage

继承 `client/pipeline/stages/edit_stage.gd` 并实现：

- `get_tool_descriptors() -> Array[Dictionary]`
- `activate(context: Dictionary) -> PackedStringArray`
- `set_active_tool(tool_id: StringName) -> PackedStringArray`
- `get_active_tool() -> StringName`
- `handle_pointer(event, image_position) -> void`
- `handle_key(event) -> bool`
- `invoke(action_id: StringName, payload: Dictionary) -> PackedStringArray`
- `cancel() -> void`
- `deactivate() -> void`

`activate` 的 context 包含 `store`、`history`、`viewport`、`get_current_frame`、`get_selected_region`、`set_selected_region`、`status` 和 `taxonomy`。候选插件必须先验证完整依赖，失败时不接管当前会话；`deactivate` 必须幂等并断开自己建立的信号。

工具描述字段为 `id`、`node_name`、`label`、`implemented`、`tooltip`、`icon_path`，可选 `presentation_text`、唯一的 `default: true` 与 `options`。每个 `options` 条目当前使用 `float_range`：`id`、`label`、`kind`、有限的 `min`/`max`/`step`/`default`，以及可选的 `shared_key`。ToolPanel 只校验并呈现描述，不硬编码具体工具 ID；它发出 `tool_option_changed(tool_id, option_id, value)`，Main 仍通过既有 `invoke` 边界转交。Paint 与 Eraser 以 `brush_radius` / `shared_key: brush_radius` 共用 1–40 image-px 半径，默认 8 px。现有插件通过 `invoke` 支持以下动作：

| action ID | payload | 行为 |
|---|---|---|
| `begin_add_box` | `{}` | 开始加框 |
| `relabel_selected` | `{"class": String}` | 重分类 |
| `set_selected_track_id` | `{"track_id": String/null}` | 修改 track ID |
| `set_selected_fill` | `{"filled": bool}` | 修改显示填充 |
| `set_selected_geometry` | `{"box": Array}` | 修改 box |
| `delete_selected` | `{}` | 删除选中区域 |
| `set_tool_option` | `{"tool_id": StringName, "option_id": StringName, "value": Variant}` | 设置已声明的工具选项；不支持、非有限或越界值拒绝且保留原值 |
| `range_propagate` | `{"keyframe": int, "start_frame": int, "end_frame": int, "mode": "overwrite"/"merge"}` | 将关键帧区域传播到连续范围 |

`basic_edit_tools` 的公共描述子顺序为 Add Box、Subtract、Lasso、Fill、Paint、Eraser 和 Select。Close Gaps、Region Growing 和 Live Wire 不再是 descriptor、capability 或快捷键；`C` / `G` / `I` 保持未绑定。`delete` 仍是 Select 的 Delete/Backspace whole-region path 能力，而不是工具按钮。Paint 的普通单环结果可新建对象；闭合空心结果则保留为临时 Working Mask，Fill 逐个合并点击的封闭孔洞，全部填完后才产生一个待分类实心 polygon。Eraser 必须先选中 region。Subtract 有选区时修改单区，无选区时对所有相交 regions 做一次原子整帧替换，允许整区删除；任一剩余几何违反 V1 则全部拒绝。选中任一笔刷就会发布跟随鼠标的空心半径圆；两者在 motion 中发布结果 raw-mask preview，不包含轨迹或中心点。Lasso/Subtract 近距离松手会自动闭合，Space 用于强制闭合；多闭区轨迹经局部 mask 提取后仍只提交 V1 可表达的实心单环。viewport pan 只使用鼠标中键，右键由 Main 清除选区并切回 Select。

### FeedbackStage

继承 `client/pipeline/stages/feedback_stage.gd` 并实现：

- `export(context: Dictionary) -> PackedStringArray`

context 包含 `records`、`output_path`、`source_manifest`、`model_digest`、`dirty_frames` 和 `batch_operations`。`file_training_handoff` 发出 `export_finished(success, path_or_error)`，在目标同级建立 staging 目录，验证内容与校验和后重命名发布；目标已存在时拒绝覆盖。

```text
training_update_v1/
├── manifest.json
└── data/
    └── corrected_annotations.jsonl
```

manifest 包含 schema/package 版本、确定性 package ID、源数据集 ID/SHA-256、模型基线版本/摘要、taxonomy 版本、帧覆盖、dirty frames、独立 batch operations，以及 corrected artifact 的相对路径、字节数和 SHA-256。原始 `model_output_v1.jsonl` 永远只读。

## 3. 新增插件（不修改 Registry 或 core）

1. 复制最接近的 `client/plugins/<stage>/...` 目录，改成新的目录名。
2. 填写七字段 `plugin.json`；选择唯一 ID、SemVer、能力和合理优先级。
3. 入口脚本继承对应 Stage 抽象类并实现所有方法；不要访问其他插件私有字段。
4. Source 用 `can_open` 声明新 locator，并用 `get_presentation` 提供格式无关的浏览元数据；Edit 用 tool descriptors 和 `invoke` 声明新工具。不要在 Main、ToolPanel 或 Registry 增加格式/工具分支。
5. 在 `tests/godot/fixtures/extension_plugins` 先做最小插件测试，再添加生产行为测试。
6. 需要独立团队目录时，把它追加到 Main 的 `plugin_roots`；同一 stage 的 ID 在所有 roots 中仍必须唯一。
7. 运行 Python 与 Godot 完整门禁，确认 discovery 无错误，`create_plugin` 返回不同实例。

API version 1 已冻结。向插件增加可选能力可以保持 V1；删除必需方法、改变参数数量/语义或改变所有权属于破坏性修改，必须建立 V2，不能静默修改 V1。
