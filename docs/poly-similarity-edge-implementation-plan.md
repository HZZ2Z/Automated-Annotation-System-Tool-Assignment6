# Poly Similarity and Edge Propagation Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 使 Batch 默认先在同一组冻结 PNG 上执行相邻+关键帧相似度门，再用 DIS 光流传播 Poly，并仅在安全且边缘对齐有可测改善时接受局部 GrabCut 精修；候选仍由人工预览/确认。

**Architecture:** `PolygonPropagationService` 一次冻结 Source、图像、Store 和 review 摘要，`propagate_polygons.py` 在这些准确快照上依次运行 `gray64-area-mad-v1 -> DIS raw flow -> bounded edge refinement -> final topology/evidence gates`。Provider 返回只读 proposal 与有界诊断，`BatchController` 生成 overwrite/merge 预览，`ApplyPropagationCommand` 用 v2 marker 一次提交。

**Tech Stack:** Python 3.14 project `.venv`, NumPy, OpenCV DIS/GrabCut/Sobel, Godot 4.7.2 / GDScript, pytest, local Endoscapes2023.

**Approved design:** `docs/model-assist-poly-edge-design.md`

**Execution order:** Complete this plan before the model-assist plan's real-SAM environment task. It uses only the existing project environment and produces the default Batch path independently of SAM.

---

## Task 1: Make focused Godot tests fail honestly

**Files:**
- Modify: `tests/godot/test_polygon_batch_ui.gd`
- Create: `tests/check_godot_log.sh`
- Modify: `tests/run_tests.sh`

- [ ] **Step 1: Reproduce the current false positive**

Run:

```bash
source project_env.sh
"$GODOT_BIN" --headless --log-file /tmp/poly-ui-before.log --path . --script tests/godot/test_polygon_batch_ui.gd
rg -n "SCRIPT ERROR|Invalid access.*_polygon|PASS" /tmp/poly-ui-before.log
```

Expected: exit 0/PASS can coexist with `SCRIPT ERROR` because the test accesses the removed private `_polygon` field.

- [ ] **Step 2: Fix the fixture seam, not production visibility**

Access `workflow.controller._providers[&"polygon_flow"].service.job_root` through a typed test helper (or inject a provider) rather than resurrecting `_polygon`. Ensure an exception records a `TestSupport` failure and prevents the PASS branch.

- [ ] **Step 3: Add an authoritative log gate**

Implement:

```bash
#!/usr/bin/env bash
set -euo pipefail
log_path="$1"
if rg -n 'SCRIPT ERROR|Unhandled exception|ERROR:' "$log_path"; then
    printf '%s\n' "Unexpected Godot error output" >&2
    exit 1
fi
```

Allow only exact, documented corrupt-fixture messages via anchored filters at the call site; never broadly ignore `ERROR:`.

- [ ] **Step 4: Run GREEN and commit**

Run: `source project_env.sh && "$GODOT_BIN" --headless --log-file /tmp/poly-ui-fixed.log --path . --script tests/godot/test_polygon_batch_ui.gd && tests/check_godot_log.sh /tmp/poly-ui-fixed.log`

Commit: `git commit -m "test: fail polygon ui gate on script errors"`

## Task 2: Put gray64 adjacent/keyframe similarity in the Python snapshot worker

**Files:**
- Modify: `python/annotation_data/similarity.py`
- Modify: `python/annotation_data/polygon_propagation.py`
- Modify: `tests/python/test_similarity.py`
- Modify: `tests/python/test_polygon_propagation.py`

- [ ] **Step 1: Write RED tests for exact gate semantics**

Cover BGR/BGRA/grayscale conversion, `INTER_AREA` 64x64, `uint8` difference divided by 255, threshold equality rejection, both `adjacent_mad < threshold` and `keyframe_mad < threshold`, directional stopping, and proof that a gated-out frame never constructs `MotionPair` or invokes edge refinement.

Use a seam to count calls:

```python
result = propagate(request, motion_factory=counting_motion,
                   edge_refiner=counting_refiner)
assert result["right_stop"].startswith("frame 3: similarity")
assert motion_calls == [1, 2]
assert edge_calls == [1, 2]
```

- [ ] **Step 2: Run RED**

Run: `.venv/bin/python -m pytest tests/python/test_similarity.py tests/python/test_polygon_propagation.py -q`

- [ ] **Step 3: Separate similarity threshold from flow-quality threshold**

Add:

