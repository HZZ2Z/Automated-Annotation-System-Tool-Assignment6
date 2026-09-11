extends SceneTree
const STORE = preload("res://client/domain/annotation_store.gd")
const CODEC = preload("res://client/workspace/review_session_codec.gd")
func _initialize():
	for f in 120:
		var value = f / 30.0
		var text = JSON.stringify(value,"",true,true)
		var parsed = JSON.parse_string(text)
		if value != parsed:
			print(JSON.stringify({"frame":f,"original_json":text,"parsed_json":JSON.stringify(parsed,"",true,true),"original_bytes":var_to_bytes(value).hex_encode(),"parsed_bytes":var_to_bytes(parsed).hex_encode()},"",true,true))
	quit()
