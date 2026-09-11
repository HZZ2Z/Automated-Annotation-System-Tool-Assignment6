"""Independent binary64 oracle; Godot production parser never invokes Python."""
from pathlib import Path
import decimal
import json
import math
import os
import random
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def _case(token):
    return {"token": token, "bits": struct.pack("<d", float(token)).hex()}


def _cases():
    values = [0.0, -0.0, 5e-324, 2.2250738585072014e-308,
              1.7976931348623157e308, 7 / 30, 1e-20]
    random_bits = random.Random(40530)
    for _ in range(1200):
        value = struct.unpack("<d", random_bits.getrandbits(64).to_bytes(8, "little"))[0]
        if math.isfinite(value):
            values.append(value)
    result = [_case(repr(value)) for value in values]
    with decimal.localcontext() as context:
        context.prec = 1200
        for value in [0.0, 5e-324, 2.2250738585072014e-308, 0.5, 1.0, 7 / 30, 1e200]:
            following = math.nextafter(value, math.inf)
            midpoint = (decimal.Decimal(value) + decimal.Decimal(following)) / 2
            epsilon = decimal.Decimal(10) ** -1150
            result.extend(_case(str(number)) for number in (midpoint, midpoint + epsilon, midpoint - epsilon))
    random_bits = random.Random(40531)
    for _ in range(10000):
        value = struct.unpack("<d", random_bits.getrandbits(64).to_bytes(8, "little"))[0]
        if math.isfinite(value):
            result.append(_case(repr(value)))
    for _ in range(1000):
        token = ("" if random_bits.randrange(2) else "-") + str(random_bits.randrange(1, 10)) + "."
        token += "".join(str(random_bits.randrange(10)) for _ in range(random_bits.randrange(1, 90)))
        token += "e" + str(random_bits.randrange(-330, 309))
        if math.isfinite(float(token)):
            result.append(_case(token))
    result.extend(_case(token) for token in ["12", "12.0", "12e0", "-0", "-0e99",
                  "1.7976931348623158e308", "2.4703282292062327e-324",
                  "2.4703282292062328e-324", "1e-99999999999999999999999999"])
    return result


def test_godot_exact_json_matches_python_ieee754(tmp_path):
    cases = _cases()
    expected_path, actual_path = tmp_path / "expected.json", tmp_path / "actual.json"
    expected_path.write_text(json.dumps(cases))
    process = subprocess.run(
        [os.environ["GODOT_BIN"], "--headless", "--path", str(ROOT), "--log-file", str(tmp_path / "godot.log"),
         "--script", "tests/godot/test_part4_exact_json.gd", "--", str(expected_path), str(actual_path)],
        cwd=ROOT, text=True, capture_output=True, timeout=120,
    )
    assert process.returncode == 0, process.stdout + process.stderr
    actual = json.loads(actual_path.read_text())
    assert len(actual) == len(cases) == 12230
    for expected, observed in zip(cases, actual):
        assert observed["error"] == 0 and observed["bits"] == expected["bits"], (expected, observed)
