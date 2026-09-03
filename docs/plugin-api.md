# 插件 API

本文档固定 Part 1 流水线的 **API version 1**。可执行契约位于 `client/pipeline/plugin_api.gd`；在修改本文档或升级版本前，必须先更新注册表兼容性测试。

## 插件声明

每个插件都是 `client/plugins/<stage>/<plugin-name>/` 下的一个目录，其中包含 `plugin.json` 和入口脚本。插件声明只允许以下字段：

- `id`：非空插件标识，在同一 stage 内唯一。
- `version`：非空实现版本字符串。
- `api_version`：整数 `1`；其他值均不兼容。
- `stage`：`source`、`render`、`edit` 或 `feedback` 之一。
- `entry`：指向可实例化 GDScript resource 的安全 POSIX 相对路径。

示例：

```json
{
  "id": "example_source",
  "version": "1.0.0",
  "api_version": 1,
  "stage": "source",
  "entry": "plugin.gd"
}
```

入口脚本必须能无参数实例化并继承 `RefCounted`。未知字段、不安全路径、重复 ID、未知阶段、损坏 JSON 和缺失方法都会被拒绝。发现顺序是确定的，并且按插件进行故障隔离。

## 数据源阶段（source）

必需方法：

- `open(path: String) -> PackedStringArray`：验证并暂存一个数据源；空数组表示成功。
- `get_frame_count() -> int`：权威索引帧数量。
- `get_frame_entry(index: int) -> Dictionary`：至少包含 `frame`、`time_s` 和 `image_path` 的防御性副本。
- `get_model_records() -> Array[Dictionary]`：每帧一条规范模型输出记录的深拷贝。
- `get_manifest() -> Dictionary`：规范数据清单的深拷贝。
- `load_texture(index: int) -> Texture2D`：返回已解码帧；失败时返回 `null` 并提供可读插件错误。
- `close() -> void`：释放缓存/资源并返回空状态；重复调用必须安全。

数据源插件拥有解码和缓存生命周期，主应用拥有已安装实例。帧索引、清单项和记录必须完全对齐。公开 getter 返回深拷贝，防止下游代码修改数据源真值。若清单声明 `model_version: "model_output_v1"`，实现只读取同名的 `model_output_v1.jsonl`；记录中的 `source` 仍表示帧来源，例如 `sample_v1`。

## 渲染阶段（render）

必需方法：

- `set_state(texture: Texture2D, record: Dictionary, transform, selected_id: String, opacity: float) -> void`：替换短期绘制状态。
- `draw(canvas: CanvasItem) -> void`：绘制当前图像和 overlay。
- `hit_test(image_point: Vector2) -> Dictionary`：返回命中区域的副本，或空 Dictionary。

渲染阶段接收已验证数据，以及用于命中测试的同一图像/视口变换。它不拥有标注状态，也不得修改输入记录。

## 编辑阶段（edit）

必需生命周期和交互方法：

- `activate(context: Dictionary) -> PackedStringArray`
- `set_active_tool(tool_id: StringName) -> PackedStringArray`
- `get_active_tool() -> StringName`
- `handle_pointer(event: InputEvent, image_position: Vector2) -> void`
- `handle_key(event: InputEvent) -> bool`
- `begin_add_box() -> void`
- `cancel() -> void`
- `relabel_selected(class_label: String) -> PackedStringArray`
- `set_selected_track_id(track_id: Variant) -> PackedStringArray`
- `set_selected_fill(filled: bool) -> PackedStringArray`
- `set_selected_geometry(box: Array) -> PackedStringArray`
- `delete_selected() -> PackedStringArray`
- `deactivate() -> void`

`activate` 接收 `store`、`history`、`viewport`、`get_current_frame`、`get_selected_region`、`set_selected_region`、`status` 和 `taxonomy`。它在进入 active 状态前验证完整依赖面。支持的 tool ID 是 `select`、`move`、`box`、`fill` 和 `delete`。

生命周期是显式的：Main 为候选数据源创建新实例，对暂存状态激活它，并且只在激活成功后安装。`cancel` 恢复已提交显示状态，不创建 history；`deactivate` 执行取消、断开信号、清除引用，并且是幂等的。一次完成编辑通过 history 作为一条已验证命令提交。

## 导出/回传阶段（feedback）

必需方法：

- `export(context: Dictionary) -> PackedStringArray`：验证完整 corrected snapshot 并发布；空数组表示成功。

Part 1 实现接收 `records: Array` 和 `output_path: String`，并发出：

- `export_finished(success: bool, path_or_error: String)`

插件先获取深拷贝，保留每条记录原有的 `source`，再使用 `client/domain/model_output_validator.gd` 校验。发布使用同目录临时文件和重命名；故障隔离要求之前的有效输出保持不变。导出路径必须与只读的 `model_output_v1.jsonl` 分开，插件不得覆盖原始模型输出。Part 4 可以在同一 `export(context)` 边界后新增差异报告和训练交接文件。

## 错误、数据所有权和兼容性

预期内验证和 I/O 失败返回包含简洁信息的 `PackedStringArray`；它们不能使界面崩溃，也不向用户暴露原始调用栈。空数组表示成功。除非对象被明确定义为短期渲染状态，返回 Dictionary 或记录数组的方法都返回深拷贝。插件私有字段永远不是核心接口。

API 兼容性是精确契约：新增或删除必需方法时，必须协调修改测试和文档；无法保持向后兼容时还必须修改 `api_version`。Registry 检查方法是否存在，每个 stage 的 contract test 检查行为和所有权。

## 新增插件

1. 创建 `client/plugins/<stage>/<new-plugin>/`。
2. 添加一个包含五个字段的 `plugin.json`，设置 `api_version: 1` 和 stage 内唯一 ID。
3. 在一个无参数 `RefCounted` 脚本中实现该 stage 列出的所有方法。
4. 按上述规则返回防御性副本和可恢复错误。
5. 新增聚焦行为测试，并运行完整 Godot 测试套件。
6. 启动客户端，并通过 `get_discovered_plugin(stage, id)` 确认插件被发现。

该目录应当在**不修改 Registry**或主应用发现循环的情况下被发现。只有当产品明确要改变当前实现时，主应用配置才选择替代插件 ID。
