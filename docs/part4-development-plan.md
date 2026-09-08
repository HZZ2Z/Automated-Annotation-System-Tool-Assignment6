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

## Delivery checklist (2026-09-08)

- [x] P4-1: baseline/correction/verification ownership, immutable snapshots, V3 and exact legacy backup; store and cross-language codec gates.
- [x] P4-2: one background writer, coalesced revisions, deadline, external-write rejection, failures and old/new crash recovery; Save and lifecycle integration.
- [x] P4-3: final ID-based JSON/CSV audit and class aggregation; numeric, order, undo and empty/unknown-baseline boundaries.
- [x] P4-4: verified-only and all-frame package contracts, frame maps, shared semantic validation, independent Python verification, deterministic publication/reuse and CLI/UI parity.
- [x] P4-5: export preview/progress/cancellation/results, batch persistence waits, validated independent round/archive switch, four production CLI commands and 30fps synthetic loop.
- [x] P4-6: fresh full regressions,27 focused behavioral suites,4 crash boundaries, measured120/10,000-frame workloads, rendered UI, exported runtime schemas, interface agreement and reviewer runbook.

Evidence and measured limitations are recorded in `RESULTS.md`. The implementation
and review-fix waves have independent code review; one integrated review also
caught legal Unicode JSONL separators being split incorrectly by Python. The
LF-specific reader and actual Godot→Python regression close that discrepancy.
Post-integration editor checks additionally isolate generated CSV reports from
Godot resource imports; strict package bytes survive editor rescans, and JSON-only
round archives remain supported inside project datasets.
Large-session memory and latency tails remain explicit performance follow-up
items. Real training and real-video annotation accuracy are outside Part4 scope.