```python
def gray64_area_mad(left: np.ndarray, right: np.ndarray) -> float: ...
def similarity_gate(previous, target, anchor, threshold: float) -> dict[str, float]: ...
```

Request schema v2 carries `similarity_threshold`; internal `FLOW_QUALITY_THRESHOLD = 0.65` stays algorithm-versioned and is not controlled by the UI. Result `threshold` always means the user-visible similarity threshold. Compute and store `adjacent_mad` and `keyframe_mad` before creating any flow object.

- [ ] **Step 4: Preserve directional continuity**

When either MAD is equal to or above the threshold, stop that direction at the prior accepted frame. Return a bounded stop string with both scores and threshold. Do not skip or reuse an image from the other direction.

- [ ] **Step 5: Run GREEN and commit**

Run: `.venv/bin/python -m pytest tests/python/test_similarity.py tests/python/test_polygon_propagation.py -q`

Commit: `git commit -m "feat: gate polygon flow on frozen-frame similarity"`

## Task 3: Implement bounded edge refinement as a pure Python stage

**Files:**
- Create: `python/annotation_data/polygon_edge_refinement.py`
- Create: `tests/python/test_polygon_edge_refinement.py`

- [ ] **Step 1: Write RED mask-level tests**

Construct independent synthetic images/masks for: accepted boundary shift toward a strong edge, weak edge, eroded-away thin target, multiple components, hole, ROI touching crop boundary, raw/refined IoU below 0.85, area ratio outside `[0.80,1.25]`, Hausdorff above 6 analysis pixels, edge gain below 0.01, and injected `cv2.error`.

Assert expected refusals return `accepted=False` with finite scores, while OpenCV runtime errors raise and abort the caller.

- [ ] **Step 2: Run RED**

Run: `.venv/bin/python -m pytest tests/python/test_polygon_edge_refinement.py -q`

- [ ] **Step 3: Implement the narrow-band seeds**

Public contract:

```python
@dataclass(frozen=True)
class EdgeRefinement:
    accepted: bool
    mask: np.ndarray
    reason: str
    scores: dict[str, float]

def refine(image: np.ndarray, raw_mask: np.ndarray, *,
           band_radius: int = 6, roi_padding: int = 8) -> EdgeRefinement: ...
```

Use an ellipse kernel radius 6. Set eroded core to `GC_FGD`, raw inner band to `GC_PR_FGD`, outer band to `GC_PR_BGD`, and pixels outside dilation but inside the padded/clipped ROI to `GC_BGD`. Reject expected seed/ROI deficiencies before `cv2.grabCut(..., mode=cv2.GC_INIT_WITH_MASK, iterCount=3)`.

- [ ] **Step 4: Implement deterministic acceptance metrics**

Use one-pixel morphological boundaries. Normalize Sobel magnitude by `4 * sqrt(2) * 255`, clip to `[0,1]`, and compare mean boundary samples. Compute symmetric Hausdorff from Euclidean distance transforms. Validate one component, no holes, no crop-boundary contact, raw IoU/area/Hausdorff/edge gain in that order so reasons remain stable.

- [ ] **Step 5: Run GREEN and commit**

Run: `.venv/bin/python -m pytest tests/python/test_polygon_edge_refinement.py -q`

Commit: `git commit -m "feat: add bounded polygon edge refinement"`

## Task 4: Compose flow, edge refinement, anchor checks, and diagnostics

**Files:**
- Modify: `python/annotation_data/polygon_propagation.py`
- Modify: `python/annotation_data/polygon_geometry.py`
- Modify: `tests/python/test_polygon_propagation.py`
- Modify: `tests/python/polygon_fixtures.py`
- Modify: `tests/python/polygon_benchmark.py`

- [ ] **Step 1: Write RED end-to-end algorithm tests**

Add translated boundary-offset, rotation, nonrigid deformation, occlusion, weak-texture and unsafe-topology sequences. Compare raw-flow and final IoU against fixture truth. Require at least one deterministic boundary-offset case where `final_iou > raw_iou` and edge gain is accepted; unsafe cases must either stop or retain the exact raw-flow candidate with a fallback reason.

- [ ] **Step 2: Integrate refinement after the raw-flow safety gate**

For each region and for both adjacent propagation and keyframe-direct anchor masks:

```python
raw_mask, flow_quality = ...
edge = refine(target, raw_mask)
candidate = edge.mask if edge.accepted else raw_mask
final_quality = rerun_evidence_and_topology(candidate)
```

Only expected `EdgeRefinement(accepted=False, ...)` falls back. Decode errors, `cv2.error`, non-finite scores and protocol faults abort the whole plan.

