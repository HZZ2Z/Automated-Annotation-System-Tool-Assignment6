extends RefCounted

const SPEED_CONTROL_SCENE := "res://client/ui/playback_speed_control.tscn"


func run(support, tree: SceneTree) -> void:
	var packed := load(SPEED_CONTROL_SCENE) as PackedScene
	support.expect(packed != null,
		"the compact top-toolbar playback speed control scene should exist")
	if packed == null:
		return
	var previous_embed_subwindows := tree.root.gui_embed_subwindows
	tree.root.gui_embed_subwindows = true
	var control = packed.instantiate()
	tree.root.add_child(control)
	await tree.process_frame

	var summary_button := control.get_node_or_null("SummaryButton") as Button
	var adjustment_popup := control.get_node_or_null("AdjustmentPopup") as PopupPanel
	var slider := control.get_node_or_null(
		"AdjustmentPopup/Margin/Content/SpeedSlider") as HSlider
	var custom_seconds := control.get_node_or_null(
		"AdjustmentPopup/Margin/Content/CustomSeconds") as SpinBox
	support.expect(summary_button != null and adjustment_popup != null,
		"the toolbar should expose one collapsed status button backed by a popup")
	support.expect(slider != null and custom_seconds != null,
		"the popup should own the discrete slider and custom seconds input")
	if summary_button == null or adjustment_popup == null \
		or slider == null or custom_seconds == null:
		control.queue_free()
		await tree.process_frame
		tree.root.gui_embed_subwindows = previous_embed_subwindows
		return
	support.expect(not adjustment_popup.visible,
		"the adjustment bar must be hidden until the current status is clicked")
	support.expect_equal(summary_button.text, "1 s/frame  ▾",
		"the collapsed control should show the current one-second default")
	summary_button.pressed.emit()
	await tree.process_frame
	support.expect(adjustment_popup.visible,
		"clicking the current status should open the adjustment bar")
	support.expect_equal(slider.min_value, 0.0,
		"the left slider stop should represent Custom")
	support.expect_equal(slider.max_value, 3.0,
		"the right slider stop should represent Max")
	support.expect_equal(slider.step, 1.0,
		"the playback bar should move only between its four explicit stops")
	support.expect_equal(slider.value, 2.0,
		"one second per frame should be selected by default")
	support.expect_equal(control.call("get_selected_mode"), &"one_second",
		"the default slider stop should publish the one-second clock")
	support.expect_equal(control.call("get_seconds_per_frame"), 1.0,
		"the default clock should expose one second per frame")
	support.expect(not custom_seconds.visible,
		"the custom input should stay hidden inside the popup until selected")
	support.expect(is_equal_approx(custom_seconds.min_value, 0.01)
		and is_equal_approx(custom_seconds.max_value, 60.0),
		"custom timing should accept the approved 0.01 to 60 seconds per frame range")
	# Popup windows translate an outside click into close_requested.  Drive that
	# exact framework boundary because headless tests have no window manager.
	adjustment_popup.close_requested.emit()
	await tree.process_frame
	support.expect(not adjustment_popup.visible,
		"the outside-click close request should collapse the adjustment bar")
	support.expect_equal(control.call("get_selected_mode"), &"one_second",
		"outside-click dismissal should preserve the selected playback speed")
	summary_button.pressed.emit()
	await tree.process_frame
	support.expect(adjustment_popup.visible,
		"the collapsed current status should reopen the adjustment popup")

	var requests: Array[Dictionary] = []
	control.speed_requested.connect(func(mode: StringName, seconds: float) -> void:
		requests.append({"mode": mode, "seconds": seconds})
	)
	slider.value = 1.0
	support.expect_equal(requests[-1], {"mode": &"three_seconds", "seconds": 3.0},
		"the stop left of one second should request three seconds per frame")
	support.expect_equal(summary_button.text, "3 s/frame  ▾",
		"the collapsed status should immediately reflect the selected fixed speed")
	slider.value = 0.0
	support.expect(custom_seconds.visible,
		"selecting the leftmost Custom stop should reveal its numeric input")
	custom_seconds.value = 2.5
	support.expect_equal(requests[-1], {"mode": &"custom", "seconds": 2.5},
		"editing Custom should request the exact validated seconds per frame")
	support.expect_equal(summary_button.text, "2.5 s/frame  ▾",
		"the collapsed status should expose the active Custom interval")
	slider.value = 3.0
	support.expect_equal(requests[-1], {"mode": &"max", "seconds": 0.0},
		"the rightmost stop should request unrestricted maximum-speed playback")
	support.expect(not custom_seconds.visible,
		"leaving Custom should collapse its numeric input")
	support.expect_equal(summary_button.text, "Max  ▾",
		"the collapsed status should expose maximum-speed mode")
	adjustment_popup.hide()
	support.expect(not adjustment_popup.visible and summary_button.visible,
		"closing the popup should leave only the current status visible")

	summary_button.pressed.emit()
	await tree.process_frame
	control.call("set_enabled", false)
	support.expect(summary_button.disabled and not adjustment_popup.visible,
		"disabling playback should close the popup and disable its trigger")
	support.expect(not slider.editable and not custom_seconds.editable,
		"the entire speed control should disable before a multi-frame source opens")
	control.queue_free()
	await tree.process_frame
	tree.root.gui_embed_subwindows = previous_embed_subwindows
