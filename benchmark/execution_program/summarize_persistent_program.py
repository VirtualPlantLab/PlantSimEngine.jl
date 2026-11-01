"""Validate and losslessly archive this round's small persistent-program screens.

Python only. No Julia starts here. Raw evidence is restricted to the owned
persistent-program directory; old result trees are never timing baselines.
Use --check-only first and --archive-frozen only after the controller's freeze.
"""
from pathlib import Path
import argparse
import gzip
import json
import math
import re
import statistics
import subprocess
import tempfile

import summarize_newborn_bindings as shared

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "benchmark/native_downstream/results/persistent-program"
DEST = Path(__file__).resolve().parent / "evidence/persistent-program"
shared.SOURCE = SOURCE
sha, canonical, json_bytes = shared.sha, shared.canonical, shared.json_bytes
PROTOCOL = "persistent_program_small_screen_v1"
ARMS = ("ordinary_a", "ordinary_b", "preparation_only", "typed_only", "combined")
PHASES = ("construction", "pse_preparation", "backend_lowering", "execution")
PROGRAM_COUNTS = ("batch_executions", "regions_reused", "regions_readmitted", "regions_rebuilt",
    "ordinary_fallbacks", "exposed_application_declines", "refreshes", "internal_regions_captured",
    "metadata_rebases", "live_regions", "live_active_regions")


def inventory(folder):
    result = {}
    pending = [folder]
    while pending:
        parent = pending.pop()
        for path in sorted(parent.iterdir()):
            if path.is_symlink():
                raise ValueError(f"Symlink input is unsupported: {path}")
            if path.is_dir():
                pending.append(path)
            elif path.is_file():
                result[path.relative_to(folder).as_posix()] = path.read_bytes()
    return dict(sorted(result.items()))


def source_inputs():
    paths = {Path(__file__).resolve(), Path(shared.__file__).resolve()}
    for directory in ("src", "ext", "benchmark/native_downstream", "benchmark/compiled_regions",
            "benchmark/generated_program"):
        pending = [ROOT / directory]
        while pending:
            parent = pending.pop()
            if not parent.is_dir() or parent.is_symlink():
                continue
            for path in sorted(parent.iterdir()):
                if path.is_symlink() or path.name in (".git", "results"):
                    continue
                if path.is_dir():
                    pending.append(path)
                elif path.suffix == ".jl":
                    paths.add(path)
    paths.update(ROOT / name for name in ("Project.toml", "Manifest.toml"))
    return {p.relative_to(ROOT).as_posix(): p.read_bytes() for p in sorted(paths)}


def number(value, *, integer=False):
    if isinstance(value, bool) or not isinstance(value, int if integer else (int, float)) or \
            not math.isfinite(value) or value < 0:
        raise ValueError("Expected a nonnegative finite measured count/cost")
    return value


def ratio(numerator, denominator):
    return numerator / denominator if denominator else None


def policy(arm):
    if arm not in ARMS:
        raise ValueError(f"Unknown persistent arm: {arm}")
    return dict(preparation=arm in ("preparation_only", "combined"),
        typed=arm in ("typed_only", "combined"))


