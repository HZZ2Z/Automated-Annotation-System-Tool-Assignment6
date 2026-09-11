extends SceneTree
const EXACT = preload("res://client/domain/exact_json.gd")
func _init() -> void:
	var store = preload("res://client/domain/annotation_store.gd").new()
	var records: Array = []
	var entries: Array = []
	var tokens = ["-0.0","5e-324","1e-323","2.2250738585072014e-308","1e-20","1e-7","1e-6","1.0","1e20","1e21","1.7976931348623157e308"]
	for frame in range(tokens.size()):
		var value = EXACT.parse_string(tokens[frame])
		records.append({"schema_version":1,"source":"numbers","frame":frame,"time_s":value,"regions":[{"id":"r","class":"tool","kind":"instrument","box":[value,0.0,1.0,1.0]}]})
		entries.append({"frame":frame,"frame_id":frame,"time_s":value})
	var errors = store.load_model_records(records)
	errors.append_array(store.configure_session({"session_id":"number-hashes","media_id":"numbers","media_type":"video","source_relative_path":"numbers.mp4","source":"numbers","round_id":"r1","model_revision":"m1","taxonomy_version":"t1","revision":0,"baseline_kind":"model","frame_entries":entries}))
	var reviews = {}
	var digests = {}
	for frame in range(records.size()):
		digests[str(frame)] = store.record_digest(frame)
		reviews[str(frame)] = {"accepted_digest":digests[str(frame)]}
	errors.append_array(store.load_workflow_state(reviews,[]))
	var codec = preload("res://client/workspace/review_session_codec.gd").new()
	var payload = codec.encode(store.freeze_snapshot())
	var path = "/tmp/part4-canonical-numbers-v3.json"
	var file = FileAccess.open(path,FileAccess.WRITE)
	file.store_string(JSON.stringify(payload,"",true,true))
	file.close()
	var decoded = codec.decode(EXACT.parse_string(FileAccess.get_file_as_string(path)))
	errors.append_array(decoded.errors)
	var result = preload("res://client/feedback/training_package.gd").new().export_package(store.freeze_snapshot(),{"output_parent":"/tmp/part4-canonical-numbers-package-%d" % Time.get_ticks_usec(),"kind":"training_update_v2"})
	if not result.success: errors.append_array(PackedStringArray(result.errors))
	file = FileAccess.open("/tmp/part4-canonical-numbers-evidence.json",FileAccess.WRITE)
	file.store_string(JSON.stringify({"session":path,"digests":digests,"package":result.get("output_path","")}))
	file.close()
	if errors.is_empty(): print("PASS exact JSON canonical hashes: exponent/subnormal/maxfinite V3 and package roundtrip")
	else: print("FAIL: ", errors)
	quit(0 if errors.is_empty() else 1)
