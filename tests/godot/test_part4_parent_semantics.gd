extends SceneTree
const PACKAGE = preload("res://client/feedback/training_package.gd")
const EXACT = preload("res://client/domain/exact_json.gd")
const REPO = preload("res://client/workspace/session_repository.gd")
const REVIEW = preload("res://client/domain/commands/review_frames_command.gd")
const MOVE = preload("res://client/domain/commands/move_region_command.gd")
const ROUNDS = preload("res://client/workspace/model_round_controller.gd")
var failures = []
var paths = []
func check(ok,message):
	if not ok: failures.append(message)
func _initialize():
	var base = "/tmp/part4-parent-semantics-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(base)
	var repo = REPO.new()
	var records = [{"schema_version":1,"source":"demo","frame":12,"regions":[{"id":"r1","class":"grasper,\n工具\"","kind":"instrument","box":[1,2,3,4]}]},{"schema_version":1,"source":"demo","frame":90,"regions":[]}]
	var entries = [{"frame":0,"frame_id":12},{"frame":1,"frame_id":90}]
	var opened = repo.open_session({"path":base.path_join("active.json"),"media_id":"demo","media_type":"video","source":"demo","source_relative_path":"demo.mp4","source_sha256":null,"frame_entries":entries,"seed_records":records,"baseline_kind":"model","round_id":"round1","model_revision":"m1","taxonomy_version":"t1"})
	check(opened.success,"setup")
	if not opened.success: finish(); return
	MOVE.new(12,opened.store.get_corrected_record(12),"r1",Vector2(1,0)).apply(opened.store)
	REVIEW.new([12,90],true).apply(opened.store)
	var snapshot = opened.store.freeze_snapshot()
	var saved = repo.save_snapshot(snapshot,{"path":opened.path,"expected_sha256":""})
	check(saved.success,"save")
	for mutation in ["valid","accepted_digest","record_source","record_content","frame_map","diff_counts","diff_after","diff_omitted_category","csv","class_csv","coverage","review_explicit","policy","schema","baseline"]:
		var exported = PACKAGE.export_package(snapshot,{"kind":"training_update_v2","output_parent":base.path_join(mutation)})
		check(exported.success,"export " + mutation + ": " + str(exported.get("errors")))
		if not exported.success: continue
		check(exported.get("timings_ms",{}).keys().size() == 5,"separate export timings")
		for key in exported.get("timings_ms",{}): check(exported.timings_ms[key] >= 0,"monotonic timing " + key)
		var directory = exported.output_path
		var m = EXACT.parse_string(FileAccess.get_file_as_string(directory.path_join("manifest.json")))
		check(m.coverage.get("policy") == "verified_only","explicit training policy")
		var rs = read_lines(directory.path_join(PACKAGE.PATHS[0]))
		var maps = read_lines(directory.path_join(PACKAGE.PATHS[1]))
		var diff = EXACT.parse_string(FileAccess.get_file_as_string(directory.path_join(PACKAGE.PATHS[2])))
		match mutation:
			"accepted_digest": m.review_state["12"].accepted_digest = "a".repeat(64)
			"record_source": rs[0].source = "other"
			"record_content": rs[0].regions[0].box[0] = 20
			"frame_map": maps[0].annotation_status = "negative"
			"diff_counts": diff.summary.geometry_changed = 2
			"diff_after": diff.frames[0].events[0].after.box[0] = 99
			"diff_omitted_category": diff.frames[0].events[0].before["class"] = "other"
			"coverage": m.coverage.verified_frame_ids = [12]
			"review_explicit": m.coverage.explicit_frame_ids = [12]
			"policy": m.coverage["policy"] = "all_frames_review"
			"schema": m.schema_version = 1
			"baseline": m.baseline.digest = null
		PACKAGE.write_text(directory.path_join(PACKAGE.PATHS[0]),PACKAGE.jsonl(rs))
		PACKAGE.write_text(directory.path_join(PACKAGE.PATHS[1]),PACKAGE.jsonl(maps))
		PACKAGE.write_text(directory.path_join(PACKAGE.PATHS[2]),JSON.stringify(diff,"",true,true)+"\n")
		if mutation == "csv": PACKAGE.write_text(directory.path_join(PACKAGE.PATHS[3]),"frame_id,region_id,type,before,after\n")
		if mutation == "class_csv": PACKAGE.write_text(directory.path_join(PACKAGE.PATHS[4]),"class,added,deleted,reclassified_in,reclassified_out,geometry_changed,attributes_changed\n")
		for artifact in m.artifacts:
			artifact.bytes = FileAccess.get_file_as_bytes(directory.path_join(artifact.path)).size()
			artifact.sha256 = FileAccess.get_sha256(directory.path_join(artifact.path))
		m.package_id = PACKAGE.package_identity(m)
		PACKAGE.write_text(directory.path_join("manifest.json"),JSON.stringify(m,"",true,true)+"\n")
		var errors = PACKAGE.validate_package(directory)
		check(errors.is_empty() if mutation == "valid" else not errors.is_empty(),"semantic " + mutation + ": " + str(errors))
		paths.append({"case":mutation,"path":directory})
		if mutation == "accepted_digest":
			var annotation = base.path_join("model_output_v1.jsonl")
			PACKAGE.write_text(annotation,PACKAGE.jsonl(records))
			var manifest = {"schema_version":1,"package_type":"model_round_v1","annotation_schema_version":1,"round_id":"round2","model_revision":"m2","parent_package_id":m.package_id,"taxonomy_version":"t1","media":m.media,"source_frame_entries":entries,"annotations":{"path":"model_output_v1.jsonl","bytes":FileAccess.get_file_as_bytes(annotation).size(),"sha256":FileAccess.get_sha256(annotation)}}
			var input = base.path_join("returned.json")
			PACKAGE.write_text(input,JSON.stringify(manifest,"",true,true))
			check(not ROUNDS.prepare_round({"snapshot":snapshot,"save_options":{"path":opened.path,"expected_sha256":saved.sha256},"parent_package_path":directory},input).success,"shared UI backend rejects invalid parent")
	# Legacy binding must not convert implicit placeholders into negative evidence.
	var unknown = repo.open_session({"path":base.path_join("unknown.json"),"media_id":"demo","media_type":"video","source":"demo","source_relative_path":"demo.mp4","source_sha256":null,"frame_entries":entries,"seed_records":[records[0]],"baseline_kind":"unknown","round_id":"round1","model_revision":"unknown","taxonomy_version":"t1"})
	REVIEW.new([12],true).apply(unknown.store)
	var before = unknown.store.freeze_snapshot()
	var persisted = repo.save_snapshot(before,{"path":unknown.path,"expected_sha256":""})
	var original = records.duplicate(true)
	original[1].regions = [{"id":"r90","class":"grasper","kind":"instrument","box":[1,2,3,4]}]
	var input_path = base.path_join("original.jsonl")
	PACKAGE.write_text(input_path,PACKAGE.jsonl(original))
	var bound = ROUNDS.prepare_baseline_binding({"snapshot":before,"save_options":{"path":unknown.path,"expected_sha256":persisted.sha256}},input_path)
	check(bound.success,"binding prepares")
	if bound.success:
		check(bound.snapshot.explicit_frames == [12],"binding preserves explicit frame set")
		check(bound.snapshot.records[1].regions.size() == 1,"implicit frame initializes from raw model")
		check(PACKAGE.DIFF.build_diff(bound.snapshot,[90]).summary.deleted == 0,"no invented implicit deletion")
		check(PACKAGE.DIFF.equivalent(bound.snapshot.review_state,before.review_state),"binding keeps explicit review digest")
		var review = PACKAGE.export_package(bound.snapshot,{"kind":"review_export_v1","output_parent":base.path_join("bound-review")})
		check(review.success,"bound review export")
		if review.success:
			var mapping = read_lines(review.output_path.path_join(PACKAGE.PATHS[1]))
			check(mapping[1].annotation_status == "unannotated" and not mapping[1].explicit,"implicit bound frame remains unannotated")
	PACKAGE.write_text("/tmp/part4-parent-semantics-paths.json",JSON.stringify(paths))
	finish()
func read_lines(path):
	var result = []
	for line in FileAccess.get_file_as_string(path).strip_edges().split("\n"): result.append(EXACT.parse_string(line))
	return result
func finish():
	print(JSON.stringify({"success":failures.is_empty(),"errors":failures}))
	quit(0 if failures.is_empty() else 1)
