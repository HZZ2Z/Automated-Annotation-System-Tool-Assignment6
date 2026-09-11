extends SceneTree

const SUPPORT := preload("res://tests/godot/test_support.gd")
const STORE := preload("res://client/domain/annotation_store.gd")
const COMMAND := preload("res://client/domain/commands/apply_propagation_command.gd")
const HISTORY := preload("res://client/domain/command_history.gd")
const CONTROLLER := preload("res://client/services/batch_controller.gd")
const REVIEW := preload("res://client/domain/commands/review_frames_command.gd")
const FIXTURES := preload("res://tests/godot/test_sam_video_batch.gd")
const MARKERS := preload("res://tests/godot/test_batch_marker_validation.gd")
var s = SUPPORT.new()

class Inference extends FIXTURES.Inference:
	var runtime_override := {}
	func get_result() -> Dictionary:
		var result := super.get_result()
		result.runtime.model_version = "1.1.0"
		result.runtime.merge(runtime_override, true)
		return result

func _initialize() -> void: call_deferred("run")

func run() -> void:
	MARKERS.new().run(s)
	_test_atomic_controller()
	_test_generated_targets_include_unchanged()
	_test_conflicts()
	_test_command_scope()
	_test_missing_anchor()
	_test_prefix_and_runtime()
	_test_roundtrip()
	_test_source_playback_order()
	if s.failures.is_empty():
		print("PASS SAM video batch command, exact v3 validation and persistence")
		quit(0)
	else:
		printerr(s.failure_report())
		quit(1)

func _record(index: int) -> Dictionary:
	var regions: Array = [{"id":"before","class":"anatomy","kind":"anatomy","box":[30,30,3,3]},
		{"id":"r","class":"anchor" if index == 0 else "target","kind":"instrument","track_id":"T%d" % index,"conf":0.73,"box":[10,12,4,3]},
		{"id":"after","class":"clip","kind":"anatomy","box":[40,30,3,3]}]
	if index == 2: regions.remove_at(1)
	return {"schema_version":1,"source":"test","frame":11825 + index * 25,"time_s":index * 0.8,"regions":regions}

func _fixture(count := 4, frame_ids: Array = []) -> Dictionary:
	var source := FIXTURES.Source.new()
	var records := []
	for index in range(count):
		var record := _record(index)
		if not frame_ids.is_empty(): record.frame = frame_ids[index]
		records.append(record)
		source.entries.append({"frame":index,"frame_id":record.frame,"time_s":index*0.8,"image_path":"%d.png" % index})
	var store := STORE.new()
	s.expect_equal(store.load_model_records(records), PackedStringArray(), "SAM command fixture loads")
	s.expect_equal(store.configure_session({"session_id":"sam-command-session","media_id":"clip","media_type":"image_sequence",
		"source_relative_path":"clip","source":"test","source_sha256":null,"round_id":"initial","model_revision":"fixture",
		"taxonomy_version":"v1","baseline_kind":"model","frame_entries":source.entries}),PackedStringArray(),"SAM fixture owns validated Source playback entries")
	var history := HISTORY.new()
	var controller := CONTROLLER.new()
	controller.configure(source, store, history, source.entries)
	var live := {"key_index":0,"region_id":"r","edit_pending":false}
	controller.configure_sam_context(func(): return live.duplicate(true))
	var inference := Inference.new()
	controller._providers[&"sam_video"].service = inference
	return {"store":store,"history":history,"controller":controller,"source":source,"inference":inference,"live":live}

func _prepare(f: Dictionary, requested := 2, last := -1) -> Dictionary:
	s.expect_equal(f.controller.start_sam_video_analysis(0,"r",requested,true), PackedStringArray(), "SAM analysis starts")
	f.controller.step_analysis()
	var plan: Dictionary = f.controller.get_plan()
	s.expect(not plan.is_empty(), "SAM plan published")
	if plan.is_empty(): return {}
	var preview: Dictionary = f.controller.preview(0, plan.end_index if last < 0 else last, "overwrite")
	s.expect_equal(preview.get("errors"), PackedStringArray(), "region preview valid")
	return preview

func _metadata(f: Dictionary) -> Dictionary:
	var marker := MARKERS.new()._sam_marker()
	marker.keyframe_digest = f.store.record_digest(11825)
	marker.expected_review_state = f.store.snapshot_review_state()
	marker.expected_batch_operations = f.store.snapshot_batch_operations()
	return marker

