"""Validate the cached-proof/cold-owner factorial screen without starting Julia.

The default and --check-only modes print a derived summary. --archive-frozen
creates a new immutable evidence directory only after all declared source,
correctness, forcing, CPU and seven-arm checks pass. No older result directory
is read as a numerical baseline and an existing archive is never replaced.
"""

from pathlib import Path
import argparse
import gzip
import json
import math
import re
import statistics
import tempfile

import summarize_persistent_program as old

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "benchmark/native_downstream/results/cached-proofs-owner-reuse"
DEST = Path(__file__).resolve().parent / "evidence/cached-proofs-owner-reuse"
shared = old.shared
shared.SOURCE = SOURCE
sha, canonical, json_bytes = old.sha, old.canonical, old.json_bytes
inventory, number, ratio = old.inventory, old.number, old.ratio
PROTOCOL = "cached_declaration_proofs_cold_owners_small_screen_v1"
ARMS = ("ordinary_a", "ordinary_b", "preparation_only", "persistent", "proof_only", "owner_only", "combined")
PHASES = old.PHASES
COSTS = ("seconds", "allocated_bytes", "gc_seconds", "compilation_seconds", "recompilation_seconds")
REFERENCES = ("ordinary_a", "preparation_only", "persistent")
PROOF_COUNTS = ("hits", "positive_hits", "negative_hits", "misses", "effects_queries",
    "return_type_queries", "compiler_queries", "world_invalidations", "capacity_resets",
    "invalidated_entries", "world_race_retries")
OWNER_COUNTS = ("cold_syncs", "node_headers_restored", "edge_headers_restored",
    "child_caches_materialized", "root_owners_retained", "root_owner_identity_checks",
    "shared_fallback_materializations")


def source_inputs():
    current = old.source_inputs()
    # Include all Python validators whose code determines the derived evidence.
    for path in (Path(__file__).resolve(), Path(old.__file__).resolve(), Path(shared.__file__).resolve()):
        current[path.relative_to(ROOT).as_posix()] = path.read_bytes()
    return dict(sorted(current.items()))


def policy(arm):
    if arm not in ARMS:
        raise ValueError(f"Unknown factorial arm: {arm}")
    return dict(preparation=arm not in ("ordinary_a", "ordinary_b"),
        typed=arm not in ("ordinary_a", "ordinary_b", "preparation_only"),
        proof=arm in ("proof_only", "combined"), owner=arm in ("owner_only", "combined"))


def proof_checks(before, after, enabled, *, primed):
    if not enabled:
        if before is not None or after is not None:
            raise ValueError("Disabled proof arm acquired cache snapshots")
        return None
    if not isinstance(before, dict) or not isinstance(after, dict):
        raise ValueError("Proof arm lacks explicit before/after cache counters")
    for report in (before, after):
        if report["policy"] != "strict_type_effect_proofs_per_function_type_world" or \
                report["stores_scientific_values"] is not False or report["live_declaration_calls"] != 0:
            raise ValueError("Cache proof/value boundary differs from the strict experiment")
        for key in (*PROOF_COUNTS, "world", "current_world", "entries", "capacity"):
            number(report[key], integer=True)
        if report["capacity"] <= 0 or report["entries"] > report["capacity"] or \
                report["hits"] != report["positive_hits"] + report["negative_hits"] or \
                report["compiler_queries"] != report["effects_queries"] + report["return_type_queries"] or \
                report["misses"] != report["effects_queries"] or \
                report["effects_queries"] != report["return_type_queries"]:
            raise ValueError("Cache counters do not describe completed bounded proof queries")
    if before["capacity"] != after["capacity"]:
        raise ValueError("Cache capacity changed inside the measured scene")
    delta = {key: number(after[key] - before[key], integer=True) for key in PROOF_COUNTS}
    if primed and (delta["hits"] <= 0 or delta["positive_hits"] <= 0):
        raise ValueError("Proof arm recorded no actual reused positive admission proofs")
    if primed and (delta["compiler_queries"] or delta["world_invalidations"] or delta["world_race_retries"] or
            len({before["world"], before["current_world"], after["world"], after["current_world"]}) != 1):
        raise ValueError("Primed warm scene queried the compiler or changed proof worlds")
    return dict(delta=delta, entries_before=before["entries"], entries_after=after["entries"],
        capacity=after["capacity"], world_before=before["world"], world_after=after["world"],
        primed_by_untimed_warmup=primed, cached_scientific_values=False)