def coverage_checks(c, arm, kind, work):
    expected = policy(arm)
    if c["arm"] != arm or c["policy"] != expected or c["scope"] != \
            "original_scientific_models_and_ordinary_reference_storage" or \
            c["driver_units_kind"] != "actual_selected_batch_entries_not_prepared_or_inferred_work":
        raise ValueError("Persistent arm policy/storage/work interpretation differs")
    if c["native_fields"] != 0 or c["native_driver_units"] != 0:
        raise ValueError("Persistent experiment unexpectedly entered native column storage")
    number(c["driver_units"], integer=True)
    b, g, t = c["bounded"], c["graph"], c["typed_output_preparation"]
    if b["enabled"] is not expected["preparation"] or g["enabled"] is not expected["preparation"] or \
            t["enabled"] is not expected["preparation"]:
        raise ValueError("Preparation policy contaminated another factorial arm")
    if (b["scene_entries"] > 0) is not expected["preparation"] or \
            any(b[k] is not False for k in ("cached_memberships", "cached_sampled_environments", "copied_scientific_values")):
        raise ValueError("Bounded preparation lacks actual work or cached live state")
    gc, tc = g["counters"], t["counters"]
    for counts in (gc, tc):
        for value in counts.values():
            number(value, integer=True)
    if tc["applications_completed"] != tc["initial_applications_completed"] + tc["growth_applications_completed"] or \
            tc["objects_prepared"] != tc["initial_objects_prepared"] + tc["growth_objects_prepared"]:
        raise ValueError("Typed output initial/growth completion partitions differ")
    if expected["preparation"]:
        if not all(value > 0 for value in (gc["projections_completed"], gc["rows_projected"],
                tc["applications_completed"], tc["objects_prepared"])):
            raise ValueError("Preparation arm has no actual returned rows/object preparation")
    elif any(gc.values()) or any(tc.values()):
        raise ValueError("Disabled preparation control contains completed work")
    if kind == "pb" and (tc["growth_applications_completed"] or tc["growth_objects_prepared"]):
        raise ValueError("No-growth PB fixture falsely credited growth preparation")
    if any(t[k] is not False for k in ("cached_defaults", "cached_memberships", "copied_scientific_values")):
        raise ValueError("Typed preparation cached defaults, membership or science")
    program = c["typed_program"]
    if not expected["typed"]:
        if program is not None or c["driver_units"]:
            raise ValueError("An ordinary executor control entered the typed program")
        return dict(driver_entries=0, refreshes=0, reused=0, readmitted=0,
            ordinary_fallbacks=0, numerical_roots=None, numerical_calls=None)
    if not isinstance(program, dict) or program["batch_executions"] != c["driver_units"] or c["driver_units"] <= 0:
        raise ValueError("Typed arm completed no actual selected batch entries")
    for name in PROGRAM_COUNTS:
        number(program[name], integer=True)
    if program["canonical_storage"] != "ordinary_references" or program["scientific_values_copied"] is not False or \
            program["initial_lowering"] != "additional_to_ordinary_zero_step_preparation" or \
            program["numerical_executor"] != "original_Tight_noinline_child" or \
            program["performance_fallback"] is not False or program["qualification"] != "persistent_candidate":
        raise ValueError("Typed execution/storage/lowering scope differs")
    if program["live_active_regions"] > program["live_regions"] or \
            program["regions_reused"] != program["metadata_rebases"]:
        raise ValueError("Persistent live-region/rebase accounting differs")
    for key in ("executed_numerical_roots", "executed_numerical_calls"):
        value = program[key]
        if program["actual_numerical_id_trace"]:
            number(value, integer=True)
        elif value is not None:
            raise ValueError("Compiled-out numerical counters were presented as actual counts")
    if kind == "xp" and work["added_ids"] and program["refreshes"] <= 0:
        raise ValueError("Growing XP typed run contains no actual refresh")
    return dict(driver_entries=program["batch_executions"], refreshes=program["refreshes"],
        reused=program["regions_reused"], readmitted=program["regions_readmitted"],
        ordinary_fallbacks=program["ordinary_fallbacks"],
        numerical_roots=program["executed_numerical_roots"], numerical_calls=program["executed_numerical_calls"])


