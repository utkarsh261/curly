# NativeCurlRunner

NativeCurlRunner is a native macOS GUI for importing cURL commands, editing REST requests, running them locally, and rerunning recent requests from the menu bar.

## Development

Use the `just` commands below as the canonical build and test interface for both humans and agents. They keep Xcode invocation details in one place and use local `.DerivedData` output.

```sh
just build
just test
just test-unit
just test-ui
just test-one NativeCurlRunnerUITests/URLBarImportUITests/testImportedCurlHeadersAreUsedWhenRunningRequest
```

If `just` is not installed:

```sh
brew install just
```

The project can also be opened directly in Xcode:

```sh
open NativeCurlRunner.xcodeproj
```

Generated build output should stay local in `.DerivedData`.
