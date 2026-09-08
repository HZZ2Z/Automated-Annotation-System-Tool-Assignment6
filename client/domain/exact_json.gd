## Strict JSON with correctly rounded finite binary64 numbers. No IO or Nodes.
## Godot 4.7's decimal parser can drift by ULPs, including 7/30 roundtrips.
## Native conversion is only a guess; exact midpoint comparisons decide rounding.
class_name ExactJson
extends RefCounted

const MAX_FINITE_BITS := 0x7fefffffffffffff
const FRACTION_MASK := 0x000fffffffffffff
const SIGN_MASK := -9223372036854775807 - 1
const LIMB_BASE := 1000000000
const MAX_DEPTH := 512
var data: Variant
var _text := ""
var _position := 0
var _message := ""
var _depth := 0

func parse(text: String) -> Error:
	_text = text
	_position = 0
	_message = ""
	_depth = 0
	data = _value()
	_space()
	if _message.is_empty() and _position != _text.length(): _fail("Unexpected trailing content")
	if not _message.is_empty():
		data = null
		return ERR_PARSE_ERROR
	return OK

static func parse_string(text: String) -> Variant:
	var reader = new()
	return reader.data if reader.parse(text) == OK else null

func get_error_message() -> String: return _message
func get_error_line() -> int: return _text.substr(0,_position).count("\n")

func _fail(message: String) -> void:
	if _message.is_empty(): _message = message + " at character %d" % _position

func _space() -> void:
	while _position < _text.length() and _text.unicode_at(_position) in [9,10,13,32]: _position += 1

func _value() -> Variant:
	_space()
	if _position >= _text.length(): _fail("Expected JSON value"); return null
	if _depth >= MAX_DEPTH: _fail("JSON nesting limit exceeded"); return null
	var character := _text[_position]
	if character == '"': return _string()
	if character == "[" or character == "{":
		_depth += 1
		var value: Variant = _container(character == "{")
		_depth -= 1
		return value
	for literal: String in ["true","false","null"]:
		if _text.substr(_position,literal.length()) == literal:
			_position += literal.length()
			return true if literal == "true" else (false if literal == "false" else null)
	if character == "-" or _digit(_position): return _number()
	_fail("Expected JSON value")
	return null

func _container(object: bool) -> Variant:
	_position += 1
	var result: Variant = {} if object else []
	var closing := "}" if object else "]"
	_space()
	if _position < _text.length() and _text[_position] == closing:
		_position += 1
		return result
	while _message.is_empty():
		var key := ""
		if object:
			_space()
			if _position >= _text.length() or _text[_position] != '"': _fail("Expected object key"); break
			key = _string()
			_space()
			if _position >= _text.length() or _text[_position] != ":": _fail("Expected colon"); break
			_position += 1
		var value: Variant = _value()
		if object: result[key] = value
		else: result.append(value)
		_space()
		if _position >= _text.length(): _fail("Unclosed JSON container"); break
		if _text[_position] == closing:
			_position += 1
			return result
		if _text[_position] != ",": _fail("Expected comma or closing delimiter"); break
		_position += 1
	return result

func _string() -> String:
	var start := _position
	_position += 1
	var escaped := false
	while _position < _text.length():
		var code := _text.unicode_at(_position)
		if code < 32: _fail("Unescaped control character"); return ""
		if code == 34:
			_position += 1
			if not escaped: return _text.substr(start+1,_position-start-2)
			# Native JSON is used for string escapes only, never numeric values.
			var parser := JSON.new()
			if parser.parse(_text.substr(start,_position-start)) != OK: _fail("Invalid JSON string"); return ""
			return parser.data
		if code == 92:
			escaped = true
			_position += 1
			if _position >= _text.length(): break
			var escape := _text[_position]
			if escape == "u":
				for offset in range(1,5):
					if _position+offset >= _text.length() or _text[_position+offset].to_lower() not in "0123456789abcdef": _fail("Invalid Unicode escape"); return ""
				_position += 4
			elif escape not in ['"',"\\","/","b","f","n","r","t"]: _fail("Invalid string escape"); return ""
		_position += 1
	_fail("Unclosed JSON string")
	return ""

func _digit(position: int) -> bool:
	return position < _text.length() and _text.unicode_at(position) >= 48 and _text.unicode_at(position) <= 57