def coverage_checks(c, arm, kind, work, *, primed):
    expected = policy(arm)
    if c["arm"] != arm or c["policy"] != expected or c["scope"] != \
            "original_scientific_models_and_ordinary_reference_storage" or \
            c["driver_units_kind"] != "actual_selected_batch_entries_not_prepared_or_inferred_work":
        raise ValueError("Factorial policy, storage, or actual-work interpretation differs")
    if c["native_fields"] != 0 or c["native_driver_units"] != 0:
        raise ValueError("Factorial screen unexpectedly entered native column storage")
    number(c["driver_units"], integer=True)
    bounded, graph, typed = c["bounded"], c["graph"], c["typed_output_preparation"]
    if bounded["enabled"] is not expected["preparation"] or graph["enabled"] is not expected["preparation"] or \
            typed["enabled"] is not expected["preparation"] or \
            (bounded["scene_entries"] > 0) is not expected["preparation"]:
        raise ValueError("Preparation factors leaked into a control or did no actual work")
    if any(bounded[key] is not False for key in
            ("cached_memberships", "cached_sampled_environments", "copied_scientific_values")) or \
            any(typed[key] is not False for key in ("cached_defaults", "cached_memberships", "copied_scientific_values")):
        raise ValueError("Preparation cached live defaults, membership, environments, or science")
    gc, tc = graph["counters"], typed["counters"]
    for counts in (gc, tc):
        for value in counts.values():
            number(value, integer=True)
    if tc["applications_completed"] != tc["initial_applications_completed"] + tc["growth_applications_completed"] or \
            tc["objects_prepared"] != tc["initial_objects_prepared"] + tc["growth_objects_prepared"]:
        raise ValueError("Initial/growth preparation partitions differ")
    if expected["preparation"]:
        if not all(value > 0 for value in (gc["projections_completed"], gc["rows_projected"],
                tc["applications_completed"], tc["objects_prepared"])):
            raise ValueError("Preparation arm has no actual projected rows/object completion")
    elif any(gc.values()) or any(tc.values()):
        raise ValueError("Disabled preparation control contains completed work")
    if kind == "pb" and (tc["growth_applications_completed"] or tc["growth_objects_prepared"]):
        raise ValueError("PB falsely credited organ-growth preparation")
    proof = proof_checks(c["declaration_proofs_before"], c["declaration_proofs_after"],
        expected["proof"], primed=primed)
    program = c["typed_program"]
    if not expected["typed"]:
        if program is not None or c["driver_units"]:
            raise ValueError("Ordinary/preparation control entered a custom numerical program")
        return dict(driver_entries=0, proof=None, owners=None)
    if not isinstance(program, dict) or program["batch_executions"] != c["driver_units"] or c["driver_units"] <= 0:
        raise ValueError("Typed arm contains no actual selected numerical batch entries")
    for key in old.PROGRAM_COUNTS:
        number(program[key], integer=True)
    if program["canonical_storage"] != "ordinary_references" or program["scientific_values_copied"] is not False or \
            program["initial_lowering"] != "additional_to_ordinary_zero_step_preparation" or \
            program["performance_fallback"] is not False:
        raise ValueError("Numerical storage/lowering/performance scope differs")
    if program["live_active_regions"] > program["live_regions"] or \
            program["regions_reused"] != program["metadata_rebases"]:
        raise ValueError("Live-region/rebase accounting differs")
    for key in ("executed_numerical_roots", "executed_numerical_calls"):
        if program["actual_numerical_id_trace"]:
            number(program[key], integer=True)
        elif program[key] is not None:
            raise ValueError("Disabled numerical tracing presented inferred root/call counts")
    if kind == "xp" and work["added_ids"] and program["refreshes"] <= 0:
        raise ValueError("Growing XP typed run contains no actual refresh")
    owner = None
    if expected["owner"]:
        if program["qualification"] != "cold_owner_candidate" or \
                program["numerical_executor"] != "original_Selected_rows_and_Tight_noinline_child" or \
                program["retirement_policy"] != "tracked_metadata_replayed_into_original_cold_owners" or \
                program["reuse_policy"] != "stable_wrapper_and_numerical_columns_with_original_owner_tree" or \
                program["retains_ordinary_owner_tree"] is not True or \
                program["proof_cache_enabled"] is not expected["proof"]:
            raise ValueError("Cold-owner retention/executor/proof factor differs")
        owner = {key: number(program[key], integer=True) for key in OWNER_COUNTS}
        if owner["shared_fallback_materializations"] != 0 or \
                owner["root_owners_retained"] <= 0 or \
                owner["root_owners_retained"] != owner["root_owner_identity_checks"]:
            raise ValueError("Owner arm rebuilt Shared fallback owners or lacks identity-checked retained owners")
        if kind == "xp" and work["added_ids"] and not all(owner[key] > 0 for key in ("cold_syncs", "node_headers_restored")):
            raise ValueError("Growing owner arm contains no actual cold-owner synchronization")
    elif program["qualification"] != "persistent_candidate" or \
            program["numerical_executor"] != "original_Tight_noinline_child":
        raise ValueError("Persistent control acquired an owner-specific executor")
    return dict(driver_entries=program["batch_executions"], refreshes=program["refreshes"],
        reused=program["regions_reused"], readmitted=program["regions_readmitted"],
        ordinary_fallbacks=program["ordinary_fallbacks"],
        numerical_roots=program["executed_numerical_roots"], numerical_calls=program["executed_numerical_calls"],
        proof=proof, owners=owner)


