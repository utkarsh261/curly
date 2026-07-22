# JSON editor and response memory analysis

- Date: 2026-07-22
- Analyzed commit: `70e97b062a273de53d11f4e11f681684b401c4d7`
- Platform: macOS on Apple silicon

## Question

Does the memory spike seen while editing a JSON request remain approximately fixed as request and response sizes grow, or does it scale with payload size?

## Conclusion

The dominant costs are not fixed. Request highlighting, request validation, response formatting, and Pretty response rendering all grow with the amount and token density of JSON. The response path has the largest multiplier: a token-dense 1 MB raw JSON response produced a 146.6 MiB transient footprint increase when formatted and displayed in Pretty mode; a 2 MB response produced a 284.7 MiB increase.

The streaming lexer and structural-analysis changes on the analyzed commit are effective, but they do not make the complete editor or response pipeline size-independent.

## Method

Small standalone probes compiled the production implementations with `swiftc -O`. Each data point ran in a fresh process to avoid allocator reuse between sizes. A background sampler read `task_vm_info.phys_footprint` every 250 microseconds and recorded the peak above the pre-operation baseline.

The probes exercised these paths independently:

- `SyntaxAnalysisResult.analyze`
- `JSONValidator.validate`
- editable `JSONCodeEditorView.Coordinator.applyHighlighting`
- `FileRequestLibraryRepositories.saveHiddenDraft`
- `DefaultResponseFormatter.format`
- response formatting followed by construction and highlighting of the read-only Pretty editor

Inputs were compact arrays of numeric values. This is deliberately token-dense and becomes line-dense when pretty-printed, so the measurements describe a near-worst-case JSON shape rather than an average API response. The slopes and allocation sources are still representative; exact multipliers will vary with JSON structure.

## Results

Peak physical-footprint increase:

| Operation | ~100 B | ~10 KB | ~100 KB | ~1 MB | ~2 MB |
| --- | ---: | ---: | ---: | ---: | ---: |
| Structural analysis | 0.02 MiB | 0.02 MiB | 0.02 MiB | 0.02 MiB | — |
| Request validation | 0.05 MiB | 0.20 MiB | 1.52 MiB | 7.94 MiB | 17.67 MiB |
| Editable full-document highlighting | 1.59 MiB | 1.80 MiB | 3.67 MiB | 19.75 MiB | 35.08 MiB |
| Persist one request draft | 0.11 MiB | 0.13 MiB | 0.44 MiB | 2.11 MiB | 2.77 MiB |
| Format JSON response | 0.22 MiB | 0.75 MiB | 4.55 MiB | 40.81 MiB | 69.03 MiB |
| Format and display Pretty response | 2.45 MiB | 4.36 MiB | 15.95 MiB | 146.58 MiB | 284.69 MiB |

The 1 MB compact response became approximately 2.5 MB of pretty text. The 2 MB compact response became approximately 5 MB. After the complete Pretty response operation, the measured retained increases were about 60.2 MiB and 102.7 MiB respectively. Rendering took about 7.0 seconds and 14.3 seconds respectively.

## Attribution

### Structural analysis

Streaming tokenization works as intended. `SyntaxAnalysisResult` retains only its line map and fold ranges, rather than the source and a full token array. Its peak stayed effectively flat for compact input through 1 MB.

Pretty, multiline input still requires a line map. For a 1 MB, approximately 200,000-line document, structural analysis retained about 2.8 MiB. This is proportional to line count but much smaller than TextKit highlighting.

### Editable request highlighting

`JSONCodeEditorView.Coordinator.textDidChange` performs structural analysis and full-document syntax highlighting after every edit. The token array is no longer materialized, but TextKit still stores attributes across the complete document and every keystroke still performs O(document size) work.

Full highlighting took about 1.5 seconds for 1 MB and 3.0 seconds for 2 MB in the probe. After an editor was already initialized, one additional edit increased current footprint by only about 0.03 MiB because TextKit reused existing allocations; it still repeated the proportional CPU work. Allocator reclamation and reuse can therefore make the same work appear as repeated rises and falls in Xcode's memory graph.

