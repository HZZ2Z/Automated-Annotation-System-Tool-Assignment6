## 反馈接口：导出修订快照供后续训练使用，保留原始模型输出和当前编辑状态。
## 导出格式与扩展规范见 docs/plugin-api.md。
@abstract
class_name FeedbackStage
extends RefCounted


## 同步导出；空错误数组表示成功，非空表示失败原因。
## context：records 为全部修订记录，output_path 为目标路径，source_manifest 为来源清单；
## model_digest 为原模型记录摘要，dirty_frames 为已修改原始帧号，batch_operations 为批量操作日志。
## 文件插件先校验并写入临时目录，再发布；拒绝覆盖已有目标，失败只清理本次临时产物。
@abstract func export(_context: Dictionary) -> PackedStringArray
