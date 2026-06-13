# OpenCode

OpenCode is an AI generated iOS client for [opencode](https://opencode.ai).
Connect the app to an `opencode serve` instance running on your computer and
take your sessions with you: read conversations, send prompts, watch the agent
work in real time, and answer permission requests from your phone.

## Features

- **Sessions** — browse, create, and delete the sessions on your server; live
  status shows which session the agent is currently working in.
- **Chat** — full conversation history with streaming responses: markdown with
  fenced code blocks, collapsed reasoning ("thinking") sections, and compact,
  expandable tool-call cards with live status.
- **Permissions** — when the agent asks for approval (run a command, edit a
  file, leave the project directory), the request appears as an inline card with
  _Allow Once / Always Allow / Deny_ — so the agent never sits blocked while you
  are away from your desk.
- **Model & agent selection** — pick the model and agent for new prompts from
  the chat settings menu; defaults come from your server.
- **Live & resilient** — a single server-sent-events stream drives the whole UI;
  the app reconnects with backoff and re-syncs automatically after network drops
  or backgrounding.

## Development

```bash
# Start the OpenCode server
opencode serve --hostname 0.0.0.0 --port 1503

# Start the OpenCode server with the default username "opencode" and a password
OPENCODE_SERVER_PASSWORD=your-password opencode serve --hostname 0.0.0.0 --port 1503
```

```bash
# Build (Debug, iOS Simulator)
xcodebuild build -project OpenCode.xcodeproj -scheme OpenCode -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

```bash
# Run all tests
xcodebuild test -project OpenCode.xcodeproj -scheme OpenCode -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### SourceKit-LSP / `buildServer.json`

To make the SourceKit-LSP working properly with the Xcode project, a
`buildServer.json` file must be generated at the project root using
[`xcode-build-server`](https://github.com/SolaWing/xcode-build-server)
(installable via Homebrew: `brew install xcode-build-server`).

```bash
rm -rf .bundle
xcodebuild build -project OpenCode.xcodeproj -scheme OpenCode -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -resultBundlePath .bundle
xcode-build-server config -project OpenCode.xcodeproj -scheme OpenCode
```
