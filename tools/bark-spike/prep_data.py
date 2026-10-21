"""Unpack the DisfluencySpeech test split into 16 kHz mono WAVs plus a refs.jsonl.

transcript_a is word for word (minus laughter and other events); transcript_c has fillers,
false starts and repeats removed. Those are the two references Underdog scores Bark against.

  python prep_data.py work/data/ds-test.parquet work/data/ds
"""
import io
import json
import os
import sys

import numpy as np
import pyarrow.parquet as pq
import soundfile as sf
import soxr

src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
rows = pq.read_table(src).to_pylist()
with open(os.path.join(out, "refs.jsonl"), "w") as refs:
    for i, row in enumerate(rows):
        wave, sr = sf.read(io.BytesIO(row["audio"]["bytes"]), dtype="float32", always_2d=True)
        wave = wave.mean(1)
        if sr != 16000:
            wave = soxr.resample(wave, sr, 16000)
        name = f"ds-{i:03d}.wav"
        sf.write(os.path.join(out, name), np.clip(wave, -1, 1), 16000, subtype="PCM_16")
        refs.write(json.dumps({"id": name, "verbatim": row["transcript_a"], "clean": row["transcript_c"],
                               "seconds": round(len(wave) / 16000, 3)}) + "\n")
print(f"{len(rows)} clips -> {out}")
