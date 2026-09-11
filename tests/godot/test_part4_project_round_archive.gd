extends SceneTree
const REPO = preload("res://client/workspace/session_repository.gd")
const PACKAGE = preload("res://client/feedback/training_package.gd")
const ROUNDS = preload("res://client/workspace/model_round_controller.gd")
func _init():
	var external = OS.get_cmdline_user_args()[0]
	var label_root = ProjectSettings.globalize_path("res://Dataset_test/label")
	DirAccess.make_dir_recursive_absolute(label_root)
	var path = label_root.path_join("clip.json")
	var records = [{"schema_version":1,"source":"cam","frame":12,"regions":[]}]
	var entries = [{"frame":0,"frame_id":12}]
	var repo = REPO.new()
	var opened = repo.open_session({"path":path,"media_id":"clip","media_type":"image_sequence","source":"cam","source_relative_path":"images","source_sha256":null,"frame_entries":entries,"seed_records":records,"baseline_kind":"model","round_id":"round1","model_revision":"m1","taxonomy_version":"t1"})
	if not opened.success: fail(opened); return
	opened.store.load_workflow_state({"12":{"accepted_digest":opened.store.record_digest(12)}},[])
	var snapshot = opened.store.freeze_snapshot()
	var saved = repo.save_snapshot(snapshot,{"path":path,"expected_sha256":""})
	if not saved.success: fail(saved); return
	var parent = PACKAGE.export_package(snapshot,{"output_parent":external,"kind":"training_update_v2"})
	if not parent.success: fail(parent); return
	var annotation = external.path_join("model_output_v1.jsonl")
	PACKAGE.write_text(annotation,PACKAGE.jsonl(records))
	var manifest = {"schema_version":1,"package_type":"model_round_v1","annotation_schema_version":1,"round_id":"round2","model_revision":"m2","parent_package_id":parent.package_id,"taxonomy_version":"t1","media":{"media_id":"clip","media_type":"image_sequence","source":"cam","source_relative_path":"images","source_sha256":null},"source_frame_entries":entries,"annotations":{"path":"model_output_v1.jsonl","bytes":FileAccess.get_file_as_bytes(annotation).size(),"sha256":FileAccess.get_sha256(annotation)}}
	var input = external.path_join("round.json")
	PACKAGE.write_text(input,JSON.stringify(manifest,"",true,true))
	var context = {"snapshot":snapshot,"save_options":{"path":path,"expected_sha256":saved.sha256},"parent_package_path":parent.output_path}
	var prepared = ROUNDS.prepare_round(context,input)
	if not prepared.success: fail(prepared); return
	var committed = ROUNDS.commit_round(context,prepared)
	if not committed.success: fail(committed); return
	if FileAccess.get_sha256(committed.archive_path) != saved.sha256 or committed.snapshot.round_id != "round2" or not committed.snapshot.review_state.is_empty(): fail({"errors":["round archive/reset mismatch"]}); return
	for ancestor in ["res://","res://Dataset_test","res://Dataset_test/label","res://Dataset_test/label/rounds"]:
		if FileAccess.file_exists(ancestor.path_join(".gdignore")): fail({"errors":["JSON archive silently marked an asset directory"]}); return
	var bad_parent = label_root.path_join("report_export")
	if PACKAGE.export_package(snapshot,{"output_parent":bad_parent}).success or DirAccess.dir_exists_absolute(bad_parent): fail({"errors":["CSV package guard bypassed"]}); return
	var demo_parent = label_root.path_join("cli_demo")
	var demo = preload("res://client/cli/part4_worker.gd").new().create_demo({"output":demo_parent},null)
	if demo.success or DirAccess.dir_exists_absolute(demo_parent): fail({"errors":["CLI demo did not reject imported asset output before source generation"]}); return
	print("PASS: in-project JSON round archive preserves exact old bytes and package CSV guard remains enforced")
	quit()
func fail(result):
	printerr(result)
	quit(1)
