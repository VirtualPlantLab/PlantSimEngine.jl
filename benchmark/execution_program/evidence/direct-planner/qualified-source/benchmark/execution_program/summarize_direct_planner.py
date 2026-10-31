"""Archive a frozen direct-planner round losslessly, preserving local originals.

Run only after the controller has frozen source and all raw evidence:
    python3 benchmark/execution_program/summarize_direct_planner.py --archive-frozen

No Julia is started. Every raw file, including receipts and rejected attempts,
is archived. Compact summaries are derived views; raw bytes remain authoritative.
"""

from pathlib import Path
import argparse
import datetime
import gzip
import hashlib
import json
import re
import statistics


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "benchmark/native_downstream/results/direct-planner"
DEST = Path(__file__).resolve().parent / "evidence/direct-planner"
LOCAL_JULIA_FILE = re.compile(r'"([^"\n]+\.jl)"')


def sha256(raw):
    return hashlib.sha256(raw).hexdigest()


def json_bytes(value):
    return (json.dumps(value, indent=2, ensure_ascii=False, allow_nan=False) + "\n").encode()


def canonical_sha256(value):
    return sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
        ensure_ascii=False, allow_nan=False).encode())


def utc(value):
    parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("Qualification bounds must identify UTC explicitly")
    return parsed.astimezone(datetime.timezone.utc)


def nested(value, location):
    """Resolve only explicit dict/list locations; never evaluate source text."""
    tokens = re.findall(r"([A-Za-z_][A-Za-z_0-9]*)|\[(\d+)\]", location)
    rendered = "".join(("." if index and name else "") + name if name else f"[{slot}]"
        for index, (name, slot) in enumerate(tokens))
    if rendered != location:
        raise ValueError(f"Invalid adjudicated nested location: {location}")
    for name, slot in tokens:
        value = value[name] if name else value[int(slot)]
    return value


def bound_artifact(metadata, raw_files):
    """Bind metadata to archived bytes, including copied /tmp reproduction scripts."""
    path = Path(metadata["path"])
    candidates = [path.as_posix(), path.name, "reproduction/" + path.name]
    if path.is_absolute() and path.is_relative_to(SOURCE):
        candidates.insert(0, path.relative_to(SOURCE).as_posix())
    prefix = SOURCE.relative_to(ROOT)
    if not path.is_absolute() and path.is_relative_to(prefix):
        candidates.insert(0, path.relative_to(prefix).as_posix())
    matches = [name for name in dict.fromkeys(candidates) if name in raw_files and
        sha256(raw_files[name]) == metadata["sha256"]]
    if len(matches) != 1:
        raise ValueError(f"Adjudication artifact is absent or ambiguous: {metadata['path']}")
    name = matches[0]
    if "size_bytes" in metadata and metadata["size_bytes"] != len(raw_files[name]):
        raise ValueError("Adjudicated artifact size differs")
    return name


