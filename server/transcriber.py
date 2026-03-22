from __future__ import annotations

from pathlib import Path

from mlx_audio.stt.utils import load_model as load_stt

_HF_CACHE = Path.home() / ".cache" / "huggingface" / "hub"

# Parakeet model — cached after first download (~600 MB)
_PARAKEET_REPO = "mlx-community/parakeet-tdt-0.6b-v3"

# Module-level model cache so we only load once per server process
_model = None


def _get_model():
    global _model
    if _model is None:
        if not _model_is_cached(_PARAKEET_REPO):
            print(f"First run: downloading Parakeet model (~600 MB)...", flush=True)
            print("This may take a few minutes.", flush=True)
        print(f"Loading Parakeet STT model...", flush=True)
        _model = load_stt(_PARAKEET_REPO)
    return _model


def _model_is_cached(model_repo: str) -> bool:
    cache_name = "models--" + model_repo.replace("/", "--")
    return (_HF_CACHE / cache_name).exists()


def transcribe_chunks(chunk_paths: list[Path], model: str = _PARAKEET_REPO) -> str:
    """
    Transcribe a list of WAV chunk files using Parakeet via mlx-audio.
    Returns the concatenated transcript string.
    """
    if not chunk_paths:
        return ""

    stt = _get_model()
    total = len(chunk_paths)
    texts: list[str] = []

    for i, path in enumerate(chunk_paths, start=1):
        print(f"Transcribing chunk {i}/{total}: {path.name}...", flush=True)
        result = stt.generate(str(path))
        text = result.text.strip()
        texts.append(text)
        print(f"  → {text[:80]}{'...' if len(text) > 80 else ''}", flush=True)

    return "\n".join(texts)
