# Project 6 — Automated Annotation System (Tool) — Assignment

## Introduction

This assignment evaluates the engineering foundations needed to build an automated annotation system (tool). At its core, the system connects to annotation models, overlays the model-recognized regions on the original image for human review and correction, supports **batch labelling of similar consecutive frames in a video stream**, and hands the corrected data back to the model group for re-training.

The planned client platform is **Godot** (interactive application); a **complex web front-end** may also be considered as the human–machine interaction terminal. Much of the work centres on interaction and rendering quality, so a working grasp of **computer graphics** concepts (image–viewport coordinate transforms, zoom/pan/camera, region transforms, texture rendering) is expected, and the functionality of the tool must be built as a componentized, plugin-style pipeline. A good human–computer interaction (HCI) experience should also be a design consideration.

The intended completion time is **10 days** (see [Timeline](#timeline)). The required work is deliberately limited: we value one reliable, well-documented, genuinely usable tool built with a clean plugin architecture over a broad but brittle prototype.

## Prerequisites

The following reference environment is recommended. A functionally equivalent setup is acceptable if reproducible and documented in the README.

- Client platform — pick **one** primary path and document the choice:
  - **Godot 4.x (recommended)**: interactive application client, GDScript (C#/.NET edition optional). See [Godot docs](https://docs.godotengine.org/).
  - **Complex web front-end (alternative)**: e.g., a browser client with a canvas/WebGL/WebGPU renderer backed by a small service, chosen when a richer web HITL terminal is preferred.
- Supporting tooling: Python 3.10+ (for data generation and the frame-source/decoding tooling); OpenCV (`opencv-python`) and/or `ffmpeg`/`imageio` for video decoding.
- **Interaction design reference — MITK.** Study the editing support of the [MITK (Medical Imaging Interaction Toolkit)](https://github.com/MITK/MITK) and its manual-interaction paradigm (region/contour manipulation, add/remove, undo/redo, etc. — consider only the operations relevant in the 2D setting). You do not need to use or reimplement MITK, but you should study its editing interactions, translate that paradigm to 2D region annotations, and explain your design decisions in the design note.
- Computer graphics: basic coordinate transforms, viewport/camera zoom & pan, affine transforms on regions, texture rendering. (See [Expected Outcome](#expected-outcome).)
- No external dataset is required. You must ship a **reproducible synthetic sample** (see Part 1); a real video may be used additionally.

AI assistance (LLMs, code generation, UI scaffolding) is allowed without restriction. AI-assisted content should remain within a clearly human-readable and human-understandable scope, and stay open to subsequent extension and development.

## Scenario

A perception model processes images or frames of a video and emits, per image, a list of recognized regions (e.g., boxes/polygons with class, confidence, and instance/track ids). The output is noisy: regions drift, classes are wrong, regions are missed or hallucinated, and track ids jump. A human reviewer must turn this output into trustworthy ground truth:

1. open an image or a video frame source;
2. see the model's regions rendered in 2D over the original image;
3. correct them (adjust extent, re-label, add, delete, propagate edits across similar frames);
4. export corrected annotations and a diff report, and hand a clearly specified update package to the model-training side for re-training.

The deliverable is the tool plus a design note and demonstration — not a trained model.

## Deliverable Overview and Directory Layout

A clean, componentized layout where every stage is a swappable module behind a documented interface. Suggested layout (adjust freely, keep it documented):

```
annot_tool/
├── README.md                     # Env, install, run, reviewer test script, keyboard table
├── pyproject.toml                # Python deps (frame source, sample gen) — pinned
├── client/                       # Godot project (project.godot, scenes, scripts)
│   ├── app/                      # Entry, main UI (viewport, toolbar, timeline)
│   ├── pipeline/                 # Plugin registry + Stage interfaces (Godot-side)
│   └── plugins/                  # Installed plugins (source/render/tool/export stages)
├── core/                         # Cross-language schema (JSON Schema) + shared types
├── python/
│   ├── make_sample_input.py      # Deterministic synthetic sample generator
│   └── frame_source.py           # Decode any video -> indexed frames for the client
├── sample/                       # Generated sample (not committed if large)
├── tests/                        # Godot + Python tests, headless smoke test
└── RESULTS.md                    # Design note, measurements, failure analysis
```

Provide an **architecture diagram** (Mermaid / Excalidraw / draw.io) showing: frame/image source → plugin pipeline (Source → Render → Edit → Export/Feedback) → corrected store → training handoff.

---

## Part 1 — Scaffold, Data Contract, Sample, and Plugin Architecture (2 days)

The foundation is a **versioned data contract** plus a **plugin-style pipeline skeleton**. Everything else consumes both.

### 1.1 Data contract

Define a JSON-Schema-validated per-image annotation record. Minimum fields: image/frame id (with source and index), timestamp (optional), and a list of regions. Each region: id, class label, kind (e.g., `region`/`anatomy`/`instrument`), 2D extent (box and/or polygon), optional confidence, optional track/instance id.

```jsonc
{
  "schema_version": 1,
  "source": "sample_v1",
  "frame": 128,
  "time_s": 4.27,
  "regions": [
    {
      "id": "reg-003",
      "class": "grasper",
      "kind": "instrument",
      "box": [585, 26, 268, 176],              // [x, y, w, h] px
      "polygon": [[585,26],[853,26],[853,202],[585,202]],
      "conf": 0.92,
      "track_id": "T02"
    },
    {
      "id": "reg-004",
      "class": "cystic_duct",
      "kind": "anatomy",
      "box": [361, 224, 254, 150],
      "conf": 0.87,
      "track_id": null
    }
  ]
}
```

1. Ship the JSON Schema and a validator usable from both the client and Python. Reject malformed records with clear errors; never crash the UI.
2. Version the contract; keep the model output immutable and versioned as `model_output_vX`.

### 1.2 Reproducible sample source (mandatory)

Provide `python/make_sample_input.py` that deterministically (fixed seed) generates a short synthetic clip: a **sequence of frames** (or a small encoded video) with moving colored shapes ("fake instrument"/"fake anatomy"), plus a matching annotation file containing planted, realistic defects: a few **drifted regions**, **wrong class labels**, one **missed region**, one **hallucinated region**, a **track-id swap**, and one **segment of consecutive near-identical frames** (for Part 3 batch labelling). Identical output must be reproducible from the same seed.

### 1.3 Frame source (video support)

Ship `python/frame_source.py` that decodes **any video** into indexed frames the client can consume (frame-accurate), e.g. writing an image sequence, or serving frames over localhost with explicit indices. The client must treat "video" and "image sequence" uniformly as frames-from-a-source.

### 1.4 Plugin-style pipeline

Design and document the **Stage interfaces and plugin registry**. Required extension points (each a swappable sub-module, plugin style):

- **Source stage** — provides frames + model annotations (offline replay, frame server, …);
- **Render stage** — draws the current image + its regions;
- **Edit tools** — interaction behaviors (select/move/resize/relabel/add/delete, range propagate);
- **Export / Feedback stage** — corrected dataset export and the training handoff package.

Implement at least one **working plugin per extension point** and a registry that loads plugins from a directory at startup. Write a short plugin API document (how a teammate would add a new source or tool without touching the core).

Deliverable: repo skeleton, schema + validator, deterministic sample generator, frame-source tool, plugin registry + one plugin per stage, architecture diagram, README. Verification: `python/make_sample_input.py` runs clean and its output passes schema validation with 0 errors.

---

## Part 2 — Region Display and MITK-Style Editing (3 days)

The core of this assignment's interaction and graphics work.

### 2.1 Display (computer graphics)

1. Render the original image in a 2D viewport with the model's regions overlaid. Demonstrate and document the coordinate pipeline: image → viewport with **zoom/pan/camera**, aspect-ratio preservation, and correct **pick/selection** under the same transform (mouse → image coordinates).
2. Draw regions (boxes/polygons/complex polygons) with per-class colors, labels, confidence text, and an occlusion/opacity control. Rendering must stay smooth (≥ 25–30 fps on a typical laptop while dragging/zooming with ~20 regions); document how you achieved it (batching, dirty-region redraw, texture atlases, shaders…).

### 2.2 Editing (MITK editing support as reference)

Study the MITK editing paradigm, then implement region editing translated to 2D (you are not required to implement everything — a representative subset is fine):

- **Select** a region by click (hit-testing under the current transform); show a selected state.
- **Move** a region (drag), **resize** via handles, **keyboard nudging** (1/5/10 px steps).
- **Re-label** a region's class (list + free text).
- **Add** a new region (drag to create box; optional polygon draw) and **remove** an existing one.
- Optional: polygon **vertex editing** (add/move/delete vertices).
- **Undo/redo** (bounded history, e.g., last 200 actions) covering every edit.
- **Fill** a designated region with color, including filling approximately closed region shapes.
- Keyboard-only reachability for every edit; provide a shortcut table in the README.
- An edit that would violate the schema is refused with an explanatory message (no silent corruption).

### 2.3 Design note (interaction fidelity)

In `RESULTS.md`, answer: which MITK editing interactions you emulated, which you adapted or dropped for 2D video regions, and why — this shows you read a mature tool before building your own.

Deliverable: depending on the technical approach you choose, provide a corresponding runnable client/web application that opens the synthetic sample and supports the editing features you implemented; include a reviewer test script in the README that verifies each editing feature one by one.

---

## Part 3 — Video Streams and Batch Labelling of Similar Consecutive Frames (3 days)

Video/stream processing plus the batch workflow.

### 3.1 Frame-accurate stream

1. Play a frame source (image sequence or decoded video) with play/pause, single-step, seek, and explicit frame/time display. Frame indices must align exactly with the annotation records; document how your source guarantees this (and any caveats if you used a codec-level player).
2. Handle long clips without loading everything into RAM (bounded window / on-demand frames).

### 3.2 Batch labelling over similar consecutive frames

1. Implement a **similarity metric** between consecutive frames (e.g., mean absolute difference / histogram distance on downsampled grayscale; model-confidence change is optional). Choose a threshold.
2. Workflow: reviewer opens a **keyframe**, corrects its regions, then **propagates** the corrected regions to the contiguous run of frames judged similar, with explicit **overwrite vs. merge** semantics and a recorded "batch range, keyframe id" marker.
3. Provide **verification UX**: mark frames/ranges as *verified*, highlight unverified frames in the timeline strip, auto-advance to the next unverified frame.
4. Discuss (in `RESULTS.md`) the risk of **drift accumulation** across a long similar run and one concrete mitigation you implemented or propose.

### 3.3 Measurement

Report: on the shipped sample, how many frames were covered per batch vs. what manual per-frame labelling would take; the threshold you chose; and a short qualitative check of the propagated result at the batch boundaries.

Deliverable: end-to-end batch workflow on the synthetic clip's similar-frames segment, with measurements.

---

## Part 4 — Retraining Feedback Loop and Collaboration Handoff (1 day)

This part is deliberately light on UI and heavy on *contract discipline*.

### 4.1 Persistence and export

- Persist corrected annotations (same schema, distinct `source: "human_corrected"`), with **crash-safe autosave** (atomic write + timer) and an "unsaved changes" prompt.
- Export the corrected dataset in the shared schema (JSONL and/or COCO-style) with exact per-frame alignment.

### 4.2 Diff / audit report

Produce a per-frame diff of `model_output` vs `corrected`: regions added / deleted / label-changed / geometry-changed per frame, plus an aggregate summary by class. Save as JSON/CSV next to the export.

### 4.3 Training update package (sync to model for re-training)

Define a **training update package**: a manifest + corrected annotations + the diff report (+ optional keyframe thumbnails). Implement a client module that delivers it either to:

- a **local mock training service** (`/health`, `/submit`, timeout + bounded retry + clean fallback), or
- a **file-based handoff** with a documented, versioned naming convention.

Network/IO must never block the UI thread. This module is the interface the model team consumes; keep it small and stable.

### 4.4 Collaboration interface document

Write a one-page **interface agreement** stating exactly what the model team needs from you (schema, fields, coverage, versioning) and what you need back from them (new weights / refreshed `model_output`), including how a new model round is re-ingested into the tool. This is the artifact that demonstrates team collaboration ability.

Deliverable: full loop (load → edit → autosave → export → diff → submit update package) reproducible from CLI and UI, plus the interface agreement.

---

## Part 5 — Quality, Robustness, and Plugin Depth (0.5 day + ongoing)

1. **Tests**: schema validation, undo/redo behavior, propagation semantics, export/diff correctness, plugin registry loading; a **headless smoke test** that opens the sample and drives a scripted edit session without manual clicks.
2. **Robustness**: missing/invalid files, out-of-range seeks, empty annotations, very long clips; clear error messages, not stack traces.
3. **Measurements** in `RESULTS.md`: playback/frame-delivery rate, load time, editing response time, batch coverage, autosave behavior; plus a 2–3 item **failure analysis** (bugs you hit and how you fixed them).
Deliverable: passing test suite, `RESULTS.md` with measurements, clean README runbook.

---

## Expected Outcome

By the end of this assignment, the candidate should be able to:

- Set up and develop an interactive **Godot** (or web) client application with clean project structure;
- Design a versioned, validated data contract between a model producer and a client;
- Apply **computer-graphics** reasoning to image display and region editing (coordinate transforms, viewport/camera, picking, rendering performance);
- Build a safe, fast editing workflow that references a mature tool's paradigm (MITK) rather than inventing interaction blindly;
- Implement **batch labelling over similar consecutive frames** with explicit propagate/verify semantics;
- Package corrected data and interface with a (mock) **training service**, and write a crisp cross-team interface agreement;
- Organize the whole tool as a **componentized, plugin-style pipeline** that a teammate can extend.

## Timeline

Total: **10 days**.

| Part | Scope | Suggested time |
|---|---|---|
| Part 1 | Scaffold, contract, sample, frame source, plugin architecture | 2 days |
| Part 2 | Region display (CG) + MITK-style editing | 3 days |
| Part 3 | Video stream + batch labelling of similar frames | 3 days |
| Part 4 | Persistence, diff, training handoff, interface agreement | 1 day |
| Part 5 | Tests, robustness, RESULTS.md | 0.5 day + ongoing |
| Buffer & polish | README runbook, architecture diagram, demo video | remaining |

## Code Submission

Submit through a **private GitHub repository** and add Qingbiao LI
([qingbiao.qli@gmail.com](mailto:qingbiao.qli@gmail.com)) and Tianci Yang ([PatchouliTC](https://github.com/PatchouliTC)) as collaborators.

The repository must include:

- `README.md`: environment, install, run, reviewer test script, keyboard shortcuts, plugin API overview, how to regenerate the sample;
- Godot/web client source organized by the plugin pipeline (core + plugins);
- `python/make_sample_input.py` and `python/frame_source.py`;
- pinned dependencies and Godot version (`.godot`/export settings documented);
- `RESULTS.md` with design decisions, measurements, and failure analysis;
- one architecture diagram (Mermaid/Excalidraw/draw.io).

Do not commit: API keys or credentials, private configuration files, build directories, large binaries/assets (regenerate samples instead).

### Demonstration Video

One video of **no more than 3 minutes**, uploaded privately or linked in the README, with subtitles and narration. Suggested content: open the sample → show the planted model defects → correct each type (move/resize, re-label, add, delete) → batch-label the similar-frames segment → export + diff → submit the training update package. Use unedited captures where possible; clearly label accelerated segments.

## Optional Extensions

Pick **at most one** to go deep, and only after the core is stable:

- **Real model endpoint**: integrate a live `/annotate` HTTP call into the Source stage (timeout/retry/fallback) and measure review throughput vs offline replay.
- **Web front-end comparison**: implement the same core workflow as a complex web front-end and write a short trade-off note vs the Godot client (justify which you would keep).
- **Deep region editing**: full polygon/curve vertex editing with mask export, or GPU-accelerated overlay rendering (shaders) demonstrating deeper graphics work.
- **Model-side loop demo**: connect to a toy "training" service that re-fits on submitted corrections and returns refreshed model output; measure the loop latency and improvement over 2 rounds.
- **Automated defect flagging**: rule-based helpers that pre-flag likely defects for the reviewer (edge-crossing boxes, abrupt track jumps, low confidence).

## A Note Before You Start

We do not require you to finish everything in this assignment. It is intentionally open-ended, and completing every part is not the point. What we value most is a **working, honest, well-documented tool with a clean plugin architecture**: how clearly you define the data contract, how robustly and ergonomically the editing behaves, how correctly the batch and feedback loops work, and how truthfully you report measurements and limitations — including the failure modes you hit. A smaller, reliable, clearly explained tool is worth far more to us than a broad but fragile one.

There is no restriction on the form or amount of AI assistance used for this assignment. However, the candidate is fully responsible for the submitted work and its outcomes.
