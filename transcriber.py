from __future__ import annotations

from pathlib import Path

import mlx_whisper

_HF_CACHE = Path.home() / ".cache" / "huggingface" / "hub"


def _model_is_cached(model_repo: str) -> bool:
    """Check if the HuggingFace model is already downloaded locally."""
    cache_name = "models--" + model_repo.replace("/", "--")
    return (_HF_CACHE / cache_name).exists()


def transcribe_chunks(chunk_paths: list[Path], model: str) -> str:
    """
    Transcribe a list of WAV chunk files in order.
    Returns the concatenated raw transcript string.
    """
    if not chunk_paths:
        return ""

    if not _model_is_cached(model):
        print(f"First run: downloading Whisper model '{model}'...")
        size_hint = "~3 GB for large-v3" if "large" in model else "~150 MB for small"
        print(f"This may take a few minutes ({size_hint}).")
        print("Tip: set WHISPER_MODEL=mlx-community/whisper-small-mlx in .env for faster dev.\n")

    total = len(chunk_paths)
    texts: list[str] = []

    for i, path in enumerate(chunk_paths, start=1):
        print(f"Transcribing chunk {i}/{total}: {path.name}...", flush=True)
        result = mlx_whisper.transcribe(
            str(path),
            path_or_hf_repo=model,
            verbose=False,
        )
        text = result.get("text", "").strip()
        texts.append(text)

    return "\n".join(texts)
