# Workspace Media and Label Storage Design

Date: 2026-09-05

## Goal

Replace the file-by-file opening workflow with a workspace-folder workflow. The application discovers nested images and videos without decoding them, decodes a video only after the user selects it, and automatically reads and writes deterministic per-frame labels under the workspace root `label/` directory. Previously saved labels must render on the correct frame during manual navigation and continuous playback.

## Scope

This change includes workspace discovery, deterministic media and label naming, automatic video-cache placement, per-frame label initialization, automatic label loading, atomic automatic saving, and frame/label playback synchronization.

This change does not add annotation tools, change region geometry, introduce a training framework, create training shards, delete existing local files, or change the Model Output V1 region contract.

## Selected approach

Use one deterministic label directory per media item and one JSON label file per logical frame. Use a compact media ID plus a zero-based, six-digit frame index in every label filename:

```text
sample_id = <media_id>_<frame_index:06d>
```

Media IDs use the media type, a bounded readable ASCII slug, and the first 16 hexadecimal characters of the SHA-256 digest of the normalized workspace-relative POSIX path:

```text
vid_<safe_stem>_<relative_path_digest_16>
img_<safe_stem>_<relative_path_digest_16>
```

Examples:

```text
vid_operation_8f52c01e94aa3210_000042.json
img_overview_3a91b827d12044e8_000000.json
```

The slug is lowercase ASCII, contains only `a-z`, `0-9`, and `_`, collapses consecutive separators, is limited to 32 characters, and falls back to `media`. The digest is computed from the exact normalized relative path with `/` separators. A standalone image is a one-frame media item whose frame index is always `000000`.

The path-based digest is selected because workspace discovery must not read every byte of every video. The full source SHA-256 remains in the media manifest and video cache manifest to detect source replacement. If the source at an existing path no longer matches its manifest, the application refuses to reuse those labels or cache and preserves the old data unchanged.

## Workspace layout

```text
workspace/
├── operation.mp4
├── overview.jpg
├── patient_02/
│   └── secondary.mp4
├── label/
│   ├── vid_operation_8f52c01e94aa3210/
│   │   ├── label_manifest.json
│   │   ├── vid_operation_8f52c01e94aa3210_000000.json
│   │   ├── vid_operation_8f52c01e94aa3210_000001.json
│   │   └── ...
│   └── img_overview_3a91b827d12044e8/
│       ├── label_manifest.json
│       └── img_overview_3a91b827d12044e8_000000.json
└── .annotool/
    └── cache/
        └── vid_operation_8f52c01e94aa3210/
            ├── manifest.json
            └── frames/
                ├── frame_000000.png
                └── ...
```

`label/` contains annotations and their media manifests only. `.annotool/cache/` contains generated video frames and the existing dataset manifest. The existing zero-based `frame_000000.png` cache contract remains unchanged to avoid breaking the validated decoder and normalized-source plugin.

There is no continuously maintained workspace-wide annotation index in this change. Each media manifest provides a constant-time filename formula and a frame count, so later training preparation can enumerate one manifest per media item and derive every label path without scanning every label filename. This avoids a second mutable index whose consistency would have to be maintained after every workspace change.

## Label manifest contract

Each media directory contains `label_manifest.json` with these fields:

- `schema_version`: integer `1`.
- `media_id`: the generated ID and enclosing directory name.
- `media_type`: `image` or `video`.
- `source_relative_path`: normalized path relative to the workspace root.
- `source_sha256`: full lowercase SHA-256 of the selected source.
- `frame_count`: positive integer; `1` for an image.
- `frame_digits`: integer `6`.
- `label_pattern`: exact string `<media_id>_{frame:06d}.json`.
- `initialization_state`: `initializing` or `ready`.
- `source_manifest_path`: workspace-relative cache manifest path for video, otherwise `null`.

The authoritative JSON Schema is stored outside `core/schemas/`, because that directory remains reserved for the sole Model Output V1 record schema. The new schema belongs at `core/workspace/workspace-label-manifest-v1.schema.json`. Python and Godot use separate adapters around this one logical contract, with shared valid and invalid fixtures.