func _direct(f: Dictionary, preview: Dictionary, metadata := {}) -> RefCounted:
	return COMMAND.new(f.store.get_corrected_record(11825), preview.before, preview.after, _metadata(f) if metadata.is_empty() else metadata)

func _make_targets_match_sam_candidate(f: Dictionary, frames: Array) -> void:
	var key: Dictionary = f.store.get_corrected_record(11825)
	for frame: int in frames:
		var record: Dictionary = f.store.get_corrected_record(frame)
		var position := -1
		for index in range(record.regions.size()):
			if record.regions[index].id == "r": position = index
		var shell: Dictionary = record.regions[position].duplicate(true) if position >= 0 else key.regions[1].duplicate(true)
		shell.erase("box")
		shell["polygon"] = [[10.0,12.0],[14.0,12.0],[14.0,15.0],[10.0,15.0]]
		if position >= 0: record.regions[position] = shell
		else: record.regions.append(shell)
		s.expect_equal(f.store.replace_corrected_record(frame,record),PackedStringArray(),"matching SAM target fixture installs")

func _test_atomic_controller() -> void:
	var f := _fixture()
	REVIEW.new([11825],true).apply(f.store)
	var preview := _prepare(f)
	var before: Dictionary = f.store.freeze_snapshot()
	var key: Dictionary = f.store.get_corrected_record(11825)
	var result: PackedStringArray = f.controller.apply_preview()
	s.expect_equal(result, PackedStringArray(), "SAM Controller applies exact v3 audit")
	if not result.is_empty(): return
	var after: Dictionary = f.store.freeze_snapshot()
	s.expect_equal(after.revision, before.revision+1, "Apply increments revision exactly once")
	s.expect_equal(f.history.get_undo_count(),1,"SAM is one history item")
	s.expect_equal(f.store.get_corrected_record(11825), key, "keyframe remains exact")
	s.expect_equal(after.review_state["11825"],before.review_state["11825"],"key review remains exact")
	var target: Dictionary = f.store.get_corrected_record(11850)
	s.expect_equal(target.regions[0],_record(1).regions[0],"preceding target region stays exact")
	s.expect_equal(target.regions[2],_record(1).regions[2],"following target region stays exact")
	var shell: Dictionary = target.regions[1].duplicate(true)
	shell.erase("polygon")
	var expected_shell: Dictionary = _record(1).regions[1].duplicate(true)
	expected_shell.erase("box")
	s.expect_equal(shell,expected_shell,"existing ID preserves every non-geometric field")
	var appended: Dictionary = f.store.get_corrected_record(11875)
	s.expect_equal(appended.regions.slice(0,2),_record(2).regions,"new ID appends without reordering old regions")
	s.expect_equal(appended.regions[2].track_id,"T0","new ID inherits key metadata")
	s.expect(f.store.is_verified(11850) and f.store.is_verified(11875),"accepted targets are verified")
	for frame in [11850,11875]:
		s.expect_equal(after.review_state[str(frame)].accepted_digest,f.store.record_digest(frame),"review digest names installed candidate")
	var operation: Dictionary = after.batch_operations[0]
	s.expect_equal(operation.schema_version,3,"SAM uses v3")
	s.expect_equal(operation.mode,"merge","SAM audit records fixed region merge despite overwrite input")
	s.expect_equal(operation.affected_frames,[11850,11875],"audit targets exact prefix")
	s.expect_equal(operation.risk_summary,[{"frame_id":11850,"kinds":["sparse_input"]},{"frame_id":11875,"kinds":["sparse_input"]}],"raw sparse risks collapse to bounded categories")
	s.expect_equal(operation.model_version,"1.1.0","audit uses actual reported model version")
	for forbidden in ["score","mask","outputs/","expected_review_state","expected_batch_operations","badge","prompt","token"]:
		s.expect(not JSON.stringify(after.records).contains(forbidden) and not JSON.stringify(operation).contains(forbidden), "transient " + forbidden + " never persists")
	s.expect_equal(f.history.try_undo(f.store),PackedStringArray(),"one undo succeeds")
	var undone: Dictionary = f.store.freeze_snapshot()
	for field in ["records","review_state","batch_operations"]: s.expect_equal(undone[field],before[field],"undo restores exact " + field)
	s.expect_equal(undone.revision,after.revision+1,"Undo increments revision exactly once")
	s.expect_equal(f.history.redo(f.store),PackedStringArray(),"redo succeeds")
	var redone: Dictionary = f.store.freeze_snapshot()
	for field in ["records","review_state","batch_operations"]: s.expect_equal(redone[field],after[field],"redo restores exact " + field)
	s.expect_equal(redone.revision,undone.revision+1,"Redo increments revision exactly once")

