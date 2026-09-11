extends RefCounted

const FPS_METER_PATH := "res://client/services/playback_fps_meter.gd"


static func run(support) -> void:
	var meter_script := load(FPS_METER_PATH) as Script
	support.expect(meter_script != null,
		"actual playback FPS meter should exist as an isolated runtime service")
	if meter_script == null:
		return
	var meter = meter_script.new()
	support.expect_equal(meter.get_actual_fps(), 0.0,
		"a stopped meter should report zero actual playback FPS")

	meter.start(1_000_000)
	support.expect_equal(meter.get_actual_fps(), -1.0,
		"a running meter should report unknown FPS before two delivered frames")
	support.expect(meter.record_delivery(2_000_000),
		"the first successful delivery timestamp should be accepted")
	support.expect_equal(meter.get_actual_fps(), -1.0,
		"one delivered frame is insufficient to calculate a cadence")
	support.expect(meter.record_delivery(3_000_000),
		"the second successful delivery timestamp should be accepted")
	support.expect(is_equal_approx(float(meter.get_actual_fps()), 1.0),
		"one-second delivery intervals should report one actual FPS")

	support.expect(meter.record_delivery(3_500_000),
		"a later successful delivery should update the rolling cadence")
	support.expect(is_equal_approx(float(meter.get_actual_fps()), 4.0 / 3.0),
		"the rolling meter should derive FPS only from real delivery timestamps")
	support.expect(not meter.record_delivery(3_500_000),
		"duplicate timestamps should not create artificial delivered frames")
	support.expect(not meter.record_delivery(3_400_000),
		"non-monotonic timestamps should not corrupt actual FPS")
	support.expect(is_equal_approx(float(meter.get_actual_fps()), 4.0 / 3.0),
		"rejected timestamps should leave the measured cadence unchanged")

	meter.stop()
	support.expect_equal(meter.get_actual_fps(), 0.0,
		"pausing playback should expose zero actual FPS")
	meter.start(4_000_000)
	support.expect_equal(meter.get_actual_fps(), -1.0,
		"a new playback run should not reuse stale delivery samples")