def screen_summary(screen):
    config = screen["config"]
    if config.get("protocol") != PROTOCOL or screen["baseline"] != "ordinary_a" or \
            config.get("interpretation") != "warm_fresh_scene_with_charged_ordinary_plan_then_typed_installation" or \
            config.get("statistical_unit") != "one_independent_scene" or config.get("storage") != "ordinary_references":
        raise ValueError("Unsupported protocol or uncharged installation scope")
    kind = config["kind"]
    if kind not in ("pb", "xp"):
        raise ValueError("Only original PB/XP fixtures belong to this round")
    warmups, samples, orders = screen["warmups"], screen["samples"], screen["orders"]
    repetitions = number(screen["repetitions"], integer=True)
    if repetitions < 1 or len(orders) != repetitions or len(warmups) != len(ARMS) or \
            set(row["variant"] for row in warmups) != set(ARMS):
        raise ValueError("Missing warmup, cycle or factorial arm")
    first_order = [row["variant"] for row in samples if row["cycle"] == 1]
    if len(first_order) != len(ARMS) or set(first_order) != set(ARMS):
        raise ValueError("Missing first-cycle factorial arms")
    for cycle, order in enumerate(orders, 1):
        expected = first_order if cycle % 2 else list(reversed(first_order))
        actual = [row["variant"] for row in samples if row["cycle"] == cycle]
        if order != expected or actual != expected:
            raise ValueError("Samples do not follow the recorded alternating balanced order")
    if len(samples) != repetitions * len(ARMS) or {row["cycle"] for row in samples} != set(range(1, repetitions + 1)):
        raise ValueError("Missing or extra statistical scene sample")
    reference = next(row for row in warmups if row["variant"] == "ordinary_a")
    snapshot, work = canonical(reference["snapshot"]), canonical(reference["work"])
    if set(reference["snapshot"]) != {"state", "rng"}:
        raise ValueError("Need full scientific state/history and model RNG fingerprints")
    if reference["work"]["steps"] != config["steps"] or \
            reference["snapshot"]["state"]["scientific"]["step"] != config["steps"] or \
            len(reference["snapshot"]["state"]["topology"]) != reference["work"]["objects"]:
        raise ValueError("Actual step/object work differs from configuration/snapshot")
    actual = []
    for row in warmups + samples:
        if row["case"] != screen["case"] or canonical(row["config"]) != canonical(config) or \
                row["process_id"] != screen["provenance"]["process_id"] or \
                row["digest"] != screen["expected_digest"] or canonical(row["snapshot"]) != snapshot or canonical(row["work"]) != work:
            raise ValueError("Exact state/history/RNG/work/config/PID parity differs")
        if set(row["phases"]) != set(PHASES):
            raise ValueError("Construction/preparation/lowering/execution phase missing")
        shared.validate_phase_sums(row)
        for phase in row["phases"].values():
            for key in ("seconds", "allocated_bytes", "gc_seconds", "compilation_seconds", "recompilation_seconds"):
                number(phase[key], integer=key == "allocated_bytes")
        if not math.isclose(sum(p["gc_seconds"] for p in row["phases"].values()), row["complete_gc_seconds"], abs_tol=1e-12):
            raise ValueError("Complete GC cost differs from phase sum")
        completed = coverage_checks(row["coverage"], row["variant"], kind, row["work"])
        if "cycle" in row:
            actual.append(dict(cycle=row["cycle"], arm=row["variant"], **completed))
    controls = {row["cycle"]: row for row in samples if row["variant"] == "ordinary_a"}
    reports = []
    for arm in first_order:
        rows = [r for r in samples if r["variant"] == arm]
        paired = []
        for row in rows:
            control = controls[row["cycle"]]
            phases = {name: {key: ratio(row["phases"][name][key], control["phases"][name][key])
                for key in ("seconds", "allocated_bytes")} for name in PHASES}
            paired.append(dict(cycle=row["cycle"], phases=phases,
                complete_seconds=ratio(row["complete_seconds"], control["complete_seconds"]),
                complete_allocated_bytes=ratio(row["complete_allocated_bytes"], control["complete_allocated_bytes"])))
        phase_medians = {name: {key: statistics.median(row["phases"][name][key] for row in rows)
            for key in ("seconds", "allocated_bytes", "gc_seconds", "compilation_seconds", "recompilation_seconds")} for name in PHASES}
        jit = [dict(cycle=row["cycle"], phase=name,
            compilation_seconds=p["compilation_seconds"], recompilation_seconds=p["recompilation_seconds"])
            for row in rows for name, p in row["phases"].items()
            if p["compilation_seconds"] or p["recompilation_seconds"]]
        reports.append(dict(arm=arm, samples=len(rows), phase_medians=phase_medians,
            complete_seconds=statistics.median(r["complete_seconds"] for r in rows),
            complete_allocated_bytes=statistics.median(r["complete_allocated_bytes"] for r in rows),
            paired_cycles=paired, jit_events=jit,
            execution_ratio=statistics.median(p["phases"]["execution"]["seconds"] for p in paired),
            complete_ratio=statistics.median(p["complete_seconds"] for p in paired),
            actual_work=[r for r in actual if r["arm"] == arm]))
    return dict(kind=kind, case=screen["case"], config=config, cycles=repetitions,
        digest=screen["expected_digest"], snapshot_sha256=sha(snapshot), work=reference["work"],
        sample_cohort_sha256=sha(canonical(samples)), source_epoch=shared.source_epoch(screen), arms=reports,
        ordinary_A_A=next(row for row in reports if row["arm"] == "ordinary_b"),
        interpretation="small_warm_fresh_scene_screen_two_cycles_do_not_establish_robust_speedup",
        cold_compilation_claim=False, peak_RSS_claim=False,
        driver_work="actual_batch_entries_not_prepared_regions_or_inferred_numerical_roots")


