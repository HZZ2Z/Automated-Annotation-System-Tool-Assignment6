extends SceneTree
const PACKAGE = preload("res://client/feedback/training_package.gd")
const STORE = preload("res://client/domain/annotation_store.gd")
func _init():
	var args = OS.get_cmdline_user_args()
	var parent = args[0] if not args.is_empty() else ProjectSettings.globalize_path("res://output/import_guard_%d" % Time.get_ticks_usec())
	var result_file = args[1] if args.size() > 1 else "/tmp/part4-output-guard-result.json"
	var store = STORE.new()
	var errors = store.load_model_records([{"schema_version":1,"source":"cam","frame":12,"regions":[]}])
	errors.append_array(store.configure_session({"session_id":"guard","media_id":"clip","media_type":"image","source_relative_path":"clip.png","source":"cam","source_sha256":null,"round_id":"r1","model_revision":"m1","taxonomy_version":"t1","baseline_kind":"empty","revision":0,"frame_entries":[{"frame":0,"frame_id":12}],"explicit_frames":[12]}))
	errors.append_array(store.load_workflow_state({"12":{"accepted_digest":store.record_digest(12)}},[]))
	if not errors.is_empty():
		printerr(errors)
		quit(1)
		return
	var result = PACKAGE.export_package(store.freeze_snapshot(),{"output_parent":parent,"kind":"training_update_v2"})
	if result.success:
		var checked = PACKAGE.validate_package(result.output_path)
		if not checked.is_empty():
			printerr(checked)
			quit(1)
			return
		var raw = parent.path_join("raw_%d" % Time.get_ticks_usec())
		DirAccess.make_dir_recursive_absolute(raw)
		var image = Image.create(8,8,false,Image.FORMAT_RGB8)
		image.fill(Color.RED)
		for name in ["000012.png","000090.png"]:
			if image.save_png(raw.path_join(name)) != OK:
				quit(1)
				return
		var source = preload("res://client/plugins/source/numeric_image_sequence_source/plugin.gd").new()
		var source_errors = source.open(raw)
		if not source_errors.is_empty() or source.get_frame_count() != 2 or source.get_frame_entry(1).frame_id != 90 or source.load_texture(0) == null:
			printerr("raw Source reading failed: ",source_errors)
			quit(1)
			return
		source.close()
		result["source_png_readable"] = true
	PACKAGE.write_text(result_file,JSON.stringify(result,"",true,true))
	print("PASS: output export attempt and valid-package Source checks")
	quit()
