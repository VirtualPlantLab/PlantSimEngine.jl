"""Validate and archive XP growth attribution and candidate-v2 evidence.

No Julia is started. Use --check-only first; --archive-frozen refuses an existing
immutable destination. Profiling elapsed/allocated diagnostic measurements are
never promoted to application timing. Candidate batch samples, graph metadata
microchecks and source-operation profiles are distinct protocols. Original raw
results/failed receipts are losslessly gzip-preserved. The sole exclusion is the
accidental nested historical result-source copies from the old source traversal
bug; every excluded path, size and SHA256 is recorded explicitly.
"""
from pathlib import Path
import argparse
import gzip
import json
import math
import statistics
import tempfile

# Reuse the already-frozen, source-archived validation primitives. This does not
# edit the old newborn-binding archive or its script and does not run Julia.
import summarize_newborn_bindings as shared

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "benchmark/native_downstream/results/xp-growth-attribution"
DEST = Path(__file__).resolve().parent / "evidence/xp-growth-attribution"
shared.SOURCE = SOURCE  # qualification paths resolve in this new evidence tree
sha, canonical, json_bytes = shared.sha, shared.canonical, shared.json_bytes
compact, walk = shared.compact, shared.walk
ACTUAL_FIELDS = shared.ACTUAL_FIELDS
PROTOCOL = "xp_graph_lookup_candidates_v2"
EXCLUDED_PREFIX = "source-before-fixes/benchmark/native_downstream/results/"
ARMS = ("bounded_a", "bounded_b", "bounded_sequence", "graph_only", "lookup_only",
    "graph_lookup", "graph_lookup_sequence")


