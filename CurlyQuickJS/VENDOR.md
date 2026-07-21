# QuickJS-NG vendor record

- Project: QuickJS-NG
- Tag: `v0.15.1`
- Commit: `fd0a0210b7be00957751871e7e01b8291268fc29`
- Upstream: https://github.com/quickjs-ng/quickjs
- License: MIT (`LICENSE`)

Only the core engine sources needed by Curly are vendored. `quickjs-libc.c`, the
CLI tools, module loaders, and filesystem/process standard library are omitted.

Run `just verify-quickjs-vendor` to verify the pinned files.
