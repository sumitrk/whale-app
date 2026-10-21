"""Word error rate of one or more result files against both DisfluencySpeech references.

Text goes through Whisper's English normaliser first, as the Open ASR Leaderboard does, so
casing, punctuation and spelled-out numbers don't count as errors.

  python score.py work/data/ds/refs.jsonl work/out/*.jsonl
"""
import json
import os
import sys

import jiwer
from whisper_normalizer.english import EnglishTextNormalizer

norm = EnglishTextNormalizer()


def load(path):
    with open(path) as f:
        return {r["id"]: r for r in map(json.loads, f)}


refs = load(sys.argv[1])
print(f"{'result':<34}{'clips':>6}{'vs clean %':>12}{'vs verbatim %':>15}")
for path in sys.argv[2:]:
    hyps = load(path)
    ids = [i for i in refs if i in hyps and norm(refs[i]["verbatim"]).strip()]
    hyp = [norm(hyps[i]["text"]) or "<empty>" for i in ids]
    clean = jiwer.wer([norm(refs[i]["clean"]) for i in ids], hyp)
    verbatim = jiwer.wer([norm(refs[i]["verbatim"]) for i in ids], hyp)
    print(f"{os.path.basename(path):<34}{len(ids):>6}{clean * 100:>12.2f}{verbatim * 100:>15.2f}")