def validate_manifest(manifest):
    rows = manifest["files"]
    paths = [r["path"] for r in rows]
    if paths != sorted(set(paths)) or any(Path(p).is_absolute() or ".." in Path(p).parts for p in paths):
        raise ValueError("Unsafe, duplicated or unordered source manifest")
    if any(not re.fullmatch(r"[0-9a-f]{64}", r["sha256"]) for r in rows):
        raise ValueError("Malformed source hash")
    if sha("\n".join(r["path"] + "\0" + r["sha256"] for r in rows).encode()) != manifest["aggregate_sha256"]:
        raise ValueError("Recorded source aggregate hash differs")


def scientific_sources(screens, raw, current):
    records, blobs = [], {sha(value): value for value in [*raw.values(), *current.values()]}
    for name, screen in screens.items():
        provenance = screen["provenance"]
        manifests = [(p["name"], p["root"], p["sources"]) for p in provenance["packages"]]
        manifests += [("harness", provenance["harness"]["root"], provenance["harness"]),
            ("experimental_sources", provenance["experimental_sources"]["root"], provenance["experimental_sources"])]
        if not {"PlantSimEngine", "PlantBiophysics", "XPalm"} <= {r[0] for r in manifests}:
            raise ValueError("Missing exact common scientific package provenance")
        for package, root_path, manifest in manifests:
            validate_manifest(manifest)
            root = Path(root_path).resolve()
            for row in manifest["files"]:
                key, path = row["sha256"], root / row["path"]
                if path.is_symlink() or not path.resolve().is_relative_to(root):
                    raise ValueError("Source path escapes its declared package root")
                if key not in blobs and path.is_file():
                    value = path.read_bytes()
                    if sha(value) == key:
                        blobs[key] = value
                if key not in blobs:
                    raise ValueError(f"Exact source bytes missing: {name}:{package}:{row['path']}")
                if path.is_file() and sha(path.read_bytes()) != key:
                    raise ValueError(f"Final screen source cohort differs from current source: {path}")
            records.append(dict(source=name, name=package, root=str(root),
                aggregate_sha256=manifest["aggregate_sha256"], files=manifest["files"]))
    referenced = {r["sha256"] for m in records for r in m["files"]}
    return records, {key: blobs[key] for key in sorted(referenced)}


