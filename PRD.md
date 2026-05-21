# Product Requirements Document
## Working Title
**Native macOS cURL Runner**

## 1. Product Summary
A fast, lightweight, native macOS app for importing, editing, and executing `curl` requests locally. The product is for people who already think in `curl` and want a better GUI for running requests, inspecting responses, and quickly rerunning useful calls from the menu bar.

This is a focused utility, not a collaboration platform, not a cloud workspace, and not a general-purpose API suite.

## 2. Product Vision
Build the macOS API client for people who want the speed and portability of `curl`, with a native interface that removes friction from the common workflow:
- import a request
- edit it comfortably
- run it
- inspect the response
- rerun it quickly from the menu bar

## 3. Core Principles
- **Native experience**: fast, lightweight, and aligned with macOS.
- **Local-first**: no login, no cloud dependency.
- **cURL-first**: `curl` remains the core shareable format.
- **Focused utility**: do the core request workflow extremely well.
- **Low-friction editing**: URL, headers, and body should be easy to modify.
- **Excellent JSON handling**: structured response inspection should be a major strength.
- **Useful menu bar presence**: status and rerun should work without bringing the main window forward.

## 4. Target User
Developers and technical operators who:
- regularly use `curl`
- want something lighter and faster than bloated API tools
- prefer local tools over account-based products
- care about fast reruns and clean response inspection
- want a native macOS interface that does not get in the way

## 5. Problem Statement
Current API GUI tools are often too heavy, too broad, or too awkward for quick request work. Raw `curl` is powerful and portable, but editing and repeating requests directly in terminal workflows is clumsy. Common tasks like changing a header, checking the last response, rerunning a request, or inspecting nested JSON involve more friction than they should.

Users need a native macOS tool that:
- starts from raw `curl`
- makes request editing easy
- executes requests quickly
- handles JSON responses well
- stays fully local
- exposes useful last-request and recent-request behavior through the menu bar

## 6. Goals
- Make `curl` import the fastest way to start
- Make editing materially easier than editing raw command text
- Provide strong JSON response inspection
- Surface last request status in the menu bar
- Enable fast reruns from the menu bar
- Preserve portability by keeping requests shareable as plain `curl`
- Expand into reusable request workflows in MVP

## 7. Non-Goals
- Team collaboration
- Cloud sync
- API design/spec management
- GraphQL-first workflows in early versions
- Broad platform features unrelated to request execution
- Proprietary collection formats as the primary model

## 8. Key Use Cases
1. Paste a `curl` command and run it immediately.
2. Edit URL, headers, method, or body in a comfortable GUI.
3. Inspect JSON in a tree view with expand/collapse.
4. See whether the last request succeeded from the menu bar.
5. Retrigger the last request from the menu bar.
6. Save and reopen requests as plain `curl`.
7. In MVP, quickly access recent requests from the menu bar.
8. In MVP, reuse variables and lightweight automation for repeat workflows.

---

## 9. Release Scope

## v0.1
### Goal
Prove the core loop: import `curl`, edit it, run it, inspect the response, and rerun the last request from the menu bar.

### Included
- Paste/import a `curl` command
- Parse `curl` into editable request fields:
  - method
  - URL
  - headers
  - body
- Edit request in the GUI
- Execute request
- Show response metadata:
  - status code
  - duration
  - response size
  - last run time
- Response viewer with strong JSON support:
  - pretty print
  - tree view
  - expand/collapse for objects and arrays
- Menu bar presence
- Menu bar shows last request status
- Menu bar can retrigger the last request
- Open the main app from the menu bar
- Local persistence
- Save/open/export requests as plain `curl`
- Fully local operation
- No login

### Explicitly Out of Scope
- scripting
- variable editing
- recent requests in menu bar
- request collections/workflow management beyond the core request flow
- response diff
- scratchpad/graveyard
- endpoint heartbeat
- GraphQL-specific handling

### v0.1 UX Outcome
A user should be able to paste a `curl`, make a quick edit, run it, inspect the JSON, and rerun that same request from the menu bar with very little friction.

---

## MVP
### Goal
Turn the core runner into a repeatable daily-use local API workflow tool.

### Included
Everything in `v0.1`, plus:

