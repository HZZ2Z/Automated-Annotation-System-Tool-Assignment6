extends RefCounted

signal export_finished(success: bool, path_or_error: String)

const VALIDATOR_SCRIPT := preload("res://client/domain/annotation_validator.gd")


func export(context: Dictionary) -> PackedStringArray:
	var errors := _validate_context(context)
	if not errors.is_empty():
		export_finished.emit(false, "; ".join(errors))
		return errors
	var output_path := ProjectSettings.globalize_path(String(context["output_path"])).simplify_path()
	var corrected_records: Array[Dictionary] = []
	var validator = VALIDATOR_SCRIPT.new()
	var input_records: Array = context["records"]
	for index in range(input_records.size()):
		var corrected: Dictionary = (input_records[index] as Dictionary).duplicate(true)
		corrected["source"] = "human_corrected"
		var record_errors: PackedStringArray = validator.validate_record(corrected)
		for error: String in record_errors:
			errors.append("records.%d.%s" % [index, error])
		corrected_records.append(corrected)
	if not errors.is_empty():
		export_finished.emit(false, "; ".join(errors))
		return errors

	errors = _write_jsonl_atomically(corrected_records, output_path)
	var detail := output_path if errors.is_empty() else "; ".join(errors)
	export_finished.emit(errors.is_empty(), detail)
	return errors


func _validate_context(context: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	var records: Variant = context.get("records")
	if not records is Array or records.is_empty():
		errors.append("records: expected a non-empty Array")
	else:
		for index in range(records.size()):
			if not records[index] is Dictionary:
				errors.append("records.%d: expected a Dictionary" % index)
	var output_value: Variant = context.get("output_path")
	if typeof(output_value) != TYPE_STRING or String(output_value).strip_edges().is_empty():
		errors.append("output_path: expected a non-empty String")
		return errors
	var output_path := ProjectSettings.globalize_path(String(output_value)).simplify_path()
	if DirAccess.dir_exists_absolute(output_path):
		errors.append("output_path: expected a file, got a directory")
		return errors
	var parent := output_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(parent):
		errors.append("output_path directory does not exist: %s" % parent)
	return errors


func _write_jsonl_atomically(records: Array[Dictionary], output_path: String) -> PackedStringArray:
	var errors := PackedStringArray()
	var temporary_path := output_path.get_base_dir().path_join(
		".%s.tmp-%d-%d" % [output_path.get_file(), OS.get_process_id(), Time.get_ticks_usec()]
	)
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		errors.append("cannot create temporary export beside output: %s" % error_string(FileAccess.get_open_error()))
		return errors
	for record: Dictionary in records:
		file.store_string(JSON.stringify(record, "", true) + "\n")
	file.flush()
	var write_error := file.get_error()
	file = null
	if write_error != OK:
		DirAccess.remove_absolute(temporary_path)
		errors.append("could not write corrected JSONL: %s" % error_string(write_error))
		return errors
	var rename_error := DirAccess.rename_absolute(temporary_path, output_path)
	if rename_error != OK:
		DirAccess.remove_absolute(temporary_path)
		errors.append("could not publish corrected JSONL atomically: %s" % error_string(rename_error))
	return errors