func _test_generated_targets_include_unchanged() -> void:
	for mode in ["mixed", "all_unchanged"]:
		var f := _fixture()
		_make_targets_match_sam_candidate(f,[11850] if mode == "mixed" else [11850,11875])
		var preview := _prepare(f)
		s.expect_equal(preview.changed_count,1 if mode == "mixed" else 0,mode+" preview reports actual record changes")
		s.expect_equal(preview.target_count,2,mode+" preview retains every generated target")
		s.expect(f.controller.can_apply(),mode+" generated prefix remains confirmable")
		var before: Dictionary = f.store.freeze_snapshot()
		var replacement_signals := [0]
		var review_signals := [0]
		f.store.corrected_records_replaced.connect(func(_frames): replacement_signals[0] += 1)
		f.store.review_state_changed.connect(func(): review_signals[0] += 1)
		var result: PackedStringArray = f.controller.apply_preview()
		s.expect_equal(result,PackedStringArray(),mode+" generated prefix applies")
		if not result.is_empty(): continue
		var after: Dictionary = f.store.freeze_snapshot()
		s.expect_equal(after.revision,before.revision+1,mode+" Apply increments revision once")
		s.expect_equal([replacement_signals[0],review_signals[0]],[1,1],mode+" Apply emits each Store signal once")
		s.expect_equal(f.history.get_undo_count(),1,mode+" Apply creates one history command")
		var operation: Dictionary = after.batch_operations[0]
		s.expect_equal(operation.affected_frames,[11850,11875],mode+" audit names exact generated prefix")
		s.expect_equal(operation.generated_count,2,mode+" generated_count includes unchanged targets")
		for frame in [11850,11875]:
			s.expect_equal(after.review_state[str(frame)].accepted_digest,f.store.record_digest(frame),mode+" accepted digest covers generated target")
		for frame: int in ([11850] if mode == "mixed" else [11850,11875]):
			s.expect_equal(f.store.get_corrected_record(frame),before.records[1 if frame == 11850 else 2],mode+" byte-identical record remains exact")
		s.expect_equal(f.history.try_undo(f.store),PackedStringArray(),mode+" undo succeeds")
		var undone: Dictionary = f.store.freeze_snapshot()
		for field in ["records","review_state","batch_operations"]: s.expect_equal(undone[field],before[field],mode+" undo restores exact "+field)
		s.expect_equal(undone.revision,after.revision+1,mode+" Undo increments revision once")
		s.expect_equal([replacement_signals[0],review_signals[0]],[2,2],mode+" Undo emits each Store signal once")
		s.expect_equal(f.history.redo(f.store),PackedStringArray(),mode+" redo succeeds")
		var redone: Dictionary = f.store.freeze_snapshot()
		for field in ["records","review_state","batch_operations"]: s.expect_equal(redone[field],after[field],mode+" redo restores exact "+field)
		s.expect_equal(redone.revision,undone.revision+1,mode+" Redo increments revision once")
		s.expect_equal([replacement_signals[0],review_signals[0]],[3,3],mode+" Redo emits each Store signal once")
		var path := "/tmp/sam-v3-unchanged-%s-%d-%d/label/clip.json" % [mode,OS.get_process_id(),Time.get_ticks_usec()]
		var repository = load("res://client/workspace/session_repository.gd").new()
		var saved: Dictionary = repository.save_snapshot(redone,{"path":path,"expected_sha256":""})
		s.expect(saved.get("success",false),mode+" v3 saves "+str(saved.get("errors",[])))
		if not saved.get("success",false): continue
		var options := before.duplicate(true)
		options["path"] = path
		var opened: Dictionary = repository.open_session(options)
		s.expect(opened.get("success",false),mode+" v3 reopens "+str(opened.get("errors",[])))
		if not opened.get("success",false): continue
		s.expect_equal(opened.store.snapshot_batch_operations(),after.batch_operations,mode+" exact audit survives save/reopen")
		s.expect_equal(opened.store.snapshot_review_state(),after.review_state,mode+" accepted digests survive save/reopen")
		for frame in [11850,11875]: s.expect(opened.store.is_verified(frame),mode+" generated target remains verified after reopen")

