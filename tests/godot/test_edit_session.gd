extends RefCounted

const EDIT_SESSION := preload("res://client/domain/edit_session.gd")
const OVERLAY_KEYS := [
	"brush_radius",
	"candidate_polygon",
	"cursor",
	"fill_color",
	"mask_preview",
	"message",
	"path",
	"phase",
]


static func run(support) -> void:
	_test_state_transitions_and_snapshot_isolation(support)
	_test_candidate_invalid_and_reset_transitions(support)
	_test_awaiting_class_is_private_and_resettable(support)


static func _test_state_transitions_and_snapshot_isolation(support) -> void:
	var session = EDIT_SESSION.new()
	support.expect_equal(session.phase, &"idle", "new edit session starts idle")
	support.expect_equal(session.overlay_snapshot(), {}, "idle edit session has no overlay state")

	var before := {"regions": [{"id": "committed", "box": [1, 2, 3, 4]}]}
	session.begin(&"paint", 4, "committed", before)
	before["regions"][0]["id"] = "caller-mutated"
	support.expect_equal(session.before["regions"][0]["id"], "committed", "begin keeps an isolated Store snapshot")

	var caller_path := PackedVector2Array([Vector2(1, 2), Vector2(3, 4)])
	session.set_drawing(caller_path, Vector2(3, 4), 8.0)
	caller_path[0] = Vector2(99, 99)
	var drawing: Dictionary = session.overlay_snapshot()
	support.expect_equal(session.phase, &"drawing", "a Paint press enters Drawing")
	support.expect_equal(_sorted_keys(drawing), OVERLAY_KEYS, "overlay snapshots expose exactly the transient rendering contract")
	support.expect_equal(drawing["path"], PackedVector2Array([Vector2(1, 2), Vector2(3, 4)]), "Drawing snapshots isolate the caller path")
	support.expect_equal(drawing["cursor"], Vector2(3, 4), "Drawing snapshot retains the image-space cursor")
	support.expect_equal(drawing["brush_radius"], 8.0, "Drawing snapshot retains the image-space brush radius")
	support.expect(not drawing.has("before"), "overlay snapshots never expose the committed Store record")

	var caller_mask := _mask_fixture()
	session.set_working_mask(caller_mask, "Use Fill, Close Gaps, or Escape")
	caller_mask["mask"][0] = 0
	caller_mask["roi"] = Rect2i(99, 99, 1, 1)
	var working: Dictionary = session.overlay_snapshot()
	support.expect(session.has_working_mask(), "orange WorkingMask blocks navigation")
	support.expect_equal(working["phase"], &"working_mask", "WorkingMask snapshot advertises its blocking phase")
	support.expect_equal(working["mask_preview"]["roi"], Rect2i(10, 20, 3, 2), "WorkingMask keeps the original bounded ROI")
	support.expect_equal(working["mask_preview"]["mask"], PackedByteArray([255, 0, 255, 0, 255, 0]), "WorkingMask keeps an immutable raw mask with holes")
	support.expect_equal(working["message"], "Use Fill, Close Gaps, or Escape", "WorkingMask retains repair guidance")


static func _test_candidate_invalid_and_reset_transitions(support) -> void:
	var session = EDIT_SESSION.new()
	session.begin(&"lasso", 8, "", {})
	var caller_polygon := PackedVector2Array([Vector2(2, 2), Vector2(8, 2), Vector2(8, 8)])
	session.set_candidate(caller_polygon, "Ready")
	caller_polygon[0] = Vector2.ZERO
	var candidate: Dictionary = session.overlay_snapshot()
	support.expect_equal(candidate["phase"], &"candidate", "valid transient geometry enters Candidate")
	support.expect_equal(candidate["candidate_polygon"][0], Vector2(2, 2), "Candidate snapshot isolates the caller polygon")

	var invalid_path := PackedVector2Array([Vector2(1, 1), Vector2(5, 5), Vector2(1, 5), Vector2(5, 1)])
	session.set_invalid(invalid_path, "Self-intersection", {}, EDIT_SESSION.INVALID_COLOR, invalid_path)
	invalid_path[0] = Vector2.ZERO
	var invalid: Dictionary = session.overlay_snapshot()
	support.expect_equal(invalid["phase"], &"invalid", "refused geometry remains visible as Invalid")
	support.expect_equal(invalid["path"][0], Vector2(1, 1), "Invalid snapshot isolates the refused path")
	support.expect_equal(invalid["candidate_polygon"], PackedVector2Array([
		Vector2(1, 1), Vector2(5, 5), Vector2(1, 5), Vector2(5, 1),
	]), "a closed invalid candidate remains filled through the existing candidate_polygon overlay key")
	support.expect_equal(invalid["message"], "Self-intersection", "Invalid snapshot keeps the refusal message")

	session.reset()
	support.expect_equal(session.phase, &"idle", "reset returns the session to Idle")
	support.expect_equal(session.overlay_snapshot(), {}, "reset clears all transient overlay state")
	support.expect(not session.has_working_mask(), "reset releases WorkingMask navigation blocking")


