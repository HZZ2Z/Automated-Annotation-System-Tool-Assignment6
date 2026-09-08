extends RefCounted
## Production CLI worker shared with the GUI business services.
const REPO = preload("res://client/workspace/session_repository.gd")
const CODEC = preload("res://client/workspace/review_session_codec.gd")
const DOCUMENT = preload("res://client/workspace/atomic_document.gd")
const PACKAGE = preload("res://client/feedback/training_package.gd")
const ROUNDS = preload("res://client/workspace/model_round_controller.gd")

func execute(options: Dictionary, token) -> Dictionary:
	var opened = open_v3(String(options.get("session","")),token)
	if not opened.success: return opened
	if options.command == "export":
		return PACKAGE.export_package(opened.snapshot,{"kind":options.kind,"output_parent":options.output},token)
	if options.command == "import-round":
		var context = {"snapshot":opened.snapshot,"save_options":{"path":opened.path,"expected_sha256":opened.disk_sha256},"parent_package_path":options.parent_package}
		var result = ROUNDS.import_round(context,options.input,token)
		if result.success:
			result.erase("store")
			result.erase("snapshot")
		return result
	return failure("Unsupported worker command")

func open_v3(path: String, token) -> Dictionary:
	var read = DOCUMENT.new().read_document(path)
	if not read.success: return read
	var decoded = CODEC.new().decode(read.payload)
	if not decoded.errors.is_empty(): return failure("Expected saved V3 session: " + "; ".join(decoded.errors))
	var options = decoded.snapshot.duplicate(true)
	options.path = path
	return REPO.new().open_session(options,token)

func create_demo(options: Dictionary, token) -> Dictionary:
	var output = String(options.output)
	if FileAccess.file_exists(output) or DirAccess.dir_exists_absolute(output): return failure("Demo output already exists; choose a new directory")
	var errors = PACKAGE.prepare_output_parent(output)
	if not errors.is_empty(): return failure("; ".join(errors))
	var workspace = output.path_join("workspace")
	var source = workspace.path_join("demo")
	errors = PACKAGE.prepare_output_parent(source.path_join("frames"))
	if not errors.is_empty(): return failure("; ".join(errors))
	var frames = []
	var records = []
	var entries = []
	for frame in 120:
		if PACKAGE.cancelled(token): return failure("Demo generation cancelled")
		var image_path = "frames/%06d.png" % frame
		var timestamp = frame / 32.0
		frames.append({"frame":frame,"time_s":timestamp,"image_path":image_path})
		entries.append({"frame":frame,"frame_id":frame,"time_s":timestamp,"image_path":image_path})
		var record = {"schema_version":1,"source":"demo","frame":frame,"time_s":timestamp,"regions":[{"id":"tool1","class":"grasper","kind":"instrument","box":[40,60,100,50],"track_id":"track1"},{"id":"tool2","class":"scissors","kind":"instrument","box":[220,120,70,90],"track_id":"track2"}]}
		records.append(record)
		var image = Image.create(400,240,false,Image.FORMAT_RGB8)
		image.fill(Color(0.06 + float(frame % 10) / 500.0,0.08,0.12))
		image.fill_rect(Rect2i(40,60,100,50),Color(0.85,0.25,0.25))
		image.fill_rect(Rect2i(220,120,70,90),Color(0.2,0.7,0.85))
		if image.save_png(source.path_join(image_path)) != OK: return failure("Cannot write synthetic demo PNG")
		PACKAGE.progress(token,float(frame+1)/120.0,"Generating synthetic source")
	var manifest = {"schema_version":1,"dataset_id":"demo","source_name":"demo","source_sha256":"Project6 deterministic synthetic demo, 120 frames".sha256_text(),"width":400,"height":240,"frame_count":120,"nominal_fps":32.0,"frames":frames,"model_version":"model_output_v1","taxonomy_version":"sample-taxonomy-v1"}
	errors = PACKAGE.write_text(source.path_join("manifest.json"),JSON.stringify(manifest,"",true,true)+"\n")
	errors.append_array(PACKAGE.write_text(source.path_join("model_output_v1.jsonl"),PACKAGE.jsonl(records)))
	if not errors.is_empty(): return failure("; ".join(errors))
	var opened = REPO.new().open_session({"path":workspace.path_join("label/demo.json"),"media_id":"demo","media_type":"image_sequence","source":"demo","source_relative_path":"demo","source_sha256":null,"source_root":workspace,"frame_entries":entries,"seed_records":records,"baseline_kind":"model","round_id":"round1","model_revision":"model_output_v1","taxonomy_version":"sample-taxonomy-v1"},token)
	if opened.success:
		opened["workspace"] = workspace
		opened["source_path"] = source
	return opened

