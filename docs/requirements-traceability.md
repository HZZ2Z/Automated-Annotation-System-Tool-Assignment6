# Requirements Traceability

This ledger separates teacher requirements from implementation evidence. A `PASS` row has direct automated evidence already exercised; `BLOCKED` means a required environment or manual acceptance gate is still outstanding. No later-part feature is claimed by Part 1.

| Requirement source | Requirement | Implementation | Automated evidence | Manual evidence | Status | Next task |
|---|---|---|---|---|---|---|
| Part 1.1 Data contract | Versioned per-image schema with frame/source, optional time, image size, and regions | `core/schemas/annotation-v1.schema.json` | `tests/python/test_contracts.py`; `tests/godot/test_annotation_validator.gd` | Schema reviewed against assignment example | PASS | Done |
| Part 1.1 | Python validator | `python/validate_annotations.py`; `python/annotool/contracts.py` | `tests/python/test_contracts.py` | CLI included in README | PASS | Done |
| Part 1.1 | Godot validator with readable refusal | `client/domain/annotation_validator.gd` | `tests/godot/test_annotation_validator.gd`; invalid-command tests | Status-bar handling remains visible in client | PASS | Done |
| Part 1.1 | Contract version 1 and immutable model_output_vX baseline | `AnnotationStore` keeps model and corrected copies | `tests/godot/test_annotation_store.gd` | Architecture ownership section | PASS | Done |
| Part 1.2 Reproducible sample | Fixed-seed synthetic image sequence and matching annotations | `python/make_sample_input.py`; `python/annotool/sample.py` | `tests/python/test_sample.py::test_sample_is_deterministic` | Reviewer command documented | PASS | Done |
| Part 1.2 defects | Drifted regions | Seed 6006 frames 12 and 13 | `test_sample_contains_required_defects` | `expected_defects.json` after generation | PASS | Done |
| Part 1.2 defects | Wrong class labels | Seed 6006 frame 24 | `test_sample_contains_required_defects` | `expected_defects.json` after generation | PASS | Done |
| Part 1.2 defects | Missed region | Planted sample defect | `test_sample_contains_required_defects` | `expected_defects.json` after generation | PASS | Done |
| Part 1.2 defects | Hallucinated region | Planted sample defect | `test_sample_contains_required_defects` | `expected_defects.json` after generation | PASS | Done |
| Part 1.2 defects | Track-id swap | Planted sample defect | `test_sample_contains_required_defects` | `expected_defects.json` after generation | PASS | Done |
| Part 1.2 sequence | Near-identical frames for later batching | Fixed run 40–59 and similarity scores | `test_similar_run_is_near_identical_with_distinguishable_boundaries` | Timeline review pending later batch work | PASS | Done |
| Part 1.3 Frame source | Decode any FFmpeg-readable video to indexed frames | `python/frame_source.py`; `python/annotool/frame_source.py` | Full Python gate: 70 passed, 0 skipped with FFmpeg/FFprobe 6.1.2 | Three-frame and multi-stream lossless videos decoded in integration tests | PASS | Done |
| Part 1.3 | Treat video, sequence, and standalone image uniformly as indexed frames | `image_sequence_source`; `single_image_source`; manifest contract | `test_source_plugin.gd`; `test_single_image_source.gd`; `test_playback.gd` | 1280x800 acceptance opened standalone PNG then normalized 120-frame directory | PASS | Done |
| Part 1.4 Source stage | Working normalized-directory and direct-image plugins | `client/plugins/source` | Source and single-image plugin tests | Both source routes displayed successfully in acceptance client | PASS | Done |
| Part 1.4 Render stage | Working swappable renderer | `canvas_region_renderer` | `test_renderer.gd`; viewport integration tests | Sample regions, labels, confidence, and selected outline rendered | PASS | Done |
| Part 1.4 Edit tools stage | Working explicit Edit plugin boundary | `basic_edit_tools` | command, keyboard, ToolPanel, and integration tests | Five implemented tools remain visibly separate from seven reserved controls | PASS | Done |
| Part 1.4 Export / Feedback stage | Working validated corrected JSONL plugin | `file_training_handoff` | `test_feedback_plugin.gd` | UI Export remains disabled by Part 1 boundary | PASS | Task 12 later integrates full UI package |
| Part 1.4 Plugin registry | Directory discovery, API checks, error isolation | `client/pipeline/plugin_registry.gd` | `test_plugin_registry.gd`; frontend discovery test | Four stages listed in README | PASS | Done |
| Part 1 deliverable | Plugin API document | `docs/plugin-api.md` | `tests/python/test_documentation.py` | Interface signatures reviewed against code | PASS | Done |
| Part 1 deliverable | Architecture diagram | `docs/architecture.md` | `tests/python/test_documentation.py` | Mermaid source is reviewer-readable | PASS | Done |
| Part 1 deliverable | README runbook, versions, commands, reviewer path, shortcuts | `README.md` | `tests/python/test_documentation.py` | Documented sample, validation, tests, and opening path reproduced on reference host | PASS | Done |
| Part 1 verification | Zero-error sample validation | Generator and two validators | Seed 6006 generated 120 records and 120 frames; both schema commands exited 0 | Generator printed `Validation errors: 0` | PASS | Done |
| Approved frontend layout | Left pane is a read-only explorer for only the active accepted dataset; center remains the real viewport | `DatasetExplorer`; `WorkspaceSplit`; `AnnotationViewport` | `test_dataset_explorer.gd`; `test_main_boundaries.gd`; `test_playback.gd` | 1280x800 single-image render showed the real image, `Frames (1)`, no invented metadata, and a visible center image; normalized render showed `Frames (120)` | PASS | Done |
| Approved frontend layout | Scrollable region Inspector sits above one fixed, flat, uncategorized four-column palette with twelve readable icon/label slots | `InspectorScroll`; `ToolPanel` | `test_frontend_structure.gd`; `test_tool_panel.gd` | 1280x800 single-image and normalized renders showed the Inspector scrollbar and all twelve icons and labels, with labels using at most two lines | PASS | Done |
| Approved tool inventory | Exactly Add Box, Fill, Erase, Selection, and Move / Resize are functional; Subtract, Lasso, Close, Paint, Wipe, Region Growing, and Live Wire are unavailable controls | `ToolPanel.TOOL_DEFINITIONS`; existing `basic_edit_tools` route; UI unavailable signal | `test_tool_panel.gd` checks all twelve positions, five functional routes, and seven unavailable routes; `test_playback.gd` checks non-mutation | The rendered palette showed all twelve slots; a GUI script activated Subtract and the status rendered exactly `待开发` | PASS | Done |
| Approved navigation safety | Explorer, timeline, previous/next, playback, and direct seek converge on one frame highlight; rejected navigation or replacement preserves accepted state | `AnnotationMain` accepted-source view model and one-way explorer synchronization | `test_playback.gd`; `test_main_boundaries.gd`; `test_dataset_explorer.gd` | Normalized render showed accepted frame zero and matching timeline state; interaction and failure preservation are automated evidence, not a claimed manual click-through | PASS | Done |
| Approved resize boundary | Both side panes resize without introducing docking or file-management behavior | Nested `WorkspaceSplit` and `ContentSplit` only | `test_frontend_structure.gd` | Render session set split offsets to 250 and 660; the center remained usable and no docking or file-management UI appeared | PASS | Done |
| Change compatibility | Layout change supersedes only the earlier left-tool placement; plugin API v1 and Part 1 contracts remain unchanged | UI composition, explorer coordination, and palette presentation only | Complete Godot and Python regressions; implementation diff contains no plugin API, schema, store, history, renderer, source-plugin, or Python changes | Existing Part 1 reviewer behavior remains available through the new composition | PASS | Done |
| Change verification 2026-09-03 | Complete Godot, Python, and static gates | Repository-wide test runners and static checks | Godot exit 0 with final line `PASS: complete Godot test suite` and no `SCRIPT ERROR`; Python `70 passed`; `git diff --check` clean; old `MainVBox/Workspace/` search had no matches | Real 1280x800 rendering used Godot 4.7.2 with X11 / GL Compatibility; expected corrupt-image fixture diagnostics are not product failures | PASS | Done |
| Part 2 | Region display and MITK-style editing acceptance, design note, and measurement | Existing primitives are unclaimed integration scaffolding | Not evaluated as a complete Part 2 gate | Not evaluated | BLOCKED | Explicit approval after Part 1 |
| Part 3 | Frame-accurate stream and batch labelling workflow | Out of Part 1 scope | Not evaluated | Not evaluated | BLOCKED | Task 10 |
| Part 4 | Autosave, diff, update package, and collaboration agreement | Out of Part 1 scope | Not evaluated | Not evaluated | BLOCKED | Tasks 11–12 |
| Part 5 | Full robustness, smoke session, measurements, and failure analysis | Out of Part 1 scope | Not evaluated | Not evaluated | BLOCKED | Tasks 13–14 |

## Evidence boundary for the 2026-09-03 layout acceptance

- **Real rendering observations:** the 1280x800 single-image and normalized-dataset sessions showed
  the accepted explorer content, usable central viewport, scrollable Inspector, fixed twelve-slot
  palette, readable icons/labels, real artifact list, split resizing, and rendered `待开发` result
  for a scripted Subtract activation.
- **Automated interaction evidence:** `test_tool_panel.gd` exercises all five functional routes and
  all seven unavailable routes. `test_playback.gd` covers exact `待开发`, active-tool/selection/
  annotation/gesture/history preservation, explorer navigation, timeline and playback agreement,
  direct seek, and failed replacement atomicity.
- No manual claim is made that a reviewer clicked every reserved control, every navigation path, or
  the invalid replacement case during the rendered session. Those behaviors are supported by the
  named automated tests.