Each frame label remains a single Model Output V1 JSON object. It is not JSONL and does not wrap or duplicate the region schema. The record's `frame` must equal the index encoded by its filename. Video `time_s` must equal the corresponding cache-manifest timestamp. The record `source` continues to identify the original frame source; `label_manifest.json` owns the mapping between that source and `media_id`.

## Components and responsibilities

### Workspace catalog

A focused workspace catalog scans the chosen root recursively, builds the folder/media tree, and excludes `label/`, `.annotool/`, hidden temporary files, symbolic-link traversal, and unsupported extensions. Discovery reads directory entries and basic file metadata only. It never probes or decodes video.

The catalog produces media entries containing display name, media type, absolute source path, normalized relative path, and deterministic media ID. The dataset explorer renders this view model and emits a media-selection signal. The timeline remains the frame-navigation UI; the left tree does not materialize every video frame.

### Workspace media controller

The main scene owns one workspace media controller that coordinates the catalog, source plugins, video import controller, and label repository. Opening a workspace validates and displays its media tree. Selecting an image opens it directly. Selecting a video checks the deterministic cache location and reuses it only when its manifest is valid and identifies the same source; otherwise it launches the existing background decoder at that location.

The video import dialog no longer asks the user to choose an output parent or directory name. It displays the selected source, deterministic destination, progress, and cancel action. Cancellation preserves the original video, current source, existing labels, and any previously published valid cache.

### Label repository

A label repository owns media-directory creation, manifest validation, record loading, expected-path calculation, atomic record writes, initialization progress, and unsaved-write tracking. Source plugins continue to own pixels and frame metadata. `AnnotationStore` continues to own immutable model records and mutable corrected records in memory.

When a media item has no label directory, the repository atomically publishes an `initializing` manifest, synthesizes valid empty Model Output V1 records in memory, and queues their frame files for incremental creation. The first frame can open immediately after the image or decoded video source is ready. Empty files are then materialized in bounded batches without blocking UI input. A user edit to a queued frame writes the edited record first and removes that frame from the empty-file queue. When every expected file exists and validates, the repository atomically changes the manifest state to `ready`.

When reopening a media item, a `ready` manifest requires every expected frame file to exist and validate. Missing or malformed files are reported as data errors and are never silently replaced. An `initializing` manifest may contain missing frame files after an interrupted run; those frames are synthesized as empty records and requeued, while valid existing records are preserved.

### Automatic persistence

Every successful corrected-record replacement, including undo, redo, relabeling, geometry edits, and range operations, triggers an immediate atomic write of the affected frame. The repository writes a sibling temporary file, flushes and closes it, validates the serialized JSON, and renames it over the target. No partially written JSON becomes visible at the final path.

If an automatic write fails, the in-memory edit remains visible and is marked unsaved. Playback pauses, the status bar identifies the affected frame and path, and source/workspace replacement is refused while unsaved records remain. A later edit or explicit internal retry attempts the pending writes again. The application never reports a failed write as saved.

## Data flow

### Open workspace

1. The user chooses a directory.
2. The catalog validates the root and recursively discovers supported media while excluding managed directories.
3. The explorer displays the real nested folder structure without decoding video.
4. No media source is loaded until the user selects an image or video.

### Select image

1. Compute the image media ID from its workspace-relative path.
2. Open and validate the image through the existing single-image source.
3. Calculate the existing source SHA-256 and prepare or validate its label manifest.
4. Load `img_<...>_000000.json`, or initialize an empty record when this is a new image.
5. Commit the image, label, explorer selection, and active persistence context together.

### Select video

1. Compute the video media ID without opening or hashing the complete video.
2. Reuse `.annotool/cache/<media_id>/` only if its manifest and stored source identity are valid.
3. Otherwise decode the selected video in the existing background process to the deterministic cache path.
4. Prepare or validate `label/<media_id>/label_manifest.json` against the decoded manifest.
5. Load and validate prior per-frame labels, or synthesize new empty records and start incremental file materialization.
6. Open the normalized frame source with those records and commit the new media context only after frame zero, its timestamp, and its annotation are all valid.

