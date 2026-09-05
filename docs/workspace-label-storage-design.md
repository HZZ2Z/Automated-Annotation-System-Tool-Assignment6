# Workspace Media and Label Storage Design

Date: 2026-09-05

## Goal

Replace file-by-file opening with a workspace-folder workflow. The application discovers nested photos, video files, and already-extracted video frame sequences, opens media only after it is selected in the left tree, and automatically reads and writes one deterministic label JSON per media item. Previously saved annotations must remain aligned during manual navigation and continuous playback.

## Scope

This change includes workspace discovery, sequence detection, stable media identity, lazy video decoding, single-file label storage, automatic label loading, atomic automatic saving, and frame/annotation playback synchronization.

It does not add annotation tools, change region geometry, choose a training framework, rewrite source datasets, delete local content, or change the Model Output V1 region contract.

## Selected storage model

The workspace owns one managed `label/` directory. Each logical media item owns exactly one native annotation file:

```text
workspace/
├── operation.mp4
├── overview.jpg
├── videos/
│   └── VID68/
│       ├── 000016.png
│       ├── 000023.png
│       └── ...
├── labels/                 # optional source-dataset labels; read-only
│   └── VID68.json
├── label/                  # annotation tool output
│   ├── operation.json
│   ├── overview.json
│   └── VID68.json
└── .annotool/
    └── cache/
        └── operation/
            ├── manifest.json
            └── frames/
                ├── frame_000000.png
                └── ...
```

There are no per-frame label files, media subdirectories inside `label/`, or separate `label_manifest.json` files. Media metadata and frame annotations live in the same media JSON.

## Media identity and collisions

The preferred media ID is the source file or sequence-directory stem converted to a portable ID:

- Preserve ASCII letters and digits.
- Convert separators to `_`.
- Remove leading and trailing separators.
- Fall back to `media`.
- A media ID must be unique within the opened workspace.

Examples are `VID68`, `operation_01`, and `overview`. If two discovered media items normalize to the same ID, neither is silently renamed: workspace opening reports both relative paths and requires an unambiguous source name. This preserves stable training identity when files are added elsewhere in the workspace.

The label path is always:

```text
label/<media_id>.json
```

## Native media-label JSON

The authoritative schema is `core/workspace/media-label-v1.schema.json`. A native file contains:

```json
{
  "schema_version": 1,
  "media_id": "VID68",
  "media_type": "image_sequence",
  "source_relative_path": "videos/VID68",
  "source_sha256": null,
  "frame_digits": 6,
  "frames": {
    "16": {
      "schema_version": 1,
      "source": "VID68",
      "frame": 16,
      "time_s": 16.0,
      "regions": []
    },
    "23": {
      "schema_version": 1,
      "source": "VID68",
      "frame": 23,
      "time_s": 23.0,
      "regions": []
    }
  }
}
```

Required top-level fields are:

- `schema_version`: integer `1`.
- `media_id`: the unique workspace media ID and label filename stem.
- `media_type`: `image`, `video`, or `image_sequence`.
- `source_relative_path`: normalized POSIX path relative to the workspace.
- `source_sha256`: full lowercase source SHA-256 for a single image or video file; `null` for an external frame sequence whose individual files are validated when opened.
- `frame_digits`: integer `6`.
- `frames`: object keyed by the unpadded decimal original frame ID.

Each `frames` value is exactly one Model Output V1 record. The dictionary key parsed as an integer must equal the record's `frame`. Video and sequence timestamps must equal source frame metadata. The file stores explicit frames only, so absence means “not annotated/imported”; an explicit record with `regions: []` is a labelled negative frame.

The native schema is stored outside `core/schemas/`, which remains reserved for the sole Model Output V1 schema. Godot and Python use separate adapters around the same contract and fixtures.

## Three identifiers

Playback and training use three deliberately separate values:

- `playback_index`: zero-based position in the currently loaded ordered frame list.
- `frame_id`: original source frame number. It may be sparse, such as `16, 23, 33`.
- `sample_id`: training-time identifier `<media_id>_<frame_id:06d>`.

For example, the first displayed item of `VID68` may have `playback_index=0`, `frame_id=16`, and `sample_id=VID68_000016`. The sample ID is derived when reading or exporting training data; it is not redundantly stored in every record.

A standalone photo has one source frame with `playback_index=0`, `frame_id=0`, and a derived sample ID such as `overview_000000`.

## Workspace catalog

The catalog scans the selected root recursively and excludes the managed `label/` and `.annotool/` directories, hidden temporary entries, symbolic-link traversal, and unsupported files.

It discovers:

1. Standalone images: supported images that are not claimed by a sequence.
2. Video files: supported video extensions, without probing or decoding them during discovery.
3. Image sequences: a directory containing at least two image files whose stems are non-negative decimal integers. A matching source-dataset file such as `labels/VID68.json` strengthens detection but is not required.

When a directory is accepted as an image sequence, its child images are not also exposed as standalone photos. The catalog stores only summary metadata during workspace opening. Numeric filenames are enumerated and image pixels are decoded only after the sequence is selected.

The left explorer displays the real nested folder/media structure. Video and sequence frames remain in the timeline and are not materialized as thousands of left-tree entries.