- [ ] **Step 3: Propagate the accepted seed only**

Accepted refined mask becomes the next adjacent seed; fallback raw mask becomes the seed. Run the area, local evidence, fixed-anchor IoU and final single-ring conversion again after selection. Stop the entire direction when any reference Poly cannot pass.

- [ ] **Step 4: Version and bound result diagnostics**

Set `METRIC_ID = "poly-sim-flow-edge-v1"`. Per target/region emit finite `raw_flow`, `edge.attempted/accepted/reason/raw_edge_score/refined_edge_score/raw_iou/area_ratio/hausdorff`, and final anchor/area/evidence fields. Never emit masks, flow arrays, image paths, or unbounded exception text.

- [ ] **Step 5: Run tests and benchmark**

Run:

```bash
.venv/bin/python -m pytest tests/python/test_similarity.py tests/python/test_polygon_edge_refinement.py tests/python/test_polygon_propagation.py -q
.venv/bin/python tests/python/polygon_benchmark.py --output /tmp/poly-edge-benchmark.json
```

Expected: all tests pass; benchmark JSON separately reports raw/final IoU, accepted/fallback counts and stop reasons for every fixture.

- [ ] **Step 6: Commit**

Commit: `git commit -m "feat: refine propagated polygons near image edges"`

## Task 5: Upgrade the snapshot/service protocol and stale protection

**Files:**
- Modify: `client/services/polygon_propagation_service.gd`
- Modify: `client/services/poly_batch_provider.gd`
- Modify: `python/propagate_polygons.py`
- Modify: `tests/godot/test_polygon_service.gd`
- Modify: `tests/godot/test_batch_provider_contract.gd`
- Modify: `tests/python/test_polygon_propagation.py`

- [ ] **Step 1: Write RED protocol and snapshot tests**

Require schema v2, `similarity_threshold`, image SHA-256, Source-entry digest, reference/target record digest, and review-state snapshot per frame. Test exact-threshold stop, verified target, frame-ID gap, dimensions, source/record/review/image mutation during analysis, malformed/extra result fields, non-finite edge scores, path aliases, cancel and timeout.

- [ ] **Step 2: Freeze all identities once**

Change service entrypoint to:

```gdscript
func begin(source: Variant, store: Variant, entries: Array,
           key: int, similarity_threshold: float = 0.02) -> PackedStringArray
```

For every captured frame, write one PNG and record `index/frame_id/image_path/image_sha256/entry_digest/record_digest/verified`. Capture up to 30 contiguous/unverified/same-size frames; Python decides similarity and algorithm stops on those exact PNGs.

- [ ] **Step 3: Strictly validate the v2 result**

Accept only `poly-sim-flow-edge-v1`, exact threshold/key/range/frame IDs, exact Poly IDs/attributes, at most 2048 points each and bounded diagnostic keys/counts. Recompute file and live Source/Store/review digests before publishing a result and again in `validate_source()` before apply.

- [ ] **Step 4: Route the UI threshold through the provider**

`PolyBatchProvider.begin(context)` passes `context.similarity_threshold`; availability still checks only project Python/worker. Rename strategy/provider ID to `polygon_edge` only if all saved markers and UI tests are migrated in the same task; otherwise keep the provider ID `polygon_flow` as an internal compatibility ID and use metric ID as the authoritative algorithm version.

- [ ] **Step 5: Run GREEN and commit**

Run: `source project_env.sh && "$GODOT_BIN" --headless --log-file /tmp/poly-service.log --path . --script tests/godot/test_polygon_service.gd && tests/check_godot_log.sh /tmp/poly-service.log`

Run: `.venv/bin/python -m pytest tests/python/test_polygon_propagation.py -q`

Commit: `git commit -m "feat: freeze similarity and polygon propagation inputs"`

## Task 6: Support overwrite/merge and versioned batch audit markers

**Files:**
- Modify: `client/services/batch_controller.gd`
- Modify: `client/domain/commands/apply_propagation_command.gd`
- Modify: `client/domain/annotation_store.gd`
- Modify: `tests/godot/test_polygon_batch_command.gd`
- Modify: `tests/godot/test_polygon_batch.gd`
- Modify: `tests/godot/test_batch_marker_validation.gd`
- Modify: `tests/godot/test_batch_state.gd`

- [ ] **Step 1: Write RED controller/command tests**

