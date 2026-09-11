extends SceneTree
func _init() -> void:
	for x in [12.0, 1.0, 0.12345678912345678, 123456.78912345678, 0.00000000012345678912345678, 1e20, 1.2e-8, -0.0, 3.600000000000001]:
		print(JSON.stringify(x), " | ", JSON.stringify(x,"",true,true))
	quit()
