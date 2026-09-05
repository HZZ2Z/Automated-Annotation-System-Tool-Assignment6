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
