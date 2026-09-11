extends SceneTree
const PACKAGE = preload("res://client/feedback/training_package.gd")
const DIFF = preload("res://client/feedback/annotation_diff.gd")
func _initialize():
	var records = [{"schema_version":1,"source":"工具\n","frame":12,"time_s":7/30.0,"regions":[{"id":"quote\"","class":"comma,label\n工具\"","kind":"instrument","box":[1,2,3,4]}]}, {"schema_version":1,"source":"工具\n","frame":90,"regions":[]}]
	var expected_jsonl = ""
	for record in records: expected_jsonl += JSON.stringify(PACKAGE.normalize(record),"",true,true) + "\n"
	var snapshot = {"baseline_kind":"empty","baseline_records":[],"records":records,"frame_entries":[{},{}]}
	var diff = DIFF.build_diff(snapshot,[12,90])
	var expected_events = "frame_id,region_id,type,before,after\n"
	for frame in diff.frames:
		for event in frame.events:
			expected_events += DIFF.csv_row([str(frame.frame_id),event.region_id,event.type,JSON.stringify(DIFF.normalize(event.before),"",true,true),JSON.stringify(DIFF.normalize(event.after),"",true,true)])
	var expected_classes = "class," + ",".join(DIFF.CLASS_COUNTS) + "\n"
	for row in diff.by_class:
		var values = [row["class"]]
		for key in DIFF.CLASS_COUNTS: values.append(str(row[key]))
		expected_classes += DIFF.csv_row(values)
	var success = PACKAGE.jsonl([]) == "" and PACKAGE.jsonl(records).to_utf8_buffer() == expected_jsonl.to_utf8_buffer() and DIFF.events_csv(diff).to_utf8_buffer() == expected_events.to_utf8_buffer() and DIFF.classes_csv(diff).to_utf8_buffer() == expected_classes.to_utf8_buffer()
	print("PASS byte-identical JSONL and CSV assembly" if success else "FAIL changed artifact bytes")
	quit(0 if success else 1)
