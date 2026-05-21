# Technical One-Pager
## Native macOS cURL Runner

## 1. Technical Goal
Build a native macOS app that feels fast in `v0.1`, stays maintainable through MVP, and can absorb post-MVP features without architectural churn. The design should favor a small, clear core with extension points around request execution, persistence, response viewing, variables, automation, and menu bar workflows.

## 2. Recommended Stack
- **App UI**: SwiftUI for primary UI, with targeted AppKit bridging where macOS-specific controls or performance require it
- **Language / Runtime**: Swift, using modern concurrency (`async/await`, actors)
- **Networking**: `URLSession` behind an execution abstraction
- **Persistence**: repository boundaries from the start; SQLite-backed local store introduced after `v0.1` and carried into MVP
- **Menu Bar**: native macOS menu bar integration
- **Data Format**: canonical internal request model, with `curl` import/export as a first-class boundary

This keeps the product fully native, modern, and aligned with long-term maintainability while allowing `v0.1` to stay session-scoped.

## 3. Architectural Style
Use a layered, modular architecture with clear domain boundaries:

- **Presentation layer**: windows, menu bar UI, request editor, response viewer
- **Application layer**: request execution workflows, recent requests, history coordination, variable resolution, scripting orchestration later
- **Domain layer**: core models and business rules
- **Infrastructure layer**: persistence, networking, `curl` parsing/export, local storage, scripting runtime adapters later

This should be paired with protocol-based boundaries so major subsystems can evolve independently.

## 4. Core Design Patterns
Recommended patterns for this app:

- **Unidirectional state flow** in the UI  
  Keeps request editing, response rendering, and menu bar state predictable.

- **Repository pattern** for persistence  
  Keeps storage details out of product logic and makes it easier to grow from simple saved requests into history, recent requests, graveyard, and snapshots.

- **Strategy pattern** for import/export and execution  
  `curl` parsing, `curl` generation, request execution, response rendering, and later scripting should all sit behind replaceable interfaces.

- **Pipeline / middleware pattern** for request lifecycle  
  Best fit for future pre-request and post-request scripting, token refresh, retry policies, and response extraction.

- **Actor-based concurrency boundaries**  
  Useful for execution state, recent-request tracking, response history, and future background workflows without race-condition sprawl.

## 5. Canonical Core Model
The app should revolve around a small set of stable product entities:

- `Request`
- `RequestVersion`
- `ResponseSummary`
- `ResponseBody`
- `RecentRequest`
- `Variable` later
- `ExecutionResult`
- `Collection` only if product scope later needs it

The key design choice is this:
**do not make raw `curl` text the internal source of truth.**
Instead, parse `curl` into a canonical request model, edit that model in the app, and regenerate `curl` from it when needed.

That gives the UI, persistence layer, menu bar, and future automation a stable foundation.

## 6. Execution Model
Request execution should be handled by a dedicated Request Execution Engine with a clean lifecycle:

1. resolve request data
2. execute request
3. capture metadata
4. store or publish last result / recent request state
5. publish UI updates
6. run post-processing hooks later

This engine should be isolated from the UI and callable from both:
- main app workflows
- menu bar workflows

That shared execution path is important. The menu bar should not become a special-case implementation.

## 7. Persistence Direction
Define repository boundaries from the beginning, but defer durable local persistence until the step between `v0.1` and MVP.

Why:
- `v0.1` is intentionally session-scoped in the current product plan
- MVP still needs durable request/history storage
- MVP adds recent requests and reusable request management
- post-MVP may add snapshots, graveyard, diffs, and response history
- SQLite handles that progression cleanly without forcing a storage rewrite

Recommended progression:
- `v0.1`: in-memory/session implementations behind repository interfaces
- between `v0.1` and MVP: introduce SQLite-backed implementations
- MVP onward: durable local app state uses the SQLite-backed store

Requests should remain shareable as plain `curl`, but durable local app state should be managed through the internal store once persistence is introduced.

## 8. Performance Posture
Performance should be a first-class design concern, but handled through good architecture rather than early over-engineering.

The right approach is:
- make the core request and response pipeline efficient by default
- avoid UI designs that require rendering entire large payloads eagerly
- add specialized handling only where payload size or interaction patterns justify it

### Performance principles
- **Lazy over eager**: parse, render, diff, and search incrementally where possible
- **Separate storage from presentation**: do not make the UI tree the source of truth for response data
- **Background heavy work**: parsing, indexing, diff prep, and large searches should stay off the main UI thread
- **Progressive enhancement**: `v0.1` handles normal JSON very well; MVP/post-MVP add large-payload optimizations only where needed
- **Single shared response representation**: response rendering, search, diffing, and extraction should build on the same underlying response model rather than each creating separate expensive transforms

### JSON response model direction
For normal responses, a structured JSON tree model is enough.

For larger responses, the architecture should allow a response body to be represented in more than one form:
- raw response bytes / text
- parsed JSON document
- lightweight tree index for viewer expansion/collapse
- searchable path/value index later if needed