def _retained(row):
    retained = row.get("retained")
    if retained is None:
        return None
    if retained["meaning"] != "reachable_object_size_not_RSS_or_cumulative_allocations":
        raise ValueError("Reachable object bytes presented as peak RSS/exclusive storage")
    for key in ("simulation_bytes", "simulation_program_fixture_bytes"):
        number(retained[key], integer=True)
    return dict(cycle=row["cycle"], **retained, timing_scope="after_all_phase_clocks")


def screen_summary(screen):
    config = screen["config"]
    if config.get("protocol") != PROTOCOL or screen["baseline"] != "ordinary_a" or \
            config.get("interpretation") != "warm_fresh_scene_with_charged_ordinary_plan_then_typed_installation" or \
            config.get("statistical_unit") != "one_independent_scene" or config.get("storage") != "ordinary_references" or \
            config.get("proof_cache_temperature") != "primed_by_untimed_per_arm_warmup_not_disk_or_process_cold":
        raise ValueError("Unsupported factorial protocol or uncharged lowering/cache scope")
    kind = config["kind"]
    if kind not in ("pb", "xp"):
        raise ValueError("Only original PB/XP scientific fixtures belong to this screen")
    warmups, samples, orders = screen["warmups"], screen["samples"], screen["orders"]
    repetitions = number(screen["repetitions"], integer=True)
    if repetitions < 1 or len(orders) != repetitions or len(warmups) != len(ARMS) or \
            {row["variant"] for row in warmups} != set(ARMS):
        raise ValueError("Missing seven-arm warmups or statistical cycles")
    first_order = [row["variant"] for row in samples if row["cycle"] == 1]
    if len(first_order) != len(ARMS) or set(first_order) != set(ARMS):
        raise ValueError("Missing first-cycle factorial arms")
    for cycle, order in enumerate(orders, 1):
        expected = first_order if cycle % 2 else list(reversed(first_order))
        if order != expected or [row["variant"] for row in samples if row["cycle"] == cycle] != expected:
            raise ValueError("Samples do not follow alternating balanced cycle order")
    if len(samples) != repetitions * len(ARMS) or {row["cycle"] for row in samples} != set(range(1, repetitions + 1)):
        raise ValueError("Missing or additional statistical scene sample")
    reference = next(row for row in warmups if row["variant"] == "ordinary_a")
    snapshot, work = canonical(reference["snapshot"]), canonical(reference["work"])
    if set(reference["snapshot"]) != {"state", "rng"} or reference["work"]["steps"] != config["steps"] or \
            reference["snapshot"]["state"]["scientific"]["step"] != config["steps"] or \
            len(reference["snapshot"]["state"]["topology"]) != reference["work"]["objects"]:
        raise ValueError("Scientific state/history/RNG/steps/topology snapshot is incomplete")
    mechanisms, warmup_mechanisms = [], []
    for row in warmups + samples:
        if row["case"] != screen["case"] or canonical(row["config"]) != canonical(config) or \
                row["process_id"] != screen["provenance"]["process_id"] or \
                row["digest"] != screen["expected_digest"] or canonical(row["snapshot"]) != snapshot or \
                canonical(row["work"]) != work:
            raise ValueError("Exact state/history/RNG/work/configuration/PID parity differs")
        if set(row["phases"]) != set(PHASES):
            raise ValueError("Construction/preparation/lowering/execution phase missing")
        shared.validate_phase_sums(row)
        for phase in row["phases"].values():
            for key in COSTS:
                number(phase[key], integer=key == "allocated_bytes")
        if not math.isclose(sum(p["gc_seconds"] for p in row["phases"].values()), row["complete_gc_seconds"], abs_tol=1e-12):
            raise ValueError("Complete GC cost differs from phase sum")
        measured = "cycle" in row
        completed = coverage_checks(row["coverage"], row["variant"], kind, row["work"], primed=measured)
        destination = mechanisms if measured else warmup_mechanisms
        destination.append(dict(cycle=row.get("cycle"), arm=row["variant"], **completed))
    controls = {arm: {row["cycle"]: row for row in samples if row["variant"] == arm} for arm in REFERENCES}
    reports = []
    for arm in first_order:
        rows = [row for row in samples if row["variant"] == arm]
        paired = {}
        for baseline in REFERENCES:
            ratios = []
            for row in rows:
                control = controls[baseline][row["cycle"]]
                phases = {name: {key: ratio(row["phases"][name][key], control["phases"][name][key])
                    for key in ("seconds", "allocated_bytes")} for name in PHASES}
                ratios.append(dict(cycle=row["cycle"], phases=phases,
                    complete_seconds=ratio(row["complete_seconds"], control["complete_seconds"]),
                    complete_allocated_bytes=ratio(row["complete_allocated_bytes"], control["complete_allocated_bytes"])))
            paired[baseline] = dict(cycles=ratios,
                execution_ratio=statistics.median(r["phases"]["execution"]["seconds"] for r in ratios),
                lowering_ratio=statistics.median(r["phases"]["backend_lowering"]["seconds"] for r in ratios),
                complete_ratio=statistics.median(r["complete_seconds"] for r in ratios))
        phase_medians = {name: {key: statistics.median(row["phases"][name][key] for row in rows)
            for key in COSTS} for name in PHASES}
        complete_medians = {key: statistics.median(sum(row["phases"][phase][key] for phase in PHASES)
            for row in rows) for key in COSTS}
        jit = [dict(cycle=row["cycle"], phase=name, compilation_seconds=p["compilation_seconds"],
            recompilation_seconds=p["recompilation_seconds"]) for row in rows for name, p in row["phases"].items()
            if p["compilation_seconds"] or p["recompilation_seconds"]]
        reports.append(dict(arm=arm, samples=len(rows), phase_medians=phase_medians,
            complete_medians=complete_medians, paired=paired, jit_events=jit,
            actual_work=[r for r in mechanisms if r["arm"] == arm],
            reachable_memory_after_clocks=[r for r in (_retained(row) for row in rows) if r is not None]))
    return dict(kind=kind, case=screen["case"], config=config, cycles=repetitions,
        digest=screen["expected_digest"], snapshot_sha256=sha(snapshot), work=reference["work"],
        sample_cohort_sha256=sha(canonical(samples)), source_epoch=shared.source_epoch(screen),
        arms=reports, warmup_mechanisms=warmup_mechanisms,
        ordinary_A_A=next(row for row in reports if row["arm"] == "ordinary_b"),
        interpretation="small_warm_fresh_scene_factorial_screen_not_robust_or_cold_speedup_evidence",
        cold_compilation_claim=False, peak_RSS_claim=False)


