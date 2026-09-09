# Model Assist Tool Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 把 SAM 2 恢复为标注页的单帧 Poly 创建/修正工具，具备严格协议、可取消候选、stale 保护、原子 undo/redo 和真实 SAM2ImagePredictor 验收。

**Architecture:** `BasicEditToolsPlugin` 持有 `ModelAssistSession`，通过无 Store 写权的 `ModelAssistService` 向外部 Conda Python 中的持久 `model_assist_worker.py` 发送 `model-assist-v1` JSONL。Worker 只返回有哈希的二值 ROI mask；Godot 再校验并转为 V1 单环 Poly。UI 只渲染经校验的 `session_panel` action descriptor，正式修改仅由现有 `AddPolygonCommand` / `ReplaceRegionGeometryCommand` 进入 history/store。

**Tech Stack:** Godot 4.7.2 / GDScript, Python 3.10+ external Conda runtime, PyTorch, official `sam2`, OpenCV, NumPy, JSONL, pytest.

**Approved design:** `docs/model-assist-poly-edge-design.md`

---

## Task 1: Remove the abandoned Batch-SAM protocol and lock the new image protocol

**Files:**
- Delete: `python/annotation_data/sam_batch_protocol.py`
- Delete: `python/sam_batch_worker.py`
- Delete: `tests/python/test_sam_batch_protocol.py`
- Delete: `tests/python/test_sam_batch_worker.py`
- Delete: `tests/fixtures/fake_sam_batch_backend.py`
- Create: `python/annotation_data/model_assist_protocol.py`
- Create: `tests/python/test_model_assist_protocol.py`

- [ ] **Step 1: Write failing strict-protocol tests**

Cover exact top-level keys, `hello/set_image/predict/cancel/shutdown`, duplicate JSON keys, unknown fields/op, non-finite numbers, line size `> 1 MiB`, maximum 64 points, labels limited to `0/1`, one normalized box, optional initial-mask descriptor, and response `errors` shape. Start with a canonical constructor assertion:

```python
request = parse_request(json.dumps({
    "protocol": "model-assist-v1", "request_id": "r1", "op": "predict",
    "context": context(prompt_revision=3),
    "data": {"points": [[20.0, 30.0]], "labels": [1], "box": None,
             "initial_mask": None},
}))
assert request["context"]["prompt_revision"] == 3
```

- [ ] **Step 2: Run the focused test and confirm RED**

Run: `.venv/bin/python -m pytest tests/python/test_model_assist_protocol.py -q`

Expected: FAIL because `annotation_data.model_assist_protocol` is missing.

- [ ] **Step 3: Implement bounded parsing and response builders**

Expose:

```python
PROTOCOL = "model-assist-v1"
MAX_LINE_BYTES = 1024 * 1024

def loads_line(raw: bytes) -> dict: ...
def validate_request(value: object) -> dict: ...
def success_response(request: dict, data: dict) -> dict: ...
def error_response(request_id: str, context: dict, errors: list[str]) -> dict: ...
```

Use `object_pairs_hook` to reject duplicate keys, `parse_constant` to reject NaN/Infinity, exact key sets at every level, finite numeric checks, SHA-256 lowercase hex checks, nonnegative frame/playback/revision integers, and no filesystem access.

- [ ] **Step 4: Remove the old Batch-SAM files and prove no references remain**

Run: `rg -n "sam_batch|sam-batch-v1|SamBatch" python client tests docs --glob '!docs/superpowers/specs/2026-09-09-sam-assisted-batch-design.md'`

Expected: no runtime/test references; the superseded historical spec may remain.

- [ ] **Step 5: Run GREEN and commit**

Run: `.venv/bin/python -m pytest tests/python/test_model_assist_protocol.py -q`

Commit: `git commit -m "refactor: replace batch sam protocol with model assist v1"`

## Task 2: Implement safe SAM image worker and deterministic fake worker

**Files:**
- Create: `python/annotation_data/model_assist_backend.py`
- Create: `python/model_assist_worker.py`
- Create: `tests/fixtures/fake_model_assist_worker.py`
- Create: `tests/python/test_model_assist_worker.py`

- [ ] **Step 1: Write failing backend tests with a fake predictor**

Test one-time model load, image-embedding reuse, cache invalidation on image digest change, point/box forwarding, full-image initial-mask conversion to `1x256x256` logits in correction mode, one-to-three candidates, ROI crop, binary `0/255` PNG, hash reporting, cancel acknowledgement, and shutdown. Inject a predictor factory so tests never import Torch/SAM:

