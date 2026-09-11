extends SceneTree
const EXACT = preload("res://client/domain/exact_json.gd")
const CODEC = preload("res://client/workspace/review_session_codec.gd")
var errors: Array[String] = []
func check(ok: bool,message: String) -> void:
	if not ok: errors.append(message)
func _init() -> void:
	var source_path := "/tmp/part4-python30-source"
	var arguments := OS.get_cmdline_user_args()
	var source_index := arguments.find("--source")
	if source_index >= 0 and source_index + 1 < arguments.size():
		source_path = arguments[source_index + 1]
	var source = preload("res://client/plugins/source/image_sequence_source/plugin.gd").new()
	var open_errors := source.open(source_path)
	check(open_errors.is_empty(),"Python 30fps Source opens: " + str(open_errors))
	var records: Array = source.get_model_records()
	if not open_errors.is_empty() or records.size() != 120:
		for failure in errors: print("FAIL: " + failure)
		quit(1)
		return
	var entries: Array = []
	for frame in range(120):
		var entry = source.get_frame_entry(frame)
		entry["frame_id"] = frame
		entries.append(entry)
		if not entry.has("time_s") or not records[frame].has("time_s"):
			check(false,"Source omits exact time_s at frame %d (entry=%s record=%s)" % [frame,entry.keys(),records[frame].keys()])
			continue
		check(entry.time_s == frame/30.0 and records[frame].time_s == frame/30.0 and records[frame].regions[0].box[0] == 7/30.0,"Source reads original Python numeric bits at frame %d" % frame)
	var store = preload("res://client/domain/annotation_store.gd").new()
	var exact_records = []
	for line in FileAccess.get_file_as_string(source_path.path_join("model_output_v1.jsonl")).strip_edges().split("\n"):
		exact_records.append(EXACT.parse_string(line))
	store.load_model_records(exact_records)
	for entry in entries: entry.time_s = entry.frame/30.0
	check(store.configure_session({"session_id":"numeric","media_id":"numeric30","media_type":"image_sequence","source_relative_path":"numeric30","source":"numeric30","source_sha256":null,"round_id":"round1","model_revision":"m1","taxonomy_version":"t1","revision":0,"baseline_kind":"model","frame_entries":entries}).is_empty(),"exact model configures")
	store.load_workflow_state({"7":{"accepted_digest":store.record_digest(7)}},[])
	var before = store.freeze_snapshot()
	var payload = CODEC.new().encode(before)
	var document = preload("res://client/workspace/atomic_document.gd").new()
	var path = "/tmp/part4-exact-json-session-%d.json" % Time.get_ticks_usec()
	var written = document.write_document(payload,{"path":path,"validate":func(value): return CODEC.new().decode(value).errors})
	check(written.success,"120-frame 30fps V3 exact atomic save: " + str(written.errors))
	if written.success:
		var reopened = CODEC.new().decode(document.read_document(path).payload)
		check(reopened.errors.is_empty() and reopened.snapshot.baseline_digest == before.baseline_digest,"reopened baseline digest unchanged")
		var marker = FileAccess.open("/tmp/part4-exact-json-session-path.txt",FileAccess.WRITE)
		marker.store_string(path)
		marker.close()
	var changed = store.get_corrected_record(7)
	changed.regions[0].box[0] = EXACT.parse_string("0.23333333333333336")
	store.replace_corrected_record(7,changed)
	check(not store.is_verified(7),"one ULP coordinate edit invalidates content verification")
	var round_reader = preload("res://client/workspace/model_round_controller.gd").new()
	var returned = round_reader._read_records(source_path.path_join("model_output_v1.jsonl"))
	check(returned.success and returned.records[7].time_s == 7/30.0,"returned model JSONL reads exact source timestamps")
	for failure in errors.slice(0,8): print("FAIL: " + failure)
	print("Exact JSON integration failures: ",errors.size())
	quit(0 if errors.is_empty() else 1)
