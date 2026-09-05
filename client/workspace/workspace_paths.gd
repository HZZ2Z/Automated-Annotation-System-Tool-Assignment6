class_name WorkspacePaths
extends RefCounted


const MAX_MEDIA_ID_LENGTH := 64


static func portable_media_id(stem: String) -> String:
	var result := ""
	var pending_separator := false
	for index in range(stem.length()):
		var code := stem.unicode_at(index)
		var is_ascii_letter := (
			(code >= 65 and code <= 90)
			or (code >= 97 and code <= 122)
		)
		var is_digit := code >= 48 and code <= 57
		if is_ascii_letter or is_digit:
			if pending_separator and not result.is_empty():
				result += "_"
			result += String.chr(code)
			pending_separator = false
		else:
			pending_separator = true
	result = result.left(MAX_MEDIA_ID_LENGTH).trim_suffix("_")
	return result if not result.is_empty() else "media"


static func sample_id(media_id_value: String, frame_id: int) -> String:
	if not is_portable_media_id(media_id_value):
		return ""
	if frame_id < 0 or frame_id > 999999:
		return ""
	return "%s_%06d" % [media_id_value, frame_id]


static func label_path(workspace_root: String, media_id_value: String) -> String:
	if not is_portable_media_id(media_id_value):
		return ""
	return workspace_root.path_join("label").path_join("%s.json" % media_id_value)


static func cache_path(workspace_root: String, media_id_value: String) -> String:
	if not is_portable_media_id(media_id_value):
		return ""
	return workspace_root.path_join(".annotool/cache").path_join(media_id_value)


static func is_portable_media_id(value: String) -> bool:
	if value.is_empty() or value.length() > MAX_MEDIA_ID_LENGTH:
		return false
	if value.begins_with("_") or value.ends_with("_"):
		return false
	for index in range(value.length()):
		var code := value.unicode_at(index)
		var allowed := (
			(code >= 65 and code <= 90)
			or (code >= 97 and code <= 122)
			or (code >= 48 and code <= 57)
			or code == 95
		)
		if not allowed:
			return false
	return true
