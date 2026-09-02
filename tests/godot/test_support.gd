class_name TestSupport
extends RefCounted

var failures: Array[String] = []


func expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func expect_equal(actual: Variant, expected: Variant, message: String) -> void:
	expect(actual == expected, "%s (expected %s, got %s)" % [message, str(expected), str(actual)])


func failure_report() -> String:
	return "\n".join(failures)
