# NativeCurlRunner

NativeCurlRunner is a native macOS GUI for importing cURL commands, editing REST requests, running them locally, and rerunning recent requests from the menu bar.

## Development

Use the `just` commands below as the canonical build and test interface for both humans and agents. They keep Xcode invocation details in one place and use local `.DerivedData` output.

```sh
just build
just build-release
just package-zip-free
just package-dmg-free
just package-dmg-styled-free
just verify-package-free
just test
just test-unit
just test-ui
just test-one NativeCurlRunnerUITests/URLBarImportUITests/testImportedCurlHeadersAreUsedWhenRunningRequest
```

`just package-zip-free` builds a Release app, applies ad-hoc signing (`codesign -s -`), and writes `dist/NativeCurlRunner.zip`.

`just package-dmg-free` builds/signs similarly and writes `dist/NativeCurlRunner.dmg`.

`just package-dmg-styled-free` builds/signs and creates a drag-to-Applications style DMG layout (app icon + Applications alias in Finder). This command uses Finder automation via `osascript`, so it must run in a normal logged-in macOS session.

On tester Macs, first launch may still require manual trust:
1. Right-click `NativeCurlRunner.app` and choose `Open`.
2. Confirm `Open` in the warning dialog (or use System Settings > Privacy & Security > Open Anyway).

If `just` is not installed:

```sh
brew install just
```

The project can also be opened directly in Xcode:

```sh
open NativeCurlRunner.xcodeproj
```

Generated build output should stay local in `.DerivedData`.
