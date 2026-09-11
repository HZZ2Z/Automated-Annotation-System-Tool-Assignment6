extends SceneTree
const STORE = preload("res://client/domain/annotation_store.gd")
var errors: Array[String] = []
func check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)
func _init() -> void:
	var store = STORE.new()
	check(store.has_method("freeze_snapshot"), "missing detached freeze_snapshot API")
	check(store.has_method("configure_session"), "missing session metadata API")
	check(store.has_method("restore_corrected"), "missing atomic corrected restore API")
	check(FileAccess.file_exists("res://client/workspace/review_session_codec.gd"), "missing V3 codec")
	if not errors.is_empty():
		finish()
		return
	var records = [{"schema_version":1,"source":"camera_a","frame":12,"regions":[{"id":"r1","class":"tool","kind":"instrument","box":[1,2,3,4]}]}, {"schema_version":1,"source":"camera_a","frame":90,"time_s":3.6,"regions":[]}]
	check(store.load_model_records(records).is_empty(), "load sparse baseline")
	var digest = store.model_digest()
	var context = {"session_id":"session-one","media_id":"clip","media_type":"video","source_relative_path":"clip.mp4","source":"camera_a","source_sha256":null,"round_id":"round1","model_revision":"model1","taxonomy_version":"tax1","revision":7,"baseline_kind":"model","frame_entries":[{"frame":0,"frame_id":12},{"frame":1,"frame_id":90,"time_s":3.6}],"explicit_frames":[12]}
	check(store.configure_session(context).is_empty(), "configure metadata")
	check(store.current_revision() == 7, "restore persisted revision")
	var before = store.freeze_snapshot()
	check(before.is_read_only() and before.records.is_read_only() and before.records[0].regions[0].box.is_read_only(), "snapshot recursively immutable")
	var correction = store.get_corrected_record(12)
	correction.regions[0]["class"] = "edited"
	check(store.replace_corrected_record(12, correction).is_empty(), "edit")
	check(store.current_revision() == 8, "committed edit increments revision")
	check(before.records[0].regions[0]["class"] == "tool", "published snapshot does not change after edit")
	check(store.load_workflow_state({"12":{"accepted_digest":store.record_digest(12)},"90":{"accepted_digest":store.record_digest(90)}}, []).is_empty(), "verify positive and negative")
	check(store.current_revision() == 9, "committed review increments revision")
	var snap = store.freeze_snapshot()
	check(snap.explicit_frames == [12,90], "verified negative becomes explicit")
	var codec = load("res://client/workspace/review_session_codec.gd").new()
	var payload = codec.encode(snap)
	check(payload.frames["12"].source == "human_corrected", "persistent human projection")
	check(payload.baseline_records == records, "raw baseline preserved")
	check(not payload.frames["12"].has("time_s"), "missing time stays absent")
	var artifact = FileAccess.open("/tmp/part4-v3-godot.json", FileAccess.WRITE)
	artifact.store_string(JSON.stringify(payload, "", true, true))
	artifact.close()
	var decoded = codec.decode(JSON.parse_string(JSON.stringify(payload, "", true, true)))
	check(decoded.errors.is_empty(), "decode valid projected session: " + str(decoded.errors))
	if decoded.errors.is_empty():
		var reopened = STORE.new()
		reopened.load_model_records(decoded.snapshot.baseline_records)
		reopened.configure_session(decoded.snapshot)
		check(reopened.restore_corrected(decoded.snapshot.records, decoded.snapshot.review_state, decoded.snapshot.batch_operations).is_empty(), "restore corrected")
		check(reopened.is_verified(12) and reopened.is_verified(90), "verification survives source projection")
		check(reopened.current_revision() == 9 and reopened.model_digest() == digest, "restore does not edit revision or baseline")
		var unchanged = reopened.freeze_snapshot()
		check(not reopened.restore_corrected([correction], {}, []).is_empty(), "reject incomplete frame set")
		check(reopened.freeze_snapshot() == unchanged, "invalid restore is atomic")
		var bad = decoded.snapshot.records.duplicate(true)
		bad[1]["source"] = "wrong"
		check(not reopened.restore_corrected(bad, {}, []).is_empty(), "reject wrong identity")
		check(reopened.freeze_snapshot() == unchanged, "identity failure is atomic")
	for field in ["baseline_records","frame_entries","review_state","explicit_frames"]:
		var bad = payload.duplicate(true)
		bad[field] = "malformed"
		check(not codec.decode(bad).errors.is_empty(), "reject malformed " + field)
	var duplicate_baseline = payload.duplicate(true)
	duplicate_baseline.baseline_records[0].regions.append(duplicate_baseline.baseline_records[0].regions[0].duplicate(true))
	# The malformed baseline is rejected for identity, independently of its digest.
	duplicate_baseline.baseline_digest = JSON.stringify(store._canonicalize(duplicate_baseline.baseline_records), "", true, true).sha256_text()
	check(not codec.decode(duplicate_baseline).errors.is_empty(), "reject duplicate baseline region identities")
	var bad_operation = {"schema_version":1,"type":"range_propagate","mode":"overwrite","keyframe":12,"start_frame":12,"end_frame":90,"affected_frames":[90],"extra":"unsupported"}
	check(not store.load_workflow_state({}, [bad_operation]).is_empty(), "reject uncontracted workflow fields")
	var malformed_baseline = payload.duplicate(true)
	malformed_baseline.baseline_records[0].regions = null
	check(not codec.decode(malformed_baseline).errors.is_empty(), "malformed baseline regions return checked errors")
	var filled_wrong = store.get_corrected_record(12)
	filled_wrong.regions[0]["filled"] = {"unexpected":"metadata"}
	check(not store.replace_corrected_record(12, filled_wrong).is_empty(), "reject nonboolean internal filled metadata")
	var hidden = payload.duplicate(true)
	hidden.explicit_frames = [12]
	hidden.frames.erase("90")
	hidden.review_state.erase("90")
	var hidden_result = codec.decode(hidden)
	check(hidden_result.errors.is_empty() and hidden_result.snapshot.records.size() == 2, "implicit baseline reconstruction")
	var precise_store = STORE.new()
	var precise = records.duplicate(true)
	precise[0].regions[0].box[0] = 3.600000000000001
	precise_store.load_model_records(precise)
	precise_store.configure_session(context)
	var exact_digest = precise_store.freeze_snapshot().baseline_digest
	var exact_content = precise_store.record_digest(12)
	precise[0].regions[0].box[0] = 3.6
	precise_store.load_model_records(precise)
	precise_store.configure_session(context)
	check(precise_store.record_digest(12) != exact_content, "content verification distinguishes exact numeric changes")
	check(precise_store.freeze_snapshot().baseline_digest != exact_digest, "V3 digest distinguishes exact numeric changes")
	var bad_context = context.duplicate(true)
	bad_context.frame_entries[0]["image_path"] = "/home/private/frame.png"
	check(not store.configure_session(bad_context).is_empty(), "reject absolute frame path")
	bad_context = context.duplicate(true)
	bad_context.frame_entries[0]["unexpected"] = "hidden data"
	check(not store.configure_session(bad_context).is_empty(), "reject unexpected frame map fields")
	check(codec.has_method("baseline_display_records"), "codec exposes baseline display seeding helper")
	for kind in ["unknown", "empty"]:
		var empty_payload = payload.duplicate(true)
		empty_payload.baseline_kind = kind
		empty_payload.baseline_records = []
		empty_payload.baseline_digest = null
		var decoded_empty = codec.decode(empty_payload)
		check(decoded_empty.errors.is_empty(), "decode " + kind + " baseline")
		if decoded_empty.errors.is_empty():
			var seed = codec.baseline_display_records(decoded_empty.snapshot)
			check(seed.size() == 2 and seed[0].regions.is_empty() and not seed[0].has("time_s"), "empty display helper preserves absence")
			var empty_store = STORE.new()
			empty_store.load_model_records(seed)
			empty_store.configure_session(decoded_empty.snapshot)
			empty_store.restore_corrected(decoded_empty.snapshot.records, decoded_empty.snapshot.review_state, [])
			check(empty_store.is_verified(12) and empty_store.freeze_snapshot().baseline_records.is_empty(), "unknown/empty restore never promotes corrections")
	# A malformed later baseline frame must not erase the active corrected session.
	var snapshot_before_rejected_load = store.freeze_snapshot()
	var dirty_before_rejected_load = store.get_dirty_frames()
	var digest_before_rejected_load = store.model_digest()
	var malformed_model = records.duplicate(true)
	malformed_model[0].regions[0]["class"] = "candidate-only"
	malformed_model[1].regions = [records[0].regions[0].duplicate(true), records[0].regions[0].duplicate(true)]
	var duplicate_errors = store.load_model_records(malformed_model)
	check(not duplicate_errors.is_empty(), "model load rejects duplicate region IDs within one frame")
	check("records.1.regions.1.id" in " ".join(duplicate_errors), "duplicate model region reports indexed identity path")
	check(store.freeze_snapshot() == snapshot_before_rejected_load, "invalid model load preserves baseline, corrected, metadata, revision and workflow")
	check(store.get_dirty_frames() == dirty_before_rejected_load and store.model_digest() == digest_before_rejected_load, "invalid model load preserves dirty state and legacy digest")
	var shared_ids = records.duplicate(true)
	shared_ids[1].regions = [records[0].regions[0].duplicate(true)]
	check(STORE.new().load_model_records(shared_ids).is_empty(), "same region ID in different frames remains valid")
	_test_v3_playback_audit()
	finish()

