"""Run Whale's S1-mini Cleanup over another result file: the "Parakeet + Cleanup" baseline.

Same prompt string, greedy decoding and token budget as Whale/Sources/Cleanup/S1Prompt.swift
and S1CleanupEngine.swift, through Python mlx-lm instead of mlx-swift-lm.

  python run_s1.py <S1-mini-MLX-8bit dir> work/out/parakeet-v2-coreml.jsonl work/out/parakeet-v2+s1.jsonl
"""
import json
import resource
import sys
import time

from mlx_lm import generate, load
from mlx_lm.sample_utils import make_sampler

SYSTEM = ("You are a text normalizer for speech-to-text transcripts. The input begins with a control line "
          "specifying the styling, structure, and context settings; clean the transcript to match those "
          "settings and output only the cleaned text.")
CONTROL = "[Styling: semi-formal] [Structure: prose] [Context: general]"

model_dir, src, dst = sys.argv[1:4]
t0 = time.perf_counter()
model, tokenizer = load(model_dir)
load_s = time.perf_counter() - t0
greedy = make_sampler(temp=0.0)

busy = 0.0
rows = [json.loads(line) for line in open(src)]
with open(dst, "w") as out:
    for row in rows:
        text = row["text"]
        if text.strip():
            prompt = (f"<|im_start|>system\n{SYSTEM}<|im_end|>\n<|im_start|>user\n{CONTROL}\n{text}<|im_end|>\n"
                      "<|im_start|>assistant\n<think>\n\n</think>\n\n")
            tokens = tokenizer.encode(prompt, add_special_tokens=False)
            t = time.perf_counter()
            text = generate(model, tokenizer, tokens, max_tokens=int(len(tokens) * 1.3) + 32,
                            sampler=greedy, verbose=False).strip()
            busy += time.perf_counter() - t
        out.write(json.dumps({"id": row["id"], "text": text}) + "\n")

print(json.dumps({"files": len(rows), "load_s": round(load_s, 2), "cleanup_s": round(busy, 2),
                  "peak_rss_mb": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**20)}))