def adjudicated_regions(documents, raw_files):
    """Promote exact audited regions while retaining an overall false RPC flag."""
    regions = {}
    for name, audit in documents.items():
        if not name.endswith("adjudication.json") or not isinstance(audit, dict):
            continue
        bindings = audit.get("artifacts", [audit])
        for binding in bindings:
            if "raw_artifact" not in binding:
                continue
            raw_name = bound_artifact(binding["raw_artifact"], raw_files)
            cpu_name = bound_artifact(binding["cpu_artifact"], raw_files)
            cpu = documents[cpu_name]
            # Subscreen adjudication must never silently rewrite the whole RPC.
            if cpu.get("qualified") is not False or binding["cpu_artifact"].get("overall_qualified") is not False:
                raise ValueError("Expected explicitly false whole-RPC CPU qualification")
            for artifact in ("script", "receipt", "completed_receipt", "stage_artifact"):
                if artifact in binding:
                    bound_artifact(binding[artifact], raw_files)
            for row in binding.get("rows", []):
                location = row["nested_location"]
                target = nested(documents[raw_name], location)
                if row.get("kind") != target.get("kind", row.get("kind")):
                    raise ValueError("Adjudicated kind differs")
                # reports[i].screen carries kind on the enclosing report.
                if location.endswith(".screen"):
                    enclosing = nested(documents[raw_name], location[:-7])
                    if row.get("kind") != enclosing.get("kind"):
                        raise ValueError("Adjudicated report kind differs")
                if row.get("case") != target.get("case") or \
                        row["config_sha256"] != canonical_sha256(target["config"]):
                    raise ValueError("Adjudicated case/config differs")
                if "arm" in row and row["arm"] != target.get("arm"):
                    raise ValueError("Adjudicated execution arm differs")
                cohort_field = row.get("sample_cohort_field", "samples")
                if cohort_field not in ("samples", "observations") or \
                        row["sample_cohort_sha256"] != canonical_sha256(target[cohort_field]):
                    raise ValueError("Adjudicated sample cohort differs")
                if "warmup_cohort_sha256" in row and \
                        row["warmup_cohort_sha256"] != canonical_sha256(target["warmups"]):
                    raise ValueError("Adjudicated warmup cohort differs")
                lower = utc(row["bounds"]["start_lower_utc"])
                upper = utc(row["bounds"]["end_upper_utc"])
                if "sampling_bounds" in row:
                    sample_bounds = row["sampling_bounds"]
                    if not lower <= utc(sample_bounds["start_lower_utc"]) <= \
                            utc(sample_bounds["end_upper_utc"]) <= upper:
                        raise ValueError("Sampling bounds escape the audited diagnostic interval")
                quiet = row["quiet_observations"]
                if quiet.get("index_base", 0) != 0:
                    raise ValueError("Use zero-based CPU observation indices")
                indices = quiet["indices"]
                if not indices or indices != list(range(indices[0], indices[-1] + 1)):
                    raise ValueError("CPU audit must identify a contiguous bracketing interval")
                observations = cpu["observations"]
                if indices[0] < 0 or indices[-1] >= len(observations):
                    raise ValueError("CPU observation index outside artifact")
                selected = [observations[index] for index in indices]
                if quiet.get("observations_sha256", canonical_sha256(selected)) != canonical_sha256(selected):
                    raise ValueError("Audited CPU observation cohort differs")
                bracketed = utc(selected[0]["at"]) <= lower <= upper <= utc(selected[-1]["at"])
                busy = any(item.get("other_busy") for item in selected)
                qualified = row.get("qualified") is True
                if qualified and (not bracketed or busy or quiet.get("busy_in_window", []) != []):
                    raise ValueError("Audited interval is not bracketed by quiet CPU observations")
                key = (raw_name, location)
                if key in regions:
                    raise ValueError("Duplicate region adjudication")
                regions[key] = dict(qualified=qualified, whole_rpc_qualified=False,
                    scope="explicit_hash_bound_subscreen_not_whole_RPC", adjudication=name,
                    raw_sha256=binding["raw_artifact"]["sha256"], cpu_record=cpu_name,
                    cpu_sha256=binding["cpu_artifact"]["sha256"], nested_location=location,
                    kind=row.get("kind"), case=row.get("case"), bounds=row["bounds"],
                    sampling_bounds=row.get("sampling_bounds"),
                    cpu_indices=indices, checks=compact(row.get("checks")),
                    status=row.get("status"), qualification=row.get("qualification"))
    return regions


def compact(value, depth=5):
    """Bound diagnostics only; phase numbers/configuration are retained separately."""
    if isinstance(value, str) and len(value) > 512:
        return dict(prefix=value[:320], utf8_bytes=len(value.encode()), sha256=sha256(value.encode()))
    if isinstance(value, (dict, list)) and depth <= 0:
        return dict(entries=len(value), sha256=sha256(json_bytes(value)))
    if isinstance(value, dict):
        return {key: compact(item, depth - 1) for key, item in value.items()
            if key not in ("snapshot", "observations", "status_types")}
    if isinstance(value, list):
        if len(value) > 12:
            return dict(entries=len(value), preview=[compact(item, depth - 1) for item in value[:4]],
                sha256=sha256(json_bytes(value)))
        return [compact(item, depth - 1) for item in value]
    return value