```python
backend = ModelAssistBackend(predictor_factory=lambda *_: FakePredictor())
backend.set_image(image_path, expected_sha256)
result = backend.predict(points=[[12, 9]], labels=[1], box=None, mask_input=None)
assert 1 <= len(result["candidates"]) <= 3
```

Add traversal/symlink/non-regular file, oversized/dimension-mismatched image/mask, nonbinary mask, output collision, stale image digest, and malformed predictor output tests.

- [ ] **Step 2: Run RED**

Run: `.venv/bin/python -m pytest tests/python/test_model_assist_worker.py -q`

- [ ] **Step 3: Implement the backend against the official image API**

Import `SAM2ImagePredictor` lazily only during `hello`; construct the model with `build_sam2(config, checkpoint, device=device)`, pass it to `SAM2ImagePredictor(model)`, and call `predictor.set_image(rgb_image)`. Convert an optional selected-region binary full-image mask with nearest-neighbor resize to `256x256`, map foreground/background to logits `+8.0/-8.0`, and shape it as `1x256x256`; never pass a full-resolution binary array as `mask_input`. For `predict`, call:

```python
masks, scores, logits = predictor.predict(
    point_coords=np.asarray(points, np.float32) if points else None,
    point_labels=np.asarray(labels, np.int32) if labels else None,
    box=np.asarray(box, np.float32) if box else None,
    mask_input=mask_logits,
    multimask_output=True,
)
```

Never infer on `set_image`; crop each accepted full-image boolean mask to its nonempty ROI, write atomically inside the worker-owned job directory, and return relative filename/ROI/SHA-256/score only.

- [ ] **Step 4: Implement the JSONL process loop and fake worker scenarios**

The real worker reads bounded lines from stdin and flushes one response line to stdout. The fake worker supports deterministic `ok`, `delay`, `crash`, `malformed`, `oversize`, `wrong_hash`, `multi_component`, `hole`, and `out_of_order` modes selected through an environment variable; it must not touch repository files.

- [ ] **Step 5: Run GREEN and commit**

Run: `.venv/bin/python -m pytest tests/python/test_model_assist_protocol.py tests/python/test_model_assist_worker.py -q`

Commit: `git commit -m "feat: add bounded sam image worker"`

## Task 3: Add Godot mask import and V1 polygon safety gate

**Files:**
- Modify: `client/domain/mask_region_ops.gd`
- Create: `client/domain/model_assist_candidate.gd`
- Modify: `tests/godot/test_mask_region_ops.gd`
- Create: `tests/godot/test_model_assist_candidate.gd`
- Modify: `tests/godot/test_runner.gd`

- [ ] **Step 1: Write RED tests for candidate validation**

Cover empty/full image, nonbinary pixels, ROI overflow, hash mismatch, symlink/path escape, multi-component, hole, contour self-intersection, more than 2048 vertices, and raster round-trip IoU `< 0.99`. Verify valid concave input returns a `PackedVector2Array` while rejected input returns a reason and never mutates source bytes.

- [ ] **Step 2: Run focused RED**

Run: `source project_env.sh && "$GODOT_BIN" --headless --path . --script tests/godot/test_model_assist_candidate.gd`

- [ ] **Step 3: Implement the validator**

Create:

```gdscript
static func validate_file(
    job_dir: String, descriptor: Dictionary, image_size: Vector2i
) -> Dictionary:
    # {"ok": bool, "polygon": PackedVector2Array, "mask": Dictionary, "reason": String}
```

Canonicalize both job root and candidate path, require a regular non-symlink PNG within the exact job directory, verify SHA-256 before decode, require `FORMAT_L8/R8/RGB8/RGBA8` pixels to represent only 0/255, then use `MaskRegionOps.to_v1_candidate`. Add `MaskRegionOps.mask_iou(left, right)` and enforce `>= 0.99` after re-rasterization. Reject rather than repair holes/components.

- [ ] **Step 4: Run GREEN and commit**

Run: `source project_env.sh && "$GODOT_BIN" --headless --path . --script tests/godot/test_model_assist_candidate.gd`

Commit: `git commit -m "feat: validate model assist masks as v1 polygons"`

## Task 4: Build the external-runtime service lifecycle

**Files:**
- Create: `client/services/model_assist_service.gd`
- Create: `tests/godot/test_model_assist_service.gd`
- Modify: `tests/godot/test_runner.gd`

- [ ] **Step 1: Write RED service tests around the fake worker**