def summarize(parsed, raw):
    scope = parsed.get("run-scope.json", {})
    bindings = shared.qualification_bindings(parsed, raw)
    candidates = {name: value for name, value in parsed.items() if "/" not in name and name.endswith("-screen.json")}
    declared = scope.get("final_screens", sorted(candidates))
    if len(declared) != len(set(declared)) or not set(declared) <= set(candidates):
        raise ValueError("Missing or duplicated declared final screen")
    qualified, excluded, selected = [], [], {}
    for name in declared:
        value = candidates[name]
        result = dict(source=name, cpu=shared.cpu_qualification(name, bindings), **screen_summary(value))
        if result["cpu"]["qualified"]:
            if set(result["cpu"]["optional_evidence"]) != {"script", "receipt"}:
                raise ValueError("Qualified screen lacks exact script/completion receipt bindings")
            qualified.append(result)
            selected[name] = value
        else:
            excluded.append(result)
    if qualified and len({r["source_epoch"]["sha256"] for r in qualified}) != 1:
        raise ValueError("Final qualified screens mix source cohorts")
    excluded_rows = parsed.get("qualification.json", {}).get("excluded_artifacts", [])
    declared_exclusions = {r["artifact"]: r["reason"] for r in scope.get("excluded_screens", [])}
    if len(declared_exclusions) != len(scope.get("excluded_screens", [])):
        raise ValueError("Duplicate declared diagnostic exclusion")
    excluded_diagnostics = []
    for row in excluded_rows:
        name, cpu_name = row["artifact"], row["cpu_record"]
        if name in declared or name in bindings or name not in declared_exclusions:
            raise ValueError("Excluded diagnostic overlaps final/qualified screens or lacks a declared reason")
        for path, expected in ((name, row["artifact_sha256"]), (cpu_name, row["cpu_sha256"])):
            if path not in raw or sha(raw[path]) != expected:
                raise ValueError("Stale excluded-diagnostic artifact/CPU binding")
        if row.get("qualified") is not False or parsed[cpu_name].get("qualified") is not False:
            raise ValueError("Excluded diagnostic was represented as timing-qualified")
        optional = {kind: shared.bound_raw(row[kind], raw) for kind in ("script", "receipt")}
        excluded_diagnostics.append(dict(source=name, raw_sha256=row["artifact_sha256"],
            cpu_record=cpu_name, cpu_sha256=row["cpu_sha256"], optional_evidence=optional,
            reason=declared_exclusions[name], timing_qualified=False,
            interpretation="raw_diagnostic_only_no_derived_timing_ratios_or_speedup_claim"))
    if {r["source"] for r in excluded_diagnostics} != set(declared_exclusions) or \
            len(excluded_diagnostics) != len(declared_exclusions):
        raise ValueError("Declared diagnostic exclusions lack unique exact qualification bindings")
    gates = []
    for name in scope.get("final_gates", []):
        if name not in parsed or "/" in name or not isinstance(parsed[name], dict):
            raise ValueError("Missing declared final gate artifact")
        passed = [v["passed"] for _, v in shared.walk(parsed[name]) if "passed" in v]
        if not passed or any(value is not True for value in passed):
            raise ValueError("Declared final gate contains a failed or absent assertion result")
        gates.append(dict(source=name, sha256=sha(raw[name]), passed=True,
            scope="controller_declared_final_gate_not_all_historical_passed_files"))
    base = scope.get("core_base_revision")
    if base is not None and not re.fullmatch(r"[0-9a-f]{40}", base):
        raise ValueError("Core base must be an exact commit SHA")
    return dict(protocol=PROTOCOL, run_scope=scope, qualified_warm_screens=qualified,
        unqualified_declared_final_screens=excluded, excluded_diagnostic_screens=excluded_diagnostics,
        final_gates=gates,
        diagnostic_or_historical_raw=[name for name in sorted(raw)
            if name not in set(declared) | {r["source"] for r in gates}],
        old_results_used_as_baselines=False, cold_claim=False,
        limitations=["Two paired cycles are a small screen, not robust speedup evidence.",
            "A/A spread includes cache, timer and OS effects; it is not an isolated noise estimate.",
            "Typed installation is charged after ordinary plan preparation.",
            "Batch-entry counts do not imply numerical-root counters when their tracing is compiled out.",
            "No million-organ, peak-RSS, full-monolith or cold-compilation claim follows."]), selected


def core_base_check(scope, current):
    base = scope.get("core_base_revision")
    if base is None:
        return dict(verified=False, reason="controller_has_not_declared_core_base")
    files = [p for p in current if p.startswith(("src/", "ext/"))]
    for path in files:
        result = subprocess.run(["git", "show", base + ":" + path], cwd=ROOT,
            capture_output=True, timeout=10, check=False)
        if result.returncode or result.stdout != current[path]:
            raise ValueError(f"Core source differs from declared base {base}: {path}")
    return dict(verified=True, revision=base, files=len(files),
        scope="exact_current_src_and_ext_bytes_equal_declared_core_base")


def forcing_source(scope, raw):
    declared = scope.get("forcing")
    if declared is None:
        return dict(captured=False, reason="controller_has_not_supplied_forcing_copy")
    name, expected = declared["raw_artifact"], declared["sha256"]
    if name not in raw or sha(raw[name]) != expected:
        raise ValueError("Controller forcing copy is absent or differs from declared hash")
    return dict(captured=True, **declared,
        scope="controller_supplied_exact_forcing_copy_not_an_independent_during_screen_IO_guard")