def inventory(folder):
    kept, excluded = {}, []
    for path in sorted(folder.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Symlink evidence input: {path}")
        if not path.is_file():
            continue
        name = path.relative_to(folder).as_posix()
        raw = path.read_bytes()
        if name.startswith(EXCLUDED_PREFIX):
            excluded.append(dict(path=name, raw_bytes=len(raw), raw_sha256=sha(raw),
                reason="accidental_irrelevant_historical_result_source_copy_from_old_manifest_traversal"))
        else:
            kept[name] = raw
    return kept, excluded


def policies(arm):
    if arm not in ARMS:
        raise ValueError(f"Unknown candidate-v2 arm: {arm}")
    seq = arm in ("bounded_sequence", "graph_lookup_sequence")
    return dict(graph=arm in ("graph_only", "graph_lookup", "graph_lookup_sequence"),
        lookup=arm in ("lookup_only", "graph_lookup", "graph_lookup_sequence"),
        sequence=seq, bounded=True,
        underlying_arm="bounded_sequence" if seq else "bounded_preparation")


def nonnegative(counters):
    if any(not isinstance(v, int) or isinstance(v, bool) or v < 0 for v in counters.values()):
        raise ValueError("Metadata counters must be actual nonnegative integers")


def sum_counters(rows, fields):
    return {key: sum(row[key] for row in rows) for key in fields}


def original_sequence_coverage(coverage, work, config, *, newborn=True):
    """Revalidate the unchanged NBP/NBS certificates without treating them as kernels."""
    c = dict(coverage, measurement_protocol="base_vs_consumer_sequence_v1")
    conf = dict(config, measurement_protocol="base_vs_consumer_sequence_v1",
        sequence_details=False, shared_world_cache=False,
        require_actual_newborn_instruction=newborn)
    return shared.sequence_binding_coverage(dict(variant=c["sequence_arm"],
        coverage=c, work=work), conf)


def candidate_instance(coverage, work, config, arm):
    p = policies(arm)
    if coverage.get("candidate_arm") != arm or coverage.get("candidate_policies") != p:
        raise ValueError("Per-instance candidate policy differs from registered arm")
    if coverage.get("measurement_protocol") != PROTOCOL:
        raise ValueError("Unsupported candidate per-instance protocol")
    original_sequence_coverage(coverage, work, config)
    if coverage["sequence_policies"] != dict(mechanism="sequence" if p["sequence"] else "ordinary",
            bounded=True, typed=False, underlying_arm="bounded_preparation"):
        raise ValueError("NBS policy differs from candidate arm")
    graph, epoch = coverage["graph_projection"], coverage["execution_group_lookup"]
    g, e, v = graph["counters"], epoch["counters"], epoch["v1"]["counters"]
    for c in (g, e, v):
        nonnegative(c)
    if bool(graph["enabled"]) != p["graph"]:
        raise ValueError("Graph policy contamination")
    if p["graph"]:
        if g["projections_completed"] <= 0 or g["rows_projected"] <= 0:
            raise ValueError("Graph arm completed no returned graph table")
    elif any(g.values()):
        raise ValueError("Disabled graph policy has work")
    if epoch["enabled"] is not p["lookup"] or epoch["v1"]["enabled"] is not p["lookup"]:
        raise ValueError("Epoch/v1 policy contamination")
    if e["epoch_attempts"] != e["epochs_validated"] + e["epochs_rejected"]:
        raise ValueError("Epoch proof partition differs")
    if v["lookups"] != v["slot_hits"] + v["slot_misses"] + e["trusted_empty_returns"]:
        raise ValueError("Lookup hit/miss/trusted-empty partition differs")
    if v["slot_misses"] != sum(v[k] for k in
            ("absent_slot_misses", "out_of_range_misses", "identity_misses")):
        raise ValueError("Original-ID miss reasons differ")
    if e["query_fallbacks"] != v["slot_misses"] or v["dictionary_lookups"] != v["slot_misses"]:
        raise ValueError("ID fallback count differs")
    if v["dictionaries_built"] > v["refresh_lookups_created"] or \
            epoch["dictionary_builds_avoided"] != v["refresh_lookups_created"] - v["dictionaries_built"]:
        raise ValueError("Dictionary construction accounting differs")
    if e["nonempty_epoch_hits"] > v["slot_hits"]:
        raise ValueError("Epoch-owned hits exceed all slot hits")
    if p["lookup"]:
        if not (e["epochs_validated"] > 0 and e["nonempty_epoch_hits"] > 0 and v["slot_hits"] > 0):
            raise ValueError("Epoch arm has no OWN validated nonempty growth hit")
        if coverage["lookup_eligibility"] != "actual_epoch_validated_growth_hits":
            raise ValueError("Epoch coverage credited fallback-only work")
    elif any(e.values()) or any(v.values()):
        raise ValueError("Disabled epoch/v1 policy has work")
    expected = dict(actual_graph_completions=g["projections_completed"],
        actual_graph_rows=g["rows_projected"], actual_graph_edges=g["edges_projected"],
        actual_lookup_slot_hits=v["slot_hits"], actual_lookup_fallback_builds=v["dictionaries_built"],
        actual_lookup_epoch_hits=e["nonempty_epoch_hits"],
        actual_lookup_trusted_empty=e["trusted_empty_returns"])
    if any(coverage[k] != value for k, value in expected.items()):
        raise ValueError("Public metadata actual-work aliases differ from namespaces")
    if coverage.get("metadata_work_is_not_kernel_work") is not True:
        raise ValueError("Metadata counted as scientific kernel work")
    return dict(graph=g, epoch=e, lookup=v, sequence=coverage["sequence_actual"],
        total=coverage["total_actual"])


def candidate_coverage(sample, config):
    c, arm = sample["coverage"], sample["variant"]
    if c.get("candidate_arm") != arm or c.get("candidate_policies") != policies(arm):
        raise ValueError("Batch policy differs from arm")
    if c.get("measurement_protocol") != PROTOCOL or config.get("measurement_protocol") != PROTOCOL:
        raise ValueError("Unsupported batch candidate protocol")
    if config.get("candidate_policies_by_arm", {}).get(arm) != policies(arm):
        raise ValueError("Configured candidate policy differs")
    n = config["batch_size"]
    reports, works = c["per_instance"], sample["work"]["instances"]
    if len(reports) != n or len(works) != n:
        raise ValueError("Missing independently constructed simulation")
    independent = c["independent_instances"]
    if independent["models"] != n or independent.get("cross_instance_statuses_disjoint") is not True or \
            independent.get("cross_instance_canonical_references_disjoint") is not True:
        raise ValueError("Batch has no disjoint-model/status/reference proof")
    rows = [candidate_instance(report, work, config, arm) for report, work in zip(reports, works)]
    for field, namespace in (("actual_completions", "total"), ("actual_sequence_completions", "sequence"),
            ("actual_lookup", "lookup"), ("actual_epoch_lookup", "epoch")):
        expected = sum_counters([row[namespace] for row in rows], c[field])
        if c[field] != expected:
            raise ValueError(f"Batch counted a metadata namespace twice or omitted work: {field}")
    expected_graph = {key: sum(row["graph"][key] for row in rows) for key in c["actual_graph"]}
    if c["actual_graph"] != expected_graph:
        raise ValueError("Batch graph work differs from per-instance completions")
    for field in ("native_fields", "driver_units", "native_driver_units"):
        if c[field] != sum(report[field] for report in reports):
            raise ValueError("Batch numerical coverage differs from actual per-instance counts")
    if c.get("counter_accounting") != "sum_each_actual_namespace_per_instance_once" or \
            c.get("statistical_unit") != "one_batch_sample" or \
            c.get("metadata_work_is_not_kernel_work") is not True or \
            c.get("placebo_control") is not (arm in ("bounded_a", "bounded_b")):
        raise ValueError("Unrecognized aggregation/statistical-unit convention")
    snapshot = sample["snapshot"]
    if snapshot["batch_size"] != n or len(snapshot["instance_map"]) != n:
        raise ValueError("Scientific observation has missing instances")
    if [row["instance"] for row in snapshot["instance_map"]] != list(range(1, n + 1)):
        raise ValueError("Scientific observation instance identities differ")
    observed = snapshot["full_observations"]
    if not 1 <= len(observed) <= n:
        raise ValueError("No lossless scientific observation payload")
    used = set()
    for mapping in snapshot["instance_map"]:
        index = mapping["observation_index"]
        if not 1 <= index <= len(observed) or mapping["digest"] != observed[index - 1]["digest"]:
            raise ValueError("Scientific deduplication mapping differs from full observation")
        used.add(index)
    if used != set(range(1, len(observed) + 1)):
        raise ValueError("Unreferenced scientific observation payload")
    work = sample["work"]
    expected_work = dict(total_simulated_steps=sum(row["steps"] for row in works),
        total_final_objects=sum(row["objects"] for row in works),
        total_added_objects=sum(len(row["added_ids"]) for row in works),
        total_retained_streams=sum(row["streams"] for row in works))
    if work["batch_size"] != n or any(work[k] != value for k, value in expected_work.items()) or \
            any(row["steps"] != config["steps"] for row in works):
        raise ValueError("Batch scientific work totals differ")
    return dict(graph=c["actual_graph"], lookup=c["actual_lookup"], epoch=c["actual_epoch_lookup"],
        bindings=c["actual_completions"], sequence=c["actual_sequence_completions"],
        independent_instances=independent, metadata_is_not_kernel_work=True)


def phase_events(rows):
    return [dict(cycle=row.get("cycle"), variant=row.get("variant", row.get("arm")),
        phase=name, **{key: value.get(key) for key in
            ("compilation_seconds", "recompilation_seconds", "gc_seconds")})
        for row in rows for name, value in row["phases"].items()
        if any(value.get(key, 0) for key in ("compilation_seconds", "recompilation_seconds", "gc_seconds"))]


def warm_summary(screen):
    config, samples, warmups = screen["config"], screen["samples"], screen["warmups"]
    if config.get("measurement_protocol") != PROTOCOL:
        raise ValueError("Unknown XP warm timing protocol")
    for key, expected in dict(statistical_unit="one_batch_sample", sequence_details=False,
            shared_world_cache=False,
            execution_scope="advance_each_independent_prepared_simulation_once",
            complete_cost_scope="construction_enablement_all_preparation_and_batch_execution").items():
        if config.get(key) != expected:
            raise ValueError(f"Changed batch scope: {key}")
    if not samples or screen["baseline"] != "bounded_a":
        raise ValueError("Candidate cohort must have bounded A/A reference")
    order = screen["orders"][0]
    if len(order) != len(set(order)) or not {"bounded_a", "bounded_b"} <= set(order):
        raise ValueError("Both unique A/A controls required")
    if len(screen["orders"]) != screen["repetitions"] or screen["repetitions"] <= 0:
        raise ValueError("Wrong cycle count")
    if any(row != (order if i % 2 == 0 else order[::-1]) for i, row in enumerate(screen["orders"])):
        raise ValueError("Not alternating forward/reverse orders")
    if [(row["cycle"], row["variant"]) for row in samples] != [(i + 1, arm)
            for i, cycle in enumerate(screen["orders"]) for arm in cycle]:
        raise ValueError("Sample order differs from configured cycles")
    if sorted(row["variant"] for row in warmups) != sorted(order):
        raise ValueError("Need one independent warmup per arm")
    if any(row["temperature"] != "warm" for row in samples) or \
            any(row["temperature"] != "warmup" for row in warmups):
        raise ValueError("Mislabeled timing temperature")
    all_rows = samples + warmups
    if len({row["process_id"] for row in all_rows}) != 1 or \
            samples[0]["process_id"] != screen["provenance"]["process_id"]:
        raise ValueError("One warm cohort cannot mix workers")
    for row in all_rows:
        if row["case"] != screen["case"] or canonical(row["config"]) != canonical(config):
            raise ValueError("Changed case/config during cohort")
        if row["digest"] != screen["expected_digest"] or \
                canonical(row["snapshot"]) != canonical(samples[0]["snapshot"]) or \
                canonical(row["work"]) != canonical(samples[0]["work"]):
            raise ValueError("Scientific state/RNG/history/work/digest differs")
        if set(row["phases"]) != {"construction", "pse_preparation", "backend_lowering", "execution"}:
            raise ValueError("Complete cost omits a required phase")
        shared.validate_phase_sums(row)
        for phase in row["phases"].values():
            for key in ("compilation_seconds", "recompilation_seconds", "gc_seconds"):
                value = phase.get(key)
                if not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                    raise ValueError("Missing or invalid measured phase JIT/GC counter")
        if not math.isclose(sum(phase["gc_seconds"] for phase in row["phases"].values()),
                row["complete_gc_seconds"], rel_tol=1e-12, abs_tol=1e-12):
            raise ValueError("Complete GC time differs from phase sum")
        candidate_coverage(row, config)
    indexed = {(row["cycle"], row["variant"]): row for row in samples}
    comparisons = []
    for control in order:
        for arm in order:
            if arm == control:
                continue
            paired = []
            for cycle in range(1, screen["repetitions"] + 1):
                a, b = indexed[cycle, arm], indexed[cycle, control]
                ratios = {key: a["phases"][key]["seconds"] / b["phases"][key]["seconds"]
                    for key in ("execution", "pse_preparation")}
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
            phases={name: dict(seconds=statistics.median(row["phases"][name]["seconds"] for row in selected),
                allocated_bytes=statistics.median(row["phases"][name]["allocated_bytes"] for row in selected))
                for name in selected[0]["phases"]},
            complete_seconds=statistics.median(row["complete_seconds"] for row in selected),
            complete_allocated_bytes=statistics.median(row["complete_allocated_bytes"] for row in selected),
            phase_events=phase_events(selected),
            actual_work=[candidate_coverage(row, config) for row in selected]))
    return dict(case=screen["case"], config=config, repetitions=screen["repetitions"],
        protocol=PROTOCOL, baseline=screen["baseline"], orders=screen["orders"],
        expected_digest=screen["expected_digest"], scientific_work=samples[0]["work"],
        sample_cohort_sha256=sha(canonical(samples)), warmup_cohort_sha256=sha(canonical(warmups)),
        source_epoch=shared.source_epoch(screen), rows=rows, comparisons=comparisons,
        warmup_phase_events=phase_events(warmups),
        verification="full_stored_state_RNG_history_topology_work_digests_and_actual_counter_partitions_agree",
        freshness="fresh_models_statuses_refs_and_scientific_state_per_instance_reported_and_checked",
        statistical_unit="one_batch_sample_not_each_instance_an_independent_timing_sample",
        ratio_method="median_of_paired_cycle_ratios",
        scope="construction_enablement_preparation_and_execution_cost_included")


