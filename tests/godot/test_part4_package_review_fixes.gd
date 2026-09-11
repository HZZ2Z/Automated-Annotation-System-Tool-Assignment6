extends SceneTree
const PACKAGE = preload("res://client/feedback/training_package.gd")
var failures = []
func check(value, message):
	if not value: failures.append(message)
func _init():
	var original_path = FileAccess.get_file_as_string("/tmp/part4-package-path.txt")
	var expected = JSON.parse_string(FileAccess.get_file_as_string(original_path.path_join("manifest.json")))
	var copy = "/tmp/part4-reuse-review-%d" % Time.get_ticks_usec()
	for sub in ["data","reports"]: DirAccess.make_dir_recursive_absolute(copy.path_join(sub))
	for relative in PACKAGE.PATHS: DirAccess.copy_absolute(original_path.path_join(relative),copy.path_join(relative))
	for bad in [-1,0.5,true,"4",null]:
		var manifest = expected.duplicate(true)
		manifest.revision = bad
		PACKAGE.write_text(copy.path_join("manifest.json"),JSON.stringify(manifest,"",true,true))
		check(not PACKAGE.validate_package(copy,expected).is_empty(),"reject invalid excluded revision " + str(bad))
	for key in ["revision","media","coverage"]:
		var manifest = expected.duplicate(true)
		manifest.erase(key)
		manifest.package_id = PACKAGE.package_identity(manifest)
		PACKAGE.write_text(copy.path_join("manifest.json"),JSON.stringify(manifest,"",true,true))
		check(not PACKAGE.validate_package(copy).is_empty(),"reject missing manifest field " + key)
	var valid = expected.duplicate(true)
	valid.revision += 5
	PACKAGE.write_text(copy.path_join("manifest.json"),JSON.stringify(valid,"",true,true))
	check(PACKAGE.validate_package(copy,expected).is_empty(),"valid different revision still reusable")
	valid["created_at"] = "unsupported"
	PACKAGE.write_text(copy.path_join("manifest.json"),JSON.stringify(valid,"",true,true))
	check(not PACKAGE.validate_package(copy,expected).is_empty(),"excluded undeclared fields rejected")
	for failure in failures: push_error(failure)
	if failures.is_empty(): print("PASS: manifest structure and revision reuse boundaries")
	quit(0 if failures.is_empty() else 1)
