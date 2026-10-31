"""Validate and immutably archive ordinary XP dispatch/refresh comparisons.

Source-only Python: never starts Julia. Only xp_ordinary_dispatch_refresh_v1
samples from this round can become timing evidence. The two ordinary labels
must disable bounded metadata, graph, binding and lookup policies. Bounded+graph
is a separate positive anchor. Preserve failed/idle-worker receipts and exact
source bytes; promote timing only through explicit hash-bound CPU qualification.
"""
from pathlib import Path
import argparse
import gzip
import json
import math
import statistics
import tempfile

# These prior scripts are immutable validation primitives, not timing baselines.
# Both script sources are captured in this archive's source closure.
import summarize_xp_attribution as prior

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "benchmark/native_downstream/results/xp-dispatch-refresh"
DEST = Path(__file__).resolve().parent / "evidence/xp-dispatch-refresh"
prior.shared.SOURCE = SOURCE
sha, canonical, json_bytes = prior.sha, prior.canonical, prior.json_bytes
compact, walk = prior.compact, prior.walk
PROTOCOL = "xp_ordinary_dispatch_refresh_v1"
ARMS = ("ordinary_a", "ordinary_b", "bounded_graph", "trusted_index", "typed_barrier",
    "trusted_barrier", "trusted_barrier_graph", "typed_graph", "trusted_graph")


