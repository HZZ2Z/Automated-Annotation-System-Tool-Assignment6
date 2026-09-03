# Plugin API

This document freezes **API version 1** for the Part 1 pipeline. The executable contract is `client/pipeline/plugin_api.gd`; registry compatibility tests must change before this document or the version changes.

## Manifest

Every plugin is a directory below `client/plugins/<stage>/<plugin-name>/` containing `plugin.json` and its entry script. The manifest permits exactly these fields:

- `id`: non-empty plugin identifier, unique within its stage.
- `version`: non-empty implementation version string.
- `api_version`: integer `1`; any other value is incompatible.
- `stage`: one of `source`, `render`, `edit`, or `feedback`.
- `entry`: safe, relative POSIX path to an instantiable GDScript resource.

Example:

```json
{
  "id": "example_source",
  "version": "1.0.0",
  "api_version": 1,
  "stage": "source",
  "entry": "plugin.gd"
}
```

The entry script must instantiate without arguments and extend `RefCounted`. Unknown fields, unsafe paths, duplicate IDs, unknown stages, malformed JSON, and missing methods are rejected. Discovery is deterministic and failure isolation is per plugin.

## Source

Required methods:

- `open(path: String) -> PackedStringArray`: validate and stage one source; an empty array means success.
- `get_frame_count() -> int`: number of authoritative indexed frames.
- `get_frame_entry(index: int) -> Dictionary`: defensive copy containing at least `frame`, `time_s`, and `image_path`.
- `get_model_records() -> Array[Dictionary]`: deep copy of one canonical model-output record per frame.
- `get_manifest() -> Dictionary`: deep copy of the canonical dataset manifest.
- `load_texture(index: int) -> Texture2D`: decoded frame or `null` with a readable plugin error.
- `close() -> void`: release cache/resources and return to an empty state; it must be safe to call repeatedly.

The Source owns decoding and cache lifetime. Main owns the installed instance. Frame indices, manifest entries, and records must align exactly. Public getters return a deep copy so downstream code cannot mutate Source truth.

## Render

Required methods:

- `set_state(texture: Texture2D, record: Dictionary, transform, selected_id: String, opacity: float) -> void`: replace transient drawing state.
- `draw(canvas: CanvasItem) -> void`: draw the current image and overlays.
- `hit_test(image_point: Vector2) -> Dictionary`: return a copied hit region or an empty dictionary.

The Render stage receives already validated data and the same image/viewport transform used for picking. It owns no annotation state and must not mutate its input record.

## Edit

Required lifecycle and interaction methods:

- `activate(context: Dictionary) -> PackedStringArray`
- `set_active_tool(tool_id: StringName) -> PackedStringArray`
- `get_active_tool() -> StringName`
- `handle_pointer(event: InputEvent, image_position: Vector2) -> void`
- `handle_key(event: InputEvent) -> bool`
- `begin_add_box() -> void`
- `cancel() -> void`
- `relabel_selected(class_label: String) -> PackedStringArray`
- `set_selected_track_id(track_id: Variant) -> PackedStringArray`
- `set_selected_fill(filled: bool) -> PackedStringArray`
- `set_selected_geometry(box: Array) -> PackedStringArray`
- `delete_selected() -> PackedStringArray`
- `deactivate() -> void`

`activate` receives `store`, `history`, `viewport`, `get_current_frame`, `get_selected_region`, `set_selected_region`, `status`, and `taxonomy`. It validates the full dependency surface before becoming active. Supported tool IDs are `select`, `move`, `box`, `fill`, and `delete`.

The lifecycle is explicit: Main creates a fresh instance for a candidate source, activates it against staged state, and installs it only after activation succeeds. `cancel` restores committed display state and creates no history; `deactivate` cancels, disconnects signals, clears references, and is idempotent. A completed edit is submitted through history as one validated command.

## Feedback

Required method:

- `export(context: Dictionary) -> PackedStringArray`: validate a complete corrected snapshot and publish it; an empty array means success.

The Part 1 implementation accepts `records: Array` and `output_path: String`. It emits:

- `export_finished(success: bool, path_or_error: String)`

The plugin takes a deep copy before changing record sources to `human_corrected`. Each copy must satisfy the shared annotation validator before any write. Publication uses a sibling temporary file and rename; failure isolation requires the prior valid output to remain unchanged. Part 4 may add diff and training-package files behind the same `export(context)` boundary.

## Errors, data ownership, and compatibility

Expected validation and I/O failures return a `PackedStringArray` of concise messages; they do not crash the UI or expose a raw stack trace to the user. Empty means success. Methods returning dictionaries or record arrays return a deep copy unless the object is explicitly transient render state. Plugin-private fields are never a core interface.

API compatibility is exact: adding or removing a required method requires coordinated tests, documentation, and an `api_version` change when backward compatibility cannot be maintained. The registry checks method presence; each stage's contract tests check behavior and ownership.

## Add a plugin

1. Create `client/plugins/<stage>/<new-plugin>/`.
2. Add a five-field `plugin.json` with `api_version: 1` and a unique stage-local ID.
3. Implement every method listed for that stage in an argument-free `RefCounted` script.
4. Return defensive copies and recoverable errors according to the rules above.
5. Add focused behavior tests and run the complete Godot suite.
6. Launch the client and confirm discovery through `get_discovered_plugin(stage, id)`.

That directory is discoverable **without changing the registry** or Main's discovery loop. Main configuration selects an alternative plugin ID only when the product intentionally changes which implementation is active.