That matters because:
- tree rendering needs fast expand/collapse
- diffing needs stable node/path identity
- search needs fast traversal without forcing full UI expansion
- response-to-variable extraction needs reliable path access

The key point is not to bind the JSON viewer directly to a naive fully-expanded in-memory UI tree.

### What `v0.1` should do
`v0.1` does not need the full large-payload system, but it should avoid boxing itself in.

Recommended `v0.1` posture:
- parse JSON once into a structured response model
- render the tree lazily as branches are expanded
- avoid building a fully materialized visible tree for the whole payload up front
- keep response parsing and formatting off the main thread
- keep raw response body separate from rendered view state, even if both are session-only in `v0.1`

This gives good performance for typical payloads without prematurely building a custom large-file engine.

### What MVP should prepare for
MVP should extend the response architecture so the same response model can support:
- response search
- variable extraction from paths
- response diff preparation
- recent response comparisons

At this point, it is worth introducing a clearer separation between:
- raw response storage
- parsed response document
- viewer tree state
- derived indexes used for search or diff

### What Post-MVP likely needs
If the product adds large-response workflows, diffing, and history, the architecture should be ready for:
- streaming large responses to disk
- loading only needed slices into memory
- virtualized tree rendering
- path-based indexing for search and extraction
- diff engines that operate on structured JSON nodes rather than only line diffs

That is the point where specialized large-payload handling becomes justified.

## 9. Data Flow
### v0.1 Data Flow
The `v0.1` flow should stay simple and centralized:

1. User pastes a URL or `curl`
2. `curl` import service parses it into the canonical `Request`
3. Request editor renders that request from application state
4. User edits URL, method, headers, or body
5. Updated request state lives in shared session state
6. User triggers execution from either:
   - main app
   - menu bar "rerun last request"
7. Request Execution Engine sends the request
8. Engine captures:
   - status code
   - duration
   - response size
   - response body
   - last run timestamp
9. Response data is stored in shared session state
10. UI state is updated for:
   - main response viewer
   - last request status
   - menu bar status
11. Response viewer formats and renders JSON tree or readable raw output

Important property: both the main window and menu bar run through the same execution path and consume the same shared session state in `v0.1`.

### Post-v0.1 Persistence Step
Before MVP feature work lands, introduce durable local persistence behind the existing repository boundaries:

1. Replace in-memory/session repository implementations with SQLite-backed ones
2. Persist current request workspace
3. Persist last executed request summary/state
4. Establish migration-safe schemas for future:
   - reusable requests
   - recent requests
   - response history/snapshots
5. Keep the application-layer interfaces unchanged so UI and execution code do not need to be reworked

Important property: persistence should be added as an infrastructure swap, not as a change to the product’s core execution or state model.

### MVP Data Flow
MVP should extend the same core flow rather than replacing it:

1. User opens a saved or recent request
2. Request is loaded from the repository into application state
3. Variable resolver expands request values before execution
4. Optional pre-request pipeline steps run:
   - token refresh
   - request mutation
   - script-based preparation
5. Request Execution Engine sends the resolved request
6. Engine captures response and metadata
7. Optional post-request pipeline steps run:
   - extract response values into variables
   - update recent-request state
   - run post-request scripts
8. Repositories persist:
   - updated request state
   - variable changes
   - response summary
   - recent-request ordering
9. UI state updates for:
   - main request list
   - current request editor
   - response viewer
   - menu bar recent requests
   - last execution status

Important property: variables, automation, recent requests, and menu bar actions all plug into the same request lifecycle instead of adding separate workflows.

## 10. Extensibility Plan by Phase
### v0.1
Build the stable core:
- canonical request model
- `curl` import/export
- execution engine
- response viewer abstraction
- repository boundaries with session/in-memory implementations
- menu bar integration for last request

### Between v0.1 and MVP
Add durable local persistence without changing the core product shape:
- SQLite-backed repository implementations
- workspace persistence
- last-request persistence
- schema foundations for reusable requests and recent requests

### MVP
Extend through existing seams:
- recent requests
- variable system
- structured URL/header editing
- request reuse workflows
- pre-request and post-request pipeline hooks

### Post-MVP
Add features without reworking the core:
- response history and snapshots
- diffing
- smart retry policies
- auth refresh flows
- scratchpad / graveyard
- large-response specialized rendering
- GraphQL support as another request mode, not a new app shape

## 11. Maintainability Rules
To keep the codebase healthy:
- keep UI state separate from domain state
- keep parsing, execution, persistence, and rendering isolated
- avoid putting workflow logic directly in views
- make menu bar and main app share the same application services
- prefer small feature modules over one large app target with tangled responsibilities
- add extension points before adding special cases

## 12. Recommendation
The best technical design for this app is:

**A native Swift macOS app with SwiftUI-first UI, a canonical request domain model, repository boundaries from day one, SQLite-backed persistence introduced after `v0.1`, a shared execution engine, and a pipeline-based architecture for future variables and automation.**

That structure is modern, clean, and practical. It supports the jump from `v0.1` to MVP to post-MVP without forcing a rewrite of the core product shape.