def inventory(folder):
    result = {}
    for path in sorted(folder.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Symlink evidence input is unsupported: {path}")
        if path.is_file():
            result[path.relative_to(folder).as_posix()] = path.read_bytes()
    return result


def policies(arm):
    if arm not in ARMS:
        raise ValueError(f"Unknown ordinary XP arm: {arm}")
    graph = arm in ("bounded_graph", "trusted_barrier_graph", "typed_graph", "trusted_graph")
    trusted = arm in ("trusted_index", "trusted_barrier", "trusted_barrier_graph", "trusted_graph")
    return dict(bounded=graph, graph=graph, trusted_index=trusted,
        typed_output_preparation=arm in ("typed_barrier", "trusted_barrier", "trusted_barrier_graph", "typed_graph"),
        underlying_arm="bounded_preparation" if graph else "reference_executor",
        numerical_executor="ordinary", binding_program="disabled",
        previous_epoch_lookup="conservative_fallback_only" if trusted else "disabled")


def typed_counts(report, enabled, *, growth=True):
    c = report["counters"]
    prior.nonnegative(c)
    if report["enabled"] is not enabled:
        raise ValueError("Typed output policy/control contamination")
    if c["applications_completed"] != c["initial_applications_completed"] + c["growth_applications_completed"] or \
            c["objects_prepared"] != c["initial_objects_prepared"] + c["growth_objects_prepared"]:
        raise ValueError("Typed output initial/growth partitions disagree")
    if c["application_attempts"] < c["applications_completed"] + c["declines"] or \
            c["defaults_added"] > c["canonical_ports_visited"]:
        raise ValueError("Typed completed work exceeds actual attempts/visits")
    if enabled:
        if c["applications_completed"] <= 0 or c["objects_prepared"] <= 0:
            raise ValueError("Typed path completed no actual object preparation")
        if growth and (c["growth_applications_completed"] <= 0 or c["growth_objects_prepared"] <= 0):
            raise ValueError("Typed path has no actual growth-phase object preparation")
    elif any(c.values()):
        raise ValueError("Typed counters contaminated ordinary control")
    if any(report[key] is not False for key in ("cached_defaults", "cached_memberships", "copied_scientific_values")):
        raise ValueError("Typed barrier unexpectedly cached scientific state/defaults/membership")
    if report.get("growth_definition") != "after_initial_binding_cache_publication_not_unique_newborn_objects":
        raise ValueError("Typed growth counts misrepresented as unique newborns")
    return c


def trusted_counts(report, enabled, *, growth=True):
    c = report["counters"]
    fallback = report["fallback_epoch"]
    e, v = fallback["counters"], fallback["v1"]["counters"]
    for namespace in (c, e, v):
        prior.nonnegative(namespace)
    if report["enabled"] is not enabled or fallback["enabled"] is not enabled or \
            fallback["v1"]["enabled"] is not enabled:
        raise ValueError("Trusted/fallback policy contamination")
    if c["refresh_attempts"] != c["certificate_hits"] + c["certificate_misses"]:
        raise ValueError("Trusted certificate hit/miss partition disagrees")
    if c["lookup_attempts"] != c["trusted_group_hits"] + c["trusted_empty_returns"] + c["fallback_queries"]:
        raise ValueError("Trusted query hit/empty/fallback partition disagrees")
    if c["construction_begins"] < c["indices_certified"] + c["indices_rejected"] or \
            c["fallback_lookups_created"] > c["fallback_queries"]:
        raise ValueError("Trusted proof/fallback completions exceed actual attempts")
    if e["epoch_attempts"] != e["epochs_validated"] + e["epochs_rejected"] or \
            v["lookups"] != v["slot_hits"] + v["slot_misses"] + e["trusted_empty_returns"] or \
            v["slot_misses"] != sum(v[k] for k in
                ("absent_slot_misses", "out_of_range_misses", "identity_misses")):
        raise ValueError("Conservative fallback partitions disagree")
    if not e["query_fallbacks"] == v["slot_misses"] == v["dictionary_lookups"] or \
            v["dictionaries_built"] > v["refresh_lookups_created"] or \
            fallback["dictionary_builds_avoided"] != v["refresh_lookups_created"] - v["dictionaries_built"]:
        raise ValueError("Conservative ID dictionary fallback accounting disagrees")
    if c["fallback_queries"] != v["lookups"] or c["fallback_lookups_created"] != e["epoch_attempts"]:
        raise ValueError("Trusted fallback calls disagree with embedded epoch namespace")
    if enabled and growth:
        if not all(c[key] > 0 for key in
                ("indices_certified", "certificate_hits", "trusted_group_hits", "trusted_empty_returns")):
            raise ValueError("Trusted candidate has no OWN certified group/empty growth work")
    if not enabled and (any(c.values()) or any(e.values()) or any(v.values())):
        raise ValueError("Trusted/old lookup counters contaminated ordinary control")
    if report.get("cached_memberships") is not False or report.get("cached_scientific_values") is not False:
        raise ValueError("Trusted index unexpectedly caches scientific values/memberships")
    return c, e, v


def instance_coverage(coverage, work, config, arm):
    p = policies(arm)
    if coverage.get("dispatch_arm") != arm or coverage.get("dispatch_policies") != p or \
            coverage.get("measurement_protocol") != PROTOCOL:
        raise ValueError("Per-instance dispatch policy/protocol differs from case")
    # This proves base and NBS are disabled without claiming any old instruction
    # optimization. Underlying arm determines only ordinary/bounded metadata.
    prior.original_sequence_coverage(coverage, work, config, newborn=False)
    if coverage["sequence_policies"] != dict(mechanism="ordinary", bounded=p["bounded"],
            typed=False, underlying_arm=p["underlying_arm"]):
        raise ValueError("Numerical driver/binding policy contaminated ordinary executor")
    if any(coverage[key] for key in ("native_fields", "driver_units", "native_driver_units")):
        raise ValueError("Ordinary-executor experiment entered an alternate numerical driver")
    g = coverage["graph_projection"]["counters"]
    prior.nonnegative(g)
    if coverage["graph_projection"]["enabled"] is not p["graph"]:
        raise ValueError("Graph policy differs from arm")
    if p["graph"]:
        if g["projections_completed"] <= 0 or g["rows_projected"] <= 0:
            raise ValueError("Graph anchor completed no actual returned table/rows")
    elif any(g.values()):
        raise ValueError("Graph counters contaminated an ordinary arm")
    t = typed_counts(coverage["typed_output_preparation"], p["typed_output_preparation"])
    u, e, v = trusted_counts(coverage["trusted_execution_index"], p["trusted_index"])
    aliases = dict(actual_graph={key: g[key] for key in
        ("projections_completed", "rows_projected", "edges_projected")},
        actual_typed_output=t, actual_trusted_index=u,
        actual_trusted_fallback_epoch=e, actual_trusted_fallback_queries=v)
    if any(coverage[key] != value for key, value in aliases.items()):
        raise ValueError("Public actual-work aliases differ from source namespaces")
    if coverage.get("metadata_work_is_not_kernel_work") is not True or \
            coverage.get("ordinary_baseline") is not (arm in ("ordinary_a", "ordinary_b")) or \
            coverage.get("baseline_scope") != "ordinary_reference_executor_without_bounded_or_other_candidates":
        raise ValueError("Metadata/baseline interpretation differs")
    return aliases


def scientific_batch(sample, config):
    n, snapshot, work = config["batch_size"], sample["snapshot"], sample["work"]
    if snapshot["batch_size"] != n or len(snapshot["instance_map"]) != n or \
            [row["instance"] for row in snapshot["instance_map"]] != list(range(1, n + 1)):
        raise ValueError("Missing independently observed scientific instance")
    observations = snapshot["full_observations"]
    if not 1 <= len(observations) <= n:
        raise ValueError("No lossless scientific observation payload")
    used = set()
    for row in snapshot["instance_map"]:
        position = row["observation_index"]
        if not 1 <= position <= len(observations) or row["digest"] != observations[position - 1]["digest"]:
            raise ValueError("Scientific observation deduplication map is inconsistent")
        used.add(position)
    if used != set(range(1, len(observations) + 1)):
        raise ValueError("Unused scientific observation payload")
    works = work["instances"]
    if work["batch_size"] != n or len(works) != n or any(row["steps"] != config["steps"] for row in works):
        raise ValueError("Missing independent trajectory work")
    expected = dict(total_simulated_steps=sum(row["steps"] for row in works),
        total_final_objects=sum(row["objects"] for row in works),
        total_added_objects=sum(len(row["added_ids"]) for row in works),
        total_retained_streams=sum(row["streams"] for row in works))
    if any(work[key] != value for key, value in expected.items()):
        raise ValueError("Batch actual scientific work does not sum")
    return works


def batch_coverage(sample, config):
    arm, c = sample["variant"], sample["coverage"]
    p, n = policies(arm), config["batch_size"]
    if c.get("dispatch_arm") != arm or c.get("dispatch_policies") != p or \
            c.get("measurement_protocol") != PROTOCOL or config["dispatch_policies_by_arm"].get(arm) != p:
        raise ValueError("Batch policy/protocol differs from registered arm")
    reports = c["per_instance"]
    if len(reports) != n:
        raise ValueError("Missing actual per-instance work coverage")
    independent = c["independent_instances"]
    if independent["models"] != n or independent.get("cross_instance_statuses_disjoint") is not True or \
            independent.get("cross_instance_canonical_references_disjoint") is not True:
        raise ValueError("No independent-model/status/Ref identity proof")
    works = scientific_batch(sample, config)
    rows = [instance_coverage(report, work, config, arm) for report, work in zip(reports, works)]
    for namespace in rows[0]:
        expected = prior.sum_counters([row[namespace] for row in rows], c[namespace])
        if c[namespace] != expected:
            raise ValueError(f"Omitted or double-counted metadata namespace: {namespace}")
    if any(c[key] != sum(report[key] for report in reports) for key in
            ("native_fields", "driver_units", "native_driver_units")):
        raise ValueError("Numerical work differs from per-instance coverage")
    if c.get("counter_accounting") != "sum_completed_namespace_per_instance_once" or \
            c.get("statistical_unit") != "one_batch_sample" or \
            c.get("metadata_work_is_not_kernel_work") is not True or \
            c.get("ordinary_baseline") is not (arm in ("ordinary_a", "ordinary_b")):
        raise ValueError("Unrecognized completion aggregation/baseline")
    return {key: c[key] for key in rows[0]} | dict(independent_instances=independent)


def warm_summary(screen):
    config, samples, warmups = screen["config"], screen["samples"], screen["warmups"]
    if config.get("measurement_protocol") != PROTOCOL or screen["baseline"] != "ordinary_a":
        raise ValueError("Only current-round ordinary-baseline protocol is accepted")
    expected_scope = dict(statistical_unit="one_batch_sample", numerical_executor="ordinary",
        binding_instructions=False,
        previous_epoch_lookup="disabled_on_controls_conservative_fallback_only_for_trusted",
        execution_scope="advance_each_fresh_prepared_simulation_once",
        complete_cost_scope="construction_enablement_all_preparation_and_batch_execution")
    if any(config.get(key) != value for key, value in expected_scope.items()):
        raise ValueError("Changed ordinary-batch execution/preparation scope")
    if not samples:
        raise ValueError("Empty warm cohort")
    order = screen["orders"][0]
    if len(order) != len(set(order)) or not {"ordinary_a", "ordinary_b", "bounded_graph"} <= set(order):
        raise ValueError("Both ordinary A/A controls and bounded graph anchor required")
    if len(screen["orders"]) != screen["repetitions"] or screen["repetitions"] <= 0 or any(
            row != (order if i % 2 == 0 else order[::-1]) for i, row in enumerate(screen["orders"])):
        raise ValueError("Cycle orders are not balanced forward/reverse")
    if [(row["cycle"], row["variant"]) for row in samples] != [(i + 1, arm)
            for i, cycle in enumerate(screen["orders"]) for arm in cycle]:
        raise ValueError("Sample cycle order differs")
    if sorted(row["variant"] for row in warmups) != sorted(order):
        raise ValueError("Need exactly one fresh warmup per arm")
    if any(row["temperature"] != "warm" for row in samples) or any(
            row["temperature"] != "warmup" for row in warmups):
        raise ValueError("Incorrect sample temperature")
    all_rows = samples + warmups
    if len({row["process_id"] for row in all_rows}) != 1 or \
            samples[0]["process_id"] != screen["provenance"]["process_id"]:
        raise ValueError("One warm source cohort mixes workers")
    for row in all_rows:
        if row["case"] != screen["case"] or canonical(row["config"]) != canonical(config) or \
                row["digest"] != screen["expected_digest"] or \
                canonical(row["snapshot"]) != canonical(samples[0]["snapshot"]) or \
                canonical(row["work"]) != canonical(samples[0]["work"]):
            raise ValueError("Stored science/RNG/history/topology/work/digest/config differs")
        if set(row["phases"]) != {"construction", "pse_preparation", "backend_lowering", "execution"}:
            raise ValueError("Required charged phase missing")
        prior.shared.validate_phase_sums(row)
        for phase in row["phases"].values():
            if any(not isinstance(phase.get(key), (int, float)) or not math.isfinite(phase[key]) or phase[key] < 0
                    for key in ("compilation_seconds", "recompilation_seconds", "gc_seconds")):
                raise ValueError("Missing/invalid measured JIT/GC counter")
        if not math.isclose(sum(phase["gc_seconds"] for phase in row["phases"].values()),
                row["complete_gc_seconds"], rel_tol=1e-12, abs_tol=1e-12):
            raise ValueError("Complete GC differs from charged phase sum")
        batch_coverage(row, config)
    indexed = {(row["cycle"], row["variant"]): row for row in samples}
    comparisons = []
    for control in order:
        for arm in order:
            if arm == control:
                continue
            paired = []
            for cycle in range(1, screen["repetitions"] + 1):
                a, b = indexed[cycle, arm], indexed[cycle, control]
                ratios = {phase: a["phases"][phase]["seconds"] / b["phases"][phase]["seconds"]
                    for phase in ("execution", "pse_preparation")}
                ratios["complete"] = a["complete_seconds"] / b["complete_seconds"]
                paired.append(dict(cycle=cycle, **ratios))
            comparisons.append(dict(variant=arm, control=control, cycle_ratios=paired,
                medians={key: statistics.median(row[key] for row in paired) for key in ratios},
                ranges={key: [min(row[key] for row in paired), max(row[key] for row in paired)] for key in ratios},
                wins={key: sum(row[key] < 1 for row in paired) for key in ratios}))
    rows = []
    for arm in order:
        selected = [row for row in samples if row["variant"] == arm]
        rows.append(dict(variant=arm, samples=len(selected),
            phases={phase: dict(seconds=statistics.median(row["phases"][phase]["seconds"] for row in selected),
                allocated_bytes=statistics.median(row["phases"][phase]["allocated_bytes"] for row in selected))
                for phase in selected[0]["phases"]},
            complete_seconds=statistics.median(row["complete_seconds"] for row in selected),
            complete_allocated_bytes=statistics.median(row["complete_allocated_bytes"] for row in selected),
            phase_events=prior.phase_events(selected),
            actual_work=[batch_coverage(row, config) for row in selected]))
    return dict(case=screen["case"], protocol=PROTOCOL, config=config,
        baseline="ordinary_a", repetitions=screen["repetitions"], orders=screen["orders"],
        expected_digest=screen["expected_digest"], scientific_work=samples[0]["work"],
        sample_cohort_sha256=sha(canonical(samples)), warmup_cohort_sha256=sha(canonical(warmups)),
        source_epoch=prior.shared.source_epoch(screen), rows=rows, comparisons=comparisons,
        warmup_phase_events=prior.phase_events(warmups),
        verification="full_stored_per_instance_science_RNG_history_work_and_actual_counter_partitions_agree",
        baseline_scope="ordinary_reference_executor_without_bounded_or_other_candidates",
        anchor_scope="bounded_metadata_plus_graph_is_a_separate_policy_not_the_reference",
        ratio_method="median_of_paired_cycle_ratios",
        statistical_unit="one_batch_sample_not_one_sample_per_simulation")


def summarize(parsed, raw):
    bindings = prior.shared.qualification_bindings(parsed, raw)
    warm, excluded, checks, excluded_attempts = [], [], [], []
    for name, data in sorted(parsed.items()):
        if "/" in name:
            continue
        if name.startswith("excluded-"):
            excluded_attempts.append(dict(source=name, raw_sha256=sha(raw[name]),
                interpretation="explicitly_excluded_older_or_idle_worker_attempt_raw_only_not_current_validation_or_timing"))
            continue
        for location, value in walk(data):
            if isinstance(value.get("samples"), list) and "baseline" in value and "orders" in value:
                result = warm_summary(value)
                cpu = prior.shared.cpu_qualification(name, bindings)
                row = dict(source=name, location=location, cpu=cpu, **result)
                (warm if cpu["qualified"] else excluded).append(row)
            if isinstance(value.get("passed"), bool):
                checks.append(dict(source=name, location=location, **{key: compact(value[key])
                    for key in ("passed", "kind", "arm", "case", "test_counts", "work") if key in value}))
    unique, duplicate = {}, []
    for row in warm:
        key = row["sample_cohort_sha256"]
        if key in unique:
            duplicate.append(dict(source=row["source"], location=row["location"],
                canonical_source=unique[key]["source"], sample_cohort_sha256=key))
        else:
            unique[key] = row
    return dict(warm_screens=list(unique.values()), excluded_warm_screens=excluded,
        qualified_first_use=[], duplicate_screen_exports=duplicate, checks=checks,
        excluded_attempts=excluded_attempts,
        unexecuted_future_proposals=[dict(source=name, raw_bytes=len(value), raw_sha256=sha(value),
            interpretation="source_proposal_only_not_loaded_applied_tested_or_timed")
            for name, value in sorted(raw.items()) if name.startswith("unexecuted-future-proposal/")],
        unparsed_raw_evidence=[dict(source=name, **value) for name, value in parsed.items()
            if isinstance(value, dict) and "_archive_parse_error" in value],
        scope="independent_trusted_constructor_index_and_typed_output_preparation_against_ordinary_XP_executor",
        old_results_used_as_current_baseline=False,
        limitations=["A/A spread includes fresh-instance/cache/OS/timer effects, not isolated timer noise.",
            "Typed growth-phase object visits do not count unique newborn objects.",
            "Trusted stamp/construction/certification work is included, not inferred free from avoided scans.",
            "Conservative epoch/ID fallbacks are reported separately and earn no trusted-path credit.",
            "Metadata operations are not scientific kernel executions; numerical executor stays ordinary.",
            "No cold compilation, full suite, peak RSS, million-organ or optional package claim is established."])


def source_inputs():
    paths = set((ROOT / "src").rglob("*.jl"))
    paths.update((ROOT / "benchmark/native_downstream").glob("*.jl"))
    paths.update(ROOT / name for name in ("Project.toml", "Manifest.toml"))
    paths.update((Path(__file__).resolve(), Path(prior.__file__).resolve(), Path(prior.shared.__file__).resolve()))
    return {path.relative_to(ROOT).as_posix(): path.read_bytes() for path in sorted(paths)}


def archive(raw, sources, scientific, blobs, summary):
    if DEST.exists():
        raise FileExistsError(f"Immutable evidence destination exists: {DEST}")
    DEST.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".xp-dispatch-refresh-", dir=DEST.parent) as temporary:
        stage = Path(temporary) / "xp-dispatch-refresh"
        stage.mkdir()
        manifest = []
        def put(name, value, kind, origin):
            compressed = gzip.compress(value, mtime=0)
            path = stage / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(compressed)
            manifest.append(dict(kind=kind, origin=origin, artifact=name, raw_bytes=len(value),
                raw_sha256=sha(value), compressed_sha256=sha(compressed), encoding="gzip"))
        for name, value in sorted(raw.items()):
            put("raw/" + name + ".gz", value, "raw_evidence", name)
        for name, value in sorted(sources.items()):
            put("qualified-source/" + name + ".gz", value, "current_source_snapshot", name)
        for key, value in sorted(blobs.items()):
            put("source-blobs/" + key + ".gz", value, "scientific_source_blob", key)
        for name, value in (("summary.json", summary), ("scientific-provenance.json", scientific)):
            payload = json_bytes(value)
            (stage / name).write_bytes(payload)
            manifest.append(dict(kind="derived_metadata", origin=name, artifact=name,
                raw_bytes=len(payload), raw_sha256=sha(payload), encoding="identity"))
        (stage / "manifest.json").write_bytes(json_bytes(sorted(manifest, key=lambda row: row["artifact"])))
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
        raise FileExistsError(f"Refusing immutable overwrite: {DEST}")
    raw = inventory(SOURCE)
    parsed = prior.shared.documents(raw)
    summary = summarize(parsed, raw)
    sources = source_inputs()
    scientific, blobs = prior.scientific_sources(parsed, raw, sources, summary)
    if raw != inventory(SOURCE) or sources != source_inputs():
        raise RuntimeError("Source/evidence changed during validation; retry after freeze")
    if args.archive_frozen:
        archive(raw, sources, scientific, blobs, summary)
    print(json.dumps(dict(archived=bool(args.archive_frozen), raw_files=len(raw), source_files=len(sources),
        scientific_source_blobs=len(blobs), qualified_warm_screens=len(summary["warm_screens"]),
        excluded_warm_screens=len(summary["excluded_warm_screens"]), checks=len(summary["checks"]),
        explicitly_excluded_attempts=len(summary["excluded_attempts"]),
        unparsed_raw_evidence=len(summary["unparsed_raw_evidence"])), sort_keys=True))


if __name__ == "__main__":
    main()
