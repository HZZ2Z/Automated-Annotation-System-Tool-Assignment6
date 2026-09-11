extends SceneTree
const PACKAGE_SCRIPT = preload("res://client/feedback/training_package.gd")
var errors: Array[String] = []
func check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)
func _init() -> void:
	check(FileAccess.file_exists("res://client/feedback/annotation_diff.gd"), "missing pure diff service")
	check(FileAccess.file_exists("res://client/feedback/training_package.gd"), "missing package service")
	if not errors.is_empty():
		finish()
		return
	var store = load("res://client/domain/annotation_store.gd").new()
	var region = {"id":"r1","class":"tool","kind":"instrument","box":[12,2,3,4]}
	var records = [{"schema_version":1,"source":"cam","frame":12,"regions":[region]}, {"schema_version":1,"source":"cam","frame":90,"time_s":3.600000000000001,"regions":[]}]
	check(store.load_model_records(records).is_empty(), "load")
	var context = {"session_id":"sess","media_id":"clip","media_type":"video","source_relative_path":"clip.mp4","source":"cam","source_sha256":null,"round_id":"round1","model_revision":"m1","taxonomy_version":"t1","revision":0,"baseline_kind":"model","frame_entries":[{"frame":0,"frame_id":12},{"frame":1,"frame_id":90,"time_s":3.600000000000001}],"explicit_frames":[12]}
	check(store.configure_session(context).is_empty(), "configure")
	var diff = load("res://client/feedback/annotation_diff.gd").new()
	check(diff.build_diff(store.freeze_snapshot(), [12,90]).summary.changed_regions == 0, "unchanged diff")
	var changed = store.get_corrected_record(12)
	changed.regions[0].box[0] = 12.0
	changed.regions[0]["filled"] = true
	store.replace_corrected_record(12, changed)
	check(diff.build_diff(store.freeze_snapshot(), [12]).summary.changed_regions == 0, "numeric and filled ignored")
	changed.regions[0].box[0] = 12.000000000000002
	changed.regions[0]["class"] = "new,tool"
	changed.regions[0]["conf"] = 0.8
	store.replace_corrected_record(12, changed)
	var d = diff.build_diff(store.freeze_snapshot(), [12,90])
	check(d.summary.changed_regions == 1 and d.summary.geometry_changed == 1 and d.summary.label_changed == 1 and d.summary.attributes_changed == 1, "three categories one region")
	var batch_marker = {"schema_version":2,"type":"range_propagate","mode":"merge","keyframe":12,
		"start_frame":12,"end_frame":90,"affected_frames":[90],"metric_id":"poly-sim-flow-edge-v1",
		"threshold":0.6,"max_frames":30,"frame_step":78,"keyframe_digest":"a".repeat(64),
		"created_at":"2026-09-10T17:45:15","start_index":0,"end_index":1,"left_stop":"source boundary",
		"right_stop":"source boundary","changed_count":1,"covered_count":2,"edge_refinement":{
			"attempted":1,"accepted":0,"fallback":1,"items":[{"frame_id":90,"region_id":"r1",
				"accepted":false,"reason":"Hausdorff above 6","raw_edge_score":0.04,"refined_edge_score":0.09}]}}
	check(store.load_workflow_state({"12":{"accepted_digest":store.record_digest(12)},"90":{"accepted_digest":store.record_digest(90)}}, [batch_marker]).is_empty(), "load Poly V2 batch provenance")
	var package = load("res://client/feedback/training_package.gd").new()
	var plugin = load("res://client/plugins/feedback/file_training_handoff/plugin.gd").new()
	check(plugin.has_method("export_package"), "plugin exposes optional V2 package API")
	var token = load("res://client/services/job_token.gd").new()
	var parent = "/tmp/part4-package-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(parent)
	var options = {"output_parent":parent,"kind":"training_update_v2"}
	var result = package.export_package(store.freeze_snapshot(), options, token)
	check(not token.take_progress().is_empty(), "real JobToken receives worker progress")
	check(result.success, "export " + str(result.errors))
	if result.success:
		check(result.summary.included_frames == 2, "verified negative included")
		var manifest = JSON.parse_string(FileAccess.get_file_as_string(result.output_path.path_join("manifest.json")))
		var texts = {}
		for relative in PACKAGE_SCRIPT.PATHS: texts[relative] = FileAccess.get_file_as_string(result.output_path.path_join(relative))
		var report = JSON.parse_string(texts[PACKAGE_SCRIPT.PATHS[2]])
		for mutation in ["wrong_step","keyframe_item","legacy_claim","missing_audit"]:
			var invalid = manifest.duplicate(true)
			match mutation:
				"wrong_step": invalid.batch_operations[0].frame_step = 77
				"keyframe_item": invalid.batch_operations[0].edge_refinement.items[0].frame_id = 12
				"legacy_claim": invalid.batch_operations[0].schema_version = 1
				"missing_audit": invalid.batch_operations[0].erase("edge_refinement")
			check(not PACKAGE_SCRIPT.SEMANTICS.validate(invalid,texts,report).is_empty(), "reject Poly V2 package provenance " + mutation)
		var second = package.export_package(store.freeze_snapshot(), options)
		check(second.success and second.reused and second.package_id == result.package_id, "valid existing reuse")
		var codec = load("res://client/workspace/review_session_codec.gd").new()
		var reopened = codec.decode(JSON.parse_string(JSON.stringify(codec.encode(store.freeze_snapshot()), "", true, true)))
		var again = package.export_package(reopened.snapshot, options)
		check(again.success and again.package_id == result.package_id, "same identity after reopen")
		var marker = FileAccess.open("/tmp/part4-package-path.txt", FileAccess.WRITE)
		marker.store_string(result.output_path)
		marker.close()
		var extra = FileAccess.open(result.output_path.path_join("extra.txt"), FileAccess.WRITE)
		extra.store_string("foreign content")
		extra.close()
		check(not package.export_package(store.freeze_snapshot(), options).success, "refuse package containing foreign file")
		DirAccess.remove_absolute(result.output_path.path_join("extra.txt"))
	var unknown = store.freeze_snapshot().duplicate(true)
	unknown.baseline_kind = "unknown"
	unknown.baseline_records = []
	unknown.baseline_digest = null
	check(not package.export_package(unknown, options).success, "unknown refuses training")
	check(not diff.build_diff(unknown,[12]).available, "unknown diff unavailable")
	var review = package.export_package(unknown, {"output_parent":parent,"kind":"review_export_v1"})
	check(review.success, "unknown review allowed " + str(review.errors))
	store.load_workflow_state({}, [])
	check(not package.export_package(store.freeze_snapshot(), options).success, "zero verified refuses")
	finish()
func finish() -> void:
	for e in errors: push_error(e)
	if errors.is_empty(): print("PASS: Part 4 diff and package")
	quit(0 if errors.is_empty() else 1)
