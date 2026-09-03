class_name PluginApi
extends RefCounted

const API_VERSION := 1
const STAGES := ["source", "render", "edit", "feedback"]
const REQUIRED_METHODS := {
	"source": ["can_open", "open", "get_frame_count", "get_frame_entry", "get_model_records", "get_manifest", "get_presentation", "load_texture", "close"],
	"render": ["set_state", "draw", "hit_test"],
	"edit": ["get_tool_descriptors", "activate", "set_active_tool", "get_active_tool", "handle_pointer", "handle_key", "invoke", "cancel", "deactivate"],
	"feedback": ["export"],
}
const REQUIRED_ARITY := {
	"source": {"can_open": 1, "open": 1, "get_frame_count": 0, "get_frame_entry": 1, "get_model_records": 0, "get_manifest": 0, "get_presentation": 0, "load_texture": 1, "close": 0},
	"render": {"set_state": 5, "draw": 1, "hit_test": 1},
	"edit": {"get_tool_descriptors": 0, "activate": 1, "set_active_tool": 1, "get_active_tool": 0, "handle_pointer": 2, "handle_key": 1, "invoke": 2, "cancel": 0, "deactivate": 0},
	"feedback": {"export": 1},
}
