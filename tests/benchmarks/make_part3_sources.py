"""Create temporary 640x360 playback and 10k-frame stress sources for Part 3.1."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil


ROOT = Path(__file__).resolve().parents[2]
SAMPLE = ROOT / "sample" / "assignment_v1"


def _link_or_copy(source: Path, target: Path) -> None:
    try:
        os.link(source, target)
    except OSError:
        shutil.copyfile(source, target)


def _digest(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def make_playback_source(output: Path, frame_count: int = 360) -> None:
    if output.exists():
        raise FileExistsError(f"output already exists: {output}")
    sample_manifest = json.loads((SAMPLE / "manifest.json").read_text(encoding="utf-8"))
    sample_records = [
        json.loads(line)
        for line in (SAMPLE / "model_output_v1.jsonl").read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    output.mkdir(parents=True)
    frames_dir = output / "frames"
    frames_dir.mkdir()
    fps = 30.0
    entries: list[dict[str, object]] = []
    records: list[dict[str, object]] = []
    for index in range(frame_count):
        sample_index = index % len(sample_records)
        relative = f"frames/frame_{index:06d}.png"
        _link_or_copy(SAMPLE / "frames" / f"frame_{sample_index:06d}.png", output / relative)
        entries.append({"frame": index, "time_s": index / fps, "image_path": relative})
        record = json.loads(json.dumps(sample_records[sample_index]))
        record["source"] = "part3_playback.mp4"
        record["frame"] = index
        record["time_s"] = index / fps
        records.append(record)
    manifest = {
        "schema_version": 1,
        "dataset_id": "part3-playback-360",
        "source_name": "part3_playback.mp4",
        "source_sha256": _digest("part3-playback-360"),
        "width": int(sample_manifest["width"]),
        "height": int(sample_manifest["height"]),
        "frame_count": frame_count,
        "nominal_fps": fps,
        "frames": entries,
        "model_version": "model_output_v1",
        "taxonomy_version": str(sample_manifest["taxonomy_version"]),
    }
    (output / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (output / "model_output_v1.jsonl").write_text(
        "".join(json.dumps(record, sort_keys=True) + "\n" for record in records),
        encoding="utf-8",
    )


def make_stress_source(output: Path, frame_count: int = 10_000) -> None:
    if output.exists():
        raise FileExistsError(f"output already exists: {output}")
    sample_manifest = json.loads((SAMPLE / "manifest.json").read_text(encoding="utf-8"))
    source_frame = SAMPLE / "frames" / "frame_000000.png"
    output.mkdir(parents=True)
    frames_dir = output / "frames"
    frames_dir.mkdir()
    fps = 30.0
    entries: list[dict[str, object]] = []
    for index in range(frame_count):
        relative = f"frames/frame_{index:06d}.png"
        _link_or_copy(source_frame, output / relative)
        entries.append({"frame": index, "time_s": index / fps, "image_path": relative})
    manifest = {
        "schema_version": 1,
        "dataset_id": "part3-stress-10000",
        "source_name": "part3_stress.mp4",
        "source_sha256": _digest("part3-stress-10000"),
        "width": int(sample_manifest["width"]),
        "height": int(sample_manifest["height"]),
        "frame_count": frame_count,
        "nominal_fps": fps,
        "frames": entries,
        "model_version": "none",
        "taxonomy_version": "none",
    }
    (output / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--playback-output", type=Path, required=True)
    parser.add_argument("--stress-output", type=Path, required=True)
    args = parser.parse_args()
    make_playback_source(args.playback_output)
    make_stress_source(args.stress_output)
    print(args.playback_output)
    print(args.stress_output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