func _number() -> Variant:
	var start := _position
	if _text[_position] == "-": _position += 1
	if not _digit(_position): _fail("Expected number digit"); return null
	if _text[_position] == "0": _position += 1
	else:
		while _digit(_position): _position += 1
	if _position < _text.length() and _text[_position] == ".":
		_position += 1
		if not _digit(_position): _fail("Expected fractional digit"); return null
		while _digit(_position): _position += 1
	if _position < _text.length() and _text[_position].to_lower() == "e":
		_position += 1
		if _position < _text.length() and _text[_position] in ["+","-"]: _position += 1
		if not _digit(_position): _fail("Expected exponent digit"); return null
		while _digit(_position): _position += 1
	var token := _text.substr(start,_position-start)
	var decimal := _decimal(token)
	var negative := token.begins_with("-")
	if decimal.digits == "0": return _from_bits(SIGN_MASK if negative else 0)
	var order: int = decimal.digits.length() + decimal.exponent
	if order > 309: _fail("Number exceeds finite binary64 range"); return null
	if order < -324: return _from_bits(SIGN_MASK if negative else 0)
	var approximate := absf(token.to_float())
	# A shortest round-trip spelling identifies the correct rounding interval.
	if is_finite(approximate) and _compare(decimal,_decimal(JSON.stringify(approximate,"",true,true))) == 0:
		return -approximate if negative else approximate
	var bits := _bits(approximate) if is_finite(approximate) else MAX_FINITE_BITS
	var found := false
	for attempt in range(8):
		var direction := _rounding_direction(decimal,bits)
		if direction == 0: found = true; break
		if direction > 0 and bits == MAX_FINITE_BITS: _fail("Number exceeds finite binary64 range"); return null
		bits += direction
	if not found:
		# Native conversion may be far off for long/subnormal decimals. Search
		# all finite bit patterns instead of assuming a fixed ULP error bound.
		var low := 0
		var high := MAX_FINITE_BITS
		while low <= high:
			bits = low + (high-low) / 2
			var direction := _rounding_direction(decimal,bits)
			if direction == 0: found = true; break
			if direction < 0: high = bits-1
			else: low = bits+1
	if not found: _fail("Number exceeds finite binary64 range"); return null
	return _from_bits(bits | SIGN_MASK if negative else bits)

static func _decimal(token: String) -> Dictionary:
	var text := token.trim_prefix("-").to_lower()
	var parts := text.split("e")
	var mantissa := parts[0]
	var exponent := 0
	if parts.size() > 1:
		var exp_text: String = parts[1].trim_prefix("+").trim_prefix("-").lstrip("0")
		# Exponents beyond input length cannot be cancelled by mantissa digits.
		var bound := token.length()+2048
		var bound_text := str(bound)
		if exp_text.length() < bound_text.length() or (exp_text.length() == bound_text.length() and exp_text <= bound_text):
			exponent = int(parts[1])
		else:
			exponent = -bound if parts[1].begins_with("-") else bound
	var dot := mantissa.find(".")
	if dot >= 0: exponent -= mantissa.length()-dot-1
	var digits := mantissa.replace(".","").lstrip("0")
	if digits.is_empty(): return {"digits":"0","exponent":0}
	var trimmed := digits.rstrip("0")
	exponent += digits.length()-trimmed.length()
	return {"digits":trimmed,"exponent":exponent}

static func _compare(left: Dictionary, right: Dictionary) -> int:
	if left.digits == "0": return 0 if right.digits == "0" else -1
	if right.digits == "0": return 1
	var left_order: int = left.digits.length()+left.exponent
	var right_order: int = right.digits.length()+right.exponent
	if left_order != right_order: return -1 if left_order < right_order else 1
	var length: int = maxi(left.digits.length(),right.digits.length())
	var a: String = left.digits.rpad(length,"0")
	var b: String = right.digits.rpad(length,"0")
	return 0 if a == b else (-1 if a < b else 1)

static func _rounding_direction(decimal: Dictionary, bits: int) -> int:
	if bits > 0:
		var lower := _compare(decimal,_upper_midpoint(bits-1))
		if lower < 0 or (lower == 0 and (bits & 1) != 0): return -1
	var upper := _compare(decimal,_upper_midpoint(bits))
	if upper > 0 or (upper == 0 and (bits & 1) != 0): return 1
	return 0

static func _upper_midpoint(bits: int) -> Dictionary:
	var encoded_exponent := (bits >> 52) & 2047
	var significand := bits & FRACTION_MASK
	var exponent := -1074
	if encoded_exponent != 0:
		significand |= 1 << 52
		exponent = encoded_exponent-1023-52
	# Upper adjacent spacing remains 2^exponent even at a binade boundary.
	return _binary_decimal(2*significand+1,exponent-1)

static func _binary_decimal(significand: int, exponent: int) -> Dictionary:
	var limbs: Array[int] = [significand % LIMB_BASE, significand / LIMB_BASE]
	var remaining := absi(exponent)
	while remaining > 0:
		var count := mini(remaining,13 if exponent < 0 else 29)
		var factor := 1
		for _index in range(count): factor *= 5 if exponent < 0 else 2
		var carry := 0
		for index in range(limbs.size()):
			var product: int = limbs[index]*factor+carry
			limbs[index] = product % LIMB_BASE
			carry = product / LIMB_BASE
		while carry > 0:
			limbs.append(carry % LIMB_BASE)
			carry /= LIMB_BASE
		remaining -= count
	while limbs.size() > 1 and limbs[-1] == 0: limbs.pop_back()
	var digits := str(limbs[-1])
	for index in range(limbs.size()-2,-1,-1): digits += "%09d" % limbs[index]
	return {"digits":digits,"exponent":mini(exponent,0)}

static func _bits(value: float) -> int:
	var bytes := PackedByteArray()
	bytes.resize(8)
	bytes.encode_double(0,value)
	return bytes.decode_u64(0) & 0x7fffffffffffffff

static func _from_bits(bits: int) -> float:
	var bytes := PackedByteArray()
	bytes.resize(8)
	bytes.encode_u64(0,bits)
	return bytes.decode_double(0)
