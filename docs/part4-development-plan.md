# Part 4 Implementation Plan

Spec: docs/part4-design.md (approved user plan, 2026-09-08).

## Global Constraints

Preserve Model Output V1 and local datasets. Corrected disk records use
human_corrected. One media per package; verified-only training; independent new
rounds. Keep Plugin API V1, add an optional V2 capability. No IO on UI thread.
Tests remain local per repository policy. Use TDD and requirement-level evidence.

### Task 1: Store and session contract

- Extend AnnotationStore with session metadata, committed revision, atomic corrected
  restoration and immutable freeze_snapshot per the design interface.
- Add client/workspace/review_session_codec.gd and Media Label V3 schema; strict
  baseline/corrected/frame/workflow validation, human_corrected round-trip preserving
  internal source and explicit/negative frame distinctions.
- Add Python schema/semantic support and Godot/Python behavioral contract tests.
- Do not change Main, WorkspaceSession, MediaLabelStore, Feedback plugin or UI.
- Acceptance: raw baseline remains unchanged through correction/round-trip;
  malformed restoration is atomic; verification survives source projection.

### Task 2: Persistence integration

- Add background atomic snapshot writer and adapt MediaLabelStore/WorkspaceSession
  for V3, migration backups, revision/coalescing, stale completions and external edit
  detection. Preserve old disk on failures; source/direct session integration follows.
- Cover slow IO, new edits during writes, timer deadline and failed migration.

### Task 3: Diff and package

- Add pure AnnotationDiff and TrainingPackage services, optional plugin capability,
  schema contracts, independent Python validator and tests.
- Follow package/diff conventions in the design; no Main/UI edits in this task.

### Task 4: UI, source and lifecycle

- Bind baseline and corrected separately for workspace/direct source; migrate legacy
  conservatively; deterministic user storage for direct sources.
- Save/Ctrl+S/status, asynchronous unsaved close/switch guard, export dialog/progress,
  snapshot gate and result links; batch save/verification auto-advance integration.
- No main-thread persistence/export serialization or IO; immutable jobs and tokens.

### Task 5: Model rounds and CLI

- Validate model round contract/media/frame/taxonomy/parent/checksum; archive old
  round and atomic active-session switch, reset verification/batch/history.
- UI round preview and import; CLI demo/export/validate-package/import-round share
  production modules. Script demo real edits and wait autosave/reopen/export/import.

### Task 6: Whole-loop validation and documentation

- Add crash-process/fault tests and measurable UI autosave/export benchmarks.
- Run existing Python/Godot and batch gates; independently verify package/diff.
- Complete one-page interface agreement, README reviewer steps, RESULTS evidence,
  requirements traceability; review changes before delivery.
