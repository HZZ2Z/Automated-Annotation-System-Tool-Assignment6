extends RefCounted

const DECODER_PATH := "res://client/domain/coco_rle.gd"
const IMAGE_ALGORITHMS := preload("res://client/domain/image_region_algorithms.gd")


func run(support) -> void:
	var decoder := ResourceLoader.load(DECODER_PATH, "Script") as Script
	support.expect(decoder != null, "COCO compressed-RLE decoder should exist")
	if decoder == null:
		return
	_test_known_vectors(decoder, support)
	_test_malformed_vectors(decoder, support)
	_test_polygon_gate(decoder, support)


func _test_known_vectors(decoder: Script, support) -> void:
	var empty: Dictionary = decoder.decode({"size": [2, 2], "counts": "4"})
	support.expect(bool(empty.get("ok", false)), "an all-background compressed RLE should decode")
	support.expect_equal(empty.get("size"), Vector2i(2, 2),
		"decoded size should preserve width and height")
	support.expect_equal(Array(empty.get("mask", PackedByteArray())), [0, 0, 0, 0],
		"an all-background mask should remain empty")

	# Fixed COCO counts [6,3,2,3,2,3,6], including the i-2 delta encoding.
	var square: Dictionary = decoder.decode({"size": [5, 5], "counts": "6320004"})
	support.expect(bool(square.get("ok", false)),
		"a known centered-square compressed RLE should decode")
	support.expect_equal(Array(square.get("mask", PackedByteArray())), [
		0, 0, 0, 0, 0,
		0, 1, 1, 1, 0,
		0, 1, 1, 1, 0,
		0, 1, 1, 1, 0,
		0, 0, 0, 0, 0,
	], "COCO column-major pixels must map to Project6 row-major mask")

	# Fixed counts [1,2,2,1]; final O is signed delta -1 from count 1.
	var alternating: Dictionary = decoder.decode({"size": [2, 3], "counts": "122O"})
	support.expect(bool(alternating.get("ok", false)),
		"signed COCO deltas should decode")
	support.expect_equal(Array(alternating.get("mask", PackedByteArray())),
		[0, 1, 0, 1, 0, 1],
		"column-major alternating runs should be reordered row-major")

	# Official maskApi encodes run 42 as the two bytes Z1; no ASCII gap is
	# removed during rleFrString decoding.
	var high_ascii: Dictionary = decoder.decode({"size": [1, 43], "counts": "Z11"})
	support.expect(bool(high_ascii.get("ok", false)),
		"compressed RLE bytes above ASCII X should retain their six-bit value")
	if bool(high_ascii.get("ok", false)):
		var expected := PackedByteArray()
		expected.resize(43)
		expected[42] = 1
		support.expect_equal(high_ascii.get("mask"), expected,
			"the official [42, 1] run vector should decode exactly")


func _test_malformed_vectors(decoder: Script, support) -> void:
	_expect_failure(decoder.decode({"size": [2], "counts": "4"}), "size", support)
	_expect_failure(decoder.decode({"size": [2, 2], "counts": "P"}), "truncated", support)
	_expect_failure(decoder.decode({"size": [2, 2], "counts": "O"}), "negative", support)
	_expect_failure(decoder.decode({"size": [2, 2], "counts": "3"}), "total", support)
	_expect_failure(decoder.decode({"size": [1048577, 1], "counts": "1"}), "limit", support)
	_expect_failure(decoder.decode({"size": [2, 2], "counts": " "}), "invalid", support)


func _test_polygon_gate(decoder: Script, support) -> void:
	var decoded: Dictionary = decoder.decode({"size": [5, 5], "counts": "6320004"})
	var polygonized := IMAGE_ALGORITHMS.polygonize_mask(decoded.mask, decoded.size)
	support.expect(bool(polygonized.get("ok", false)),
		"a decoded single centered component should pass the existing V1 polygon gate")

	var multiple := PackedByteArray([
		1, 0, 0,
		0, 0, 0,
		0, 0, 1,
	])
	support.expect_equal(
		IMAGE_ALGORITHMS.polygonize_mask(multiple, Vector2i(3, 3)).get("code"),
		&"multiple_components",
		"decoded disconnected masks should retain the existing V1 refusal code")
	var hole := PackedByteArray([
		1, 1, 1,
		1, 0, 1,
		1, 1, 1,
	])
	support.expect_equal(
		IMAGE_ALGORITHMS.polygonize_mask(hole, Vector2i(3, 3)).get("code"),
		&"hole_topology",
		"decoded masks with a hole should retain the existing V1 refusal code")


func _expect_failure(result: Dictionary, fragment: String, support) -> void:
	support.expect(
		not bool(result.get("ok", false))
		and fragment in String(result.get("error", "")).to_lower(),
		"malformed COCO RLE should fail with a %s diagnostic" % fragment)
