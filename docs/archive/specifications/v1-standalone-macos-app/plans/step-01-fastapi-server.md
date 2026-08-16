# Step 1: Python FastAPI Server

## Goal
Wrap the existing Python transcription + LLM logic into a FastAPI HTTP server that runs on `localhost:8765`. This is the Python "brain" that the Swift app will call. Test it entirely with `curl` — no Swift needed yet.

## What Is Usable After This Step
`curl http://localhost:8765/health` returns `{"status":"ok"}`. You can send a WAV file and get a transcript back. You can send a transcript and get a Claude summary back. The server is the complete backend.

---

## Files to Create/Modify

### New file: `server/server.py`

This is the FastAPI entry point. It wraps transcriber.py and llm.py in HTTP endpoints.

```python
from __future__ import annotations

import os
import tempfile
from pathlib import Path

import uvicorn
from fastapi import FastAPI, File, Form, UploadFile, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from transcriber import transcribe_chunks
from llm import process_transcript, LLMResult

app = FastAPI(title="TranscribeMeeting Server", version="1.0.0")


# ── Health ────────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok", "version": "1.0.0"}


# ── Transcribe ─────────────────────────────────────────────────────────────────

@app.post("/transcribe")
async def transcribe(
    file: UploadFile = File(...),
    model: str = Form(default="mlx-community/whisper-small-mlx"),
):
    """Receive a WAV file, return the transcript."""
    # Write uploaded file to a temp path
    suffix = Path(file.filename or "audio.wav").suffix or ".wav"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        content = await file.read()
        tmp.write(content)
        tmp_path = Path(tmp.name)

    try:
        transcript = transcribe_chunks([tmp_path], model)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        tmp_path.unlink(missing_ok=True)

    return {
        "transcript": transcript,
        "model": model,
    }


# ── Summarise ─────────────────────────────────────────────────────────────────

class SummariseRequest(BaseModel):
    transcript: str
    api_key: str
    model: str = "claude-sonnet-4-5"


@app.post("/summarise")
def summarise(req: SummariseRequest):
    """Send a transcript to Claude, return cleaned transcript + summary."""
    if not req.transcript.strip():
        raise HTTPException(status_code=400, detail="Transcript is empty")
    try:
        result: LLMResult = process_transcript(req.transcript, req.api_key, req.model)
    except Exception as e:
        raise HTTPException(status_code=502, detail=str(e))

    return {
        "cleaned_transcript": result.cleaned_transcript,
        "summary": result.summary,
    }


# ── Models ────────────────────────────────────────────────────────────────────

AVAILABLE_MODELS = [
    {"id": "mlx-community/whisper-tiny-mlx",     "label": "Tiny",     "size_mb": 40},
    {"id": "mlx-community/whisper-small-mlx",    "label": "Small",    "size_mb": 150},
    {"id": "mlx-community/whisper-medium-mlx",   "label": "Medium",   "size_mb": 500},
    {"id": "mlx-community/whisper-large-v3-mlx", "label": "Large v3", "size_mb": 3000},
]

MODEL_CACHE = Path.home() / "Library" / "Application Support" / "TranscribeMeeting" / "models"


@app.get("/models")
def list_models():
    """List available models and whether they are downloaded."""
    result = []
    for m in AVAILABLE_MODELS:
        model_dir = MODEL_CACHE / m["id"].replace("/", "--")
        downloaded = model_dir.exists()
        result.append({**m, "downloaded": downloaded})
    return {"models": result}


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8765, log_level="warning")
```

---

### New file: `server/requirements.txt`

```
fastapi
uvicorn[standard]
python-multipart
pydantic
mlx-whisper
anthropic
scipy
numpy
```

---

### Move/copy existing scripts into `server/`

The server imports `transcriber.py`, `llm.py`, and `output.py` from the same directory.

```bash
# From project root:
cp transcriber.py server/transcriber.py
cp llm.py server/llm.py
cp output.py server/output.py
```

The root-level files stay for V0 CLI use. The `server/` copies are the V1 backend.

---

### Update `transcriber.py` (server copy) — make model path configurable

The existing `transcribe_chunks` function needs to respect the model cache directory:

```python
# In server/transcriber.py — add model_cache_dir param
MODEL_CACHE = Path.home() / "Library" / "Application Support" / "TranscribeMeeting" / "models"

def transcribe_chunks(chunk_paths: list[Path], model: str) -> str:
    import mlx_whisper
    results = []
    for i, path in enumerate(chunk_paths):
        print(f"  Transcribing chunk {i+1}/{len(chunk_paths)}: {path.name}...", flush=True)
        result = mlx_whisper.transcribe(
            str(path),
            path_or_hf_repo=model,
        )
        results.append(result["text"].strip())
    return "\n".join(results)
```

---

## Install Dependencies

```bash
cd server
pip install -r requirements.txt
```

---

## Run the Server

```bash
cd server
python server.py
```

Expected output:
```
INFO:     Started server process [12345]
INFO:     Waiting for application startup.
INFO:     Application startup complete.
INFO:     Uvicorn running on http://127.0.0.1:8765
```

---

## Tests

### Test 1: Health check
```bash
curl http://localhost:8765/health
```
Expected:
```json
{"status":"ok","version":"1.0.0"}
```

### Test 2: List models
```bash
curl http://localhost:8765/models
```
Expected:
```json
{
  "models": [
    {"id": "mlx-community/whisper-tiny-mlx", "label": "Tiny", "size_mb": 40, "downloaded": false},
    ...
  ]
}
```

### Test 3: Transcribe a WAV file
Use any WAV from a previous V0 test session, or record one:
```bash
# Record 5 seconds and transcribe
python3 -c "
import sounddevice as sd
import scipy.io.wavfile as wf
import numpy as np
data = sd.rec(int(5 * 16000), samplerate=16000, channels=1, dtype='int16')
sd.wait()
wf.write('/tmp/test.wav', 16000, data)
print('Recorded')
"

curl -X POST http://localhost:8765/transcribe \
  -F "file=@/tmp/test.wav" \
  -F "model=mlx-community/whisper-small-mlx"
```
Expected:
```json
{"transcript": "Hello this is a test...", "model": "mlx-community/whisper-small-mlx"}
```

### Test 4: Summarise a transcript
```bash
curl -X POST http://localhost:8765/summarise \
  -H "Content-Type: application/json" \
  -d '{
    "transcript": "So today we need to talk about the Q2 roadmap. Alice wants to prioritize onboarding, Bob wants API work.",
    "api_key": "YOUR_API_KEY_HERE",
    "model": "claude-sonnet-4-5"
  }'
```
Expected:
```json
{
  "cleaned_transcript": "Today we discussed the Q2 roadmap...",
  "summary": "## Topics Discussed\n- Q2 roadmap..."
}
```

---

## Done When

- [ ] `curl http://localhost:8765/health` returns `{"status":"ok"}`
- [ ] `curl http://localhost:8765/models` returns model list with `downloaded` flags
- [ ] `/transcribe` with a real WAV returns non-empty transcript
- [ ] `/summarise` with a transcript returns cleaned transcript + summary
- [ ] Server starts cleanly with no import errors

---

**Next:** `plans/step-02-swift-menubar-shell.md`