def metadata_micro_summary(value):
    if value.get("passed") is not True or value.get("scientific_kernel_execution") is not False or \
            value.get("application_speed_claim") is not False or value.get("cold_compilation_claim") is not False:
        raise ValueError("Graph helper microcheck must not claim application/scientific speed")
    samples, cycles = value["samples"], value["cycles"]
    expected = [(i, arm) for i in range(1, cycles + 1) for arm in
        (("reference", "projection") if i % 2 else ("projection", "reference"))]
    if [(row["cycle"], row["arm"]) for row in samples] != expected:
        raise ValueError("Graph helper microcheck order differs")
    idx = {(row["cycle"], row["arm"]): row for row in samples}
    ratios = []
    for row in samples:
        evidence = row["evidence"]
        if evidence["work"] != value["work"]:
            raise ValueError("Graph helper metadata work differs")
        if not math.isclose(row["complete"]["seconds"], row["build"]["seconds"] +
                row["second_table"]["seconds"], rel_tol=1e-12, abs_tol=1e-12):
            raise ValueError("Graph helper phase sum differs")
        if row["complete"]["allocated_bytes"] != row["build"]["allocated_bytes"] + row["second_table"]["allocated_bytes"]:
            raise ValueError("Graph helper allocation sum differs")
        p = evidence["projection_counts"]
        if row["arm"] == "projection":
            if p is None or p["projections_completed"] != value["work"]["tables"] or \
                    p["rows_projected"] != value["work"]["rows"] or p["edges_projected"] != value["work"]["edges"]:
                raise ValueError("No actual graph helper completion")
        elif p is not None:
            raise ValueError("Graph helper control contamination")
    for cycle in range(1, cycles + 1):
        a, b = idx[cycle, "projection"], idx[cycle, "reference"]
        ratios.append(dict(cycle=cycle, **{phase: a[phase]["seconds"] / b[phase]["seconds"]
            for phase in ("build", "second_table", "complete")}))
    if canonical(ratios) != canonical(value["ratios"]):
        raise ValueError("Stored graph helper paired ratios differ")
    return dict(protocol="graph_relation_metadata_helper_micro_v1", napplications=value["napplications"],
        cycles=cycles, work=value["work"], paired_cycle_ratios=ratios,
        medians={key: statistics.median(row[key] for row in ratios)
            for key in ("build", "second_table", "complete")},
        samples=compact(samples), scientific_kernel_execution=False, application_speed_claim=False,
        cold_compilation_claim=False, interpretation="isolated_metadata_helper_not_whole_application_or_kernel")