func _test_v3_playback_audit() -> void:
	var store = STORE.new()
	var records := []
	for frame in [90,12,77,5]: records.append({"schema_version":1,"source":"camera_a","frame":frame,"regions":[]})
	check(store.load_model_records(records).is_empty(),"codec playback fixture loads")
	var context := {"session_id":"playback-session","media_id":"clip","media_type":"video","source_relative_path":"clip.mp4","source":"camera_a",
		"source_sha256":null,"round_id":"initial","model_revision":"fixture","taxonomy_version":"v1","baseline_kind":"model",
		"frame_entries":[{"frame":0,"frame_id":90},{"frame":1,"frame_id":12},{"frame":2,"frame_id":77},{"frame":3,"frame_id":5}]}
	check(store.configure_session(context).is_empty(),"codec retains nonmonotonic playback entries")
	var marker := {"schema_version":3,"type":"range_propagate","mode":"merge","provider_id":"sam_video","metric_id":"sam-video-v1",
		"keyframe":90,"keyframe_playback_index":0,"keyframe_digest":store.record_digest(90),"region_id":"r","direction":"forward",
		"requested_count":3,"generated_count":3,"start_frame":90,"end_frame":5,"affected_frames":[12,77,5],"target_playback_indices":[1,2,3],
		"stop_frame":null,"stop_reason":"","checkpoint_sha256":"b".repeat(64),"device":"cpu","model_version":"1.1.0","elapsed_ms":10,
		"risk_summary":[],"created_at":"2026-09-11T01:02:03"}
	var snapshot := store.freeze_snapshot().duplicate(true)
	snapshot.batch_operations = [marker]
	var codec = load("res://client/workspace/review_session_codec.gd").new()
	var payload: Dictionary = codec.encode(snapshot)
	check(codec.decode(payload).errors.is_empty(),"codec validates v3 against payload playback entries")
	var wrong := payload.duplicate(true)
	wrong.batch_operations[0].merge({"keyframe":5,"start_frame":5,"end_frame":90,"affected_frames":[12,77,90]},true)
	check(not codec.decode(wrong).errors.is_empty(),"codec refuses numerically sorted v3 forgery with matching frame membership")
	wrong = payload.duplicate(true)
	wrong.batch_operations[0].affected_frames = [77,12,5]
	check(not codec.decode(wrong).errors.is_empty(),"codec refuses target order differing from playback")
	wrong = payload.duplicate(true)
	wrong.batch_operations[0].merge({"generated_count":1,"end_frame":12,"affected_frames":[12],"target_playback_indices":[1],"stop_frame":5,"stop_reason":"model_topology"},true)
	check(not codec.decode(wrong).errors.is_empty(),"codec stop must be the next playback entry")
	wrong.batch_operations[0].stop_frame = 77
	check(codec.decode(wrong).errors.is_empty(),"codec accepts first excluded frame in actual playback order")

func finish() -> void:
	for error in errors: print("FAIL: " + error)
	if errors.is_empty(): print("PASS: Part 4 store and session behavioral contract")
	quit(0 if errors.is_empty() else 1)
