extends SceneTree
const REPO = preload("res://client/workspace/session_repository.gd")
const PACKAGE = preload("res://client/feedback/training_package.gd")
const REVIEW = preload("res://client/domain/commands/review_frames_command.gd")
const CODEC = preload("res://client/workspace/review_session_codec.gd")
var failures = []
func check(value, message):
	if not value: failures.append(message)
func _initialize():
	var script = load("res://client/workspace/model_round_controller.gd")
	check(script != null, "ModelRoundController is available")
	if script != null: run_cases(script)
	print(JSON.stringify({"success":failures.is_empty(),"errors":failures}))
	quit(0 if failures.is_empty() else 1)
func run_cases(rounds):
	var base = "/tmp/part4-round-test-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(base)
	var entries = [{"frame":0,"frame_id":4,"time_s":0.0},{"frame":1,"frame_id":9,"time_s":0.5}]
	var records = [{"schema_version":1,"source":"demo","frame":4,"regions":[]},{"schema_version":1,"source":"demo","frame":9,"time_s":0.5,"regions":[]}]
	var repo = REPO.new()
	var opened = repo.open_session({"path":base.path_join("label.json"),"media_id":"demo","media_type":"image_sequence","source":"demo","source_relative_path":"images","source_sha256":null,"frame_entries":entries,"seed_records":records,"baseline_kind":"model","round_id":"round1","model_revision":"m1","taxonomy_version":"t1"})
	check(opened.success, "initial session opens")
	if not opened.success: return
	check(REVIEW.new([4],true).apply(opened.store).is_empty(), "real review command")
	var snapshot = opened.store.freeze_snapshot()
	var saved = repo.save_snapshot(snapshot,{"path":opened.path,"expected_sha256":""})
	check(saved.success, "initial save")
	var parent = PACKAGE.export_package(snapshot,{"kind":"training_update_v2","output_parent":base})
	check(parent.success, "parent training package")
	var context = {"snapshot":snapshot,"save_options":{"path":opened.path,"expected_sha256":saved.get("sha256","")},"parent_package_path":parent.output_path}
	var annotation = base.path_join("model_output_v1.jsonl")
	PACKAGE.write_text(annotation,PACKAGE.jsonl(records))
	var manifest = {"schema_version":1,"package_type":"model_round_v1","annotation_schema_version":1,"round_id":"round2","model_revision":"m2","parent_package_id":parent.package_id,"taxonomy_version":"t1","media":{"media_id":"demo","media_type":"image_sequence","source":"demo","source_relative_path":"images","source_sha256":null},"source_frame_entries":entries,"annotations":{"path":"model_output_v1.jsonl","bytes":FileAccess.get_file_as_bytes(annotation).size(),"sha256":FileAccess.get_sha256(annotation)}}
	var input = base.path_join("round.json")
	PACKAGE.write_text(input,JSON.stringify(manifest))
	var prepared = rounds.prepare_round(context,input)
	check(prepared.success, "valid round prepares: %s" % str(prepared.get("errors")))
	if not prepared.success: return
	check(FileAccess.get_sha256(opened.path) == saved.sha256, "prepare leaves active bytes")
	for field in ["round_id","parent_package_id","taxonomy_version"]:
		var bad = manifest.duplicate(true)
		bad[field] = "round1" if field == "round_id" else "wrong"
		PACKAGE.write_text(input,JSON.stringify(bad))
		check(not rounds.prepare_round(context,input).success, "reject wrong " + field)
	PACKAGE.write_text(input,JSON.stringify(manifest))
	var wrong_media = manifest.duplicate(true)
	wrong_media.media.media_id = "other"
	PACKAGE.write_text(input,JSON.stringify(wrong_media))
	check(not rounds.prepare_round(context,input).success,"reject wrong media")
	var wrong_map = manifest.duplicate(true)
	wrong_map.source_frame_entries[1].frame_id = 10
	PACKAGE.write_text(input,JSON.stringify(wrong_map))
	check(not rounds.prepare_round(context,input).success,"reject wrong source frame map")
	PACKAGE.write_text(input,JSON.stringify(manifest))
	var bad_context = context.duplicate(true)
	bad_context.parent_package_path = base
	check(not rounds.prepare_round(bad_context,input).success,"reject invalid parent directory")
	for mutation in ["coverage","source","time","duplicate"]:
		var bad = records.duplicate(true)
		match mutation:
			"coverage": bad.pop_back()
			"source": bad[0].source = "other"
			"time": bad[0]["time_s"] = 123.0
			"duplicate": bad[1] = bad[0]
		PACKAGE.write_text(annotation,PACKAGE.jsonl(bad))
		var bad_manifest = manifest.duplicate(true)
		bad_manifest.annotations.bytes = FileAccess.get_file_as_bytes(annotation).size()
		bad_manifest.annotations.sha256 = FileAccess.get_sha256(annotation)
		PACKAGE.write_text(input,JSON.stringify(bad_manifest))
		check(not rounds.prepare_round(context,input).success,"reject " + mutation)
	PACKAGE.write_text(annotation,PACKAGE.jsonl(records))
	PACKAGE.write_text(input,JSON.stringify(manifest))
	PACKAGE.write_text(annotation,PACKAGE.jsonl(records) + "\n")
	check(not rounds.commit_round(context,prepared).success,"changed candidate rejects commit")
	check(FileAccess.get_sha256(opened.path) == saved.sha256,"failed commit preserves bytes")
	PACKAGE.write_text(annotation,PACKAGE.jsonl(records))
	var rounds_dir = opened.path.get_base_dir().path_join("rounds")
	PACKAGE.write_text(rounds_dir,"blocked")
	check(not rounds.commit_round(context,prepared).success,"archive failure rejects commit")
	check(FileAccess.get_sha256(opened.path) == saved.sha256,"archive failure preserves bytes")
	DirAccess.remove_absolute(rounds_dir)
	DirAccess.make_dir_absolute(rounds_dir)
	OS.execute("chmod",["0555",base])
	var publication_failure = rounds.commit_round(context,prepared)
	OS.execute("chmod",["0755",base])
	check(not publication_failure.success,"publication failure rejects commit")
	check(FileAccess.get_sha256(opened.path) == saved.sha256,"publication failure preserves bytes")
	var result = rounds.commit_round(context,prepared)
	check(result.success,"round committed: %s" % str(result.get("errors")))
	if result.success:
		check(result.snapshot.round_id == "round2" and result.snapshot.revision == 0,"new round revision reset")
		check(result.snapshot.review_state.is_empty() and result.snapshot.batch_operations.is_empty(),"workflow reset")
		check(result.snapshot.session_id != snapshot.session_id,"new session identity")
		check(FileAccess.get_sha256(result.archive_path) == saved.sha256,"archive exact prior bytes")
		check(not result.snapshot.baseline_records[0].has("time_s"),"preserves omitted raw time")
		check(not rounds.commit_round(context,prepared).success,"stale commit rejected")
	# Unknown binding retains corrected content and review digest.
	var unknown = snapshot.duplicate(true)
	unknown.baseline_kind = "unknown"
	unknown.baseline_records = []
	unknown.baseline_digest = null
	unknown.session_id = "legacy-session"
	unknown.explicit_frames = [4,9]
	var unknown_path = base.path_join("unknown.json")
	var unknown_saved = repo.save_snapshot(unknown,{"path":unknown_path,"expected_sha256":""})
	check(unknown_saved.success,"unknown saved")
	var binding_context = {"snapshot":unknown,"save_options":{"path":unknown_path,"expected_sha256":unknown_saved.get("sha256","")}}
	var binding = rounds.prepare_baseline_binding(binding_context,annotation)
	check(binding.success,"binding prepared: %s" % str(binding.get("errors")))
	if binding.success:
		var bound = rounds.commit_baseline_binding(binding_context,binding)
		check(bound.success,"binding committed")
		if bound.success:
			check(bound.snapshot.revision == unknown.revision + 1,"binding bumps revision")
			check(PACKAGE.DIFF.equivalent(bound.snapshot.records,unknown.records),"binding preserves corrections")
			check(PACKAGE.DIFF.equivalent(bound.snapshot.review_state,unknown.review_state),"binding preserves reviews")
	check(not rounds.prepare_baseline_binding(context,annotation).success,"known baseline cannot rebind")
	var mismatch = unknown.duplicate(true)
	mismatch.records[0]["time_s"] = 0.0
	var mismatch_path = base.path_join("mismatch.json")
	var mismatch_saved = repo.save_snapshot(mismatch,{"path":mismatch_path,"expected_sha256":""})
	check(mismatch_saved.success,"unknown optional time setup")
	var mismatch_context = {"snapshot":mismatch,"save_options":{"path":mismatch_path,"expected_sha256":mismatch_saved.get("sha256","")}}
	check(not rounds.prepare_baseline_binding(mismatch_context,annotation).success,"binding rejects optional time presence mismatch")
	# Trusted Source descriptors use the same correction/identity gates and a
	# two-phase re-read before automatic baseline binding is persisted.
	var source_label_directory = base.path_join("labels")
	DirAccess.make_dir_recursive_absolute(source_label_directory)
	var source_label_path = source_label_directory.path_join("demo.json")
	var source_label = {"fps":25.0,"categories":{"instrument":{"0":"grasper"}},"annotations":{"4":[[0,0,0,0.1,0.1,0.2,0.2,0]],"9":[[1,0,0,0.5,0.5,0.2,0.2,0]]}}
	var source_label_text = JSON.stringify(source_label)
	PACKAGE.write_text(source_label_path,source_label_text)
	var descriptor = {"kind":"cholect50","path":source_label_path,"root":base,"media_id":"demo","image_size":[100.0,100.0]}
	var auto_unknown = unknown.duplicate(true)
	auto_unknown.session_id = "automatic-legacy-session"
	auto_unknown.explicit_frames = [4]
	auto_unknown.review_state = {}
	auto_unknown.records[0]["time_s"] = 0.0
	auto_unknown.records[0].regions = [{"id":"human-4","class":"corrected","kind":"instrument","box":[1.0,2.0,3.0,4.0]}]
	var auto_path = base.path_join("automatic-unknown.json")
	var auto_saved = repo.save_snapshot(auto_unknown,{"path":auto_path,"expected_sha256":""})
	check(auto_saved.success,"automatic unknown baseline fixture saved")
	var auto_context = {"snapshot":auto_unknown,"save_options":{"path":auto_path,"expected_sha256":auto_saved.get("sha256","")}}
	var automatic = rounds.prepare_auto_baseline_binding(auto_context,descriptor)
	check(automatic.success,"automatic binding prepared: %s" % str(automatic.get("errors")))
	if automatic.success:
		check(automatic.snapshot.baseline_kind == "imported_labels","trusted Cholec baseline retains imported-label identity")
		check(automatic.snapshot.baseline_records.size() == entries.size(),"automatic baseline has complete Source coverage")
		check(automatic.snapshot.records[0].regions[0].class == "corrected","automatic binding preserves explicit human correction")
		check(automatic.snapshot.records[1].regions.size() == 1,"implicit legacy empty is replaced by original baseline evidence")
		check(automatic.source_sha256 == FileAccess.get_sha256(source_label_path),"prepared binding freezes original source hash")
		var resized_descriptor = descriptor.duplicate(true)
		resized_descriptor.image_size = [200.0,100.0]
		check(not rounds.commit_auto_baseline_binding(auto_context,automatic,resized_descriptor).success,"candidate digest change rejects automatic commit")
		check(FileAccess.get_sha256(auto_path) == auto_saved.sha256,"candidate rejection preserves active session bytes")
		PACKAGE.write_text(source_label_path,source_label_text + "\n")
		check(not rounds.commit_auto_baseline_binding(auto_context,automatic,descriptor).success,"original label byte change rejects automatic commit")
		check(FileAccess.get_sha256(auto_path) == auto_saved.sha256,"source hash rejection preserves active session bytes")
		PACKAGE.write_text(source_label_path,source_label_text)
		var stable_automatic = rounds.prepare_auto_baseline_binding(auto_context,descriptor)
		check(stable_automatic.success,"stable automatic binding prepares again")
		if stable_automatic.success:
			var auto_bound = rounds.commit_auto_baseline_binding(auto_context,stable_automatic,descriptor)
			check(auto_bound.success,"stable automatic binding commits: %s" % str(auto_bound.get("errors")))
			if auto_bound.success:
				check(auto_bound.snapshot.revision == auto_unknown.revision + 1,"automatic binding bumps revision once")
				check(auto_bound.snapshot.records[0].regions[0].class == "corrected","committed automatic baseline preserves human correction")
	# An unoccupied archive filename that is a dangling symlink is still a conflict.
	var link_context = context.duplicate(true)
	link_context.save_options.path = base.path_join("link-active.json")
	PACKAGE.write_text(link_context.save_options.path,FileAccess.get_file_as_string(result.archive_path))
	var link_prepared = rounds.prepare_round(link_context,input)
	check(link_prepared.success,"symlink archive test prepare")
	var archive_path = result.archive_path
	var archive_backup = archive_path + ".test-preserved"
	DirAccess.rename_absolute(archive_path,archive_backup)
	OS.execute("ln",["-s",base.path_join("absent"),archive_path])
	check(not rounds.commit_round(link_context,link_prepared).success,"dangling archive symlink refuses overwrite")
	DirAccess.remove_absolute(archive_path)
	DirAccess.rename_absolute(archive_backup,archive_path)