def strict_qualification(parsed, raw):
    bindings = shared.qualification_bindings(parsed, raw)
    rows = parsed.get("qualification.json", {}).get("artifacts", [])
    for row in rows:
        artifact = row["artifact"]
        record = parsed[row["cpu_record"]]
        health = record.get("sampler_health", {})
        if row.get("qualified") is not True or row.get("failure") is not None or \
                row.get("source_and_forcing_unchanged") is not True:
            raise ValueError("Qualified screen lacks successful source/forcing/whole-RPC assertion")
        if health.get("healthy") is not True or health.get("sampler_errors") != [] or \
                not all(health.get(key) is True for key in
                    ("initial_and_final_samples_required", "thread_entered", "thread_exited", "thread_stopped")):
            raise ValueError("CPU sampler health/initial/final/thread checks failed")
        observed = number(health["maximum_observed_gap_seconds"])
        allowed = number(health["allowed_maximum_gap_seconds"])
        if allowed <= 0 or observed > allowed or health["observations"] != len(record["observations"]):
            raise ValueError("CPU sample count or maximum sample gap differs")
        if set(bindings[artifact]["optional_evidence"]) != {"script", "receipt"}:
            raise ValueError("Qualified screen lacks exact script/completion receipt bindings")
        receipt_name = bindings[artifact]["optional_evidence"]["receipt"]
        receipt = parsed[receipt_name]
        response = receipt.get("response", {})
        result = response.get("result", {})
        text = "\n".join(item.get("text", "") for item in result.get("content", []) if item.get("type") == "text")
        if receipt.get("tool") not in ("ex", "check_eval") or "error" in response or result.get("isError") is True or \
                result.get("status") in ("running", "failed", "cancelled", "canceled", "interrupted") or \
                "promoted to background" in text.lower() or \
                re.search(r"(?mi)^\s*(?:ERROR:|failed\s*[,\n]|running\s*[,\n]|cancelled\s*[,\n]|canceled\s*[,\n])", text):
            raise ValueError("Final hash-bound Kaimon receipt does not attest completed successful execution")
    return bindings


