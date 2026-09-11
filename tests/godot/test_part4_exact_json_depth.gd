extends SceneTree
const EXACT = preload("res://client/domain/exact_json.gd")
func _init() -> void:
	var failures: Array[String] = []
	var reader = EXACT.new()
	for depth in [1,255,256]:
		for leaf in ["0", "[]", "{}"]:
			# Empty array/object leaves add one container, so subtract their level.
			var outer = depth if leaf == "0" else depth-1
			var text = "[".repeat(outer)+leaf+"]".repeat(outer)
			if reader.parse(text) != OK: failures.append("valid depth %d rejected: %s" % [depth,reader.get_error_message()])
	for depth in [257,510,511,512,600,10000]:
		var text = "[".repeat(depth)+"0"+"]".repeat(depth)
		if reader.parse(text) == OK: failures.append("excessive depth %d accepted" % depth)
		elif reader.data != null or not reader.get_error_message().contains("nesting limit"):
			failures.append("depth %d did not return checked nesting failure" % depth)
	if reader.parse('{"after":[0.23333333333333334]}') != OK or reader.data.after[0] != 7/30.0:
		failures.append("reader does not recover after excessive nesting")
	for failure in failures: print("FAIL: "+failure)
	if failures.is_empty(): print("PASS exact JSON depth 256, excessive nesting and parser reuse")
	quit(0 if failures.is_empty() else 1)