Test environment-variable preflight, exact missing Python/package/config/checkpoint/device messages, CPU badge, explicit-CUDA refusal, worker starts once, sequential request IDs, current-image cache, 180 s load / 60 s predict deadline injection, latest-token-only delivery, cancel/crash/malformed/oversized-line behavior, and cleanup preserving a sibling sentinel directory.

- [ ] **Step 2: Run RED**

Run: `source project_env.sh && "$GODOT_BIN" --headless --path . --script tests/godot/test_model_assist_service.gd`

- [ ] **Step 3: Implement a nonblocking service**

Public surface:

```gdscript
signal state_changed(snapshot: Dictionary)
signal prediction_ready(token: int, result: Dictionary)

func preflight() -> Dictionary
func set_image(context: Dictionary, image: Image, initial_mask: Dictionary = {}) -> int
func predict(context: Dictionary, prompts: Dictionary) -> int
func cancel(token: int) -> void
func step() -> void
func shutdown() -> void
```

Read `PROJECT6_MODEL_PYTHON`, `PROJECT6_SAM2_CONFIG`, `PROJECT6_SAM2_CHECKPOINT`, and `PROJECT6_SAM2_DEVICE` without inventing defaults to user directories. Create one exact job directory under `user://model-assist-jobs`, snapshot PNG/mask atomically, and launch only that configured interpreter with `OS.execute_with_pipe(path, args, false)`. Retain its returned `stdio`, `stderr`, and `pid`; read/write nonblocking and inspect `FileAccess.get_error()` rather than interpreting an empty read as EOF. Because Godot documents that this process outlives the engine, every shutdown/exit/timeout path must first send `shutdown` or `cancel`, then terminate only this instance's recorded PID if it does not exit within the bounded grace period.

- [ ] **Step 4: Run GREEN and commit**

Run: `source project_env.sh && "$GODOT_BIN" --headless --path . --script tests/godot/test_model_assist_service.gd`

Commit: `git commit -m "feat: add model assist process service"`

## Task 5: Add a pure model-assist session state machine

**Files:**
- Create: `client/domain/model_assist_session.gd`
- Create: `tests/godot/test_model_assist_session.gd`
- Modify: `tests/godot/test_runner.gd`

- [ ] **Step 1: Write RED transition tests**

Exercise `unavailable -> ready -> requesting -> candidate/invalid/failed -> awaiting_class`, creation vs selected Box/Poly correction, first-prompt target freeze, positive/negative points, unique Ctrl-drag box, Backspace prompt undo, candidate cycle, retry, stale revision rejection, cancel, commit snapshot, and 64-point cap. Assert defensive-copy snapshots.

- [ ] **Step 2: Implement the session**

Use a small explicit API:

```gdscript
func begin(frame_id: int, playback_index: int, record: Dictionary,
           selected_region_id: String, image_size: Vector2i, preflight: Dictionary) -> void
func add_point(point: Vector2, positive: bool) -> Dictionary
func set_box(box: Rect2) -> Dictionary
func undo_prompt() -> Dictionary
func begin_request(token: int, context: Dictionary) -> void
func accept(token: int, candidates: Array[Dictionary]) -> bool
func cycle(delta: int) -> void
func snapshot() -> Dictionary
func reset() -> void
```

The snapshot owns `overlay`, `session_panel`, `navigation_blocked`, `draft_active`, and human-readable message. Initial correction mask alone stays `ready` and nonblocking.

- [ ] **Step 3: Run GREEN and commit**

Run: `source project_env.sh && "$GODOT_BIN" --headless --path . --script tests/godot/test_model_assist_session.gd`

Commit: `git commit -m "feat: model model-assist prompt sessions"`

## Task 6: Generalize ToolPanel session actions and draw prompts

**Files:**
- Modify: `client/ui/tool_panel.gd`
- Modify: `client/ui/edit_overlay.gd`
- Modify: `tests/godot/test_tool_panel.gd`
- Modify: `tests/godot/test_edit_overlay.gd`

- [ ] **Step 1: Write RED UI-component tests**

Validate `session_panel` only accepts `tool_id/status/badge/summary/actions`; every action requires exact `id/label/enabled/primary` fields; duplicates/unknown fields are rejected. Verify action buttons emit only `tool_action_requested(action_id)`. Add draw-command/image checks for green `+`, red `-`, cyan dashed prompt box, candidate mask/polygon, and no mutation of supplied state.

- [ ] **Step 2: Replace Fill-specific ownership**

Replace `fill_repair_action` and `set_fill_repair_visible()` with:

```gdscript
signal tool_action_requested(action_id: StringName)
func set_session_panel(snapshot: Dictionary) -> PackedStringArray
```

