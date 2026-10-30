"""Archive local bounded experiment evidence without changing original files.

Run with Python; Julia work itself belongs to the Kaimon-controlled runners.
Raw snapshots/provenance remain lossless in deterministic gzip files. Summaries
use paired cycle ratios, not ratios of independent medians.
"""
from pathlib import Path
import gzip
import hashlib
import json
import shutil
import statistics

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "benchmark/native_downstream/results/pure-gap"
DEST = Path(__file__).resolve().parent / "evidence/current-programs"


def summarize(screen):
    baseline = screen["baseline"]
    controls = {s["cycle"]: s for s in screen["samples"] if s["variant"] == baseline}
    expected = screen["expected_digest"]
    assert all(s["digest"] == expected for s in screen["samples"])
    variants = list(dict.fromkeys(s["variant"] for s in screen["samples"]))
    rows = []
    for variant in variants:
        samples = [s for s in screen["samples"] if s["variant"] == variant]
        def ratios(field):
            return [field(s) / field(controls[s["cycle"]]) for s in samples]
        execution = lambda s: s["phases"]["execution"]["seconds"]
        complete = lambda s: s["complete_seconds"]
        execution_ratios, complete_ratios = ratios(execution), ratios(complete)
        rows.append(dict(
            variant=variant, samples=len(samples),
            execution_ms=1000 * statistics.median(map(execution, samples)),
            complete_ms=1000 * statistics.median(map(complete, samples)),
            paired_execution_ratio=statistics.median(execution_ratios),
            paired_complete_ratio=statistics.median(complete_ratios),
            execution_cycle_ratios=execution_ratios,
            complete_cycle_ratios=complete_ratios,
            execution_bytes=statistics.median(s["phases"]["execution"]["allocated_bytes"] for s in samples),
            execution_wins=sum(x < 1 for x in execution_ratios),
            complete_wins=sum(x < 1 for x in complete_ratios),
            timed_jit_seconds=sum(p["compilation_seconds"] for s in samples for p in s["phases"].values()),
            timed_rejit_seconds=sum(p["recompilation_seconds"] for s in samples for p in s["phases"].values()),
            timed_gc_seconds=sum(s["complete_gc_seconds"] for s in samples),
            first_sample_coverage=samples[0]["coverage"],
            first_sample_work=samples[0]["work"],
        ))
    return dict(case=screen["case"], config=screen["config"], baseline=baseline,
                repetitions=screen["repetitions"], expected_digest=expected,
                provenance=screen["provenance"], rows=rows)


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    manifest, screens, cold = [], [], []
    for path in sorted(SOURCE.glob("*.json")):
        raw = path.read_bytes()
        data = json.loads(raw)
        target = DEST / (path.name + ".gz")
        target.write_bytes(gzip.compress(raw, mtime=0))
        manifest.append(dict(source=path.relative_to(ROOT).as_posix(),
                             artifact=target.name, raw_sha256=hashlib.sha256(raw).hexdigest(),
                             compressed_sha256=hashlib.sha256(target.read_bytes()).hexdigest()))
        if isinstance(data, dict) and "samples" in data and "baseline" in data:
            screens.append(summarize(data))
        if isinstance(data, dict) and "record" in data and "loader_seconds" in data:
            record = data["record"]
            cold.append(dict(arm=record["variant"], pid=record["process_id"],
                             freshness=record["freshness"], phases=record["phases"],
                             complete_seconds=record["complete_seconds"], digest=record["digest"],
                             loader_seconds=data["loader_seconds"], loader_scope=data["loader_scope"]))
    for directory in ("receipts", "source-snapshots", "source-snapshots-final"):
        if (SOURCE / directory).is_dir():
            shutil.copytree(SOURCE / directory, DEST / directory, dirs_exist_ok=True)
    log = SOURCE / "ordinary-focused.log"
    if log.exists():
        (DEST / "ordinary-focused.log.gz").write_bytes(gzip.compress(log.read_bytes(), mtime=0))
    (DEST / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (DEST / "summary.json").write_text(json.dumps(dict(screens=screens, cold=cold), indent=2) + "\n")
    print(json.dumps(dict(archived_records=len(manifest), screens=len(screens), cold=len(cold))))


if __name__ == "__main__":
    main()