def profile_summary(value, name):
    if value.get("passed") is not True or value.get("benchmark_claim") is not False:
        raise ValueError("Source profile is not a passed non-timing diagnostic")
    preparation = "sampled_region" in value
    oracle, config = value["oracle"], value["config"]
    manifests = value["source_manifest"]["files"]
    bad_inventory = any("results" in Path(row["path"]).parts for row in manifests)
    # Early four-day profiles predate the entry-selected sampling and corrected
    # manifest traversal. Retain every byte but do not use them for stable shares.
    preliminary = bad_inventory or name.startswith("profile4-") or name == "allocation-profiler-warmup.json"
    cpu = value.get("cpu")
    stable = cpu is not None and not preliminary and cpu.get("samples_with_operation", 0) >= 100 and \
        cpu.get("buffer_full") is False and cpu.get("trailing_raw_ips", 0) == 0
    if stable and cpu.get("qualification") != "coarse_operation_sampling":
        raise ValueError("CPU source population/qualification disagrees")
    checks = []
    if preparation:
        if value.get("scientific_kernel_steps") != 0 or value.get("canonical_identity_transitions_match") is not True:
            raise ValueError("Preparation-only profile advanced science or changed identities")
        checks.append(("preparation", value["cases"]))
    else:
        for key in ("cpu_check", "allocation_check"):
            check = value.get(key)
            if check is not None:
                if check.get("passed") is not True or check.get("canonical_identity_transitions_match") is not True or \
                        check["count"] != value["repetitions"]:
                    raise ValueError("Profile scientific/reference check failed")
                checks.append((key, check["cases"]))
        framework = value.get("framework")
        if framework is not None:
            check = framework["check"]
            if check.get("passed") is not True or check.get("canonical_identity_transitions_match") is not True:
                raise ValueError("Instrumented framework companion failed parity")
            checks.append(("framework", check["cases"]))
    for scope, cases in checks:
        if len(cases) != (1 if scope == "framework" else value["repetitions"]):
            raise ValueError("Missing independent profile companion")
        for case in cases:
            if case["digest"] != oracle["digest"] or case["work"] != oracle["work"]:
                raise ValueError("Profile oracle digest/work differs")
            original_sequence_coverage(case["coverage"], case["work"], config, newborn=not preparation)
            if preparation and case.get("current_step") != 0:
                raise ValueError("Preparation-only companion ran scientific steps")
    return dict(protocol="xp_preparation_source_profile_v1" if preparation else "xp_growth_source_profile_v1",
        arm=value["arm"], config=config, repetitions=value["repetitions"], pid=value["pid"],
        oracle=compact(oracle), source_manifest=compact(value["source_manifest"]),
        source_manifest_sha256=value["source_manifest"]["aggregate_sha256"],
        source_manifest_files=len(manifests), contains_accidental_results=bad_inventory,
        preliminary=preliminary, qualified_coarse_operation_sampling=stable,
        cpu=compact(cpu, 6), allocations=compact(value.get("allocations"), 6),
        instrumentation_measurements={key: value.get(key) for key in
            ("cpu_measurement", "allocation_measurement")},
        framework=compact(value.get("framework"), 6),
        science_checks=[dict(scope=scope, cases=len(cases)) for scope, cases in checks],
        sampled_region=value.get("sampled_region", value.get("CPU_and_allocation_span")),
        benchmark_claim=False,
        interpretation="source_operation_sampling_and_instrumented_companions_not_application_speed_ratios",
        limitations=["CPU inclusive categories and framework phase timers overlap.",
            "Nearest eligible source sites are not exact exclusive line or guard costs.",
            "Sampled allocation bytes do not establish causal runtime savings or retained/peak memory.",
            "Profiler elapsed time includes diagnostic overhead/JIT; never pooled with warm samples."])


