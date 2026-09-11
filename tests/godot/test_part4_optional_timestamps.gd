extends SceneTree
const STORE = preload("res://client/domain/annotation_store.gd")
const CODEC = preload("res://client/workspace/review_session_codec.gd")
var errors: Array[String] = []
func check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)
func _init() -> void:
	var fixture = preload("res://tests/godot/test_playback.gd").new()
	var support = preload("res://tests/godot/test_support.gd").new()
	var path = fixture._make_source(support,"untimed_model",2,25.0,"model_output_v1")
	check(support.failures.is_empty(),"actual playback fixture generated")
	var source = preload("res://client/plugins/source/image_sequence_source/plugin.gd").new()
	check(source.open(path).is_empty(),"actual playback source opens")
	var records: Array = source.get_model_records()
	var entries: Array = []
	for index in range(2):
		var entry = source.get_frame_entry(index)
		entry["frame_id"] = index
		entries.append(entry)
	check(not records[0].has("time_s") and entries[0].time_s == 0.125,"real fixture supplies timed entries and untimed V1 records")
	var context = {"session_id":"optional-session","media_id":"clip","media_type":"image_sequence","source_relative_path":"clip","source":records[0].source,"source_sha256":null,"round_id":"r1","model_revision":"m1","taxonomy_version":"t1","revision":0,"baseline_kind":"model","frame_entries":entries,"explicit_frames":[0,1]}
	var store = STORE.new()
	store.load_model_records(records)
	var configured = store.configure_session(context)
	check(configured.is_empty(),"allow untimed raw baseline under timed Source entries: " + str(configured))
	var codec = CODEC.new()
	if configured.is_empty():
		var before = store.freeze_snapshot()
		var correction = store.get_corrected_record(0)
		correction.regions = [{"id":"r","class":"tool","kind":"instrument","box":[0,0,1,1]}]
		check(store.replace_corrected_record(0,correction).is_empty(),"edit keeps absent timestamp")
		store.load_workflow_state({"0":{"accepted_digest":store.record_digest(0)}},[])
		var payload = codec.encode(store.freeze_snapshot())
		var decoded = codec.decode(JSON.parse_string(JSON.stringify(payload,"",true,true)))
		check(decoded.errors.is_empty(),"known baseline V3 reopens")
		if decoded.errors.is_empty():
			var reopened = STORE.new()
			reopened.load_model_records(codec.baseline_display_records(decoded.snapshot))
			reopened.configure_session(decoded.snapshot)
			reopened.restore_corrected(decoded.snapshot.records,decoded.snapshot.review_state,decoded.snapshot.batch_operations)
			check(reopened.is_verified(0) and reopened.freeze_snapshot().baseline_records == before.baseline_records and not reopened.get_corrected_record(0).has("time_s"),"raw optionality, baseline and verification survive reopen")
			var package = preload("res://client/feedback/training_package.gd").new()
			var exported = package.export_package(reopened.freeze_snapshot(),{"output_parent":"/tmp/part4-untimed-package-%d" % Time.get_ticks_usec(),"kind":"training_update_v2"})
			check(exported.success,"actual Godot untimed annotation/timed frame-map package: " + str(exported.errors))
			if exported.success:
				var output = FileAccess.open("/tmp/part4-untimed-package-path.txt",FileAccess.WRITE)
				output.store_string(exported.output_path)
				output.close()
		var invalid_correction = store.get_corrected_record(0)
		invalid_correction.time_s = entries[0].time_s
		check(not store.replace_corrected_record(0,invalid_correction).is_empty(),"correction cannot invent baseline timestamp even if source agrees")
	var wrong = records.duplicate(true)
	wrong[0].time_s = 999
	var wrong_store = STORE.new()
	wrong_store.load_model_records(wrong)
	check(not wrong_store.configure_session(context).is_empty(),"provided model time must exactly match Source")
	var missing_map = context.duplicate(true)
	missing_map.frame_entries[0].erase("time_s")
	check(not wrong_store.configure_session(missing_map).is_empty(),"provided model time requires Source timestamp")
	var unknown = context.duplicate(true)
	unknown.merge({"schema_version":3,"frame_digits":6,"baseline_kind":"unknown","baseline_records":[],"baseline_digest":null,"explicit_frames":[0],"frames":{"0":{"schema_version":1,"source":"human_corrected","frame":0,"regions":[]}},"review_state":{},"batch_operations":[]},true)
	for kind in ["unknown","empty"]:
		unknown.baseline_kind = kind
		var decoded = codec.decode(unknown)
		check(decoded.errors.is_empty(),"legacy explicit timestamp absence preserved for " + kind + ": " + str(decoded.errors))
		if decoded.errors.is_empty():
			var seed = codec.baseline_display_records(decoded.snapshot)
			check(not seed[0].has("time_s") and seed[1].time_s == entries[1].time_s,"explicit absence preserved; implicit frame may use source time")
			check(not codec.encode(decoded.snapshot).frames["0"].has("time_s"),"codec never invents legacy timestamp")
	unknown.frames["0"].time_s = 999
	check(not codec.decode(unknown).errors.is_empty(),"wrong provided legacy time rejected")
	for message in errors: print("FAIL: " + message)
	if errors.is_empty(): print("PASS Part 4 optional V1 timestamps, legacy absence and real untimed training package")
	quit(0 if errors.is_empty() else 1)