def summarize(parsed, raw):
    scope = parsed.get("run-scope.json", {})
    bindings = strict_qualification(parsed, raw)
    candidates = {name: value for name, value in parsed.items() if "/" not in name and name.endswith("-screen.json")}
    declared = scope.get("final_screens", sorted(candidates))
    if len(declared) != len(set(declared)) or not set(declared) <= set(candidates):
        raise ValueError("Missing or duplicate declared final screen")
    qualified, excluded, selected = [], [], {}
    for name in declared:
        result = dict(source=name, cpu=shared.cpu_qualification(name, bindings), **screen_summary(candidates[name]))
        if result["cpu"]["qualified"]:
            qualified.append(result)
            selected[name] = candidates[name]
        else:
            excluded.append(result)
    if qualified and len({row["source_epoch"]["sha256"] for row in qualified}) != 1:
        raise ValueError("Qualified factorial screens mix source cohorts")
    worker = scope.get("worker", {}).get("pid")
    if worker is not None and any(row["source_epoch"]["process_id"] != worker for row in qualified):
        raise ValueError("Qualified screen differs from declared Kaimon worker PID")
    declared_exclusions = {row["artifact"]: row["reason"] for row in scope.get("excluded_screens", [])}
    if len(declared_exclusions) != len(scope.get("excluded_screens", [])):
        raise ValueError("Duplicate diagnostic exclusion declaration")
    diagnostics = []
    for row in parsed.get("qualification.json", {}).get("excluded_artifacts", []):
        name, cpu_name = row["artifact"], row["cpu_record"]
        if name in declared or name in bindings or name not in declared_exclusions:
            raise ValueError("Diagnostic exclusion overlaps final timing or lacks a declared reason")
        for path, expected in ((name, row["artifact_sha256"]), (cpu_name, row["cpu_sha256"])):
            if path not in raw or sha(raw[path]) != expected:
                raise ValueError("Stale diagnostic artifact/CPU binding")
        if row.get("qualified") is not False or parsed[cpu_name].get("qualified") is not False:
            raise ValueError("Diagnostic exclusion is represented as timing-qualified")
        optional = {kind: shared.bound_raw(row[kind], raw) for kind in ("script", "receipt")}
        diagnostics.append(dict(source=name, raw_sha256=row["artifact_sha256"],
            cpu_record=cpu_name, cpu_sha256=row["cpu_sha256"], optional_evidence=optional,
            reason=declared_exclusions[name], timing_qualified=False,
            interpretation="raw_diagnostic_only_no_derived_timing_ratios_or_speedup_claim"))
    if {row["source"] for row in diagnostics} != set(declared_exclusions) or len(diagnostics) != len(declared_exclusions):
        raise ValueError("Declared diagnostics lack unique exact qualification bindings")
    gates = []
    for name in scope.get("final_gates", []):
        if name not in parsed or "/" in name or not isinstance(parsed[name], dict):
            raise ValueError("Missing declared final correctness artifact")
        passed = [v["passed"] for _, v in shared.walk(parsed[name]) if "passed" in v]
        if not passed or any(value is not True for value in passed):
            raise ValueError("Declared final gate contains absent or failed assertions")
        gates.append(dict(source=name, sha256=sha(raw[name]), passed=True))
    return dict(protocol=PROTOCOL, run_scope=scope, qualified_warm_screens=qualified,
        unqualified_declared_final_screens=excluded, excluded_diagnostic_screens=diagnostics, final_gates=gates,
        diagnostic_or_historical_raw=[name for name in sorted(raw) if name not in set(declared) | {r["source"] for r in gates}],
        old_results_used_as_baselines=False, cold_claim=False,
        limitations=["A few balanced cycles screen candidates; they do not establish a robust speedup.",
            "Every typed installation is charged after ordinary zero-step preparation.",
            "Warm shared proof caches are populated by untimed per-arm warmup; they are not process-cold evidence.",
            "Ordinary owner retention may trade allocations for retained memory.",
            "Reachable object size is collected outside phase clocks and is not exclusive storage or RSS.",
            "No million-organ, broad feature-matrix, cold-compilation, or peak-RSS claim follows."]), selected


