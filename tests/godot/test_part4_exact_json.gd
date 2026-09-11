extends SceneTree
func _init() -> void:
	if not FileAccess.file_exists("res://client/domain/exact_json.gd"):
		print("FAIL: reusable exact JSON reader is missing")
		quit(1)
		return
	var reader = load("res://client/domain/exact_json.gd").new()
	var failures: Array = []
	for frame in range(120):
		var value = frame / 30.0
		var encoded = JSON.stringify(value,"",true,true)
		if reader.parse(encoded) != OK or reader.data != value:
			failures.append("30 fps exact roundtrip " + str(frame))
	for invalid in ["", "01", "-01", "+1", "1.", ".1", "1e", "1e+", "NaN", "Infinity", "[1,]", "{\"a\":1,}", "[true false]", "{a:1}", "\"bad\ntext\"", "\"\\x\"", "1e9999"]:
		if reader.parse(invalid) == OK: failures.append("invalid JSON accepted: " + invalid)
	for valid in ["null", "true", "false", "{\"x\":[1,2.0,-3e-4,\"123\",\"\\u4e2d\"],\"x\":1}"]:
		if reader.parse(valid) != OK: failures.append("valid JSON refused: " + valid)
	var args = OS.get_cmdline_user_args()
	var cases_path = args[0] if args.size() > 0 else "/tmp/part4-exact-json-cases.json"
	var actual_path = args[1] if args.size() > 1 else "/tmp/part4-exact-json-actual.json"
	var cases = JSON.parse_string(FileAccess.get_file_as_string(cases_path))
	var actual: Array = []
	for test: Dictionary in cases:
		var result = reader.parse(test.token)
		var bytes = PackedByteArray()
		bytes.resize(8)
		if result == OK: bytes.encode_double(0, reader.data)
		var bits = bytes.hex_encode()
		actual.append({"token":test.token,"bits":bits,"error":result})
		if result != OK or bits != test.bits: failures.append("different IEEE754 bits: " + test.token + " expected " + test.bits + " got " + bits)
	var output = FileAccess.open(actual_path,FileAccess.WRITE)
	output.store_string(JSON.stringify(actual))
	output.close()
	for failure in failures.slice(0,20): print("FAIL: " + failure)
	print("Exact JSON cases: ", cases.size(), "; failures: ", failures.size())
	quit(0 if failures.is_empty() else 1)
