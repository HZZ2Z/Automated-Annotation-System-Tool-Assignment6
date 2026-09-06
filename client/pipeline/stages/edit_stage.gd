## 编辑接口：将输入和工具动作转为可撤销命令；预览留在草稿，正式记录由 Store 管理。
## 错误数组为空表示成功；上下文字段、动作参数与扩展规范见 docs/plugin-api.md。
@abstract
class_name EditStage
extends RefCounted


## 返回工具描述的深拷贝，供 ToolPanel 创建按钮和选项。
@abstract func get_tool_descriptors() -> Array[Dictionary]

## 校验并绑定 store、history、viewport、taxonomy 和状态/选择回调。
## get_current_frame 回调使用原始帧号；依赖校验通过后才启用编辑。
@abstract func activate(_context: Dictionary) -> PackedStringArray

## 按工具 ID 切换；未知工具或草稿冲突时返回错误，不隐式提交草稿。
@abstract func set_active_tool(_tool_id: StringName) -> PackedStringArray

## 返回当前工具 ID，供界面同步选中状态。
@abstract func get_active_tool() -> StringName

## 处理指针事件；image_position 已是图像像素坐标。预览完成后通过命令提交。
@abstract func handle_pointer(_event: InputEvent, _image_position: Vector2) -> void

## 处理键盘事件；true 表示已消费，false 表示交给后续快捷键处理。
@abstract func handle_key(_event: InputEvent) -> bool

## 统一动作入口；按 action_id 校验 payload，失败不得部分修改正式记录。
@abstract func invoke(_action_id: StringName, _payload: Dictionary = {}) -> PackedStringArray

## 放弃未提交的手势和草稿，清理预览；不撤销已提交的修改。
@abstract func cancel() -> void

## 结束会话，清理预览、信号连接和依赖引用；可重复调用，不销毁共享对象。
@abstract func deactivate() -> void
