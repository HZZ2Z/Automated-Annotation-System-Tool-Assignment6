extends SceneTree

const SUPPORT := preload("res://tests/godot/test_support.gd")
const MODEL := preload("res://client/ui/batch_range_model.gd")

func _initialize() -> void:
	var s = SUPPORT.new()
	var model = MODEL.new()
	var entries := [
		{"frame":0,"frame_id":49,"time_s":0.0},
		{"frame":1,"frame_id":56,"time_s":0.28},
		{"frame":2,"frame_id":63,"time_s":0.56},
	]
	s.expect_equal(model.configure(entries, 0, 0, 2), PackedStringArray(), "sparse candidate configures")
	s.expect_equal(model.indices(), PackedInt64Array([0,1,2]), "range stores playback indices")
	s.expect_equal(model.frame_ids(), PackedInt64Array([49,56,63]), "range displays exact source frame IDs")
	s.expect_equal(model.index_at(1), 1, "option maps to playback index")
	s.expect_equal(model.option_for_index(2), 2, "playback index maps back to option")
	s.expect(not model.configure(entries, 1, 0, 2).is_empty(), "range rejects a keyframe outside selected endpoints")
	s.expect(model.indices().is_empty() and model.frame_ids().is_empty(), "invalid range leaves no stale endpoint mapping")
	quit(0 if s.failures.is_empty() else 1)