### Edit and playback

1. An edit command validates and replaces one or more corrected records.
2. Each changed record is immediately written to its deterministic frame-label path.
3. Playback requests the next explicit frame index.
4. The source loads that index's PNG and timestamp; the store provides the same index's restored or edited record.
5. The UI switches only after image, timestamp, and annotation all succeed.
6. A load, validation, or persistence failure pauses playback and preserves the last fully accepted image and annotation.

This preserves the current no-frame-skipping behavior. Slow loading reduces playback speed rather than presenting a frame with another frame's annotations.

## Compatibility and migration

Existing direct source APIs and normalized directories remain readable for tests and compatibility. The toolbar's user-facing Open action changes to workspace-directory selection. Existing `model_output_v1.jsonl` files are not deleted, moved, or silently rewritten.

The first implementation provides a non-destructive legacy import path: when a compatible normalized source supplies valid Model Output V1 records and the workspace has no label directory for that media, those records automatically seed the new per-frame files. If both legacy records and new per-frame labels exist, the new per-frame label directory is authoritative and the legacy file remains untouched.

## Error handling and safety

- Invalid workspace roots or empty workspaces do not replace the current valid workspace/source.
- Directory traversal and symbolic-link escapes are rejected for workspace-relative paths, cache paths, manifests, and labels.
- Cache or label collisions never overwrite existing unrelated content.
- Source checksum, media ID, frame count, frame index, timestamp, and label filename are cross-validated before activation.
- Corrupt prior labels cause a bounded error naming the exact file; they are not converted to empty annotations.
- Failed media selection pauses playback and preserves the previous accepted image, annotation, source, and explorer selection.
- Managed background initialization can resume, but a ready manifest is strict and never repairs data silently.
- No implementation step deletes existing user media, labels, caches, environments, or generated artifacts.

## Training boundary

The `media_id_frame` sample name is stable within a workspace and distinguishes duplicate basenames at different relative paths. A future training reader can enumerate `label/*/label_manifest.json`, derive each label path from `frame_count` and `label_pattern`, and join video labels to cache-manifest image paths and timestamps. When multiple independent workspaces are combined, the training preparation step must namespace sample IDs by workspace or verify the full source SHA-256 before merging. A future exporter may copy or shard images and labels under the resulting common sample ID without changing annotation identity.

Per-frame JSON is the editable source of truth, not the final high-throughput training container. When the training pipeline is defined, it can compile these records into NDJSON, WebDataset, TFRecord, Arrow, or another appropriate shard format. This separation follows the direct image/label matching used by [CVAT YOLO](https://docs.cvat.ai/docs/manual/advanced/formats/format-yolo/), explicit frame metadata used by [CVAT manifests](https://docs.cvat.ai/docs/dataset_management/dataset_manifest/), and the streaming or shard-oriented loading documented by [Ultralytics](https://docs.ultralytics.com/datasets/detect/), [WebDataset](https://webdataset.github.io/webdataset/webdataset/), and [TensorFlow](https://www.tensorflow.org/tutorials/load_data/tfrecord).

## Verification criteria

- Opening a nested workspace discovers supported images and videos without starting video import.
- `label/` and `.annotool/` never appear as user media.
- Same-named media in different nested folders receive different deterministic IDs.
- Selecting a video starts exactly one background import on a cache miss and reuses a valid cache on the next selection.
- Images and videos generate labels named `<media_id>_<frame:06d>.json`.
- New media opens before background empty-label materialization completes.
- Interrupted initialization resumes without overwriting valid label files.
- Every edit, undo, redo, and range operation writes the correct frame atomically.
- Reopening a workspace restores previous annotations.
- Continuous playback renders each frame with its own restored annotation and never skips indices to catch up.
- A missing or corrupt ready-state label pauses/refuses activation without displaying mismatched data.
- Existing direct image and normalized-sequence behavior remains covered by regression tests.
- Python contract tests, Godot unit/integration tests, documentation checks, and the full project test runners pass from the saved working tree.
