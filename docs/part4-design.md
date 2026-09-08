# Part 4: Persistence, Audit and Training Feedback

Approved 2026-09-08. Assignment Part 4 is the requirements authority.

## Goal and scope

Load an immutable model baseline, edit and verify annotations, autosave safely,
export corrected annotations and an audit, hand a versioned file package to the
model team, and ingest a new independent model round. Implement CLI and UI paths.
The training package includes only content-verified frames. A separate full review
export includes every source frame with explicit annotation/verification flags.
No HTTP service, real training, weights execution, COCO, thumbnails, multiple
media per package, concurrent writers, or automatic carry-over of old corrections.

## Binding requirements

- Preserve Model Output V1, original input files, sparse original frame IDs, source
  timestamps (including absence), and sample IDs `<media_id>_<frame_id:06d>`.
  The source frame map may provide a timestamp even when a V1 annotation omits
  its optional `time_s`. Keep that annotation omission; when an annotation does
  provide a timestamp, it must exactly match its source frame.
- Persist and export corrected records with `source: human_corrected`; restore the
  internal source identity through one codec so content verification survives reopen.
- Baseline, corrected data, persisted revision, and content verification are separate.
  Reopening corrections MUST NOT make them the model baseline.
- Media Label V3 atomically owns baseline/provenance, corrected records, frame map,
  revision, round metadata, explicit frame coverage, review state, and batch markers.
  Read V1/V2; preserve an exact backup before migration. Legacy baseline is unknown
  until explicitly bound. Empty/imported-label origins must not be called model output.
- Workspace paths remain nearest dataset root `label/<media_id>.json`; direct Source
  paths get deterministic user sessions. Do not overwrite source datasets or caches.
- Autosave after 300 ms idle, request at least every 2 s under continuous edits;
  one active writer and latest pending snapshot. Temp sibling -> flush/close ->
  validate -> atomic rename. Reject external file changes. Failure preserves old
  disk bytes and dirty memory. Session ID/revision guard delayed completion.
- All new persistence/export/round IO, serialization, hashing, and validation run
  outside the active SceneTree/main thread. Snapshot records are immutable once
  published; workers do not use live Store, Nodes, textures, or mutable UI objects.
- Save button/Ctrl+S and unsaved lifecycle guard: Save and continue / Discard only
  unsaved changes / Cancel. In-flight writes settle asynchronously before discard.
  Drafts are not silently committed. Exit handling precedes `_exit_tree()`.
- Batch verification auto-advance awaits successful persistence and a current token.
- Diff is final baseline-vs-corrected, paired by frame and region ID. Added, deleted,
  label_changed, geometry_changed, attributes_changed (kind/track_id/conf). Source
  projection and filled are ignored. Numeric 12 == 12.0, no coordinate tolerance.
  Region order is irrelevant; ID change is delete+add. Count unique changed regions.
  Per-class additions use new class, deletions old, relabel out/in, geometry and
  attributes final class. JSON before/after, CSV events and class summary.
- Training coverage = all verified current-content frames, including unchanged and
  verified negative frames. Never include unreviewed empties; reject zero coverage.
  Full review exports label unannotated and unverified frames honestly.
- Package directory `training_update_v2_<media_id>_<round_id>_<id12>` or separate
  `review_export_v1_...`. Files: manifest.json, data/corrected_annotations.jsonl,
  data/frame_map.jsonl, reports/diff.json, reports/diff.csv,
  reports/summary_by_class.csv. Unknown baseline review exports report unavailable
  audit explicitly; training export refuses an unknown baseline.
- Manifest identifies tool/package/schema versions, round/model/taxonomy, media,
  baseline digest, source hash (nullable), revision, total/included/excluded original
  frames, verification and batch provenance, artifact byte sizes and SHA-256.
  All artifacts derive from one snapshot. Deterministic package ID excludes path,
  timestamp and transient revision; same content reuses only a validated existing
  package. Never overwrite a conflicting destination. Publish atomically.
