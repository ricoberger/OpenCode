# OpenCode iOS Client

iOS client for [opencode](https://opencode.ai): connect to an `opencode serve`
instance, view/create sessions, send prompts, watch the agent work live, and
answer permission requests.

## Build & Test

```sh
# Build (Simulator)
xcodebuild build -project OpenCode.xcodeproj -scheme OpenCode \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO

# Unit tests (Swift Testing; UI test target exists but is intentionally empty)
xcodebuild test -project OpenCode.xcodeproj -scheme OpenCode \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:OpenCodeTests CODE_SIGNING_ALLOWED=NO
```

If `xcodebuild` complains about CommandLineTools, prefix commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Architecture

MV (no ViewModels), everything MainActor by default
(`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`):

- `Models/APIModels.swift` — hand-written Codable models for the server API.
- `Networking/` — `APIClient` (stateless struct, ~10 REST endpoints),
  `SSE.swift` (parser + `/event` stream), `Keychain`, `ServerConfig`.
- `Stores/ServerConnection.swift` — config + connection state machine + SSE
  event loop with exponential-backoff reconnect.
- `Stores/SessionStore.swift` — single in-memory source of truth; hydrated via
  REST, kept current by folding in SSE events (idempotent upserts).
- `Views/` — render store state only; user actions call store methods.

Data flow rules:

- **No local persistence.** The server owns all data; the app is a remote
  control. Only the server config (UserDefaults + Keychain for the password) and
  model/agent selection (UserDefaults) persist.
- **SSE has no replay.** Every (re)connect triggers `refreshAll()`. Never rely
  on events alone for correctness.
- Prompts go through `prompt_async` (fire-and-forget); all results arrive via
  the single app-wide SSE stream.
- Message loading is driven by the sidebar **selection** in `ContentView`, not
  by view lifecycle (see landmines below).

## Hard rules

- **Lenient decoding, never throw.** Unknown part/event/status/role
  discriminators decode to `.unknown` cases; non-identity fields are optional.
  An old app version against a new server must degrade to placeholder chips,
  never crash or fail a whole payload. Every new part type needs a JSON fixture
  test, plus an unknown-discriminator test.
- **The published OpenAPI spec lies sometimes — trust captured payloads.** Known
  deviations (observed on 1.16.2, fixtures in `DecodingTests`):
  - Permission requests arrive as `permission.asked` (spec says
    `permission.updated`) with
    `{ permission, patterns, tool: { messageID, callID } }` and **no title**
    (spec says `{ type, pattern, title, ... }`). The decoder accepts both
    shapes.
  - `permission.replied` carries `requestID`/`reply` (spec says
    `permissionID`/`response`).
- **Native-first dependency policy.** Exactly one dependency
  (`swift-markdown-ui`, needed for fenced code blocks). SSE parsing and Keychain
  stay hand-rolled. Do not add packages without strong need.
- Timestamps from the server are epoch **milliseconds**.

## SwiftUI landmines (do not "simplify" these away)

- **`NavigationSplitView` fires a spurious disappear/appear on the detail view
  during push transitions on iPhone.** A `.task` on the detail gets cancelled
  mid-request and never restarts (identity unchanged). This is why `ContentView`
  loads messages from `.onChange(of: selectedSessionID)` with an unstructured
  `Task`, and why `ChatView` has no loading logic.
- **`ChatView` is identity-keyed** (`.id(session.id)`) so scroll position,
  composer drafts, and card-expansion state never leak between sessions.
- **`"\r\n"` is a single `Character` in Swift.** The SSE parser splits lines on
  unicode scalars; a character-level search for `"\n"` misses CRLF.
- **Hardware Return doesn't insert newlines** in a vertical-axis `TextField` —
  the composer intercepts `.onKeyPress(.return)` and re-asserts focus afterwards
  (the text system tries to end editing).

## Conventions

- Conventional Commits (`feat:`, `fix:`, `docs:`, `build:`, ...); subjects
  imperative, ≤72 chars; bodies explain intent and root causes, not diffs.
- Swift: 4-space indent (see `.editorconfig`); file-header comments explain each
  file's role and the decisions baked into it — keep them current.
- Tests: Swift Testing (`@Test`/`#expect`), suites annotated `@MainActor`
  (models are MainActor-isolated via the project default). High-value surfaces
  only: decoding fixtures, SSE parser edge cases, store event application. No UI
  tests, no mocked-URLSession client tests.

## Out of scope for v1 (intentional)

File browser, diffs, todos, share links, fork/revert, shell/slash commands,
sending attachments, multiple servers, offline cache, push notifications (top v2
candidate: notify on pending permissions).
