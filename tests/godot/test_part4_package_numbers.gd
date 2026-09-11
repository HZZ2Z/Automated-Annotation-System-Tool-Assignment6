extends SceneTree
func _init():
	# 真实多边形坐标 570.6338500976563 在 Python 中可等价地最短写成末位 2；
	# 固定此边界，确保 Godot 导出与独立校验保持一致。
	var cases = [0.00000001,0.000000000123456789,100000000000000000000.0,1.2345678901234567,0.00001,0.0001,570.6338500976563]
	var paths = []
	for value in cases:
		var store = preload("res://client/domain/annotation_store.gd").new()
		store.load_model_records([{"schema_version":1,"source":"cam","frame":12,"regions":[{"id":"r","class":"tool","kind":"instrument","box":[value,2,3,4]}]}])
		store.configure_session({"session_id":"sess","media_id":"clip","media_type":"video","source_relative_path":"clip.mp4","source":"cam","source_sha256":null,"round_id":"r1","model_revision":"m1","taxonomy_version":"t1","revision":0,"baseline_kind":"model","frame_entries":[{"frame":0,"frame_id":12}],"explicit_frames":[12]})
		store.load_workflow_state({"12":{"accepted_digest":store.record_digest(12)}},[])
		var result = preload("res://client/feedback/training_package.gd").export_package(store.freeze_snapshot(),{"output_parent":"/tmp/part4-package-numbers"})
		if not result.success:
			printerr(result.errors)
			quit(1)
			return
		paths.append(result.output_path)
	var file = FileAccess.open("/tmp/part4-package-number-paths.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(paths))
	file.close()
	print("PASS: numeric package generation")
	quit()
