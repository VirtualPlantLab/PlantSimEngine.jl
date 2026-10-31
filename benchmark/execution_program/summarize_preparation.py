"""Losslessly archive preparation-factorial evidence; preserve local originals."""
from pathlib import Path
import gzip
import hashlib
import json
import shutil
import statistics

from summarize_evidence import summarize

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "benchmark/native_downstream/results/preparation-reuse"
DEST = Path(__file__).resolve().parent / "evidence/preparation-reuse"


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    manifest, screens, cold = [], [], []
    paths = list(SOURCE.glob("*.json")) + list(SOURCE.glob("*.jsonl"))
    for path in sorted(paths):
        raw = path.read_bytes()
        data = json.loads(raw) if path.suffix == ".json" else None
        if path.suffix == ".jsonl":
            for line in raw.splitlines():
                json.loads(line)
        target = DEST / (path.name + ".gz")
        target.write_bytes(gzip.compress(raw, mtime=0))
        manifest.append(dict(source=path.relative_to(ROOT).as_posix(), artifact=target.name,
            raw_sha256=hashlib.sha256(raw).hexdigest(),
            compressed_sha256=hashlib.sha256(target.read_bytes()).hexdigest()))
        if isinstance(data, dict) and "samples" in data and "baseline" in data:
            screen = summarize(data)
            controls = {s["cycle"]: s for s in data["samples"] if s["variant"] == data["baseline"]}
            for row in screen["rows"]:
                samples = [s for s in data["samples"] if s["variant"] == row["variant"]]
                row["prepare_ms"] = 1000 * statistics.median(
                    s["phases"]["pse_preparation"]["seconds"] for s in samples)
                row["paired_prepare_ratio"] = statistics.median(
                    s["phases"]["pse_preparation"]["seconds"] /
                    controls[s["cycle"]]["phases"]["pse_preparation"]["seconds"] for s in samples)
                row["prepare_bytes"] = statistics.median(
                    s["phases"]["pse_preparation"]["allocated_bytes"] for s in samples)
                row["complete_bytes"] = statistics.median(
                    s["complete_allocated_bytes"] for s in samples)
            screens.append(screen)
        if path.name.startswith("cold-") and isinstance(data, dict) and "record" in data:
            r = data["record"]
            cold.append(dict(package="pb" if "-pb-" in path.name else "xp", arm=r["variant"],
                pid=r["process_id"], freshness=r["freshness"], phases=r["phases"],
                complete_seconds=r["complete_seconds"], digest=r["digest"], work=r["work"],
                coverage=r["coverage"], loader_seconds=data["loader_seconds"]))
    for package in {c["package"] for c in cold}:
        records = [c for c in cold if c["package"] == package]
        assert len({c["pid"] for c in records}) == len(records)
        assert len({c["digest"] for c in records}) == 1
        assert all(c["work"] == records[0]["work"] for c in records)
    for directory in ("receipts", "qualified-source", "cold-pb-source",
        "unqualified-harness-source"):
        if (SOURCE / directory).is_dir():
            shutil.copytree(SOURCE / directory, DEST / directory, dirs_exist_ok=True)
    (DEST / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (DEST / "summary.json").write_text(json.dumps(dict(screens=screens, cold=cold), indent=2) + "\n")
    print(json.dumps(dict(records=len(manifest), screens=len(screens), cold=len(cold))))


if __name__ == "__main__":
    main()