def summarize(parsed, raw_files, excluded):
    bindings = shared.qualification_bindings(parsed, raw_files)
    warm, excluded_warm, micros, profiles, checks = [], [], [], [], []
    for name, data in sorted(parsed.items()):
        if "/" in name:
            continue
        for location, value in walk(data):
            if isinstance(value.get("samples"), list) and "baseline" in value and "orders" in value:
                result = warm_summary(value)
                cpu = shared.cpu_qualification(name, bindings)
                row = dict(source=name, location=location, cpu=cpu, **result)
                (warm if cpu["qualified"] else excluded_warm).append(row)
            if "napplications" in value and "application_speed_claim" in value and "samples" in value:
                cpu = shared.cpu_qualification(name, bindings)
                result = metadata_micro_summary(value)
                if not cpu["qualified"]:
                    result = {key: item for key, item in result.items()
                        if key not in ("paired_cycle_ratios", "medians", "samples")}
                    result["unqualified_timings"] = "retained_only_in_lossless_raw_microcheck"
                micros.append(dict(source=name, location=location, cpu=cpu, **result,
                    timing_qualified=cpu["qualified"]))
            if value.get("benchmark_claim") is False and "source_manifest" in value and "oracle" in value:
                profiles.append(dict(source=name, location=location, **profile_summary(value, name)))
            if isinstance(value.get("passed"), bool):
                checks.append(dict(source=name, location=location, **{key: compact(value[key])
                    for key in ("passed", "kind", "arm", "case", "test_counts", "work") if key in value}))
    cohorts, duplicate = {}, []
    for row in warm:
        key = row["sample_cohort_sha256"]
        if key in cohorts:
            duplicate.append(dict(source=row["source"], location=row["location"],
                canonical_source=cohorts[key]["source"], sample_cohort_sha256=key))
        else:
            cohorts[key] = row
    return dict(warm_screens=list(cohorts.values()), excluded_warm_screens=excluded_warm,
        duplicate_screen_exports=duplicate, metadata_microchecks=micros, profiles=profiles, checks=checks,
        qualified_first_use=[],  # legacy scientific-source helper expects this explicit empty cohort
        excluded_accidental_source_copies=excluded,
        unparsed_raw_evidence=[dict(source=name, **value) for name, value in parsed.items()
            if isinstance(value, dict) and "_archive_parse_error" in value],
        scope="XP_growth_source_attribution_and_separate_graph_epoch_sequence_candidates",
        limitations=["A/A placebo spread is retained; small runtime differences are not automatically causal.",
            "Prepared batches contain independent scientific instances but one timing observation per batch.",
            "Targeted tests are not a full regression suite or million-organ validation.",
            "No cold compilation or optional AMAPSim/MAESPA benefit is established by this experiment.",
            "Source/effect proofs and reference parity are reported Julia results, not rerun by Python.",
            "All early failed/unqualified results remain raw; only irrelevant nested historical source copies are excluded by explicit path/hash manifest."])


