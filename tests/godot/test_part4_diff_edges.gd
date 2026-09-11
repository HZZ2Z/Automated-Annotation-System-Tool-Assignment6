extends SceneTree
const DIFF = preload("res://client/feedback/annotation_diff.gd")
const PACKAGE = preload("res://client/feedback/training_package.gd")
var errors = []
class CancelDuringWrite extends RefCounted:
	var stopped = false
	func is_cancelled(): return stopped
	func report_progress(_value): stopped = true
func check(value, message):
	if not value: errors.append(message)
func _init():
	var baseline = []
	for id in [12,13,24,36,72,90]:
		baseline.append({"schema_version":1,"source":"cam","frame":id,"regions":[{"id":"r","class":"old","kind":"tool","box":[0,0,10,10]}]})
	baseline[5].regions.append({"id":"second","class":"old","kind":"tool","box":[0,0,10,10]})
	var corrected = baseline.duplicate(true)
	corrected[0].regions[0].box[0] = 1
	corrected[1].regions[0]["class"] = "new"
	corrected[2].regions.append({"id":"added","class":"new","kind":"tool","box":[1,1,2,2]})
	corrected[3].regions.clear()
	corrected[4].regions[0]["track_id"] = "track"
	corrected[5].regions[0].box[0] = 2
	corrected[5].regions[1]["conf"] = 0.8
	var snapshot = {"baseline_kind":"model","baseline_records":baseline,"records":corrected,"frame_entries":[{},{},{},{},{},{}]}
	var d = DIFF.build_diff(snapshot,[12,13,24,36,72,90])
	check(d.summary.changed_frames == 6 and d.summary.changed_regions == 7,"acceptance 6 frames 7 unique regions")
	for key in {"geometry_changed":2,"label_changed":1,"added":1,"deleted":1,"attributes_changed":2}:
		check(d.summary[key] == {"geometry_changed":2,"label_changed":1,"added":1,"deleted":1,"attributes_changed":2}[key],key)
	check(d.by_class[0].reclassified_in == 1 and d.by_class[0].added == 1,"final class allocation")
	var reordered = baseline.duplicate(true)
	reordered[5].regions.reverse()
	snapshot.records = reordered
	check(DIFF.build_diff(snapshot,[90]).summary.changed_regions == 0,"reorder ignored")
	reordered[0].regions[0].id = "newid"
	var renamed = DIFF.build_diff(snapshot,[12])
	check(renamed.summary.added == 1 and renamed.summary.deleted == 1 and renamed.summary.changed_regions == 2,"id replacement delete plus add")
	var store = load("res://client/domain/annotation_store.gd").new()
	store.load_model_records(baseline)
	var entries = []
	for i in baseline.size(): entries.append({"frame":i,"frame_id":baseline[i].frame})
	var context = {"session_id":"edges","media_id":"clip","media_type":"video","source_relative_path":"clip.mp4","source":"cam","source_sha256":null,"round_id":"round1","model_revision":"model1","taxonomy_version":"tax1","revision":0,"baseline_kind":"model","frame_entries":entries,"explicit_frames":[12,13,24,36,72,90]}
	store.configure_session(context)
	store.load_workflow_state({"12":{"accepted_digest":store.record_digest(12)}}, [])
	var parent = "/tmp/part4-package-cancel-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(parent)
	var missing = parent.path_join("new/exports")
	check(PACKAGE.export_package(store.freeze_snapshot(),{"output_parent":missing}).success,"create missing absolute output parent")
	var token = CancelDuringWrite.new()
	var result = PACKAGE.export_package(store.freeze_snapshot(),{"output_parent":parent},token)
	check(result.cancelled and not result.success,"cancel during artifact writing")
	check(Array(DirAccess.open(parent).get_directories()) == ["new"],"own staging removed and unrelated parent retained on cancellation")
	var snap = store.freeze_snapshot().duplicate(true)
	snap.revision += 99
	var first = PACKAGE.export_package(store.freeze_snapshot(),{"output_parent":parent})
	var later = PACKAGE.export_package(snap,{"output_parent":parent})
	check(first.success and later.success and first.package_id == later.package_id,"revision excluded from content identity")
	check(PACKAGE.preview(store.freeze_snapshot(),{}).summary.included_frames == 1,"unchanged verified included")
	for kind in ["empty","imported_labels"]:
		var changed_snapshot = store.freeze_snapshot().duplicate(true)
		changed_snapshot.baseline_kind = kind
		if kind == "empty":
			changed_snapshot.baseline_records = []
			changed_snapshot.baseline_digest = null
		var package = PACKAGE.export_package(changed_snapshot,{"output_parent":parent})
		check(package.success,kind + " legitimate baseline export: " + str(package.errors))
		if kind == "empty" and package.success:
			PACKAGE.write_text("/tmp/part4-package-empty-path.txt",package.output_path)
	for e in errors: push_error(e)
	if errors.is_empty(): print("PASS: diff acceptance counts, identity, baseline and cancellation boundaries")
	quit(0 if errors.is_empty() else 1)