def source_guard(scope, parsed, raw, current):
    declared = scope.get("source_guard_artifact", "screen-source-image.json")
    if declared not in parsed:
        return dict(verified=False, reason="no_source_guard_image")
    image = parsed[declared]
    if set(image) != {"PSE", "PlantBiophysics", "XPalm", "forcing_sha256"}:
        raise ValueError("Unexpected source/forcing guard image")
    package_roots = dict(PSE=ROOT, PlantBiophysics=Path("/Users/rvezy/Documents/dev/PlantBiophysics"),
        XPalm=Path("/Users/rvezy/Documents/dev/XPalm"))
    count = 0
    for package, root in package_roots.items():
        for name, expected in image[package].items():
            path = Path(name)
            if path.is_absolute() or ".." in path.parts or not re.fullmatch(r"[0-9a-f]{64}", expected):
                raise ValueError("Unsafe source-guard path/hash")
            target = root / path
            if target.is_symlink() or not target.is_file() or sha(target.read_bytes()) != expected:
                raise ValueError(f"Current source differs from screen guard: {package}:{name}")
            if package == "PSE" and name in current and sha(current[name]) != expected:
                raise ValueError("Captured/current PSE source differs from source guard")
            count += 1
    if image["forcing_sha256"] != scope.get("forcing", {}).get("sha256"):
        raise ValueError("Forcing source guard differs from declared scientific forcing")
    return dict(verified=True, artifact=declared, sha256=sha(raw[declared]), files=count,
        interpretation="controller_before_after_assertion_plus_current_exact_hash_revalidation")