Render a bounded reusable action row. Make the edit plugin expose Fill Apply/Cancel through the same descriptor so there is one UI action path.

- [ ] **Step 3: Extend overlay rendering**

Read `positive_points`, `negative_points`, and `prompt_box` from the defensive snapshot. Keep all coordinates image-space and transform only during `_draw()`.

- [ ] **Step 4: Run GREEN and commit**

Run: `source project_env.sh && "$GODOT_BIN" --headless --path . --script tests/godot/test_tool_panel.gd`

Run: `source project_env.sh && "$GODOT_BIN" --headless --path . --script tests/godot/test_edit_overlay.gd`

Commit: `git commit -m "refactor: generalize edit session actions"`

## Task 7: Integrate the Model Assist tool into BasicEditToolsPlugin

**Files:**
- Modify: `client/plugins/edit/basic_edit_tools/plugin.gd`
- Modify: `client/plugins/edit/basic_edit_tools/plugin.json`
- Add: `client/ui/icons/tools/model_assist.svg`
- Create: `tests/godot/test_model_assist_plugin.gd`
- Modify: `tests/godot/test_plugin_registry.gd`
- Modify: `tests/godot/test_delivery_tool_surface.gd`
- Modify: `tests/godot/test_runner.gd`

- [ ] **Step 1: Write RED plugin tests**

Assert `model_assist` is the eighth descriptor without changing existing IDs/order, `M` selects it, activation runs preflight but not inference, empty-space click adds positive prompt without selecting a region, Shift+click adds negative, Ctrl+drag replaces box, Backspace undoes prompt, Tab/candidate actions cycle, Enter/Apply commits only a current candidate, and Escape/Cancel invalidates all late callbacks.

Cover create and correction separately. For creation, assert Apply enters existing class assignment and confirmation produces exactly one `AddPolygonCommand`. For correction, assert one `ReplaceRegionGeometryCommand` retains ID/class/kind/track/custom fields, converts Box to Poly, and undo/redo restores exact records. Every rejected/cancelled path must keep Store and history byte-for-byte equal.

- [ ] **Step 2: Add dependency injection and descriptor**

Allow tests to set a service factory before `activate()`. Add `MODEL_ASSIST_SESSION`, `MODEL_ASSIST_SERVICE`, and `MODEL_ASSIST_CANDIDATE` preloads, append `&"model_assist"` to `TOOL_IDS`, and add the descriptor/icon without reordering the existing seven tools.

- [ ] **Step 3: Route prompts and latest-token candidates**

In `handle_pointer()` branch before selection logic when the active tool is `model_assist`. Rasterize a selected Box/Poly once at first prompt; freeze frame ID, playback index, image digest, record digest and selected region ID. Each prompt revision cancels the previous token, sends the full prompt set, validates every returned mask, and passes only safe candidates to the session.

- [ ] **Step 4: Route actions and atomic commands**

Add action IDs `model_apply`, `model_cancel`, `model_retry`, `model_previous_candidate`, `model_next_candidate`, and `model_recheck`. Creation calls `_await_class_for_polygon(..., &"model_assist")`; correction constructs `ReplaceRegionGeometryCommand` against the frozen `before` only after current frame/record/selection checks pass.

- [ ] **Step 5: Lifecycle cleanup**

`set_active_tool`, `cancel`, `deactivate`, source loss, and plugin replacement must invalidate session tokens, clear overlay/suppression, restore `viewport.set_edit_selection_authoritative(false)`, and call `service.shutdown()` only for the owned service.

- [ ] **Step 6: Run GREEN and commit**

Run: `source project_env.sh && "$GODOT_BIN" --headless --path . --script tests/godot/test_model_assist_plugin.gd`

Commit: `git commit -m "feat: add single-frame model assist edit tool"`

## Task 8: Wire Main navigation, generic actions, and real mounted UI

**Files:**
- Modify: `client/app/main.gd`
- Modify: `client/ui/batch_workflow.gd`
- Modify: `tests/godot/edit_test_harness.gd`
- Create: `tests/godot/test_model_assist_ui.gd`
- Modify: `tests/godot/test_main_boundaries.gd`
- Modify: `tests/godot/test_keyboard_reachability.gd`
- Modify: `tests/godot/test_runner.gd`

- [ ] **Step 1: Write RED mounted-Main tests**

