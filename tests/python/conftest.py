"""Build package interoperability fixtures when their Python checks are selected."""
from pathlib import Path
import os
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture(scope="session", autouse=True)
def fresh_godot_package_fixtures(request, tmp_path_factory):
    selected = {Path(item.path).name for item in request.session.items}
    suites = []
    if "test_training_package_v2.py" in selected:
        suites.extend(["diff_edges", "package", "package_numbers"])
    if "test_training_package_jsonl.py" in selected:
        suites.append("package_unicode_jsonl")
    if not suites:
        return
    logs = tmp_path_factory.mktemp("godot-package-fixtures")
    for name in suites:
        process = subprocess.run(
            [os.environ["GODOT_BIN"], "--headless", "--path", str(ROOT),
             "--log-file", str(logs / f"{name}.godot.log"),
             "--script", f"tests/godot/test_part4_{name}.gd"],
            cwd=ROOT, capture_output=True, text=True, timeout=120,
        )
        output = process.stdout + process.stderr
        (logs / f"{name}.log").write_text(output)
        assert process.returncode == 0 and "SCRIPT ERROR:" not in output, output
