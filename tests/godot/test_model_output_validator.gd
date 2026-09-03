extends RefCounted

const VALIDATOR_PATH := "res://client/domain/model_output_validator.gd"


static func run(support: TestSupport) -> void:
	var script := ResourceLoader.load(VALIDATOR_PATH, "Script") as Script
	support.expect(script != null, "ModelOutputValidator script should exist")
	if script == null:
		return
	var validator = script.new()
	_test_shared_fixtures(validator, support)
	_test_assignment_semantics(validator, support)
	_test_field_paths(validator, support)
	_test_malformed_variants(validator, support)


static func _test_shared_fixtures(validator, support: TestSupport) -> void:
	for filename: String in DirAccess.get_files_at("res://core/fixtures/valid"):
		if "model-output-v1" in filename and filename.ends_with(".json"):
			var record: Variant = JSON.parse_string(
				FileAccess.get_file_as_string("res://core/fixtures/valid/%s" % filename)
			)
			support.expect(
				validator.validate_record(record).is_empty(),
				"valid shared fixture rejected: %s" % filename,
			)
	for filename: String in DirAccess.get_files_at("res://core/fixtures/invalid"):
		if filename.begins_with("model-output-v1-") and filename.ends_with(".json"):
			var record: Variant = JSON.parse_string(
				FileAccess.get_file_as_string("res://core/fixtures/invalid/%s" % filename)
			)
			support.expect(
				not validator.validate_record(record).is_empty(),
				"invalid shared fixture accepted: %s" % filename,
			)


static func _test_assignment_semantics(validator, support: TestSupport) -> void:
	var record: Dictionary = _read_valid("assignment-model-output-v1.json")
	support.expect_equal(record.get("source"), "sample_v1", "source identifies the frame source")
	support.expect(
		record["regions"][0].has("box") and record["regions"][0].has("polygon"),
		"assignment example carries both geometries",
	)
	support.expect(validator.validate_record(record).is_empty(), "assignment example should pass")
	var open_kind: Dictionary = _read_valid("model-output-v1-box-only.json")
	open_kind["regions"][0]["kind"] = "future_custom_kind"
	support.expect(
		validator.validate_record(open_kind).is_empty(),
		"kind examples must not become a closed enum",
	)


static func _test_field_paths(validator, support: TestSupport) -> void:
	var record: Dictionary = _read_valid("model-output-v1-box-only.json")
	record["regions"][0].erase("box")
	var errors: PackedStringArray = validator.validate_record(record)
	support.expect(_has_path(errors, "regions.0"), "missing geometry should identify regions.0")
	record = _read_valid("model-output-v1-box-only.json")
	record["regions"][0]["box"] = [-1, 0, 2, 2]
	errors = validator.validate_record(record)
	support.expect(_has_path(errors, "regions.0.box.0"), "negative x should identify its coordinate")


static func _test_malformed_variants(validator, support: TestSupport) -> void:
	for malformed: Variant in [null, true, 1, "record", [], PackedInt32Array([1, 2])]:
		var errors: PackedStringArray = validator.validate_record(malformed)
		support.expect(not errors.is_empty(), "malformed input should return errors")
		support.expect(_has_path(errors, "$"), "malformed input should identify the root")


static func _read_valid(filename: String) -> Dictionary:
	return JSON.parse_string(
		FileAccess.get_file_as_string("res://core/fixtures/valid/%s" % filename)
	)


static func _has_path(errors: PackedStringArray, path: String) -> bool:
	for error: String in errors:
		if error.begins_with(path + ":") or error.begins_with(path + "."):
			return true
	return false