Require Poly `overwrite` to remove target-only regions and Poly `merge` to preserve them; both update/add reference Poly IDs. Assert keyframe unchanged, verified targets rejected, range can only shrink, preview exactness, one history entry, undo/redo, stale Source/image/record/review rejection, and no review-state changes.

- [ ] **Step 2: Remove the merge-only refusal**

Let `BatchController.preview()` use the already-existing overwrite/merge branch for Poly proposals. Do not silently convert reference Box regions; proposals include only valid reference Poly.

- [ ] **Step 3: Define marker v2 validation**

Keep v1 readable. v2 exact fields include current structural fields plus `metric_id`, similarity `threshold`, mode, real/playback ranges, stop reasons and bounded `edge_refinement` summary. Validate:

```gdscript
{"attempted": int, "accepted": int, "fallback": int,
 "items": [{"frame_id": int, "region_id": String,
            "accepted": bool, "reason": String,
            "raw_edge_score": float, "refined_edge_score": float}]}
```

Limit items to `29 * reference_poly_count`; reject unknown fields, NaN/Infinity, duplicates and inconsistent counts. Never project this metadata into Model Output V1.

- [ ] **Step 4: Build the marker from the immutable plan**

`ApplyPropagationCommand` sets structural `mode` from the preview rather than forcing merge, compares the key and all before snapshots on apply/redo, and preserves exact marker ordering/content through save/reopen/undo.

- [ ] **Step 5: Run GREEN and commit**

Run:

```bash
source project_env.sh
"$GODOT_BIN" --headless --log-file /tmp/poly-command.log --path . --script tests/godot/test_polygon_batch_command.gd
tests/check_godot_log.sh /tmp/poly-command.log
"$GODOT_BIN" --headless --log-file /tmp/poly-integration.log --path . --script tests/godot/test_polygon_batch.gd
tests/check_godot_log.sh /tmp/poly-integration.log
```

Commit: `git commit -m "feat: persist poly edge batches with v2 audit"`

## Task 7: Make Poly edge the default visible Batch workflow

**Files:**
- Modify: `client/ui/batch_workflow.gd`
- Modify: `client/app/main.gd`
- Modify: `tests/godot/test_batch_workflow.gd`
- Modify: `tests/godot/test_batch_no_candidate_ui.gd`
- Modify: `tests/godot/test_polygon_batch_ui.gd`
- Modify: `tests/godot/test_main_boundaries.gd`

- [ ] **Step 1: Write RED mounted-UI expectations**

On first open, assert `Poly 光流 + 边缘精修` is selected, difference threshold `0.02` is visible/editable, mode supports overwrite/merge, and fixed-copy remains selectable. Analyze via real worker; assert summary always shows candidate count, similarity stop, flow stop and `边缘精修 X 帧，光流回退 Y 帧`.

Test only-keyframe, missing original IDs plus jump, shortened ranges, preview lockout, Apply/save/reopen, confirm range, and auto-next. Click Batch while an edit draft/class modal exists and assert annotation tab/tool panel remain visible.

- [ ] **Step 2: Change controller entrypoint and defaults**

Use one `start_polygon_analysis(index, threshold)` path. Select Poly option by default, keep the threshold row outside Advanced, leave mode enabled, and update labels/tooltips to distinguish similarity threshold from internal flow quality.

- [ ] **Step 3: Render bounded diagnostics**

Compute summary counts from the plan's bounded per-region diagnostics. Put actionable stop/fallback text in the main card and full finite scores in Advanced. Threshold/mode/source/store changes invalidate the plan and clear preview/timeline candidate.

- [ ] **Step 4: Gate tab switching**

Before `_show_tab(true)` hides ToolPanel, call `_host._prepare_edit_navigation()` and refuse if `navigation_blocked`; keep current tab and explain Apply/Cancel. Entering Batch with no active draft may cancel inert preview state and pause playback.

- [ ] **Step 5: Run GREEN and commit**

Run:

```bash
source project_env.sh
"$GODOT_BIN" --headless --log-file /tmp/poly-ui.log --path . --script tests/godot/test_polygon_batch_ui.gd
tests/check_godot_log.sh /tmp/poly-ui.log
"$GODOT_BIN" --headless --log-file /tmp/batch-workflow.log --path . --script tests/godot/test_batch_workflow.gd
tests/check_godot_log.sh /tmp/batch-workflow.log
```

Commit: `git commit -m "feat: make edge-aware poly the default batch mode"`

## Task 8: Add reproducible Endoscapes fixture preparation and evidence

