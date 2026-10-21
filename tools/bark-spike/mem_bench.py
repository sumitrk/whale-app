"""How much memory each model costs, measured from outside the process.

Core ML hands Neural Engine models to the system, so a process's own footprint barely moves
when it loads one. This runs asr-bench with ASR_HOLD and samples, at load and after
transcribing:

  footprint  the process's physical footprint (what Activity Monitor's Memory column shows)
  system     wired + anonymous + compressed memory across the whole Mac, as a delta from just
             before the process started. Noisy, since everything else on the Mac moves it
             too, so each case runs several times and the median is reported.

  python mem_bench.py <asr-bench> <audio-dir> runs name=<dir>:<v2|v3|v3-local>[:cpu] ...
"""
import json
import re
import statistics
import subprocess
import sys
import time

bench, audio_dir, runs = sys.argv[1], sys.argv[2], int(sys.argv[3])
cases = [arg.split("=", 1) for arg in sys.argv[4:]]
PAGE = 16384


def system_bytes():
    out = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
    pages = {m.group(1): int(m.group(2)) for m in re.finditer(r'"?([^:\n"]+)"?:\s+(\d+)\.', out)}
    return (pages["Pages wired down"] + pages["Anonymous pages"] + pages["Pages occupied by compressor"]) * PAGE


def footprint_mb(pid):
    out = subprocess.run(["footprint", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"Footprint:\s+([\d.]+)\s+(KB|MB|GB)", out)
    if not m:
        return None
    return float(m.group(1)) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[m.group(2)]


results = {}
for name, spec in cases:
    folder, version, *flags = spec.split(":")
    env = {"ASR_HOLD": "8", **({"ASR_CPU_ONLY": "1"} if "cpu" in flags else {})}
    samples = []
    for _ in range(runs):
        time.sleep(3)
        before = system_bytes()
        proc = subprocess.Popen([bench, folder, version, audio_dir, "/tmp/mem-bench.jsonl"],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                                env={**__import__("os").environ, **env})
        row = {}
        for line in proc.stdout:
            if line.startswith(("LOADED", "DONE")):
                marker, pid = line.split()
                time.sleep(4)  # let the load or the last transcription settle
                row[f"{marker.lower()}_footprint_mb"] = footprint_mb(pid)
                row[f"{marker.lower()}_system_mb"] = (system_bytes() - before) / 2**20
            elif line.startswith("{"):
                row.update({k: v for k, v in json.loads(line).items() if k in ("footprint_peak_mb", "load_s", "transcribe_s")})
        proc.wait()
        samples.append(row)
    results[name] = {k: round(statistics.median(s[k] for s in samples if s.get(k) is not None))
                     for k in samples[0]}
    print(name, json.dumps(results[name]), flush=True)
