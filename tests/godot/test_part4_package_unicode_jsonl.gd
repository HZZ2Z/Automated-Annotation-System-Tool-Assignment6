extends SceneTree
const STORE = preload("res://client/domain/annotation_store.gd")
const PACKAGE = preload("res://client/feedback/training_package.gd")
const SEMANTICS = preload("res://client/feedback/package_semantics.gd")
var failures = []
func check(ok, message):
	if not ok: failures.append(message)
func _init():
	var output = "/tmp/part4-unicode-jsonl-%d" % Time.get_ticks_usec()
	var cases = []
	for codepoint in [0x85,0x2028,0x2029]:
		for field in ["class","image_path","both"]:
			var separator = String.chr(codepoint)
			var label = "label" + separator + "end" if field != "image_path" else "new_label"
			var path = "images/frame" + separator + "12.png" if field != "class" else "images/frame12.png"
			var store = STORE.new()
			var regions = [{"id":"r1","class":"before","kind":"instrument","box":[1,2,3,4]}]
			var records = [{"schema_version":1,"source":"cam","frame":12,"regions":regions},{"schema_version":1,"source":"cam","frame":90,"regions":[]}]
			check(store.load_model_records(records).is_empty(),"load baseline")
			var context = {"session_id":"unicode","media_id":"clip","media_type":"image_sequence","source_relative_path":"images","source":"cam","source_sha256":null,"round_id":"r1","model_revision":"m1","taxonomy_version":"t1","baseline_kind":"model","revision":0,"frame_entries":[{"frame":0,"frame_id":12,"image_path":path},{"frame":1,"frame_id":90,"image_path":"images/frame90.png","time_s":1.0}],"explicit_frames":[12]}
			check(store.configure_session(context).is_empty(),"configure Unicode path")
			var changed = store.get_corrected_record(12)
			changed.regions[0]["class"] = label
			check(store.replace_corrected_record(12,changed).is_empty(),"apply Unicode class")
			check(store.load_workflow_state({"12":{"accepted_digest":store.record_digest(12)},"90":{"accepted_digest":store.record_digest(90)}},[]).is_empty(),"verify")
			var result = PACKAGE.export_package(store.freeze_snapshot(),{"output_parent":output,"kind":"training_update_v2"})
			check(result.success,"Unicode export " + str(result.errors))
			if result.success:
				check(PACKAGE.validate_package(result.output_path).is_empty(),"Unicode package Godot validator")
				cases.append({"codepoint":codepoint,"field":field,"path":result.output_path})
	var valid = ['{"id":"a"}\n{"id":"b"}\n','{"id":"a"}\r\n{"id":"b"}\r\n','{"id":"a"}\n{"id":"b"}','{"id":"a"}\r\n{"id":"b"}']
	for text in valid:
		var errors = PackedStringArray()
		var parsed = SEMANTICS._jsonl(text,errors)
		check(errors.is_empty() and parsed.size() == 2,"Godot accepts LF/CRLF and optional terminal newline")
	for text in ['\n','{"id":"a"}\n\n','{"id":"a"}\n\n{"id":"b"}','{"id":"a"}\r{"id":"b"}','{"id":\n"a"}\n','not json\n']:
		var errors = PackedStringArray()
		SEMANTICS._jsonl(text,errors)
		check(not errors.is_empty(),"Godot rejects malformed or blank JSONL records")
	var empty_errors = PackedStringArray()
	check(SEMANTICS._jsonl("",empty_errors).is_empty() and empty_errors.is_empty(),"empty text parses as zero rows; coverage rejects empty package artifacts")
	PACKAGE.write_text("/tmp/part4-unicode-jsonl-cases.json",JSON.stringify(cases,"",true,true))
	for failure in failures: push_error(failure)
	if failures.is_empty(): print("PASS: 9 real Unicode class/path exports and JSONL line boundary behavior")
	quit(0 if failures.is_empty() else 1)