def source_inputs():
    paths = set((ROOT / "src").rglob("*.jl"))
    paths.update((ROOT / "benchmark/native_downstream").glob("*.jl"))
    paths.update(ROOT / name for name in ("Project.toml", "Manifest.toml"))
    paths.update((Path(__file__).resolve(), Path(shared.__file__).resolve()))
    return {path.relative_to(ROOT).as_posix(): path.read_bytes() for path in sorted(paths)}


def scientific_sources(parsed, raw_files, current, summary):
    # Include exact recorded PSE source manifests from both preliminary and final
    # profiles, as well as per-screen PSE/PB/XP and experimental source packages.
    adapted = dict(parsed)
    omitted = {}
    for name, data in parsed.items():
        if "/" in name:
            continue
        for location, value in walk(data):
            manifest = value.get("source_manifest")
            if isinstance(manifest, dict) and "root" in manifest and "files" in manifest:
                key = name + "#profile-manifest:" + location
                excluded = [row for row in manifest["files"] if "results" in Path(row["path"]).parts]
                active = [row for row in manifest["files"] if "results" not in Path(row["path"]).parts]
                adapted[key] = dict(packages=[dict(name="PlantSimEngine", root=manifest["root"],
                    sources=dict(manifest, files=active))])
                if excluded:
                    omitted[key] = excluded
    records, blobs = shared.scientific_sources(adapted, raw_files, current, summary)
    for record in records:
        if record["record"] in omitted:
            record["source_inventory_scope"] = "active_source_subset_of_preliminary_overbroad_manifest"
            record["excluded_irrelevant_recorded_source_entries"] = omitted[record["record"]]
            record["original_full_inventory"] = "unchanged_raw_preliminary_profile_source_manifest"
    return records, blobs