func finish_demo(snapshot: Dictionary, save_options: Dictionary, output: String, token) -> Dictionary:
	var expected = {"geometry_changed":2,"label_changed":1,"added":1,"deleted":1,"attributes_changed":2,"changed_frames":6,"changed_regions":7}
	var ids = [12,13,24,36,72,90]
	var diff = PACKAGE.DIFF.build_diff(snapshot,ids)
	for key in expected:
		if diff.summary.get(key) != expected[key]: return failure("Demo diff mismatch: " + key)
	var training = PACKAGE.export_package(snapshot,{"kind":"training_update_v2","output_parent":output.path_join("packages")},token)
	if not training.success: return training
	var reopened = open_v3(save_options.path,token)
	if not reopened.success: return reopened
	if not PACKAGE.DIFF.equivalent(snapshot.baseline_records,reopened.snapshot.baseline_records) or not PACKAGE.DIFF.equivalent(diff,PACKAGE.DIFF.build_diff(reopened.snapshot,ids)) or not PACKAGE.DIFF.equivalent(snapshot.review_state,reopened.snapshot.review_state):
		return failure("Reopen changed baseline, diff or reviews")
	var again = PACKAGE.export_package(reopened.snapshot,{"kind":"training_update_v2","output_parent":output.path_join("packages")},token)
	if not again.success or not again.reused or again.package_id != training.package_id: return failure("Reopened package identity changed")
	var review = PACKAGE.export_package(reopened.snapshot,{"kind":"review_export_v1","output_parent":output.path_join("packages")},token)
	if not review.success: return review
	if training.summary.included_frames != 6 or training.summary.excluded_frames != 114 or review.summary.included_frames != 120:
		return failure("Demo package coverage mismatch")
	var round_directory = output.path_join("simulated_return")
	var errors = PACKAGE.prepare_output_parent(round_directory)
	if not errors.is_empty(): return failure("; ".join(errors))
	# Explicit simulated predictions; this does not train or execute model weights.
	var returned = snapshot.baseline_records.duplicate(true)
	for record in returned:
		if int(record.frame) == 12: record.regions[0].box[0] = 43
	var annotation = round_directory.path_join("model_output_v1.jsonl")
	errors = PACKAGE.write_text(annotation,PACKAGE.jsonl(returned))
	if not errors.is_empty(): return failure("; ".join(errors))
	var manifest = {"schema_version":1,"package_type":"model_round_v1","annotation_schema_version":1,"round_id":"round2","model_revision":"simulated-model-r2","parent_package_id":training.package_id,"taxonomy_version":snapshot.taxonomy_version,"media":ROUNDS._media(snapshot),"source_frame_entries":snapshot.frame_entries,"annotations":{"path":"model_output_v1.jsonl","bytes":FileAccess.get_file_as_bytes(annotation).size(),"sha256":FileAccess.get_sha256(annotation)},"weights_ref":"simulation-only:no-weights"}
	var manifest_path = round_directory.path_join("manifest.json")
	errors = PACKAGE.write_text(manifest_path,JSON.stringify(manifest,"",true,true)+"\n")
	if not errors.is_empty(): return failure("; ".join(errors))
	var imported = ROUNDS.import_round({"snapshot":reopened.snapshot,"save_options":save_options,"parent_package_path":training.output_path},manifest_path,token)
	if not imported.success: return imported
	if imported.snapshot.revision != 0 or not imported.snapshot.review_state.is_empty() or not imported.snapshot.batch_operations.is_empty() or imported.snapshot.session_id == snapshot.session_id or FileAccess.get_sha256(imported.archive_path) != save_options.expected_sha256:
		return failure("New round reset/archive mismatch")
	var restored = open_v3(imported.path,token)
	if not restored.success or restored.snapshot.round_id != "round2": return failure("New round cannot reopen")
	return {"success":true,"errors":[],"training_simulated":true,"summary":diff.summary,"training_coverage":6,"training_excluded":114,"review_coverage":120,"reopen_stable":true,"new_round_reset":true,"training_package":training.output_path,"review_package":review.output_path,"training_package_id":training.package_id,"review_package_id":review.package_id,"archive_path":imported.archive_path,"active_session":imported.path,"round_manifest":manifest_path,"workspace":output.path_join("workspace"),"source_path":output.path_join("workspace/demo"),"new_round_id":restored.snapshot.round_id,"autosaved_revision":snapshot.revision}

func failure(message: String) -> Dictionary:
	return {"success":false,"errors":[message]}