func _test_conflicts() -> void:
	for phase in ["apply","undo","redo"]:
		for conflict in ["key","target","review","operations"]:
			var f := _fixture()
			var preview := _prepare(f)
			var command := _direct(f,preview)
			if phase != "apply":
				var applied: PackedStringArray = f.history.execute(command,f.store)
				s.expect_equal(applied,PackedStringArray(),"conflict setup applies")
				if not applied.is_empty(): continue
			if phase == "redo": s.expect_equal(f.history.try_undo(f.store),PackedStringArray(),"conflict setup undoes")
			if conflict in ["key","target"]:
				var frame := 11825 if conflict == "key" else 11850
				var edited: Dictionary = f.store.get_corrected_record(frame)
				edited.regions[0]["class"] = "changed"
				f.store.replace_corrected_record(frame,edited)
			elif conflict == "review": REVIEW.new([11900],true).apply(f.store)
			else:
				var operations: Array = f.store.snapshot_batch_operations()
				operations.append({"schema_version":1,"type":"range_propagate","mode":"merge","keyframe":11825,"start_frame":11850,"end_frame":11850,"affected_frames":[11850]})
				s.expect_equal(f.store.load_workflow_state(f.store.snapshot_review_state(),operations),PackedStringArray(),"valid unrelated history change")
			var frozen: Dictionary = f.store.freeze_snapshot()
			var undo_count: int = f.history.get_undo_count()
			var redo_count: int = f.history.get_redo_count()
			var result: PackedStringArray
			if phase == "apply": result = f.history.execute(command,f.store)
			elif phase == "undo": result = f.history.try_undo(f.store)
			else: result = f.history.redo(f.store)
			s.expect(not result.is_empty(),phase+" rejects "+conflict+" conflict")
			s.expect_equal(f.store.freeze_snapshot(),frozen,phase+" conflict preserves entire Store")
			s.expect_equal([f.history.get_undo_count(),f.history.get_redo_count()],[undo_count,redo_count],"refusal preserves history stacks")

func _test_command_scope() -> void:
	for fault in ["other_region","target_metadata","new_metadata","reorder","score","extra_audit","missing_schema","missing_review","missing_operations","affected_mismatch","digest"]:
		var f := _fixture()
		var preview := _prepare(f)
		var metadata := _metadata(f)
		if fault == "other_region": preview.after[11850].regions[0]["class"] = "changed"
		elif fault == "target_metadata": preview.after[11850].regions[1].conf = 0.9
		elif fault == "new_metadata": preview.after[11875].regions[2].track_id = "wrong"
		elif fault == "reorder": preview.after[11850].regions.reverse()
		elif fault == "score": preview.after[11850].regions[1]["score"] = 0.9
		elif fault == "extra_audit": metadata["prompt"] = "secret"
		elif fault == "missing_schema": metadata.erase("schema_version")
		elif fault == "missing_review": metadata.erase("expected_review_state")
		elif fault == "missing_operations": metadata.erase("expected_batch_operations")
		elif fault == "affected_mismatch": metadata.affected_frames = [11850,11900]
		elif fault == "digest": metadata.keyframe_digest = "f".repeat(64)
		var frozen: Dictionary = f.store.freeze_snapshot()
		s.expect(not f.history.execute(_direct(f,preview,metadata),f.store).is_empty(),"command rejects " + fault)
		s.expect_equal(f.store.freeze_snapshot(),frozen,"scope rejection is atomic " + fault)

