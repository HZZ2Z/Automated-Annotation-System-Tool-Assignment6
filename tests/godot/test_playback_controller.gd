extends RefCounted

const PLAYBACK_CONTROLLER_SCRIPT := preload("res://client/services/playback_controller.gd")


static func run(support) -> void:
	var controller = PLAYBACK_CONTROLLER_SCRIPT.new()
	var frames := [
		{"frame": 0, "time_s": 0.0},
		{"frame": 1, "time_s": 0.04},
		{"frame": 2, "time_s": 0.04},
		{"frame": 3, "time_s": 0.20},
	]
	support.expect_equal(controller.configure(frames, 25.0), PackedStringArray(),
		"valid manifest timing should configure playback")
	support.expect(controller.has_method("get_effective_fps"),
		"playback controller should expose a read-only effective FPS query")
	if controller.has_method("get_effective_fps"):
		support.expect(is_equal_approx(float(controller.call("get_effective_fps", 0)), 25.0),
			"source timing should derive FPS from the next timestamp interval")
		support.expect(is_equal_approx(float(controller.call("get_effective_fps", 1)), 25.0),
			"duplicate source timestamps should report the nominal FPS fallback")
		support.expect(is_equal_approx(float(controller.call("get_effective_fps", 2)), 6.25),
			"source timing should report the current local interval instead of a global average")
	support.expect(controller.play(0), "play should start before the last frame")
	support.expect(controller.is_playing(), "controller should expose active playback")
	support.expect_equal(controller.tick(0.039, 0), -1,
		"playback should wait for the next manifest timestamp")
	support.expect_equal(controller.tick(0.001, 0), 1,
		"playback should request exactly the next explicit index")

	support.expect_equal(controller.tick(5.0, 1), 2,
		"a late tick should request one frame without skipping")
	support.expect_equal(controller.tick(0.0, 2), -1,
		"late time must not be retained for catch-up skipping")
	support.expect_equal(controller.tick(0.159, 2), -1,
		"positive timestamp deltas should control the next interval")
	support.expect_equal(controller.tick(0.001, 2), 3,
		"the next manifest interval should be frame accurate")
	support.expect_equal(controller.tick(1.0, 3), -1,
		"the final frame should never loop")
	support.expect(not controller.is_playing(),
		"reaching the final frame should stop playback")

	controller.configure(frames, 25.0)
	support.expect(controller.play(1), "duplicate-timestamp setup should play")
	support.expect_equal(controller.tick(0.039, 1), -1,
		"duplicate timestamps should fall back to nominal FPS")
	support.expect_equal(controller.tick(0.001, 1), 2,
		"nominal FPS fallback should advance one frame")
	controller.pause()
	support.expect(not controller.is_playing(), "pause should be immediate")
	support.expect_equal(controller.tick(10.0, 2), -1,
		"paused playback should ignore elapsed time")

	support.expect(not controller.play(3), "play at the last frame should remain stopped")
	support.expect(not controller.configure(frames, 0.0).is_empty(),
		"non-positive nominal FPS should be rejected")
	support.expect(not controller.configure([], 25.0).is_empty(),
		"an empty frame sequence should be rejected")

	var sparse_frames := [
		{"frame": 0, "time_s": 16.0},
		{"frame": 1, "time_s": 23.0},
	]
	support.expect_equal(controller.configure(sparse_frames, 1.0), PackedStringArray(),
		"sparse source timing should configure without changing stored timestamps")
	support.expect(controller.play(0), "sparse source-time playback should start")
	support.expect_equal(controller.tick(6.999, 0), -1,
		"source-time playback should preserve the seven-second sparse interval")
	support.expect_equal(controller.tick(0.001, 0), 1,
		"source-time playback should advance after the full sparse interval")

	support.expect_equal(controller.configure(sparse_frames, 1.0), PackedStringArray(),
		"sparse review timing should start from a fresh controller configuration")
	support.expect_equal(controller.set_clock(&"review", 25.0), PackedStringArray(),
		"review playback should accept a finite positive item rate")
	support.expect(controller.play(0), "review playback should start")
	support.expect_equal(controller.tick(0.039, 0), -1,
		"25 fps review playback should wait for its forty-millisecond interval")
	if controller.has_method("get_effective_fps"):
		support.expect(is_equal_approx(float(controller.call("get_effective_fps", 0)), 25.0),
			"review FPS query should report the configured presentation rate")
	support.expect_equal(controller.tick(0.001, 0), 1,
		"reading FPS must not reset elapsed playback or change the next frame")

	support.expect_equal(controller.configure(sparse_frames, 1.0), PackedStringArray(),
		"clock-change pause setup should reconfigure sparse playback")
	support.expect(controller.play(0), "clock-change pause setup should start playback")
	support.expect_equal(controller.set_clock(&"review", 10.0), PackedStringArray(),
		"changing to another supported review rate should succeed")
	support.expect(not controller.is_playing(),
		"changing the playback clock should pause and discard elapsed time")
	support.expect(not controller.set_clock(&"unknown", 25.0).is_empty(),
		"unknown playback clock modes should be rejected")
	support.expect(not controller.set_clock(&"review", 0.0).is_empty(),
		"non-positive review rates should be rejected")

	support.expect_equal(controller.configure(frames, 25.0), PackedStringArray(),
		"maximum-speed setup should accept the same contiguous playback source")
	support.expect_equal(controller.set_clock(&"max"), PackedStringArray(),
		"maximum-speed playback should be an explicit supported clock")
	support.expect(controller.play(0), "maximum-speed playback should start")
	support.expect_equal(controller.tick(0.0, 0), 1,
		"maximum speed should deliver the next frame without an artificial wait")
	support.expect_equal(controller.tick(0.0, 1), 2,
		"maximum speed should still advance exactly one ordered frame per tick")
	support.expect_equal(controller.tick(0.0, 2), 3,
		"maximum speed should never skip an explicit frame index")
	support.expect_equal(controller.tick(0.0, 3), -1,
		"maximum speed should stop at the final frame instead of looping")
