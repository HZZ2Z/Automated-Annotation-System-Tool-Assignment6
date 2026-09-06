class_name PlaybackSpeedControl
extends Control

signal speed_requested(mode: StringName, seconds_per_frame: float)

const MODE_CUSTOM := &"custom"
const MODE_THREE_SECONDS := &"three_seconds"
const MODE_ONE_SECOND := &"one_second"
const MODE_MAX := &"max"

const CUSTOM_INDEX := 0
const THREE_SECONDS_INDEX := 1
const ONE_SECOND_INDEX := 2
const MAX_INDEX := 3

const POPUP_WIDTH := 266
const POPUP_FIXED_HEIGHT := 78
const POPUP_CUSTOM_HEIGHT := 106

@onready var _summary_button: Button = $SummaryButton
@onready var _popup: PopupPanel = $AdjustmentPopup
@onready var _custom_seconds: SpinBox = $AdjustmentPopup/Margin/Content/CustomSeconds
@onready var _slider: HSlider = $AdjustmentPopup/Margin/Content/SpeedSlider
@onready var _stop_buttons: Array[Button] = [
	$AdjustmentPopup/Margin/Content/Stops/Custom,
	$AdjustmentPopup/Margin/Content/Stops/ThreeSeconds,
	$AdjustmentPopup/Margin/Content/Stops/OneSecond,
	$AdjustmentPopup/Margin/Content/Stops/Max,
]

var _selected_mode := MODE_ONE_SECOND
var _syncing := false


func _ready() -> void:
	_summary_button.pressed.connect(_on_summary_pressed)
	_popup.close_requested.connect(_on_popup_close_requested)
	_slider.value_changed.connect(_on_slider_value_changed)
	_custom_seconds.value_changed.connect(_on_custom_seconds_changed)
	for index in range(_stop_buttons.size()):
		_stop_buttons[index].pressed.connect(_on_stop_pressed.bind(index))
	_apply_index(ONE_SECOND_INDEX, false)


func set_enabled(enabled: bool) -> void:
	_summary_button.disabled = not enabled
	_slider.editable = enabled
	_custom_seconds.editable = enabled
	for button: Button in _stop_buttons:
		button.disabled = not enabled
	if not enabled:
		_popup.hide()
	modulate.a = 1.0 if enabled else 0.55


func select_mode(
	mode: StringName,
	custom_seconds_per_frame: float = 5.0,
	emit_request: bool = false
) -> bool:
	var index := _index_for_mode(mode)
	if index < 0:
		return false
	if mode == MODE_CUSTOM:
		if not is_finite(custom_seconds_per_frame) \
			or custom_seconds_per_frame < _custom_seconds.min_value \
			or custom_seconds_per_frame > _custom_seconds.max_value:
			return false
		_syncing = true
		_custom_seconds.value = custom_seconds_per_frame
		_syncing = false
	_apply_index(index, emit_request)
	return true


func get_selected_mode() -> StringName:
	return _selected_mode


func get_seconds_per_frame() -> float:
	match _selected_mode:
		MODE_CUSTOM:
			return _custom_seconds.value
		MODE_THREE_SECONDS:
			return 3.0
		MODE_ONE_SECOND:
			return 1.0
		_:
			return 0.0


func _on_slider_value_changed(value: float) -> void:
	if _syncing:
		return
	_apply_index(clampi(roundi(value), CUSTOM_INDEX, MAX_INDEX), true)


func _on_summary_pressed() -> void:
	if _summary_button.disabled:
		return
	if _popup.visible:
		_popup.hide()
		return
	var popup_position := Vector2i(
		roundi(global_position.x),
		roundi(global_position.y + size.y + 4.0)
	)
	var popup_height := (
		POPUP_CUSTOM_HEIGHT if _selected_mode == MODE_CUSTOM else POPUP_FIXED_HEIGHT
	)
	_popup.popup(Rect2i(popup_position, Vector2i(POPUP_WIDTH, popup_height)))


func _on_popup_close_requested() -> void:
	_popup.hide()


func _on_custom_seconds_changed(_value: float) -> void:
	if _syncing or _selected_mode != MODE_CUSTOM:
		return
	_update_summary()
	speed_requested.emit(MODE_CUSTOM, _custom_seconds.value)


func _on_stop_pressed(index: int) -> void:
	_apply_index(index, true)


func _apply_index(index: int, emit_request: bool) -> void:
	_selected_mode = _mode_for_index(index)
	_syncing = true
	_slider.value = index
	_syncing = false
	_custom_seconds.visible = _selected_mode == MODE_CUSTOM
	_update_summary()
	if _popup.visible:
		_popup.size.y = (
			POPUP_CUSTOM_HEIGHT if _selected_mode == MODE_CUSTOM else POPUP_FIXED_HEIGHT
		)
	for button_index in range(_stop_buttons.size()):
		_stop_buttons[button_index].button_pressed = button_index == index
	if emit_request:
		speed_requested.emit(_selected_mode, get_seconds_per_frame())


func _update_summary() -> void:
	match _selected_mode:
		MODE_CUSTOM:
			_summary_button.text = "%s s/frame  ▾" % _format_seconds(_custom_seconds.value)
		MODE_THREE_SECONDS:
			_summary_button.text = "3 s/frame  ▾"
		MODE_ONE_SECOND:
			_summary_button.text = "1 s/frame  ▾"
		MODE_MAX:
			_summary_button.text = "Max  ▾"


func _format_seconds(seconds: float) -> String:
	if is_equal_approx(seconds, roundf(seconds)):
		return "%d" % roundi(seconds)
	var result := "%.2f" % seconds
	while result.ends_with("0"):
		result = result.left(-1)
	return result


func _mode_for_index(index: int) -> StringName:
	match index:
		CUSTOM_INDEX:
			return MODE_CUSTOM
		THREE_SECONDS_INDEX:
			return MODE_THREE_SECONDS
		ONE_SECOND_INDEX:
			return MODE_ONE_SECOND
		MAX_INDEX:
			return MODE_MAX
		_:
			return StringName()


func _index_for_mode(mode: StringName) -> int:
	match mode:
		MODE_CUSTOM:
			return CUSTOM_INDEX
		MODE_THREE_SECONDS:
			return THREE_SECONDS_INDEX
		MODE_ONE_SECOND:
			return ONE_SECOND_INDEX
		MODE_MAX:
			return MAX_INDEX
		_:
			return -1