**Files:**
- Create: `tests/manual/prepare_endoscapes_poly_fixture.py`
- Create: `tests/manual/run_endoscapes_poly_acceptance.py`
- Create: `tests/python/test_endoscapes_fixture_builder.py`
- Modify: `.gitignore`
- Create: `tests/manual/endoscapes_poly_acceptance.md`

- [ ] **Step 1: Write RED builder tests against a miniature fake dataset**

Test input discovery, step-25 ordering, missing/duplicate frames, 5-frame and 30-frame bounds, SHA-256 provenance, contiguous playback indices, original frame IDs, mask/CSV count mismatch, selected instance, polygon validity, destination collision, and source immutability.

- [ ] **Step 2: Implement explicit CLI inputs**

Expose:

```bash
.venv/bin/python tests/manual/prepare_endoscapes_poly_fixture.py \
  --dataset-root /absolute/endoscapes \
  --output .local-acceptance/endoscapes-poly-65 \
  --video-id 65 --start-frame 11775 --end-frame 11875 \
  --key-frame 11800 --instance-index 0
```

Default to symlinks, with opt-in `--copy`; create into a staging directory then rename only when complete. `manifest.json` uses playback `frame: 0..N-1` and preserves dataset frame numbers in provenance. `model_output_v1.jsonl` contains the keyframe Poly derived from `insseg/65_11800.npy`; no dataset path or private pixels are committed.

- [ ] **Step 3: Run builder unit tests and real preparation**

Run: `.venv/bin/python -m pytest tests/python/test_endoscapes_fixture_builder.py -q`

Run the CLI above. Confirm exactly five images `65_11775.jpg` through `65_11875.jpg`, keyframe playback index 1, label 5 for instance 0, and hash matches provenance. Then separately create an up-to-30-frame window around the same video for stop/cap diagnostics.

- [ ] **Step 4: Run algorithm and visible UI acceptance**

At threshold `0.02`, record actual candidate range, adjacent/key MAD, per-frame/per-region edge accepted/fallback, stop reasons, elapsed time and generated raw/refined overlay images. Open the generated fixture in Main, preview every accepted target, Apply once, undo/redo, save/reopen, confirm, and auto-next.

- [ ] **Step 5: State evidence limits**

The sparse `insseg` mask is a keyframe seed, not dense target truth. Record target-frame results as qualitative reviewer evidence only. Keep synthetic tests as the only IoU claim unless new independent target annotations are produced.

- [ ] **Step 6: Commit reusable code and prose only**

Run: `git status --short` and verify `.local-acceptance/` plus dataset symlinks/images/masks are ignored.

Commit: `git commit -m "test: add Endoscapes poly acceptance workflow"`

## Task 9: Documentation, full regression, and completion audit

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/plugin-api.md`
- Modify: `docs/poly-propagation.md`
- Modify: `docs/requirements-traceability.md`
- Modify: `RESULTS.md`
- Modify: `tests/run_tests.sh`

- [ ] **Step 1: Update user and architecture documentation**

Document Poly-edge as default, visible threshold, overwrite/merge, same-snapshot similarity, exact edge gate/fallback, v2 marker/v1 compatibility, Endoscapes recipe and privacy/provenance boundary. Separate implementation, automated synthetic evidence, Endoscapes qualitative evidence and remaining manual review.

- [ ] **Step 2: Run focused gates with audited logs**

Run every Python test introduced above and these Godot scripts separately: `test_polygon_batch_command.gd`, `test_polygon_batch.gd`, `test_polygon_service.gd`, `test_polygon_batch_ui.gd`, `test_batch_workflow.gd`, `test_batch_no_candidate_ui.gd`, and `test_main_boundaries.gd`. Pass every log through `tests/check_godot_log.sh`.

- [ ] **Step 3: Run full fresh regression**

Run:

```bash
source project_env.sh
tests/run_tests.sh
```

Expected: all Python/Godot suites exit 0, no unexpected `SCRIPT ERROR`/engine error, and existing playback/edit/review/Part 4 tests remain green.

- [ ] **Step 4: Inspect artifacts and repository state**

Open the current UI and Endoscapes overlay evidence, check layout at the default window size, then run `git diff --check`, `git status --short`, and `git diff --stat`. Ensure no image, `.npy`, checkpoint, temporary job or local environment path is tracked.

- [ ] **Step 5: Commit documentation/evidence**

Commit: `git commit -m "docs: document similarity-gated edge poly propagation"`

Completion may claim the exact tested synthetic properties and Endoscapes path closure. It must not claim dense Endoscapes accuracy, universal edge improvement, or automatic verification.
