"""Transcribe a folder of WAVs with Bark through Underdog's own MLX script (the reference result).

  python run_mlx.py work/models/bark-clean work/data/ds work/out/bark-clean-mlx.jsonl
"""
import json
import os
import resource
import sys
import time

import soundfile as sf

model_dir, audio_dir, out_path = sys.argv[1:4]
sys.path.insert(0, model_dir)
import bark_mlx  # noqa: E402  (Underdog's script, read before use)

t0 = time.perf_counter()
model = bark_mlx.load_model(os.path.join(model_dir, "model.bark"), bits=16,
                            cache_dir=os.path.join(model_dir, "bark_mlx_fp16"))
load_s = time.perf_counter() - t0

names = sorted(f for f in os.listdir(audio_dir) if f.endswith(".wav"))
audio_s = busy_s = 0.0
with open(out_path, "w") as out:
    for name in names:
        wave, sr = sf.read(os.path.join(audio_dir, name), dtype="float32", always_2d=True)
        t = time.perf_counter()
        text = bark_mlx.transcribe(model, wave.mean(1), sr)
        busy_s += time.perf_counter() - t
        audio_s += len(wave) / sr
        out.write(json.dumps({"id": name, "text": text}) + "\n")

peak_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**20
print(json.dumps({"files": len(names), "load_s": round(load_s, 2), "audio_s": round(audio_s, 1),
                  "transcribe_s": round(busy_s, 2), "peak_rss_mb": round(peak_mb)}))