func _test_prefix_and_runtime() -> void:
	for count in [1,30]:
		var f := _fixture(count+1)
		_prepare(f,count)
		s.expect_equal(f.controller.apply_preview(),PackedStringArray(),"bounded endpoint count applies %d" % count)
		s.expect_equal(f.store.snapshot_batch_operations()[0].generated_count,count,"all requested endpoint targets accepted")
	for mode in ["model_topology","verified_target","source_end","shortened"]:
		var f := _fixture(3 if mode == "source_end" else 4)
		if mode == "model_topology": f.inference.stop_at = 1
		if mode == "verified_target": REVIEW.new([11875],true).apply(f.store)
		_prepare(f,3,1 if mode == "shortened" else -1)
		var result: PackedStringArray = f.controller.apply_preview()
		s.expect_equal(result,PackedStringArray(),"truncated prefix applies " + mode)
		if not result.is_empty(): continue
		var operation: Dictionary = f.store.snapshot_batch_operations()[0]
		s.expect_equal(operation.generated_count,2 if mode == "source_end" else 1,"generated_count equals changed accepted prefix")
		s.expect_equal(operation.requested_count,3,"request retained through stop")
		s.expect_equal(operation.stop_frame,null if mode == "source_end" else 11875,"stop is first excluded Source frame")
		s.expect_equal(operation.stop_reason,"user_range" if mode == "shortened" else mode,"stop persists only stable reason code")
		s.expect(not f.store.is_verified(11825),"unverified key never auto-verifies")
	for pair in [["device","auto"],["checkpoint_sha256",null],["model_version",null],["model_version","/private/model"],["elapsed_ms",-1]]:
		var f := _fixture()
		f.inference.runtime_override[pair[0]] = pair[1]
		_prepare(f)
		# elapsed is Controller-owned; corrupt the completed plan to exercise final ingress validation.
		if pair[0] == "elapsed_ms": f.controller._plan.runtime.elapsed_ms = -1
		var frozen: Dictionary = f.store.freeze_snapshot()
		s.expect(not f.controller.apply_preview().is_empty(),"invalid runtime refuses Apply " + str(pair))
		s.expect_equal(f.store.freeze_snapshot(),frozen,"invalid runtime is atomic")

func _test_missing_anchor() -> void:
	var f := _fixture()
	var preview := _prepare(f,1)
	var key: Dictionary = f.store.get_corrected_record(11825)
	key.regions.remove_at(1)
	s.expect_equal(f.store.replace_corrected_record(11825,key),PackedStringArray(),"key fixture can omit selected region")
	var metadata := _metadata(f)
	metadata.merge({"requested_count":1,"generated_count":1,"end_frame":11850,"affected_frames":[11850],"target_playback_indices":[1]},true)
	var frozen: Dictionary = f.store.freeze_snapshot()
	s.expect(not f.history.execute(_direct(f,preview,metadata),f.store).is_empty(),"command refuses a region absent from the actual keyframe")
	s.expect_equal(f.store.freeze_snapshot(),frozen,"missing anchor refuses without mutation")

func _test_roundtrip() -> void:
	var f := _fixture()
	var records := [_record(0),_record(1),_record(2),_record(3)]
	var path := "/tmp/sam-v3-roundtrip-%d-%d/label/clip.json" % [OS.get_process_id(),Time.get_ticks_usec()]
	var options := {"path":path,"media_id":"clip","media_type":"image_sequence","source":"test","source_relative_path":"clip",
		"source_sha256":null,"round_id":"initial","model_revision":"fixture","taxonomy_version":"v1","baseline_kind":"model",
		"seed_records":records,"frame_entries":f.source.entries}
	var repository = load("res://client/workspace/session_repository.gd").new()
	var opened: Dictionary = repository.open_session(options)
	s.expect(opened.get("success",false),"SAM persistence session opens")
	if not opened.get("success",false): return
	f.store = opened.store
	f.controller.configure(f.source,f.store,f.history,f.source.entries)
	_prepare(f)
	var errors: PackedStringArray = f.controller.apply_preview()
	s.expect_equal(errors,PackedStringArray(),"SAM persistence batch applies")
	if not errors.is_empty(): return
	var snapshot: Dictionary = f.store.freeze_snapshot()
	var saved: Dictionary = repository.save_snapshot(snapshot,{"path":path,"expected_sha256":opened.disk_sha256})
	s.expect(saved.get("success",false),"SAM v3 saves " + str(saved.get("errors",[])))
	if not saved.get("success",false): return
	opened = repository.open_session(options)
	s.expect(opened.get("success",false),"SAM v3 reopens " + str(opened.get("errors",[])))
	if not opened.get("success",false): return
	s.expect_equal(opened.store.snapshot_batch_operations(),snapshot.batch_operations,"v3 marker survives exact save/reopen")
	s.expect_equal(opened.store.snapshot_review_state(),snapshot.review_state,"accepted digests survive save/reopen")
	s.expect(opened.store.is_verified(11850) and opened.store.is_verified(11875),"reopened targets remain verified")