Drive only real UI/input: click Model Assist; click/Shift-click/Ctrl-drag; see prompt markers and action panel; receive out-of-order fake responses; cycle candidate; Apply correction; undo/redo; create + class dialog; save/reopen; cancel; switch frame/tool/tab while ready vs requesting/candidate. Assert no request changes selected region, preview suppresses only the corrected region, and batch-tab click is refused while a draft is active.

- [ ] **Step 2: Preserve validated session state in Main**

Extend `_on_edit_state_changed()` to copy only validated `session_panel`, never arbitrary callbacks. Connect `ToolPanel.tool_action_requested` to a generic handler that invokes the edit plugin, refreshes annotations only if Store changed, and returns focus to viewport.

- [ ] **Step 3: Add shortcut and navigation gates**

Route plain `M` in `_route_edit_key()` only when no text/modal/draft owns the event. Make `BatchWorkflow._show_tab(true)` call `_host._prepare_edit_navigation()` before hiding the annotation controls. Global undo/redo, playback, timeline, explorer, source/round change and exit obey `navigation_blocked`.

- [ ] **Step 4: Run GREEN and commit**

Run: `source project_env.sh && "$GODOT_BIN" --headless --path . --script tests/godot/test_model_assist_ui.gd`

Run: `source project_env.sh && "$GODOT_BIN" --headless --path . --script tests/godot/test_main_boundaries.gd`

Commit: `git commit -m "feat: expose model assist workflow in main ui"`

## Task 9: Verify a real external Conda SAM runtime

**Files:**
- Create: `tests/manual/model_assist_smoke.py`
- Create: `tests/manual/model_assist_acceptance.md`
- Modify: `.gitignore`

- [ ] **Step 1: Add a read-only smoke driver before changing any Conda environment**

The driver accepts explicit `--python/--config/--checkpoint/--image/--output-dir/--device`; records versions, checkpoint SHA-256, actual device, prompt coordinates, candidate hashes/scores and elapsed time. It never downloads or overwrites weights and writes only to an ignored output directory.

- [ ] **Step 2: Re-probe candidate environments**

Run each explicit interpreter with:

```bash
/path/to/conda/env/bin/python -c 'import sys,torch; print(sys.executable); print(torch.__version__); print(torch.cuda.is_available())'
```

Then test `import sam2`. Choose an existing user-authorized environment; keep project `.venv` unchanged.

- [ ] **Step 3: If `sam2` or a checkpoint is missing, stop for the required approval**

Installing a package or downloading weights is an external mutation. Request approval for the exact environment and official source before running installation/download commands. Do not substitute an unofficial checkpoint.

- [ ] **Step 4: Run the real closed loop**

Export the four `PROJECT6_*` variables, then use the mounted UI on one local surgical frame to complete: create, correction, Cancel, one-command undo/redo, save, reopen. Capture CPU/CUDA badge, config/checkpoint hash, candidate evidence, and logs with no `SCRIPT ERROR`.

- [ ] **Step 5: Record the honest boundary and commit the reusable harness only**

If CPU only, mark functional closure PASS and CUDA performance NOT RUN. If the runtime cannot be provisioned, keep the feature available-with-reason but do not claim real-model completion.

Commit: `git commit -m "test: add real model assist acceptance harness"`

## Task 10: Documentation and full regression

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/plugin-api.md`
- Modify: `docs/requirements-traceability.md`
- Modify: `RESULTS.md`
- Modify: `tests/run_tests.sh`

- [ ] **Step 1: Update contracts and reviewer instructions**

Document the eighth tool, `M`, prompt gestures, action panel, external runtime variables, CPU/GPU badge, no-download rule, stale/cancel semantics, and exact distinction between fake-worker coverage and real-SAM evidence.

- [ ] **Step 2: Add focused tests to the authoritative runner**

Ensure `test_runner.gd` preloads pure component tests, while process-owning SceneTree tests run as separate commands in `tests/run_tests.sh`. Add a shell helper that fails if any Godot log contains `SCRIPT ERROR`, `ERROR:`, or unhandled exception even when exit code is zero; whitelist only documented expected corrupt-fixture messages.

- [ ] **Step 3: Run the complete verification gate**

Run:

```bash
source project_env.sh
tests/run_tests.sh
```

Expected: all Python and Godot suites exit 0 and the log audit reports no unexpected engine/script errors.

- [ ] **Step 4: Inspect the final diff and commit**

Run: `git diff --check && git status --short && git diff --stat`

Commit: `git commit -m "docs: document single-frame model assist workflow"`

Do not call the subsystem complete unless Task 9 has a real official-SAM closure; otherwise report implementation/fake-worker verification as complete and real-model acceptance as pending.
