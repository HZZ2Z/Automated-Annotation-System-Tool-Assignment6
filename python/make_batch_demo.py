"""Create a separate, reproducible batch-review workspace from assignment_v1."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import shutil


def make_demo(source: Path, output: Path) -> dict:
    source, output = source.resolve(), output.resolve()
    if output.exists():
        raise ValueError("Output already exists; choose a new workspace directory")
    if source == output or source in output.parents:
        raise ValueError("Output must be outside the original sample")
    raw = (source / "model_output_v1.jsonl").read_bytes()
    records = [json.loads(line) for line in raw.splitlines() if line]
    if len(records) != 120 or any(records[i]["frame"] != i for i in range(120)):
        raise ValueError("Expected the 120-frame assignment_v1 sample")
    truth = {str(i): copy.deepcopy(records[i]["regions"][0]) for i in range(40, 60)}
    for i in range(40, 60):
        region = records[i]["regions"][0]
        region["class"] = "batch_demo_wrong"
        if "box" in region:
            region["box"][0] += 8
    clip = output / "batch_clip"
    shutil.copytree(source, clip, ignore=shutil.ignore_patterns("hashes.json", "expected_defects.json", "label"))
    (clip / "model_output_v1.jsonl").write_text(
        "".join(json.dumps(record) + "\n" for record in records), encoding="utf-8")
    evidence = {
        "source_annotations_sha256": hashlib.sha256(raw).hexdigest(),
        "defect": "First region: class batch_demo_wrong; box x +8 on frames 40-59",
        "keyframe": 50, "start": 40, "end": 59, "truth_regions": truth,
    }
    (output / "batch_demo_truth.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    return evidence


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("sample/assignment_v1"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    make_demo(args.source, args.output)
    print(f"Open workspace: {args.output.resolve()}; select batch_clip, correct frame 50.")
