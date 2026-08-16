# Bundle Pi as the local agent runtime

Whale will bundle a version-pinned official Pi standalone executable and control it as a local subprocess through Pi's JSONL RPC protocol. This gives AI Actions an extensible agent runtime without requiring users to install Node.js or making Whale maintain a custom TypeScript host and protocol; Swift remains responsible for the macOS experience and process lifecycle. A custom Pi SDK host or a Swift-native agent loop may replace this boundary later if Pi's RPC and extension surfaces prove insufficient.

The runtime is a generated build input, not a tracked repository artifact or a separate user installation. Xcode downloads and checksum-verifies the pinned official Apple Silicon archive when the ignored source cache is absent, then embeds it inside the signed Whale application.