def inventory(directory):
    paths = []
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Refusing symlink evidence input: {path}")
        if path.is_file():
            paths.append(path)
    return {path.relative_to(directory).as_posix(): path.read_bytes() for path in paths}


def parse_json(raw, relative):
    suffix = Path(relative).suffix
    if suffix == ".json":
        return json.loads(raw)
    if suffix == ".jsonl":
        for line in raw.splitlines():
            if line.strip():
                json.loads(line)
    return None


def provenance_summary(provenance):
    return dict(
        **{key: provenance[key] for key in ("process_id", "julia", "cpu", "threads",
            "active_project_sha256", "active_manifest_sha256") if key in provenance},
        packages=[dict(name=package.get("name"), revision=package.get("revision"),
            version=package.get("version"), source_sha256=package.get("sources", {}).get("aggregate_sha256"))
            for package in provenance.get("packages", [])])


def cpu_qualification(relative, documents):
    stem = Path(relative).stem
    candidates = sorted(name for name in documents if "/" not in name and
        name.startswith(stem + "-") and name.endswith("-cpu.json"))
    if not candidates:
        return dict(qualified=False, record=None, reason="no_cpu_qualification_record")
    name = candidates[-1]
    record = documents[name]
    observations = record.get("observations", [])
    busy = sum(bool(item.get("other_busy")) for item in observations)
    return dict(qualified=record.get("qualified") is True and bool(observations) and not busy, record=name,
        samples=len(observations), busy_observations=sum(bool(item.get("other_busy"))
            for item in observations), scope=record.get("scope"))


def cold_summary(relative, data, documents):
    record = data["record"]
    freshness = record.get("freshness") or record.get("config", {}).get("freshness") or {}
    pid = record.get("pid", record.get("process_id", freshness.get("pid")))
    fresh = all(freshness.get(key) is True for key in
        ("new_process", "no_prior_case_execution", "no_prior_ir_probe"))
    fresh = fresh and freshness.get("pid", pid) == pid and freshness.get("previous_pid") != pid
    cpu = cpu_qualification(relative, documents)
    config = record.get("config", {})
    return dict(source=relative, kind=config.get("kind", record.get("kind")),
        arm=record.get("arm"), pid=pid, config=config, freshness=freshness,
        qualified_first_use=fresh and cpu["qualified"], cpu=cpu,
        phases=record["phases"], complete_seconds=record.get("complete_seconds"),
        complete_allocated_bytes=record.get("complete_allocated_bytes"), digest=record.get("digest"),
        work=compact(record.get("work")), coverage=compact(record.get("coverage")),
        loader_seconds=data.get("loader_seconds"), loader_scope=data.get("loader_scope"),
        provenance=provenance_summary(data.get("provenance", {})))


def warm_summary(kind, screen):
    samples = screen["samples"]
    baseline = screen["baseline"]
    controls = {row["cycle"]: row for row in samples if row["variant"] == baseline}
    expected = screen.get("expected_digest")
    if expected is not None and any(row["digest"] != expected for row in samples):
        raise ValueError("Warm screen scientific digest mismatch")
    rows = []
    for variant in dict.fromkeys(row["variant"] for row in samples):
        selected = [row for row in samples if row["variant"] == variant]
        def paired(field):
            values = []
            for row in selected:
                denominator = field(controls[row["cycle"]])
                if denominator <= 0:
                    raise ValueError("Nonpositive warm control denominator")
                values.append(field(row) / denominator)
            return values
        execution = lambda row: row["phases"]["execution"]["seconds"]
        complete = lambda row: row["complete_seconds"]
        prepare = lambda row: row["phases"]["pse_preparation"]["seconds"]
        ratios = dict(execution=paired(execution), complete=paired(complete), preparation=paired(prepare))
        rows.append(dict(variant=variant, samples=len(selected),
            execution_ms=1000 * statistics.median(map(execution, selected)),
            complete_ms=1000 * statistics.median(map(complete, selected)),
            preparation_ms=1000 * statistics.median(map(prepare, selected)),
            paired_execution_ratio=statistics.median(ratios["execution"]),
            paired_complete_ratio=statistics.median(ratios["complete"]),
            paired_preparation_ratio=statistics.median(ratios["preparation"]),
            cycle_ratios=ratios,
            execution_allocated_bytes=statistics.median(
                row["phases"]["execution"]["allocated_bytes"] for row in selected),
            preparation_allocated_bytes=statistics.median(
                row["phases"]["pse_preparation"]["allocated_bytes"] for row in selected),
            complete_allocated_bytes=statistics.median(row["complete_allocated_bytes"] for row in selected),
            phase_compilation=[{name: {key: phase.get(key) for key in
                ("compilation_seconds", "recompilation_seconds")}
                for name, phase in row["phases"].items()} for row in selected],
            first_coverage=compact(selected[0].get("coverage")),
            first_work=compact(selected[0].get("work"))))
    return dict(kind=kind, case=screen.get("case"), config=screen.get("config"),
        baseline=baseline, repetitions=screen.get("repetitions"), expected_digest=expected, rows=rows,
        ratio_method="median_of_paired_same_cycle_ratios_not_ratio_of_independent_medians",
        provenance=provenance_summary(screen.get("provenance", {})))


