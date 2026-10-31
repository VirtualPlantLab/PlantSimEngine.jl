"""Archive future-layout experiments losslessly; leave local raw records intact."""
from pathlib import Path
import gzip
import hashlib
import json
import re
import shutil

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "benchmark/native_downstream/results/future-layouts"
DEST = Path(__file__).resolve().parent / "evidence/future-layouts"


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    manifest, records = [], []
    paths = [*SOURCE.glob("*.json"), *SOURCE.glob("*.jsonl"), *SOURCE.glob("*.tsv")]
    for path in sorted(paths):
        raw = path.read_bytes()
        if path.suffix == ".jsonl":
            for line in raw.splitlines():
                json.loads(line)
            data = None
        elif path.suffix == ".json":
            data = json.loads(raw)
        else:
            raw.decode("utf-8")
            data = None
        target = DEST / (path.name + ".gz")
        target.write_bytes(gzip.compress(raw, mtime=0))
        manifest.append(dict(source=path.relative_to(ROOT).as_posix(),
            artifact=target.name, raw_sha256=hashlib.sha256(raw).hexdigest(),
            compressed_sha256=hashlib.sha256(target.read_bytes()).hexdigest()))
        if isinstance(data, dict):
            record = data.get("record", data)
            if isinstance(record, dict) and "phases" in record:
                row = dict(source=path.name, **{key: record[key]
                    for key in ("case", "package", "arm", "variant", "config",
                        "process_id", "pid", "temperature", "freshness", "phases",
                        "complete_seconds", "complete_allocated_bytes", "digest",
                        "all_preparation_seconds", "work", "coverage", "catalogue",
                        "layout_matches", "future_report", "status_matches",
                        "kernel_matches", "bounded_report", "final_probe")
                    if key in record})
                match = re.fullmatch(r"cold-(pb|xp)-(reference_executor|future_precompile|bounded_preparation|combined)\.json", path.name)
                row["qualified_first_use"] = False
                if match:
                    observations = sorted(SOURCE.glob(path.stem + "-*-cpu.json"))
                    if observations:
                        cpu = json.loads(observations[-1].read_text())
                        row["qualified_first_use"] = cpu["qualified"]
                        row["cpu_record"] = observations[-1].name
                    row["package"], row["arm"] = match.groups()
                records.append(row)
    qualified = [r for r in records if r["qualified_first_use"]]
    pids = [r["config"]["process_id"] for r in qualified]
    assert len(pids) == len(set(pids)), "Each cold arm needs a distinct Julia PID"
    for package in {r["package"] for r in qualified}:
        arms = [r for r in qualified if r["package"] == package]
        assert len({r["digest"] for r in arms}) == 1, package
        assert all(r["final_probe"] == arms[0]["final_probe"] for r in arms), package
    for directory in ("receipts", "qualified-source", "unqualified-source",
        "qualified-earlier-source"):
        if (SOURCE / directory).is_dir():
            shutil.copytree(SOURCE / directory, DEST / directory, dirs_exist_ok=True)
    (DEST / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (DEST / "summary.json").write_text(json.dumps(dict(records=records,
        qualified_first_use=qualified), indent=2) + "\n")
    print(json.dumps(dict(raw_records=len(manifest), measurements=len(records),
        qualified_cold=len(qualified))))


if __name__ == "__main__":
    main()
