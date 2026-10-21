"""Load Bark into NeMo and transcribe a few clips in PyTorch, to check the weight mapping
against Underdog's MLX output before converting anything.

  python check_nemo.py <parakeet-v3.nemo> <bark-dir> <audio-dir> <bark-mlx.jsonl> [n]
"""
import json
import os
import sys

import nemo.collections.asr as nemo_asr

from bark_to_nemo import load_bark_into

nemo_path, bark_dir, audio_dir, mlx_path = sys.argv[1:5]
n = int(sys.argv[5]) if len(sys.argv) > 5 else 8

model = nemo_asr.models.EncDecRNNTBPEModel.restore_from(nemo_path, map_location="cpu").eval()
count, changed, _ = load_bark_into(model, bark_dir)
print(f"loaded {count} tensors, {changed} differ from stock v3")

mlx = {r["id"]: r["text"] for r in map(json.loads, open(mlx_path))}
names = sorted(mlx)[:n]
outs = model.transcribe([os.path.join(audio_dir, f) for f in names], batch_size=1, verbose=False)
same = 0
for name, out in zip(names, outs):
    text = (out.text if hasattr(out, "text") else out).strip()
    same += text == mlx[name]
    print(f"{name}\n  nemo: {text}\n  mlx : {mlx[name]}")
print(f"{same}/{len(names)} identical to MLX")