def archive(raw_files, sources, scientific, blobs, summary):
    if DEST.exists():
        raise FileExistsError(f"Immutable archive already exists: {DEST}")
    DEST.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".xp-growth-attribution-", dir=DEST.parent) as temporary:
        stage = Path(temporary) / "xp-growth-attribution"
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
        for name, value in (("scientific-provenance.json", scientific), ("summary.json", summary),
                ("excluded-accidental-source-copies.json", summary["excluded_accidental_source_copies"])):
            raw = json_bytes(value)
            (stage / name).write_bytes(raw)
            manifest.append(dict(kind="derived_metadata", origin=name, artifact=name,
                raw_bytes=len(raw), raw_sha256=sha(raw), encoding="identity"))
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
        raise FileExistsError(f"Refusing immutable archive overwrite: {DEST}")
    raw, excluded = inventory(SOURCE)
    parsed = shared.documents(raw)
    summary = summarize(parsed, raw, excluded)
    sources = source_inputs()
    scientific, blobs = scientific_sources(parsed, raw, sources, summary)
    if (raw, excluded) != inventory(SOURCE) or sources != source_inputs():
        raise RuntimeError("Evidence/source changed during validation; retry after final freeze")
    if args.archive_frozen:
        archive(raw, sources, scientific, blobs, summary)
    print(json.dumps(dict(archived=bool(args.archive_frozen), raw_files=len(raw),
        excluded_historical_source_copies=len(excluded), source_files=len(sources),
        scientific_source_blobs=len(blobs), qualified_warm_screens=len(summary["warm_screens"]),
        excluded_warm_screens=len(summary["excluded_warm_screens"]),
        metadata_microchecks=len(summary["metadata_microchecks"]), profiles=len(summary["profiles"]),
        coarse_qualified_profiles=sum(row["qualified_coarse_operation_sampling"] for row in summary["profiles"]),
        checks=len(summary["checks"]), unparsed_raw_evidence=len(summary["unparsed_raw_evidence"])), sort_keys=True))


if __name__ == "__main__":
    main()