def profile_rows(value, source, location=""):
    """Find sampling/framework diagnostics without retaining scientific snapshots."""
    rows = []
    if isinstance(value, dict):
        if isinstance(value.get("samples"), dict) and "inclusive_phase_samples" in value["samples"]:
            rows.append(dict(source=source, nested_location=location, **{key: compact(value[key]) for key in
                ("kind", "arm", "config", "policies", "repetitions", "pid", "samples",
                 "inclusive_phase_samples_per_simulation", "diagnostic_measurement", "digest",
                 "framework", "qualification", "benchmark_claim") if key in value}))
            return rows
        if "final_framework_performance" in value:
            rows.append(dict(source=source, nested_location=location, **{key: compact(value[key]) for key in
                ("kind", "arm", "config", "policies", "steps_report", "final_framework_performance",
                 "interpretation", "per_phase_allocations", "targeted_preparation") if key in value}))
            return rows
        for key, child in value.items():
            if key not in ("provenance", "snapshot", "observations", "screen"):
                rows.extend(profile_rows(child, source, location + ("." if location else "") + key))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            rows.extend(profile_rows(child, source, location + f"[{index}]"))
    return rows


def summarize(documents, raw_files=None):
    cold, warm, correctness, profiles, excluded_warm, excluded_profiles = [], [], [], [], [], []
    regions = adjudicated_regions(documents, raw_files or {})
    def qualification(relative, location):
        global_cpu = cpu_qualification(relative, documents)
        if global_cpu["qualified"]:
            return dict(qualified=True, whole_rpc_qualified=True,
                scope="whole_RPC_CPU_qualification", cpu=global_cpu)
        return regions.get((relative, location), dict(qualified=False,
            whole_rpc_qualified=False, scope="no_matching_qualified_subscreen_audit", cpu=global_cpu))
    def add_warm(relative, data, kind, screen, location):
        proof = qualification(relative, location)
        cohort = dict(kind=kind, case=screen.get("case"),
            variants=list(dict.fromkeys(row["variant"] for row in screen["samples"])),
            config_sha256=canonical_sha256(screen["config"]),
            sample_cohort_sha256=canonical_sha256(screen["samples"]),
            admitted_sources=data.get("admission_sources", []))
        if proof["qualified"]:
            warm.append(dict(source=relative, nested_location=location, qualification=proof,
                cohort=cohort, **warm_summary(kind, screen)))
        else:
            excluded_warm.append(dict(source=relative, nested_location=location,
                qualification=proof, cohort=cohort,
                reason="performance_ratios_excluded_preserved_only_in_lossless_raw_artifact"))
    for relative, data in sorted(documents.items()):
        if "/" in relative or not isinstance(data, dict):
            continue
        if relative.startswith("cold-") and isinstance(data.get("record"), dict) and \
                isinstance(data["record"].get("phases"), dict):
            cold.append(cold_summary(relative, data, documents))
        if "passed" in data or "test_counts" in data or "bridge_test_counts" in data:
            correctness.append(dict(source=relative, **{key: compact(data[key]) for key in
                ("passed", "process_id", "test_counts", "kind", "arm", "reports", "source", "project",
                 "bridge_checks", "bridge_test_counts", "admission_sources")
                if key in data and key != "source"}))
        if "samples" in data and "baseline" in data:
            add_warm(relative, data, data.get("kind"), data, "")
        for index, report in enumerate(data.get("reports", []) if isinstance(data.get("reports"), list) else []):
            if isinstance(report, dict) and isinstance(report.get("screen"), dict):
                add_warm(relative, data, report.get("kind"), report["screen"], f"reports[{index}].screen")
        for profile in profile_rows(data, relative):
            proof = qualification(relative, profile["nested_location"])
            profile["cpu_qualification"] = proof
            if proof["qualified"]:
                profiles.append(profile)
            else:
                excluded_profiles.append(dict(source=relative, nested_location=profile["nested_location"],
                    kind=profile.get("kind"), arm=profile.get("arm"), qualification=proof,
                    reason="unqualified_diagnostic_metrics_preserved_in_raw_artifact"))
    qualified = [row for row in cold if row["qualified_first_use"]]
    pids = [row["pid"] for row in qualified]
    if len(pids) != len(set(pids)):
        raise ValueError("Qualified cold arms require distinct Julia workers")
    groups = {}
    for row in qualified:
        config = {key: value for key, value in row["config"].items()
            if key not in ("policies", "policies_by_arm", "freshness")}
        groups.setdefault(json.dumps(config, sort_keys=True), []).append(row)
    for rows in groups.values():
        if len({row["digest"] for row in rows}) != 1:
            raise ValueError("Qualified cold scientific digest mismatch")
        if any(row["work"] != rows[0]["work"] for row in rows):
            raise ValueError("Qualified cold work mismatch")
    return dict(correctness=correctness, cold=cold, qualified_first_use=qualified,
        warm_screens=warm, growth_profiles=profiles, excluded_warm_screens=excluded_warm,
        excluded_growth_profiles=excluded_profiles,
        parent_source_attribution=dict(qualified_science_samples=0, attribution_claim=False,
            reason="parent_worker_setup_failed_no_parent_scientific_sample",
            preserved_artifacts=[name for name in documents if name.startswith("parent-")]),
        interpretation="single_cold_observations_and_paired_warm_screen_are_separate_evidence",
        profile_scope="inclusive_overlapping_CPU_samples_and_instrumented_framework_counters_not_benchmark_times")