- Model round return includes round manifest, complete model_output_v1.jsonl,
  parent package ID, round ID/model revision, media/frame identity, taxonomy,
  file bytes/hash; weights ref optional. A second model round is NOT schema V2.
  Validate candidate before archiving old round and atomically publishing the new
  active session. Clear review, batch, undo in new round. Failure preserves old state.
- Keep Plugin API V1 export(context); add optional training_update_v2 capability.
  UI/CLI share production business modules. Demo uses real command classes,
  autosave, reopen and independent validation, not prebuilt success output.

## Locked internal snapshot interface

`AnnotationStore.freeze_snapshot() -> Dictionary` returns a detached immutable
snapshot with `schema_version: 1`, `session_id`, `media_id`, `media_type`,
`source_relative_path`, `source` (internal source identity), `source_sha256`,
`round_id`, `model_revision`, `taxonomy_version`, `revision`, `baseline_kind`
(`model|imported_labels|empty|unknown`), `baseline_digest`, `baseline_records`
(Array of original records), `records` (Array of internal corrected records),
`frame_entries` (ordered Source entries with original `frame_id` and playback
`frame`), `explicit_frames` (original IDs), `review_state`, `batch_operations`.
Optional `source_root` is local-only; do not publish absolute host paths.

`configure_session(context: Dictionary)` supplies session metadata without changing
baseline data. `restore_corrected(records, review_state, batch_operations)` validates
an exact complete frame set before atomic restoration without changing baseline.
`current_revision()` returns the committed edit/review revision. Loading a persisted
session restores its revision without treating restoration as a new edit.

`ReviewSessionCodec.encode(snapshot) -> Dictionary` produces V3;
`ReviewSessionCodec.decode(payload) -> Dictionary` returns `{snapshot, errors}`.
V3 includes the snapshot metadata, `frames` map in human_corrected projection,
baseline_records unchanged, review/batch state, and frame_entries. `frames` contains
explicit frames only; absent frames are reconstructed from baseline/empty display
records. Consumers must additionally verify expected media/source/frame identity.

`AnnotationDiff.build_diff(snapshot, frame_ids: Array) -> Dictionary` returns
`{schema_version:1, available:bool, frames:Array, summary:Dictionary, by_class:Array}`.
Each frame has frame ID, events and category counts. Each event has region_id,
type and before/after region (null when absent). Summary has source frame coverage,
changed_frames, changed_regions and the five category counts.

`TrainingPackage.export_package(snapshot, options) -> Dictionary` options include
output_parent and kind (`training_update_v2|review_export_v1`); result has success,
errors, output_path, package_id, revision and cancelled. Export workers can accept
a cancellation/progress callable that does not touch the SceneTree.

## Acceptance

Demo corrections on frames 12,13,24,36,72,90: geometry=2, label=1, added=1,
deleted=1, attributes=2; 6 changed frames and 7 changed regions. Verify those 6:
training coverage 6/120, exclusion 114, review export 120. Reopen preserves
baseline/diff/verification/content identity. Cover sparse IDs, empty/unchanged
verified frames, reorder/undo, malformed records, IO failures, stale completions,
V1/V2 migration, external modifications, package corruption and round mismatch.
Crash injection at writing/validated/before-and-after rename must restore complete
old or new data only. Standard sample autosave completion p95 <= 1 s; 10,000 x
20-region source input response p95 <= 100 ms; injected 2 s IO remains responsive.
Measure snapshot/save/diff/publish/UI separately, do not claim unmeasured gates.

## Deliverables

Design, execution checklist, one-page interface agreement, production CLI demo,
UI reviewer script, independent validator, regression/fault/performance evidence,
README/RESULTS/traceability updates. Local tests/output/tmp are retained and not
force-added to Git. Demonstration commands cannot depend on ignored test files.
