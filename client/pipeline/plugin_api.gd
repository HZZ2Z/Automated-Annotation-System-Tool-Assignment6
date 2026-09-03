class_name PluginApi
extends RefCounted

const API_VERSION := 1
const STAGES := ["source", "render", "edit", "feedback"]
const REQUIRED_METHODS := {
	"source": ["open", "get_frame_count", "get_frame_entry", "get_model_records", "get_manifest", "load_texture", "close"],
	"render": ["set_state", "draw", "hit_test"],
	"edit": [
		"activate", "set_active_tool", "get_active_tool", "handle_pointer", "handle_key", "begin_add_box", "cancel",
		"relabel_selected", "set_selected_track_id", "set_selected_fill",
		"set_selected_geometry", "delete_selected", "deactivate",
	],
	"feedback": ["export"],
}