def source_inputs(root):
    """Snapshot core plus the literal local Julia dependency closure of the loader."""
    native = root / "benchmark/native_downstream"
    paths = set((root / "src").rglob("*.jl"))
    paths.update(root / name for name in ("Project.toml", "Manifest.toml"))
    seeds = [native / "load_direct_planner_experiment.jl", native / "load_experiments.jl"]
    seeds += list(native.glob("direct_planner*.jl"))
    seeds += list(native.glob("planner_boundar*.jl"))
    seeds += list(native.glob("local_ports_selected_bridge*.jl"))
    seeds += [native / "direct_plan_construction.jl", Path(__file__).resolve()]
    pending = list(seeds)
    seen = set()
    while pending:
        path = pending.pop().resolve()
        path.relative_to(root)
        if path in seen:
            continue
        if not path.is_file():
            raise FileNotFoundError(path)
        seen.add(path)
        paths.add(path)
        if path.suffix == ".jl":
            for reference in LOCAL_JULIA_FILE.findall(path.read_text()):
                candidate = (path.parent / reference).resolve()
                if candidate.is_file() and candidate.is_relative_to(root):
                    pending.append(candidate)
    return {path.relative_to(root).as_posix(): path.read_bytes() for path in sorted(paths)}


def source_qualification(documents, sources, summary):
    """Verify current snapshots against every available qualified cold file hash."""
    results = []
    for row in summary["qualified_first_use"]:
        provenance = documents[row["source"]].get("provenance", {})
        packages = [package for package in provenance.get("packages", [])
            if package.get("name") == "PlantSimEngine"]
        expected = {item["path"]: item["sha256"] for package in packages
            for item in package.get("sources", {}).get("files", [])}
        if "src/composite_model/compilation.jl" not in expected:
            raise ValueError(f"Qualified cold record lacks planner source hashes: {row['source']}")
        checked = [name for name in sources if name in expected]
        mismatches = [name for name in checked if sha256(sources[name]) != expected[name]]
        if mismatches:
            raise ValueError(f"Qualified cold source drift in {row['source']}: {mismatches}")
        results.append(dict(record=row["source"], checked_files=len(checked),
            mismatches=mismatches, files_without_per_record_hash=[name for name in sources if name not in expected]))
    return results