## Media opening

### Standalone image

Selecting an image opens it through the existing single-image Source plugin. The label repository then validates or creates `label/<media_id>.json` and loads frame ID `0`.

### Video file

Selecting a video computes `.annotool/cache/<media_id>/`. A valid cache is reused only when its manifest matches the selected video's full SHA-256. A cache miss launches the existing background FFmpeg decoder at that deterministic path. An existing incompatible cache is reported and preserved rather than overwritten.

After decoding, the existing indexed-PNG Source plugin supplies playback indices and timestamps. For decoded video, source frame IDs are the zero-based decoded frame numbers.

### Existing image sequence

Selecting a sequence enumerates numeric filenames, sorts them by integer frame ID, validates each image path, and builds an in-memory source mapping:

```text
playback index 0 -> frame ID 16 -> 000016.png
playback index 1 -> frame ID 23 -> 000023.png
```

This path does not run FFmpeg.

## Existing dataset-label import

Source labels such as `Dataset_test/.../labels/VID68.json` are read-only inputs. A source-specific adapter recognizes the CholecT50 video JSON shape, including `video`, `fps`, `annotations`, and category tables.

If `label/VID68.json` does not exist, compatible source labels may seed the in-memory native records and the first atomic native save. If the native file exists, it is authoritative. The original `labels/VID68.json` is never modified, moved, or deleted.

The CholecT50 adapter preserves sparse original frame IDs. It does not pretend that `num_frames` is the largest frame number or that every image has an annotation key.

## Automatic loading and saving

Opening a selected media item loads its single native JSON once. Frame records are kept in memory and looked up by original frame ID, so playback does not read or parse JSON on every tick.

Every successfully committed edit marks the corresponding frame ID dirty. Saves are automatically coalesced with a short 300 ms debounce and publish the complete media JSON using a sibling temporary file:

1. Serialize with finite JSON numbers only.
2. Flush and close the temporary file.
3. Parse and validate the temporary file.
4. Atomically rename it over `label/<media_id>.json`.

Navigation remains responsive because repeated pointer updates are not committed edits and closely spaced committed commands share one save. Pending changes are synchronously flushed before media/workspace replacement and application exit.

If saving fails, the in-memory edit remains visible, playback pauses, the status names the media/frame/path, and media or workspace replacement is refused until retry succeeds. The application never reports an unsuccessful write as saved.

## Playback synchronization

`set_frame(playback_index)` remains the only manual and automatic navigation path:

1. Resolve the source entry at the playback index.
2. Read its original `frame_id` and timestamp.
3. Load the matching image.
4. Look up the record using that exact `frame_id`; if absent, synthesize an in-memory empty display record without silently persisting it.
5. Validate image, frame ID, timestamp, and record together.
6. Commit the visible image, annotation, timeline position, and label only after all validation succeeds.

Failure pauses playback and preserves the last fully accepted image and annotation. Playback still advances by at most one ordered source item per tick; slow loading slows playback instead of skipping frames.

## Safety and compatibility

- Invalid or empty workspaces do not replace the current valid workspace.
- Media-ID collisions are explicit errors and never overwrite labels.
- Managed and source-dataset label directories never appear as user media.
- Containment and symbolic-link checks apply to workspace, source, cache, and label paths.
- Corrupt native labels are bounded errors naming the exact file and are never converted to empty annotations.
- Existing direct image and normalized-directory APIs remain readable for regression tests.
- Existing `model_output_v1.jsonl` and source dataset JSON files remain untouched.
- No implementation step deletes user media, labels, caches, environments, or generated artifacts.

## Training boundary

A training reader enumerates `label/*.json`, then derives each sample ID from the file's `media_id` and each explicit frame key:

```text
sample_id = <media_id>_<frame_id:06d>
```

It joins that record to either the source sequence image or the decoded cache entry using the stored source path and frame mapping. When combining independent workspaces, the training preparation step namespaces media IDs by dataset/workspace ID.

The per-media JSON is the editable source of truth. A future training exporter may compile records into NDJSON, WebDataset, TFRecord, Arrow, or another sharded format without changing annotation identity.

## Verification criteria

- Opening `Dataset_test/cholect50-challenge-val` shows `VID68`–`VID75` as five sequence media items instead of hundreds of independent photos.
- Workspace opening starts no video decoder.
- Selecting an existing sequence opens its sparse numeric frame list without FFmpeg.
- Selecting a video file starts one background import on a cache miss and reuses a valid cache later.
- `label/` contains exactly one JSON per annotated media and no per-frame label files.
- Existing CholecT50 source JSON remains byte-for-byte unchanged.
- Frame ID `16` maps to `000016.png`, JSON key `"16"`, and derived sample ID `VID68_000016`.
- Absent frame entries remain distinguishable from explicit empty-region records.
- Automatic edits, undo, redo, and range operations atomically update the active media JSON.
- Reopening restores previous annotations.
- Continuous playback displays each ordered image with the annotation for its original frame ID.
- Save, label validation, or frame loading failure pauses playback and preserves the last accepted UI state.
- Existing direct image and normalized-sequence behavior remains covered.
- Python and Godot suites pass after implementation.
