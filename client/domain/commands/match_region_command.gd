class_name MatchRegionCommand
extends "res://client/domain/commands/replace_frame_command.gd"

const SOLVER := preload("res://client/domain/region_match_solver.gd")

var outcome: StringName = &"invalid"
var message := ""


# 一次快照命令同时负责标签、并集和删除；redo 重放已算好的结果，不重新求几何。
func _init(frame_index: int, old_record: Dictionary, source_id: String, reference_id: String, image_size: Vector2) -> void:
	super(frame_index, old_record, old_record)
	var result := SOLVER.solve(old_record, source_id, reference_id, image_size)
	outcome = result.status
	message = result.message
	if outcome == &"invalid":
		_reject(message)
	else:
		after = result.record


func apply(store: Variant) -> PackedStringArray:
	if not _construction_errors.is_empty():
		return _construction_errors.duplicate()
	var errors := _check_snapshot(store, before)
	return super.apply(store) if errors.is_empty() else errors


func revert(store: Variant) -> PackedStringArray:
	var errors := _check_snapshot(store, after)
	return super.revert(store) if errors.is_empty() else errors


func _check_snapshot(store: Variant, expected: Dictionary) -> PackedStringArray:
	if not store is Object or not store.has_method("get_corrected_record"):
		return PackedStringArray(["Match requires an annotation Store"])
	if store.get_corrected_record(frame) != expected:
		return PackedStringArray(["区域记录已变化，Match 未覆盖后续修改"])
	return PackedStringArray()