def admission_qualification(documents, sources):
    """Bind promoted optional bridge bytes to the separately measured cohort."""
    rows = []
    for name, data in documents.items():
        if "/" in name or not isinstance(data, dict):
            continue
        for admitted in data.get("admission_sources", []):
            promoted = "benchmark/native_downstream/" + Path(admitted["path"]).name
            if promoted not in sources or sha256(sources[promoted]) != admitted["sha256"]:
                raise ValueError(f"Promoted admission source differs from {name}: {promoted}")
            rows.append(dict(record=name, original_path=admitted["path"], promoted_source=promoted,
                measured_sha256=admitted["sha256"], snapshot_sha256=sha256(sources[promoted]),
                scope="optional_later_cohort_not_retroactive_earlier_source_coverage"))
    return rows


def write_exact(path, raw):
    """Existing archive bytes are immutable; identical reruns are harmless."""
    if path.exists():
        if path.read_bytes() != raw:
            raise FileExistsError(f"Refusing to replace archived evidence: {path}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(raw)


def archive(root=ROOT, source=SOURCE, dest=DEST):
    if not source.is_dir():
        raise FileNotFoundError(source)
    raw_files = inventory(source)
    documents = {name: parse_json(raw, name) for name, raw in raw_files.items()}
    sources = source_inputs(root)
    summary = summarize(documents, raw_files)
    summary["source_qualification"] = source_qualification(documents, sources, summary)
    summary["admission_source_qualification"] = admission_qualification(documents, sources)
    manifest = []
    for relative, raw in raw_files.items():
        target = dest / "raw" / (relative + ".gz")
        encoded = gzip.compress(raw, mtime=0)
        write_exact(target, encoded)
        if gzip.decompress(target.read_bytes()) != raw:
            raise ValueError(f"Gzip round-trip mismatch: {relative}")
        manifest.append(dict(source=(source / relative).relative_to(root).as_posix(),
            artifact=target.relative_to(dest).as_posix(), raw_bytes=len(raw),
            compressed_bytes=len(encoded), raw_sha256=sha256(raw), compressed_sha256=sha256(encoded)))
    source_manifest = []
    for relative, raw in sources.items():
        target = dest / "qualified-source" / relative
        write_exact(target, raw)
        if target.read_bytes() != raw:
            raise ValueError(f"Source snapshot mismatch: {relative}")
        source_manifest.append(dict(source=relative, artifact=target.relative_to(dest).as_posix(),
            raw_bytes=len(raw), raw_sha256=sha256(raw), snapshot_sha256=sha256(target.read_bytes())))
    if inventory(source) != raw_files:
        raise RuntimeError("Raw evidence changed during archival; freeze data before retrying")
    if any((root / relative).read_bytes() != raw for relative, raw in sources.items()):
        raise RuntimeError("Qualified source changed during archival")
    write_exact(dest / "manifest.json", json_bytes(manifest))
    write_exact(dest / "source-manifest.json", json_bytes(source_manifest))
    write_exact(dest / "summary.json", json_bytes(summary))
    return dict(raw_records=len(manifest), source_snapshots=len(source_manifest),
        correctness_records=len(summary["correctness"]), cold_records=len(summary["cold"]),
        qualified_cold=len(summary["qualified_first_use"]), warm_screens=len(summary["warm_screens"]),
        growth_profiles=len(summary["growth_profiles"]), lossless_round_trips_verified=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive-frozen", action="store_true",
        help="attest controller has frozen this round's source and raw evidence")
    args = parser.parse_args()
    if not args.archive_frozen:
        parser.error("Archive only after controller approval with --archive-frozen")
    print(json.dumps(archive(), sort_keys=True))


if __name__ == "__main__":
    main()
