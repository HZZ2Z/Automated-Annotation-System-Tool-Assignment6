extends SceneTree
const CODEC = preload("res://client/workspace/review_session_codec.gd")
var errors: Array[String] = []
func _init() -> void:
	var codec = CODEC.new()
	for kind in ["unknown","empty"]:
		for source: Variant in [42, null, true, [], {}, ""]:
			var payload = {"schema_version":3,"frame_digits":6,"session_id":"s1","media_id":"clip","media_type":"video","source_relative_path":"clip.mp4","source":source,"source_sha256":null,"round_id":"r1","model_revision":"m1","taxonomy_version":"t1","revision":0,"baseline_kind":kind,"baseline_records":[],"baseline_digest":null,"frame_entries":[{"frame":0,"frame_id":0,"time_s":0.125}],"explicit_frames":[],"frames":{},"review_state":{},"batch_operations":[]}
			var result = codec.decode(payload)
			if not result.has("snapshot") or not result.has("errors"):
				errors.append("%s source %s: decode must retain snapshot/errors result shape" % [kind, str(source)])
			elif not result.snapshot.is_empty() or not result.errors is PackedStringArray or result.errors.is_empty():
				errors.append("%s source %s: malformed source must return checked failure" % [kind, str(source)])
	for message in errors: print("FAIL: " + message)
	if errors.is_empty(): print("PASS Part 4 malformed unknown/empty source returns checked errors (12 cases)")
	quit(0 if errors.is_empty() else 1)
