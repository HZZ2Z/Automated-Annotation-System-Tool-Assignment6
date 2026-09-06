## 渲染接口：绘制图像和标注并查询命中区域，只持有显示快照，不修改 Store。
## 坐标与扩展规范见 docs/plugin-api.md。
@abstract
class_name RenderStage
extends RefCounted


## 更新绘制状态；record 须深拷贝，transform 为 ViewportTransform 对象。
## selected_id 为空表示无选中区域；opacity 为 [0, 1] 的填充透明度。
@abstract func set_state(_texture: Texture2D, _record: Dictionary, _transform: Variant, _selected_id: String, _opacity: float) -> void

## 在画布绘制回调中使用最新状态绘制；通过共享变换把图像坐标转为视口坐标。
@abstract func draw(_canvas: CanvasItem) -> void

## 输入图像像素坐标；命中返回区域副本，未命中返回 {}，不改变选择状态。
@abstract func hit_test(_image_point: Vector2) -> Dictionary
