extends SceneTree
const STORE = preload("res://client/domain/annotation_store.gd")
func _init() -> void:
	var records: Array = []
	var entries: Array = []
	for frame in range(10000):
		var regions: Array = []
		for index in range(20):
			regions.append({"id":"r%d" % index,"class":"tool","kind":"instrument","box":[index,2,3,4]})
		records.append({"schema_version":1,"source":"clip","frame":frame,"regions":regions})
		entries.append({"frame":frame,"frame_id":frame})
	var store = STORE.new()
	var started = Time.get_ticks_usec()
	var load_errors = store.load_model_records(records)
	if not load_errors.is_empty(): printerr(load_errors); quit(1); return
	var load_ms = (Time.get_ticks_usec()-started)/1000.0
	var configure_errors = store.configure_session({"session_id":"bench","media_id":"clip","media_type":"video","source_relative_path":"clip.mp4","source":"clip","round_id":"round1","model_revision":"m1","taxonomy_version":"t1","revision":0,"baseline_kind":"model","frame_entries":entries})
	if not configure_errors.is_empty(): printerr(configure_errors); quit(1); return
	var timings: Array = []
	var published: Dictionary = {}
	for index in range(30):
		started = Time.get_ticks_usec()
		published = store.freeze_snapshot()
		timings.append((Time.get_ticks_usec()-started)/1000.0)
	timings.sort()
	var edit: Dictionary = store.get_corrected_record(12)
	edit.regions[0]["class"] = "changed"
	store.replace_corrected_record(12, edit)
	if published.records[12].regions[0]["class"] != "tool": printerr("snapshot mutated"); quit(1); return
	print(JSON.stringify({"frames":10000,"regions_per_frame":20,"samples":30,"load_ms":load_ms,"snapshot_p50_ms":timings[14],"snapshot_p95_ms":timings[28],"snapshot_max_ms":timings[29]}))
	quit()