def archive(raw, current, science, blobs, summary):
    if DEST.exists():
        raise FileExistsError("Refusing immutable archive overwrite")
    if summary["run_scope"].get("frozen") is not True or not summary["core_base"]["verified"] or \
            not summary["source_guard"]["verified"] or not summary["final_gates"] or \
            not summary["forcing"]["captured"] or summary["unqualified_declared_final_screens"] or \
            {row["kind"] for row in summary["qualified_warm_screens"]} != {"pb", "xp"}:
        raise ValueError("Archive requires frozen sources, final gates, forcing, and qualified PB/XP factorial screens")
    DEST.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".cached-proofs-owner-reuse-", dir=DEST.parent) as temporary:
        stage = Path(temporary) / "cached-proofs-owner-reuse"
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
                    raise ValueError("Written gzip checksum differs")
                payload = gzip.decompress(payload)
            if len(payload) != row["raw_bytes"] or sha(payload) != row["raw_sha256"]:
                raise ValueError("Lossless archive round-trip differs")
        (stage / "manifest.json").write_bytes(json_bytes(sorted(manifest, key=lambda row: row["artifact"])))
        if raw != inventory(SOURCE) or current != source_inputs():
            raise RuntimeError("Frozen source/evidence changed while archiving")
        if DEST.exists():
            raise FileExistsError(DEST)
        stage.rename(DEST)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check-only", action="store_true")
    mode.add_argument("--archive-frozen", action="store_true")
    args = parser.parse_args()
    if args.archive_frozen and DEST.exists():
        raise FileExistsError(DEST)
    raw = inventory(SOURCE)
    parsed = shared.documents(raw)
    summary, screens = summarize(parsed, raw)
    current = source_inputs()
    for name, expected in summary["run_scope"].get("backend_sha256s", {}).items():
        if name not in current or sha(current[name]) != expected:
            raise ValueError(f"Declared final backend differs from captured current source: {name}")
    science, blobs = old.scientific_sources(screens, raw, current)
    summary["core_base"] = old.core_base_check(summary["run_scope"], current)
    summary["forcing"] = old.forcing_source(summary["run_scope"], raw) if \
        "raw_artifact" in summary["run_scope"].get("forcing", {}) else \
        dict(captured=False, reason="controller_has_not_supplied_forcing_copy")
    summary["source_guard"] = source_guard(summary["run_scope"], parsed, raw, current)
    if raw != inventory(SOURCE) or current != source_inputs():
        raise RuntimeError("Source/evidence changed during validation; retry after freeze")
    if args.archive_frozen:
        archive(raw, current, science, blobs, summary)
    print(json.dumps(dict(archived=bool(args.archive_frozen), raw_files=len(raw), source_files=len(current),
        scientific_source_blobs=len(blobs), summary=summary), sort_keys=True, indent=2))


if __name__ == "__main__":
    main()
