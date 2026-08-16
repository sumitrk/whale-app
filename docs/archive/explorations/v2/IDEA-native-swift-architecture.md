# Idea: Native Swift Architecture (Remove Python Server)

## Current Architecture
Swift → HTTP → Python server (mlx_audio) → Metal GPU

## Target Architecture
Swift → WhisperKit / whisper.cpp → CoreML / Metal GPU

## Why
- App size drops from ~600MB to ~15MB (no Python runtime bundle)
- No process lifecycle management (no PythonServer, no port 8765)
- Simpler distribution — no PyInstaller, no venv
- Cleaner codebase — fewer moving parts

## Implementation Options

### Option A: WhisperKit (recommended starting point)
- Swift package from Argmax: https://github.com/argmaxinc/WhisperKit
- Runs Whisper via CoreML + Apple Neural Engine
- Built-in model hub (download on demand, same UX as today)
- Pure Swift, minimal code change

```swift
import WhisperKit
let whisper = try await WhisperKit(model: "openai_whisper-large-v3")
let result = try await whisper.transcribe(audioPath: wavURL.path)
```

### Option B: whisper.cpp via C++ bridge
- More control, better quantization options (GGUF/Q4)
- Requires C++/ObjC interop layer
- More complex but more flexible

### Option C: CoreML Whisper directly
- Convert Whisper weights to CoreML format
- Uses Neural Engine (fastest on Apple Silicon)
- Need to host/distribute CoreML models yourself

## For Local LLM (Qwen post-processing)
- mlx-swift: https://github.com/ml-explore/mlx-swift
- llama.cpp Swift bindings

## What Gets Deleted
- server/server.py
- PythonServer.swift
- TranscribeClient.swift
- PyInstaller + server.spec
- Python venv + all Python dependencies
- /models REST endpoints

## What Gets Added
- WhisperManager.swift
- TranscriptionPipeline.swift (see separate idea)
- SPM dependency: WhisperKit

## Trade-offs
| | Current | Native Swift |
|---|---|---|
| App size | ~600MB | ~15MB |
| Parakeet support | ✅ | ❌ (mlx_audio only) |
| Whisper models | ✅ | ✅ |
| Dev complexity | low | medium |
| Rewrite effort | — | ~2-3 weeks |

## Key Risk
Parakeet is only available via mlx_audio (Python). Moving to WhisperKit
means losing Parakeet. Consider keeping a minimal Python server just for
Parakeet, or waiting for a Swift/CoreML port of Parakeet.