def archive(raw, current, science, blobs, summary):
    if DEST.exists():
        raise FileExistsError("Refusing immutable archive overwrite")
    if summary["run_scope"].get("frozen") is not True or not summary["core_base"]["verified"] or \
            not summary["final_gates"] or not summary["forcing"]["captured"] or \
            len(summary["qualified_warm_screens"]) != 2 or summary["unqualified_declared_final_screens"]:
        raise ValueError("Archive requires frozen scope, exact core base, final gates and qualified PB/XP screens")
    if {row["kind"] for row in summary["qualified_warm_screens"]} != {"pb", "xp"}:
        raise ValueError("Archive needs both independent downstream screens")
    DEST.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".persistent-program-", dir=DEST.parent) as temporary:
        stage = Path(temporary) / "persistent-program"
        stage.mkdir()
        manifest = []
        def put(name, payload, kind, origin):
            encoded = gzip.compress(payload, mtime=0)
            target = stage / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(encoded)
            manifest.append(dict(kind=kind, origin=origin, artifact=name, encoding="gzip",
                raw_bytes=len(payload), raw_sha256=sha(payload), compressed_sha256=sha(encoded)))
        for name, value in raw.items():
            put("raw/" + name + ".gz", value, "raw_evidence", name)
        for name, value in current.items():
            put("qualified-source/" + name + ".gz", value, "current_source_snapshot", name)
        for key, value in blobs.items():
            put("source-blobs/" + key + ".gz", value, "scientific_source_blob", key)
        for name, value in (("scientific-provenance.json", science), ("summary.json", summary)):
            payload = json_bytes(value)
            (stage / name).write_bytes(payload)
            manifest.append(dict(kind="derived_metadata", origin=name, artifact=name,
                encoding="identity", raw_bytes=len(payload), raw_sha256=sha(payload)))
        for row in manifest:
            payload = (stage / row["artifact"]).read_bytes()
            if row["encoding"] == "gzip":
                if sha(payload) != row["compressed_sha256"]:
                    raise ValueError("Written gzip bytes differ")
                payload = gzip.decompress(payload)
            if len(payload) != row["raw_bytes"] or sha(payload) != row["raw_sha256"]:
                raise ValueError("Lossless round-trip differs")
        (stage / "manifest.json").write_bytes(json_bytes(sorted(manifest, key=lambda r: r["artifact"])))
        if raw != inventory(SOURCE) or current != source_inputs():
            raise RuntimeError("Frozen evidence/source changed while archiving")
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
        raise FileExistsError(DEST)
    raw = inventory(SOURCE)
    parsed = shared.documents(raw)
    summary, screens = summarize(parsed, raw)
    current = source_inputs()
    backend = summary["run_scope"].get("backend_sha256")
    if backend is not None and sha(current["benchmark/native_downstream/persistent_tight_program.jl"]) != backend:
        raise ValueError("Declared final backend source differs from the captured current source")
    science, blobs = scientific_sources(screens, raw, current)
    summary["core_base"] = core_base_check(summary["run_scope"], current)
    summary["forcing"] = forcing_source(summary["run_scope"], raw)
    if raw != inventory(SOURCE) or current != source_inputs():
        raise RuntimeError("Evidence/source changed during validation; retry after freeze")
    if args.archive_frozen:
        archive(raw, current, science, blobs, summary)
    print(json.dumps(dict(archived=bool(args.archive_frozen), raw_files=len(raw), source_files=len(current),
        scientific_source_blobs=len(blobs), qualified_warm_screens=len(summary["qualified_warm_screens"]),
        unqualified_final_screens=len(summary["unqualified_declared_final_screens"]),
        excluded_diagnostic_screens=len(summary["excluded_diagnostic_screens"]),
        final_gates=len(summary["final_gates"]),
        core_base_verified=summary["core_base"]["verified"],
        forcing_copy_captured=summary["forcing"]["captured"],
        lossless_roundtrip_verified=bool(args.archive_frozen)), sort_keys=True))


if __name__ == "__main__":
    main()