func _test_source_playback_order() -> void:
	for prefix in [1,3]:
		var f := _fixture(4,[90,12,77,5])
		if prefix == 1: f.inference.stop_at = 1
		_prepare(f,3)
		var before: Dictionary = f.store.freeze_snapshot()
		var result: PackedStringArray = f.controller.apply_preview()
		s.expect_equal(result,PackedStringArray(),"nonmonotonic Source playback applies prefix %d" % prefix)
		if not result.is_empty(): continue
		var after: Dictionary = f.store.freeze_snapshot()
		var marker: Dictionary = after.batch_operations[0]
		s.expect_equal(marker.affected_frames,[12] if prefix == 1 else [12,77,5],"audit preserves playback target IDs rather than numeric sorting")
		s.expect_equal(marker.target_playback_indices,[1] if prefix == 1 else [1,2,3],"audit records exact playback indices")
		s.expect_equal(marker.keyframe,90,"key remains real Source anchor")
		s.expect_equal(marker.end_frame,12 if prefix == 1 else 5,"end_frame follows playback rather than numeric maximum")
		s.expect_equal(marker.stop_frame,77 if prefix == 1 else null,"stop follows first excluded playback entry")
		s.expect(not f.store.is_verified(90) and f.store.is_verified(12),"key excluded and changed prefix verified")
		s.expect_equal(f.history.try_undo(f.store),PackedStringArray(),"nonmonotonic undo succeeds")
		for field in ["records","review_state","batch_operations"]: s.expect_equal(f.store.freeze_snapshot()[field],before[field],"nonmonotonic undo restores " + field)
		s.expect_equal(f.history.redo(f.store),PackedStringArray(),"nonmonotonic redo succeeds")
		s.expect_equal(f.store.snapshot_batch_operations(),after.batch_operations,"redo preserves exact ordered marker")
		var path := "/tmp/sam-v3-playback-%d-%d/label/clip.json" % [OS.get_process_id(),Time.get_ticks_usec()]
		var repository = load("res://client/workspace/session_repository.gd").new()
		var saved: Dictionary = repository.save_snapshot(f.store.freeze_snapshot(),{"path":path,"expected_sha256":""})
		s.expect(saved.get("success",false),"nonmonotonic v3 saves " + str(saved.get("errors",[])))
		if not saved.get("success",false): continue
		var options := before.duplicate(true)
		options["path"] = path
		var opened: Dictionary = repository.open_session(options)
		s.expect(opened.get("success",false),"nonmonotonic v3 reopens " + str(opened.get("errors",[])))
		if not opened.get("success",false): continue
		s.expect_equal(opened.store.snapshot_batch_operations(),after.batch_operations,"save/reopen preserves exact playback marker")
		s.expect_equal(opened.store.snapshot_review_state(),after.review_state,"save/reopen preserves accepted playback digests")
		var reopened_entries: Array = opened.store.freeze_snapshot().frame_entries
		s.expect_equal(reopened_entries.size(),4,"reopened Source retains all playback entries")
		for index in range(reopened_entries.size()):
			s.expect_equal(reopened_entries[index].frame,index,"reopened playback index remains exact")
			s.expect_equal(reopened_entries[index].frame_id,[90,12,77,5][index],"reopened original frame remains in actual playback order")
			s.expect_equal(reopened_entries[index].time_s,before.frame_entries[index].time_s,"reopened playback timestamp remains exact")
		var wrong := marker.duplicate(true)
		wrong.keyframe = 5
		wrong.keyframe_digest = f.store.record_digest(5)
		wrong.start_frame = 5
		wrong.end_frame = 90
		wrong.affected_frames = [12,77,90]
		wrong.generated_count = 3
		wrong.target_playback_indices = [1,2,3]
		wrong.stop_frame = null
		wrong.stop_reason = ""
		wrong.risk_summary = []
		var frozen: Dictionary = opened.store.freeze_snapshot()
		s.expect(not opened.store.load_workflow_state(after.review_state,[wrong]).is_empty(),"numeric-order forgery is rejected against real session entries")
		s.expect_equal(opened.store.freeze_snapshot(),frozen,"wrong playback marker rejection is atomic")
