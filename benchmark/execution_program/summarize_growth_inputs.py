"""Validate and archive frozen growth-input evidence without starting Julia.

Use --check-only first. --archive-frozen creates a NEW immutable evidence folder;
it never overwrites one. Every input byte is preserved, including failed checks,
receipts, diagnostics, reproduction helpers and source-before-* snapshots.
Compact summaries are derived views, not substitutes for scientific snapshots.
"""

from pathlib import Path
import argparse
import gzip
import hashlib
import json
import re
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "benchmark/native_downstream/results/growth-input"
DEST = Path(__file__).resolve().parent / "evidence/growth-inputs"
SCIENTIFIC_PACKAGES = {"PlantSimEngine", "PlantBiophysics", "XPalm"}
JULIA_REFERENCE = re.compile(r'"([^"\n]+\.jl)"')


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
        ensure_ascii=False, allow_nan=False).encode("utf8")


def json_bytes(value):
    return (json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False,
        allow_nan=False) + "\n").encode("utf8")


def inventory(folder):
    result = {}
    for path in sorted(folder.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Symlink evidence input is not supported: {path}")
        if path.is_file():
            result[path.relative_to(folder).as_posix()] = path.read_bytes()
    return result


def documents(raw_files):
    parsed = {}
    for name, raw in sorted(raw_files.items()):
        if name.endswith(".json"):
            parsed[name] = json.loads(raw)
        elif name.endswith(".jsonl"):
            for line in raw.splitlines():
                if line.strip():
                    json.loads(line)
    return parsed


def walk(value, location=""):
    if isinstance(value, dict):
        yield location, value
        for key, child in value.items():
            if key not in ("snapshot", "status_types"):
                yield from walk(child, location + ("." if location else "") + key)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from walk(child, location + f"[{index}]")


def compact(value, depth=4):
    if isinstance(value, str) and len(value) > 512:
        return dict(prefix=value[:320], utf8_bytes=len(value.encode()), sha256=sha(value.encode()))
    if isinstance(value, (dict, list)) and depth <= 0:
        return dict(entries=len(value), sha256=sha(canonical(value)))
    if isinstance(value, dict):
        return {key: compact(item, depth - 1) for key, item in value.items()
            if key not in ("snapshot", "observations", "PSE_source_stack")}
    if isinstance(value, list):
        if len(value) > 16:
            return dict(entries=len(value), preview=[compact(x, depth - 1) for x in value[:8]],
                sha256=sha(canonical(value)))
        return [compact(x, depth - 1) for x in value]
    return value


def bound_raw(metadata, raw_files):
    """Resolve optional source/receipt bytes; a basename alone cannot defeat SHA."""
    path = Path(metadata["path"])
    candidates = [path.as_posix(), path.name, "reproduction/" + path.name]
    if path.is_absolute() and path.is_relative_to(SOURCE):
        candidates.insert(0, path.relative_to(SOURCE).as_posix())
    prefix = SOURCE.relative_to(ROOT)
    if not path.is_absolute() and path.is_relative_to(prefix):
        candidates.insert(0, path.relative_to(prefix).as_posix())
    matches = [name for name in dict.fromkeys(candidates) if name in raw_files
        and sha(raw_files[name]) == metadata["sha256"]]
    if len(matches) != 1:
        raise ValueError(f"Missing or ambiguous qualification evidence: {metadata['path']}")
    return matches[0]


def qualification_bindings(parsed, raw_files):
    """Validate explicit whole-RPC bindings; never infer quietness by filename."""
    manifest = parsed.get("qualification.json")
    if manifest is None:
        return {}
    if not isinstance(manifest, dict) or not isinstance(manifest.get("artifacts"), list):
        raise ValueError("qualification.json must contain an artifacts list")
    bindings = {}
    for row in manifest["artifacts"]:
        artifact, cpu_name = row["artifact"], row["cpu_record"]
        if artifact in bindings:
            raise ValueError(f"Duplicate qualification artifact: {artifact}")
        for name, expected in ((artifact, row["artifact_sha256"]), (cpu_name, row["cpu_sha256"])):
            if name not in raw_files or sha(raw_files[name]) != expected:
                raise ValueError(f"Stale or absent qualification bytes: {name}")
        if artifact not in parsed or cpu_name not in parsed:
            raise ValueError("Qualification must bind parsed JSON evidence")
        record = parsed[cpu_name]
        observations = record.get("observations", [])
        busy = sum(bool(item.get("other_busy")) for item in observations)
        if record.get("qualified") is not True or not observations or busy:
            raise ValueError(f"Explicit CPU record is not quiet/qualified: {cpu_name}")
        optional = {kind: bound_raw(row[kind], raw_files) for kind in ("script", "receipt") if kind in row}
        bindings[artifact] = dict(qualified=True, record=cpu_name, samples=len(observations),
            busy_observations=busy, scope=record.get("scope"), artifact_sha256=row["artifact_sha256"],
            cpu_sha256=row["cpu_sha256"], qualification_manifest="qualification.json",
            qualification_sha256=sha(raw_files["qualification.json"]), optional_evidence=optional,
            controller_assertion="explicit whole-RPC artifact-to-CPU binding; not filename inference")
    return bindings


def cpu_qualification(name, bindings):
    return bindings.get(name, dict(qualified=False,
        reason="no_explicit_hash_bound_CPU_qualification"))


def warm_summary(screen):
    samples, warmups = screen["samples"], screen.get("warmups", [])
    if not samples:
        raise ValueError("Empty warm screen")
    expected = screen["expected_digest"]
    if any(row["digest"] != expected for row in samples + warmups):
        raise ValueError("Scientific digest mismatch")
    if any(row["snapshot"] != samples[0]["snapshot"] or row["work"] != samples[0]["work"]
           for row in samples + warmups):
        raise ValueError("Stored scientific/RNG snapshot or work differs")
    first_order = screen["orders"][0]
    for index, order in enumerate(screen["orders"]):
        if order != (first_order if index % 2 == 0 else first_order[::-1]):
            raise ValueError("Arm order is not balanced forward/reverse")
    if [(x["cycle"], x["variant"]) for x in samples] != [
            (i + 1, arm) for i, order in enumerate(screen["orders"]) for arm in order]:
        raise ValueError("Samples do not match recorded cycle order")
    controls = {x["cycle"]: x for x in samples if x["variant"] == screen["baseline"]}
    rows = []
    for arm in first_order:
        selected = [x for x in samples if x["variant"] == arm]
        ratios = []
        for sample in selected:
            control = controls[sample["cycle"]]
            e = control["phases"]["execution"]["seconds"]
            c = control["complete_seconds"]
            if e <= 0 or c <= 0:
                raise ValueError("Nonpositive control time")
            ratios.append(dict(cycle=sample["cycle"],
                execution=sample["phases"]["execution"]["seconds"] / e,
                complete=sample["complete_seconds"] / c))
            coverage = sample["coverage"]
            policy = coverage.get("growth_input_policies", {})
            partition, heap = coverage.get("partition", {}), coverage.get("heap", {})
            if policy:
                if partition.get("enabled") != policy["partition"] or heap.get("enabled") != policy["heap_plan"]:
                    raise ValueError("Planner coverage does not match enabled arm")
                if policy["partition"] and not (partition["partition_hits"] > 0 and partition["validated_plan_tags"] > 0):
                    raise ValueError("No nonempty partition reuse")
                if policy["heap_plan"] and not (heap["heap_plans_constructed"] > 0 and heap["current_heap_plans"] > 0):
                    raise ValueError("Heap arm performed no actual plan work")
                if "payload" in policy:
                    if policy["heap_plan"] and heap.get("payload_mode") != policy["payload"]:
                        raise ValueError("Heap payload differs from selected policy")
                    if policy["payload"] == "preboxed" and not (
                            heap["preboxed_plans_constructed"] > 0 and heap["current_preboxed_plans"] > 0):
                        raise ValueError("Preboxed arm performed no actual preboxed plan work")
                    if policy["payload"] != "preboxed" and (
                            heap.get("preboxed_plans_constructed", 0) or heap.get("current_preboxed_plans", 0)):
                        raise ValueError("Preboxed payload contaminated another arm")
        events = [dict(cycle=x["cycle"], phase=name, **{key: phase[key] for key in
            ("compilation_seconds", "recompilation_seconds", "gc_seconds")})
            for x in selected for name, phase in x["phases"].items()
            if any(phase[key] for key in ("compilation_seconds", "recompilation_seconds", "gc_seconds"))]
        rows.append(dict(variant=arm, samples=len(selected), cycle_ratios=ratios,
            execution_ratio=statistics.median(x["execution"] for x in ratios),
            complete_ratio=statistics.median(x["complete"] for x in ratios),
            execution_wins=sum(x["execution"] < 1 for x in ratios),
            complete_wins=sum(x["complete"] < 1 for x in ratios),
            execution_seconds=statistics.median(x["phases"]["execution"]["seconds"] for x in selected),
            complete_seconds=statistics.median(x["complete_seconds"] for x in selected),
            execution_allocated_bytes=statistics.median(x["phases"]["execution"]["allocated_bytes"] for x in selected),
            complete_allocated_bytes=statistics.median(x["complete_allocated_bytes"] for x in selected),
            phase_counter_availability={key: all(isinstance(phase.get(key), (int, float))
                for x in selected for phase in x["phases"].values()) for key in
                ("compilation_seconds", "recompilation_seconds", "gc_seconds")},
            phase_events=events, coverage=[compact(x["coverage"]) for x in selected],
            retained=[compact(x.get("retained")) for x in selected]))
    return dict(case=screen["case"], config=screen["config"], baseline=screen["baseline"],
        repetitions=screen["repetitions"], orders=screen["orders"], expected_digest=expected,
        sample_cohort_sha256=sha(canonical(samples)), rows=rows,
        verification="stored_snapshots_RNG_work_digests_and_order_agree",
        ratio_method="median_of_paired_cycle_ratios_not_ratio_of_independent_medians")


def summarize(parsed, raw_files):
    warm, excluded, checks, profiles = [], [], [], []
    bindings = qualification_bindings(parsed, raw_files)
    for name, data in sorted(parsed.items()):
        if "/" in name:
            continue
        for location, value in walk(data):
            if isinstance(value.get("samples"), list) and "baseline" in value and "orders" in value:
                verified = warm_summary(value)
                cpu = cpu_qualification(name, bindings)
                if cpu["qualified"]:
                    warm.append(dict(source=name, location=location, cpu=cpu, **verified))
                else:
                    excluded.append(dict(source=name, location=location, cpu=cpu,
                        case=value["case"], sample_cohort_sha256=verified["sample_cohort_sha256"],
                        reason="verified_science_but_performance_ratios_preserved_only_in_raw"))
            if "passed" in value and isinstance(value["passed"], bool):
                checks.append(dict(source=name, location=location,
                    **{key: compact(value[key]) for key in ("passed", "kind", "arm", "test_counts", "work") if key in value}))
            if "allocations" in value and "benchmark_claim" in value:
                profiles.append(dict(source=name, location=location,
                    **{key: compact(value[key]) for key in ("kind", "arm", "config", "passed", "digest", "work",
                        "cpu", "allocations", "cpu_check", "allocation_check", "cpu_measurement",
                        "allocation_measurement", "benchmark_claim", "interpretation") if key in value},
                    attribution="diagnostic_sampling_not_a_causal_runtime_speedup_measurement"))
    # Separate exports of one screen are aliases, not extra independent cycles.
    unique = {}
    duplicates = []
    for screen in warm:
        key = screen["sample_cohort_sha256"]
        if key in unique:
            duplicates.append(dict(source=screen["source"], location=screen["location"],
                case=screen["case"], sample_cohort_sha256=key,
                canonical_source=unique[key]["source"], canonical_location=unique[key]["location"],
                reason="same_full_sample_cohort_export_not_an_independent_replication"))
        else:
            unique[key] = screen
    return dict(warm_screens=list(unique.values()), duplicate_screen_exports=duplicates,
        excluded_warm_screens=excluded, checks=checks, diagnostics=profiles,
        scope="paired_warm_timing_separate_from_opt_in_sampling_and_correctness",
        limitations=["Allocation sampling byte estimates do not establish a causal speedup.",
            "Allocation volume is not retained memory or peak RSS.",
            "Targeted gates are not a completed full regression suite."])


def source_inputs():
    paths = set((ROOT / "src").rglob("*.jl"))
    paths.update(ROOT / name for name in ("Project.toml", "Manifest.toml"))
    native = ROOT / "benchmark/native_downstream"
    pending = list(native.glob("growth*.jl")) + [native / name for name in
        ("direct_planner_fixtures.jl", "direct_planner_measurements.jl", "load_direct_planner_experiment.jl")]
    pending.append(Path(__file__).resolve())
    seen = set()
    while pending:
        path = pending.pop().resolve()
        path.relative_to(ROOT)
        if path in seen:
            continue
        if not path.is_file():
            raise FileNotFoundError(path)
        seen.add(path)
        paths.add(path)
        if path.suffix == ".jl":
            for reference in JULIA_REFERENCE.findall(path.read_text()):
                child = (path.parent / reference).resolve()
                if child.is_file() and child.is_relative_to(ROOT):
                    pending.append(child)
    return {p.relative_to(ROOT).as_posix(): p.read_bytes() for p in sorted(paths)}


def scientific_sources(parsed, raw_files, current_sources, summary):
    blobs = {sha(raw): raw for raw in [*raw_files.values(), *current_sources.values()]}
    records = []
    for record, data in sorted(parsed.items()):
        if "/" in record:
            continue
        for location, value in walk(data):
            packages = [package for package in value.get("packages", [])
                if isinstance(package, dict) and package.get("name") in SCIENTIFIC_PACKAGES]
            manifest = value.get("experimental_sources")
            if isinstance(manifest, dict) and "root" in manifest and isinstance(manifest.get("files"), list):
                packages.append(dict(name="experimental_sources", root=manifest["root"], sources=manifest))
            for package in packages:
                root = Path(package["root"]).resolve()
                files = []
                for expected in package.get("sources", {}).get("files", []):
                    relative = Path(expected["path"])
                    if relative.is_absolute() or ".." in relative.parts:
                        raise ValueError("Unsafe recorded source path")
                    key = expected["sha256"]
                    path = (root / relative).resolve()
                    if not path.is_relative_to(root):
                        raise ValueError("Scientific source escapes package root")
                    if key not in blobs and path.is_file():
                        candidate = path.read_bytes()
                        if sha(candidate) == key:
                            blobs[key] = candidate
                    if key not in blobs and root.is_dir() and re.fullmatch(r"[0-9a-f]{40}", package.get("revision") or ""):
                        try:
                            result = subprocess.run(["git", "show", package["revision"] + ":" + relative.as_posix()],
                                cwd=root, capture_output=True, timeout=10, check=False)
                        except (OSError, subprocess.TimeoutExpired):
                            result = None
                        if result is not None and result.returncode == 0 and sha(result.stdout) == key:
                            blobs[key] = result.stdout
                    files.append(dict(**expected, snapshot_blob=("source-blobs/" + key + ".gz") if key in blobs else None))
                records.append(dict(record=record, provenance_location=location, name=package["name"],
                    root=str(root), version=package.get("version"), revision=package.get("revision"),
                    worktree_status=package.get("worktree_status"), files=files,
                    missing_exact_source_bytes=[x["path"] for x in files if x["snapshot_blob"] is None]))
    qualified_records = {x["source"] for x in summary["warm_screens"]}
    for record in qualified_records:
        captured = {x["name"] for x in records if x["record"] == record and x["files"]}
        if SCIENTIFIC_PACKAGES - captured:
            raise ValueError(f"Qualified warm record lacks scientific package provenance: {record}")
    missing = [x for x in records if x["record"] in qualified_records and x["missing_exact_source_bytes"]]
    if missing:
        raise ValueError("Qualified warm case lacks exact scientific source bytes: " + str(missing))
    referenced = {x["sha256"] for record in records for x in record["files"] if x["snapshot_blob"]}
    return records, {key: blobs[key] for key in sorted(referenced)}


def archive(raw_files, sources, scientific, blobs, summary):
    if DEST.exists():
        raise FileExistsError(f"Immutable archive already exists: {DEST}")
    DEST.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".growth-inputs-", dir=DEST.parent) as temporary:
        stage = Path(temporary) / "growth-inputs"
        stage.mkdir()
        manifest = []
        def put(name, raw, kind, origin):
            compressed = gzip.compress(raw, mtime=0)
            target = stage / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(compressed)
            manifest.append(dict(kind=kind, origin=origin, artifact=name, raw_bytes=len(raw),
                raw_sha256=sha(raw), compressed_sha256=sha(compressed), encoding="gzip"))
        for name, raw in sorted(raw_files.items()):
            put("raw/" + name + ".gz", raw, "raw_evidence", name)
        for name, raw in sorted(sources.items()):
            put("qualified-source/" + name + ".gz", raw, "current_source_snapshot", name)
        for key, raw in sorted(blobs.items()):
            put("source-blobs/" + key + ".gz", raw, "scientific_source_blob", key)
        for name, value in (("scientific-provenance.json", scientific), ("summary.json", summary)):
            raw = json_bytes(value)
            (stage / name).write_bytes(raw)
            manifest.append(dict(kind="derived_metadata", origin=name, artifact=name,
                raw_bytes=len(raw), raw_sha256=sha(raw), encoding="identity"))
        (stage / "manifest.json").write_bytes(json_bytes(sorted(manifest, key=lambda x: x["artifact"])))
        # Atomic rename into an absent destination; never reuse a partial folder.
        if DEST.exists():
            raise FileExistsError(DEST)
        stage.rename(DEST)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check-only", action="store_true")
    mode.add_argument("--archive-frozen", action="store_true")
    args = parser.parse_args()
    if args.archive_frozen and DEST.exists():
        raise FileExistsError(f"Refusing immutable archive overwrite: {DEST}")
    raw_files = inventory(SOURCE)
    parsed = documents(raw_files)
    summary = summarize(parsed, raw_files)
    sources = source_inputs()
    scientific, blobs = scientific_sources(parsed, raw_files, sources, summary)
    # A changing source/result tree is not a frozen snapshot.
    if raw_files != inventory(SOURCE) or sources != source_inputs():
        raise RuntimeError("Evidence/source changed during validation")
    if args.archive_frozen:
        archive(raw_files, sources, scientific, blobs, summary)
    print(json.dumps(dict(archived=bool(args.archive_frozen), raw_files=len(raw_files),
        source_files=len(sources), scientific_source_blobs=len(blobs),
        qualified_warm_screens=len(summary["warm_screens"]),
        excluded_warm_screens=len(summary["excluded_warm_screens"]), checks=len(summary["checks"])), sort_keys=True))


if __name__ == "__main__":
    main()
