## 来源接口：统一提供帧信息、模型记录和图像纹理；调用顺序为 open → 读取 → close。
## 返回的字典和记录须深拷贝；帧映射与扩展规范见 docs/plugin-api.md。
@abstract
class_name SourceStage
extends RefCounted


## 只读判断是否支持该路径或地址，不改变状态；数据完整性由 open 校验。
@abstract func can_open(_locator: String) -> bool

## 打开并校验来源，通过后才提交状态；空错误数组表示成功。
@abstract func open(_locator: String) -> PackedStringArray

## 返回帧数，成功打开后须大于 0，并与清单及模型记录数量一致。
@abstract func get_frame_count() -> int

## 返回帧信息：frame 等于播放索引 index；frame_id 为原始帧号，缺省使用 frame。
## time_s 为非负、有限且按播放顺序非递减的秒数；帧映射在会话内保持稳定。
@abstract func get_frame_entry(_index: int) -> Dictionary

## 按播放顺序返回每帧一条 V1 模型记录；记录的 frame 对应原始帧号，模型基线只读。
@abstract func get_model_records() -> Array[Dictionary]

## 返回来源清单，包含与记录数量一致的 frame_count 和有限正数 nominal_fps。
@abstract func get_manifest() -> Dictionary

## 返回浏览元数据：display_name、source_path、frames 和 artifacts，供界面统一展示。
@abstract func get_presentation() -> Dictionary

## 按播放索引加载对应纹理；越界或读取失败返回 null，不能用其他帧替代。
@abstract func load_texture(_index: int) -> Texture2D

## 清空会话并释放资源和缓存，可重复调用；不删除来源文件。
@abstract func close() -> void