static func _test_awaiting_class_is_private_and_resettable(support) -> void:
	var session = EDIT_SESSION.new()
	var before := {"regions": [{"id": "committed", "box": [1, 2, 3, 4]}]}
	var geometry := {"shape": &"box", "box": [4.0, 5.0, 20.0, 12.0]}
	session.begin(&"box", 3, "", before)
	session.set_awaiting_class(geometry, Vector2(160, 120), 17, "Choose a class and kind")
	geometry["box"][0] = 99.0
	geometry["shape"] = &"polygon"
	before["regions"][0]["id"] = "caller-mutated"

	support.expect(session.has_pending_class_assignment(), "new geometry must block as AwaitingClass")
	support.expect_equal(session.pending_request(), {
		"candidate_token": 17,
		"frame": 3,
		"tool_id": &"box",
	}, "UI request must not receive mutable geometry")
	var overlay: Dictionary = session.overlay_snapshot()
	support.expect_equal(overlay["phase"], &"awaiting_class", "pending geometry must remain visible")
	support.expect_equal(overlay["candidate_polygon"], PackedVector2Array([
		Vector2(4, 5), Vector2(24, 5), Vector2(24, 17), Vector2(4, 17),
	]), "box pending preview must use four isolated corners")
	support.expect(not session.pending_request().has("geometry"), "UI request must never expose pending geometry")
	support.expect(not session.pending_request().has("image_size"), "UI request must never expose image bounds")
	support.expect_equal(session.before["regions"][0]["id"], "committed", "pending state must preserve its exact before-record snapshot")

	var leaked_overlay: Dictionary = session.overlay_snapshot()
	leaked_overlay["candidate_polygon"][0] = Vector2.ZERO
	support.expect_equal(session.overlay_snapshot()["candidate_polygon"][0], Vector2(4, 5), "overlay callers must not mutate pending geometry")

	var polygon := PackedVector2Array([
		Vector2(7, 9), Vector2(31, 9), Vector2(28, 22), Vector2(9, 24),
	])
	session.begin(&"lasso", 3, "", before)
	session.set_awaiting_class(
		{"shape": &"polygon", "polygon": polygon},
		Vector2(160, 120),
		18,
		"Choose a class and kind",
	)
	polygon[0] = Vector2.ZERO
	var polygon_overlay: Dictionary = session.overlay_snapshot()
	support.expect_equal(
		polygon_overlay["candidate_polygon"],
		PackedVector2Array([Vector2(7, 9), Vector2(31, 9), Vector2(28, 22), Vector2(9, 24)]),
		"pending polygon overlay must retain the exact isolated ring",
	)
	support.expect_equal(session.pending_request(), {
		"candidate_token": 18,
		"frame": 3,
		"tool_id": &"lasso",
	}, "polygon request must expose identifiers without private geometry")

	session.reset()
	support.expect(not session.has_pending_class_assignment(), "reset releases AwaitingClass navigation blocking")
	support.expect_equal(session.pending_request(), {}, "reset clears the pending token and identifiers")
	support.expect_equal(session.overlay_snapshot(), {}, "reset clears pending geometry and its overlay")


static func _mask_fixture() -> Dictionary:
	return {
		"roi": Rect2i(10, 20, 3, 2),
		"mask": PackedByteArray([255, 0, 255, 0, 255, 0]),
	}


static func _sorted_keys(value: Dictionary) -> Array:
	var keys: Array = value.keys()
	keys.sort()
	return keys
