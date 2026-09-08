# Part 4 file handoff agreement

The annotation tool and model team exchange directories. No HTTP API, training
process or weights execution is part of this interface. The model team uses the
same source images; packages do not copy images. `weights_ref`, when present, is
an opaque provenance string and is never opened or executed.

**Tool → model team.** `training_update_v2` includes only frames verified against
their current annotation content, including verified unchanged/negative frames.
Zero coverage and unknown legacy baselines are rejected. `review_export_v1` is a
separate full-source export with honest explicit/annotation/review status. Both
contain `manifest.json`, `data/corrected_annotations.jsonl`, `data/frame_map.jsonl`,
`reports/diff.json`, `reports/diff.csv`, and `reports/summary_by_class.csv`.
The manifest records round/model/taxonomy, media/source/frame identity, baseline
digest, coverage, verification, revision, and each artifact's relative path,
byte length and SHA-256. Package IDs are deterministic content identities;
revision, destination and creation time do not change them. Existing packages
are reused only after validation. A baseline digest identifies provenance; it
cannot authenticate original predictions that the receiver does not possess.

**Annotation meaning.** Every JSONL line remains Model Output V1: pixel-space
box `[x,y,width,height]` or polygon coordinates, stable region IDs and original
six-digit frame IDs, independent of contiguous playback indices. Sample IDs are
`<media_id>_<frame_id:06d>`. Optional annotation `time_s` remains absent when
absent originally; supplied values must exactly match Source. Frame maps retain
Source times. Exported corrected `source` is `human_corrected`; model returns
must use the internal source identity from `manifest.media.source`. Diff counts
unique changed regions, with separate geometry/label/add/delete/attributes events.

**Model team → tool.** A new directory contains a round manifest conforming to
[`model-round-v1.schema.json`](../core/feedback/model-round-v1.schema.json) and
exactly referenced `model_output_v1.jsonl`. Required fields are `schema_version:1`,
`package_type:model_round_v1`, `annotation_schema_version:1`, new `round_id`,
`model_revision`, `parent_package_id`, unchanged `taxonomy_version`, `media`,
complete `source_frame_entries`, and `annotations` with fixed relative `path`,
`bytes`, and `sha256`. Returned records cover **every** source frame exactly once,
even when the parent training package selected only a subset. A second model
round still uses annotation schema V1. Import requires the actual parent training
package directory, validates its artifacts, and matches its media, old round,
baseline, taxonomy and full frame map. Same-round returns are rejected.

**Transaction and legacy binding.** Save the old active V3 first. Preparation
validates the candidate without publishing. Commit revalidates unchanged inputs,
archives exact prior V3 bytes as `label/rounds/<sha256>.json`, then atomically
replaces the active V3. Failures preserve old active data; a valid orphan archive
is harmless. New rounds have independent session identity, revision zero, and
empty verification/batch/undo state. Explicit binding of an unknown legacy
baseline retains corrections/reviews/batches, requires compatible optional time
presence, and atomically increments revision; known baselines cannot be rebound.

**Reviewer CLI.** Source `project_env.sh`, then run `$PROJECT6_PYTHON python/part4.py`:

```text
demo --output NEW_DIRECTORY
export --session V3_JSON --output DIRECTORY [--kind training|review]
validate-package PACKAGE_DIRECTORY
import-round --session V3_JSON --input ROUND_MANIFEST --parent-package PACKAGE_DIRECTORY
```

Each command emits one JSON result on stdout and exits `0` on success or `1` on
failure, with `success` and `errors`. Exports return package path/ID; round imports
return active path, revision and archive path. Validation uses the independent
Python validator. Demo generates 120 synthetic frames, applies eight real edit/
review commands, awaits autosave, reopens, exports both packages, imports an
explicit simulated return and saves `evidence.json`. Training is simulated only.