#### Request Reuse
- Saved request list in the main app
- Better support for managing reusable requests
- Menu bar access to recent requests
- Ability to quickly rerun recent requests from the menu bar

#### Variables
- Variable support for repeated workflows
- Detect variable opportunities from:
  - URL parts
  - query params
  - headers
  - common auth-related fields
- Variable editing in the product UI
- System variables such as generated IDs

#### Better Editing Experience
- More structured URL editing
- Better header editing for long values and repeated changes
- Lower-friction editing for commonly changed request parts

#### Automation
- Pre-request scripting
- Post-request scripting
- Response value extraction into variables
- Token refresh and similar repeat workflow support

### Why these belong in MVP
These features move the app from a strong one-off request runner into a tool people can keep open daily for repeated API work. The next layer of value after the core loop is reuse: recent requests, variables, and lightweight automation.

### MVP UX Outcome
A user should be able to move between a handful of recent requests, make common edits quickly, rerun them from the menu bar, and reduce repetitive setup work through variables and automation.

---

## Post-MVP
Strong candidates for later expansion:

### Menu Bar / Utility Features
- Global hotkey HUD
- Endpoint heartbeat
- Status-code badge overlay
- Diff indicator in menu bar

### Response Features
- Diff current response vs previous response
- Better handling for very large JSON responses
- Faster inspection workflows for large payloads
- Quick response-to-variable harvesting from the JSON viewer

### Workflow Features
- Scratchpad
- Graveyard
- Curl diff against last sent version
- Smart retry with exponential backoff
- Auto-refresh token on 401/403
- Local response history and snapshots

### Content Handling
- Smarter content-type detection
- Better multipart/file handling

### Expanded Protocol/Request Support
- GraphQL support

---

## 10. Functional Requirements

### 10.1 cURL Import
- User can paste or load a `curl` command.
- The app converts it into structured request fields.
- The request can be edited and regenerated back into valid `curl`.

### 10.2 Request Editing
- User can edit method, URL, headers, and body.
- Editing should be meaningfully easier than editing the raw command.
- Long values should remain comfortable to work with.

### 10.3 Request Execution
- User can run a request from the main window.
- The app clearly shows request state and result.

### 10.4 Response Inspection
- JSON responses should render structurally.
- Objects and arrays should support expand/collapse.
- User should be able to inspect both structured and readable response output.

### 10.5 Menu Bar
- The app exists in the menu bar.
- In `v0.1`, the menu bar centers on the last request.
- In MVP, the menu bar expands to include recent requests.
- The menu bar should support rerunning useful requests with minimal friction.

### 10.6 Persistence and Sharing
- Requests and app state are stored locally.
- No account is required.
- Requests remain shareable as plain `curl`.

### 10.7 Variables and Automation
- Not required in `v0.1`.
- Required in MVP:
  - variables
  - variable editing
  - pre-request scripting
  - post-request scripting
  - response-to-variable workflows

---

## 11. UX Direction
The app should feel like a native macOS utility, not a workspace platform.

Key characteristics:
- quick to open
- low-friction to operate
- keyboard-friendly
- visually clean
- strong information density without clutter
- no cramped editing interactions
- menu bar flow should be genuinely useful, not decorative

Design direction is intentionally left open for separate work.

## 12. Product Constraints
- Native macOS app
- Fully local except for user-triggered API requests
- No login
- Plain `curl` remains the shareable request format

## 13. Success Criteria

### v0.1 Success
A user can:
1. paste a `curl`
2. edit it in the GUI
3. run it
4. inspect the JSON response
5. see the last result in the menu bar
6. rerun that request from the menu bar

If that loop feels fast and clean, `v0.1` succeeds.

### MVP Success
A user can:
1. manage and revisit reusable requests
2. access recent requests from the menu bar
3. edit variables in-product
4. automate common repeated request workflows
5. use the app daily instead of dropping back to terminal or a heavier client

## 14. Open Product Questions
- How much structure should saved requests have from the user’s point of view: simple saved requests, lightweight collections, or something in between?
- How much of the request should become structured/editable by default versus remaining as raw text when needed?
- How prominent should recent requests be in the menu bar versus the main app?
- How opinionated should the app be about suggesting variables from imported requests?
- At what point does the product risk becoming too broad instead of staying focused on its core utility?