### Validation and persistence

Validation creates comment-stripped text, UTF-8 data, and a Foundation JSON object graph. Its allocations are mostly temporary, but its peak scales with the request body.

Every edit also snapshots the request, enqueues persistence, JSON-encodes the complete request-library container, and atomically rewrites the file. One isolated save was comparatively small, but it remains proportional to the request and library size. Rapid editing can temporarily retain multiple snapshots while persistence operations wait on the serialized task chain.

### Response formatting

The formatter holds or creates several payload-sized representations:

1. Raw response `Data`
2. The Foundation object graph returned by `JSONSerialization`
3. A recursively copied `JSONValue` tree
4. A second Foundation object graph rebuilt from `JSONValue`
5. Pretty-printed `Data`
6. The retained Pretty `String`

The final `ResponseBody` retains the raw data, `JSONValue`, and pretty string. This accounts for both the high transient peak and a meaningful retained increase.

### Read-only Pretty editor

Viewport-limited tokenization reduces the number of JSON tokens processed while scrolling, but initial highlighting still calls `setAttributes` over the full text-storage range to establish base attributes. That forces TextKit to process the complete document before the viewport slice is colored.

For a 1 MB already-pretty document:

- Structural analysis peaked at about 2.8 MiB.
- Constructing the TextKit storage/view peaked at about 1.4 MiB.
- The highlighting call peaked at about 48.3 MiB and retained about 15.0 MiB.
- The complete read-only editor initialization peaked at about 52.6 MiB.

The full-range base-attribute operation is therefore the dominant read-only editor cost despite viewport-limited lexical highlighting.

## Live-process observation

During the investigation, the Xcode-launched process had a current physical footprint near 102 MiB and a recorded peak near 227 MiB. The live allocated heap was much smaller than the graph's high-water mark, and `leaks` reported only 768 bytes in unrelated AppKit objects. This supports transient payload processing and allocator high-water behavior, rather than a large persistent leak, as the explanation for the observed graph.

## What the analyzed commit improves

- Streams lexer output to production consumers instead of materializing a token array.
- Stops `SyntaxAnalysisResult` from retaining source text and tokens.
- Limits lexical coloring of read-only responses to the visible range.
- Disables undo storage for read-only response editors.
- Removes Format/Compact's separate validation pass while preserving located formatting diagnostics.

These changes reduce analysis allocations and some redundant work. They do not eliminate the proportional TextKit attribute cost or duplicate response representations.

## Follow-up PR scope

The follow-up performance PR should treat the following as separate, measurable changes:

1. Avoid full-range attribute mutation when a read-only Pretty editor is first displayed.
2. Remove the `JSONValue -> Foundation object` reconstruction used for pretty-printing, and reduce the number of simultaneously retained response representations.
3. Define a safe large-response policy, such as an automatic lightweight/raw mode above a measured threshold, because the transport currently buffers the complete response and display has no size guard.
4. Make editable request highlighting incremental, viewport-bounded, or debounced without compromising inline diagnostics.
5. Coalesce draft persistence during rapid typing so obsolete payload-sized snapshots cannot queue.
6. Add repeatable scaling tests or benchmarks that record peak footprint, retained footprint, and latency at multiple sizes.

Acceptance should be based on slopes, not only a single small-payload measurement. At minimum, measurements should cover 100 KB, 1 MB, and 5 MB request and response bodies with both token-dense and representative nested-object fixtures.

## Limitations

- Standalone optimized probes do not reproduce all SwiftUI, Xcode debugger, and system-framework overhead of the full debug application.
- Physical-footprint deltas vary with allocator state; separate processes and multi-size comparisons were used to make scaling visible.
- The numeric-array fixture exaggerates token and line density. Real-world payloads can have lower multipliers, but the current algorithms remain proportional.
