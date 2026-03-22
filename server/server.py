from __future__ import annotations

import asyncio
import os
import tempfile  # used for temp WAV files in /transcribe
import threading
import time
from pathlib import Path

# Note: hf-transfer is intentionally disabled — it writes to a single temp file
# with no incremental progress, which makes the download bar useless.
# The standard downloader writes .incomplete files that grow in the HF cache,
# giving accurate progress tracking.

import uvicorn
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from pydantic import BaseModel

from llm import LLMResult, process_transcript
from transcriber import transcribe_chunks

app = FastAPI(title="TranscribeMeeting Server", version="1.0.0")


# ── Health ─────────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok", "version": "1.0.0"}


# ── Transcribe ─────────────────────────────────────────────────────────────────

@app.post("/transcribe")
async def transcribe(
    file: UploadFile = File(...),
):
    """Receive a WAV file, return the transcript via Parakeet."""
    suffix = Path(file.filename or "audio.wav").suffix or ".wav"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        content = await file.read()
        tmp.write(content)
        tmp_path = Path(tmp.name)

    try:
        transcript = transcribe_chunks([tmp_path])
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        tmp_path.unlink(missing_ok=True)

    return {"transcript": transcript, "model": "mlx-community/parakeet-tdt-0.6b-v3"}


# ── Summarise ──────────────────────────────────────────────────────────────────

class SummariseRequest(BaseModel):
    transcript: str
    api_key: str
    model: str = "claude-sonnet-4-6"


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


# ── Models ─────────────────────────────────────────────────────────────────────

DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"

AVAILABLE_MODELS = [
    {"id": "mlx-community/parakeet-tdt-0.6b-v3",  "label": "Parakeet 0.6B (English only, fastest)", "size_mb": 600},
    {"id": "mlx-community/whisper-large-v3-turbo", "label": "Whisper Large v3 Turbo (multilingual)", "size_mb": 809},
]

# HuggingFace cache where mlx-whisper stores downloaded models
_HF_CACHE = Path.home() / ".cache" / "huggingface" / "hub"

# In-memory progress tracking: model_id -> {downloaded_mb, total_mb, done, error}
_download_progress: dict[str, dict] = {}


@app.get("/models")
def list_models():
    """List available models and whether they are already downloaded."""
    result = []
    for m in AVAILABLE_MODELS:
        cache_name = "models--" + m["id"].replace("/", "--")
        downloaded = (_HF_CACHE / cache_name).exists()
        result.append({**m, "downloaded": downloaded})
    return {"models": result}


@app.post("/models/download")
async def download_model(model_id: str = Form(...)):
    """Download a model from HuggingFace. Streams progress via /models/download-progress."""
    model_info = next((m for m in AVAILABLE_MODELS if m["id"] == model_id), None)
    if not model_info:
        raise HTTPException(status_code=404, detail="Model not found")

    total_mb = model_info["size_mb"]
    _download_progress[model_id] = {"downloaded_mb": 0.0, "total_mb": total_mb, "done": False, "error": None}

    # Track progress by watching the HuggingFace cache directory size
    def track():
        cache_key = "models--" + model_id.replace("/", "--")
        cache_path = _HF_CACHE / cache_key
        while not _download_progress[model_id]["done"]:
            if cache_path.exists():
                try:
                    # Includes .incomplete files that grow during download
                    size = sum(f.stat().st_size for f in cache_path.rglob("*") if f.is_file())
                    if size > 0:
                        _download_progress[model_id]["downloaded_mb"] = min(size / (1024 * 1024), total_mb)
                except Exception:
                    pass
            time.sleep(0.5)

    tracker = threading.Thread(target=track, daemon=True)
    tracker.start()

    try:
        from huggingface_hub import snapshot_download
        loop = asyncio.get_event_loop()
        await loop.run_in_executor(None, lambda: snapshot_download(repo_id=model_id))
        _download_progress[model_id].update({"downloaded_mb": float(total_mb), "done": True})
    except Exception as e:
        _download_progress[model_id].update({"done": True, "error": str(e)})
        raise HTTPException(status_code=500, detail=str(e))

    return {"status": "ok", "model_id": model_id}


@app.get("/models/download-progress")
def download_progress(model_id: str):
    """Return current download progress for a model (0.0–1.0)."""
    info = _download_progress.get(model_id)
    if not info:
        return {"percent": 0.0, "downloaded_mb": 0.0, "total_mb": 0.0, "done": False, "error": None}
    total = info["total_mb"] or 1
    percent = min(info["downloaded_mb"] / total, 1.0)
    return {**info, "percent": percent}


# ── Entry point ────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8765, log_level="info")
