extends SceneTree
func _init() -> void:
	for value in [7/30.0,28/30.0,29/30.0,32/30.0,1e-20,1.2345678901234567]:
		var raw := JSON.stringify(value,"",true,true)
		print(raw, " json=",JSON.stringify(JSON.parse_string(raw),"",true,true)," str=",JSON.stringify(raw.to_float(),"",true,true))
	quit()
