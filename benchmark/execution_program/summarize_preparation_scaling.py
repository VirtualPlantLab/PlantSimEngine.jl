"""Validate and immutably archive PB/XP preparation-scaling evidence.

Python only: no Julia execution. Only this round's single-scene protocols are
timing candidates. Old modules supply validation primitives, never baselines.
Use --check-only during review; --archive-frozen only after controller freeze.
"""
from pathlib import Path
import argparse
import copy
import gzip
import json
import math
import statistics
import tempfile

import summarize_xp_dispatch_refresh as dispatch
import summarize_direct_planner as region_validation

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "benchmark/native_downstream/results/preparation-scaling"
DEST = Path(__file__).resolve().parent / "evidence/preparation-scaling"
prior = dispatch.prior
shared = prior.shared
shared.SOURCE = SOURCE
region_validation.SOURCE = SOURCE
sha, canonical, json_bytes = shared.sha, shared.canonical, shared.json_bytes
PB_PROTOCOL = "pb_original_executor_preparation_scaling_v1"
XP_PROTOCOL = "xp_preparation_single_trajectory_v1"
COLD_PROTOCOL = "preparation_scaling_cold_v1"
ARMS = ("ordinary_a", "ordinary_b", "bounded_graph", "typed_graph", "typed_barrier", "typed_only")
BASE_ARMS = ("ordinary_a", "ordinary_b", "bounded_graph", "typed_graph")
MODEL_PHASES = ("construction", "pse_preparation", "backend_lowering", "execution")
COLD_MODEL_PHASES = ("construction", "pse_preparation", "backend_lowering", "first_execution", "remaining_execution")
COLD_PACKAGES = {"PlantSimEngine", "PlantBiophysics", "XPalm", "PlantGeom"}
COLD_REQUIRED_IMAGE = {
    "Project.toml", "Manifest.toml", "src/PlantSimEngine.jl",
    "src/composite_model/compilation.jl", "src/composite_model/runtime_outputs.jl",
    *("benchmark/native_downstream/"+name for name in (
        "load_experiments.jl", "load_direct_planner_experiment.jl", "load_newborn_binding_experiment.jl",
        "direct_planner_fixtures.jl", "direct_planner_measurements.jl", "bounded_preparation.jl",
        "graph_row_projection.jl", "typed_output_preparation.jl", "xp_dispatch_refresh_measurements.jl",
        "pb_preparation_scaling.jl", "xp_preparation_scaling.jl", "preparation_scaling_cold_case.jl"))}


def inventory(folder):
    result = {}
    for path in sorted(folder.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Symlink evidence input: {path}")
        if path.is_file():
            result[path.relative_to(folder).as_posix()] = path.read_bytes()
    return result


def mapped_arm(arm):
    if arm not in ARMS:
        raise ValueError(f"Unknown preparation-scaling arm: {arm}")
    return "typed_barrier" if arm == "typed_only" else arm


def phase_checks(row, expected=MODEL_PHASES):
    if set(row["phases"]) != set(expected):
        raise ValueError("Missing or extra charged model phase")
    shared.validate_phase_sums(row)
    for phase in row["phases"].values():
        for field in ("seconds", "allocated_bytes", "gc_seconds", "compilation_seconds", "recompilation_seconds"):
            value = phase.get(field)
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                raise ValueError(f"Missing/nonfinite/negative measured phase field: {field}")
    if not math.isclose(sum(p["gc_seconds"] for p in row["phases"].values()),
            row["complete_gc_seconds"], rel_tol=1e-12, abs_tol=1e-12):
        raise ValueError("Complete GC differs from phase sum")


def science_checks(snapshot, work, config):
    if not isinstance(snapshot, dict) or set(snapshot) != {"state", "scientific_rngs"}:
        raise ValueError("Need full scalar scene state/history/types and model RNG fingerprint")
    if "batch_size" in snapshot or "instances" in work:
        raise ValueError("Batch/replica evidence cannot enter single-scene scaling")
    for value in [work["steps"],work["objects"],work["streams"],*work["objects_by_scale"].values()]:
        if isinstance(value,bool) or not isinstance(value,int) or value<0:
            raise ValueError("Scientific work must contain actual nonnegative integer counts")
    state=snapshot["state"]
    if state["scientific"]["step"] != work["steps"] or len(state["topology"]) != work["objects"] or \
            len({row["id"] for row in state["topology"]}) != work["objects"] or \
            len({canonical(value) for value in work["added_ids"]}) != len(work["added_ids"]):
        raise ValueError("Stored topology/time does not match observed work")
    if work["steps"] != config["steps"] or sum(work["objects_by_scale"].values()) != work["objects"]:
        raise ValueError("Scientific step/object/scale work differs")
    if config["kind"] == "pb":
        if work["added_ids"]:
            raise ValueError("Original PB scaling unexpectedly grew organs")
        return
    if config["kind"] != "xp":
        raise ValueError("Only original PB/XP scientific cases are accepted")
    expected = dict(scene_count=1, palm_count=1, independent_replicas_per_sample=1,
        profile=config["profile"], scaling_axis=config["scaling_axis"],
        final_objects=work["objects"], added_objects=len(work["added_ids"]),
        actual_organ_counts=work["objects_by_scale"])
    if any(work.get(k) != v for k, v in expected.items()) or work["initial_objects"] < 1:
        raise ValueError("XP work is not one complete original-scene trajectory")
    parameter = work["parameter_provenance"]
    if parameter["profile"] != config["profile"] or parameter["initiation_age"] != 0 or parameter["architecture"] is not False:
        raise ValueError("XP parameter provenance differs from declared fixture")
    if config["profile"] == "accelerated":
        if parameter["phyllochron_effective"] != dict(initial=0.2, mature=0.2) or \
                parameter["parameter_changes"] != ["production_speed_initial", "production_speed_mature"] or not work["added_ids"]:
            raise ValueError("Accelerated XP profile lacks exact declared changes/actual growth")
    elif config["profile"] == "package_defaults":
        if parameter["parameter_changes"] or parameter["phyllochron_before"] != parameter["phyllochron_effective"]:
            raise ValueError("Package-default XP parameters were changed")
    else:
        raise ValueError("Unknown XP profile")
    expected_qualification = "no_observed_newborns" if not work["added_ids"] else "original_scientific_growth_observed"
    if work["growth_qualification"] != expected_qualification:
        raise ValueError("XP actual-growth qualification differs from added IDs")


def coverage_checks(coverage, work, config, arm):
    dispatch_arm = mapped_arm(arm)
    p = dispatch.policies(dispatch_arm)
    if p["trusted_index"] or coverage["dispatch_arm"] != dispatch_arm or coverage["dispatch_policies"] != p or \
            coverage.get("measurement_protocol") != dispatch.PROTOCOL:
        raise ValueError("Preparation arm changed ordinary-executor policy")
    prior.original_sequence_coverage(coverage, work, config, newborn=False)
    if coverage["sequence_policies"] != dict(mechanism="ordinary", bounded=p["bounded"],
            typed=False, underlying_arm=p["underlying_arm"]):
        raise ValueError("Binding program or numerical driver contaminated preparation case")
    if any(coverage[field] for field in ("native_fields", "driver_units", "native_driver_units")) or coverage.get("driver") is not None:
        raise ValueError("Preparation case entered an alternate scientific executor")
    if coverage["planner"].get("enabled") is not False or coverage["planner"].get("scene_entries") != 0:
        raise ValueError("Old planner-boundary candidate contaminated this round")
    if coverage.get("canonical_storage") != "ordinary_references" or coverage.get("scientific_kernels") != "original_unmodified":
        raise ValueError("Scientific kernels or reference storage changed")
    graph = coverage["graph_projection"]
    g = graph["counters"]
    prior.nonnegative(g)
    if graph["enabled"] is not p["graph"]:
        raise ValueError("Graph projection flag differs from arm")
    if p["graph"]:
        if not g["projections_completed"] > 0 or not g["rows_projected"] > 0:
            raise ValueError("Graph arm completed no actual relation tables")
    elif any(g.values()):
        raise ValueError("Graph work contaminated disabled control")
    if graph.get("cached_memberships") is not False or graph.get("cached_scientific_values") is not False:
        raise ValueError("Graph rows unexpectedly cache scientific values/memberships")
    require_growth = config["kind"] == "xp" and config.get("profile") == "accelerated"
    typed = dispatch.typed_counts(coverage["typed_output_preparation"], p["typed_output_preparation"], growth=require_growth)
    if p["typed_output_preparation"] and (typed["initial_objects_prepared"] <= 0 or typed["initial_applications_completed"] <= 0):
        raise ValueError("Typed arm has no initial preparation work")
    if config["kind"] == "pb" and (typed["growth_objects_prepared"] or typed["growth_applications_completed"]):
        raise ValueError("PB typed work incorrectly attributed to growth")
    u, e, v = dispatch.trusted_counts(coverage["trusted_execution_index"], False, growth=False)
    expected_aliases = dict(actual_graph={key: g[key] for key in
        ("projections_completed", "rows_projected", "edges_projected")},
        actual_typed_output=typed, actual_trusted_index=u,
        actual_trusted_fallback_epoch=e, actual_trusted_fallback_queries=v)
    if any(coverage[key] != value for key, value in expected_aliases.items()):
        raise ValueError("Actual completion aliases differ from source counters")
    if coverage.get("metadata_work_is_not_kernel_work") is not True or \
            coverage.get("ordinary_baseline") is not (dispatch_arm in ("ordinary_a", "ordinary_b")):
        raise ValueError("Metadata/baseline classification differs")
    if config["kind"] == "pb":
        if coverage.get("PB_preparation_protocol") != PB_PROTOCOL or coverage.get("expected_growth") is not False:
            raise ValueError("PB preparation protocol differs")
    else:
        if coverage.get("trajectory_arm") != arm or coverage.get("scene_count") != 1 or coverage.get("palm_count") != 1 or \
                coverage.get("profile") != config["profile"] or coverage.get("newborn_count") != len(work["added_ids"]) or \
                coverage.get("newborn_coverage_required") is not require_growth:
            raise ValueError("XP trajectory/growth coverage differs from actual work")
        qualification = "no_newborn_credit" if not work["added_ids"] else "actual_added_object_ids"
        if coverage["newborn_qualification"] != qualification:
            raise ValueError("XP newborn credit lacks matching current added IDs")
    return expected_aliases


def config_checks(config):
    if "batch_size" in config:
        raise ValueError("Replica-batch configuration cannot enter scalar-scene scaling")
    protocol = config.get("measurement_protocol")
    if protocol == PB_PROTOCOL:
        expected = dict(kind="pb", statistical_unit="one_fresh_PB_simulation", expected_growth=False,
            execution_scope="ordinary_executor_original_PB_hard_calls",
            preparation_scope="warm_methods_fresh_model_and_status_state",
            complete_cost_scope="construction_enablement_normal_preparation_and_execution",
            reference_identity_checks="separate_untimed_per_step_preservation_gate")
        if not 1 <= config["nobjects"] <= 256 or not 1 <= config["steps"] <= 8:
            raise ValueError("PB scaling outside declared staged dimensions")
    elif protocol == XP_PROTOCOL:
        expected = dict(kind="xp", statistical_unit="one_fresh_single_scene_trajectory",
            scene_count=1, palm_count=1, initiation_age=0, architecture=False,
            numerical_executor="ordinary", canonical_storage="ordinary_references",
            independent_replicas_per_sample=1) if "independent_replicas_per_sample" in config else dict(
            kind="xp", statistical_unit="one_fresh_single_scene_trajectory", scene_count=1, palm_count=1,
            initiation_age=0, architecture=False, numerical_executor="ordinary", canonical_storage="ordinary_references")
        expected.update(complete_cost_scope="construction_enablement_all_preparation_and_execution",
            forcing_file_read_timing="excluded_at_registration",
            initial_scene="one_original_Palm_constructor_without_synthetic_organs",
            scaling_axis="duration_and_realized_organs_in_one_original_scene")
        if config["days"] != config["steps"] or config["days"] not in (2,12,32,64,128):
            raise ValueError("Unknown staged XP duration")
        if config["days"] > 32 and config["allow_large"] is not True:
            raise ValueError("Larger XP trajectory lacks explicit opt-in")
        forcing = config["forcing"]
        if forcing["rows"] != config["days"] or forcing["source"] != "first_original_daily_rows" or forcing["copy_per_construction"] is not True:
            raise ValueError("XP forcing scope differs")
        if config["profile"] == "accelerated":
            if config["accelerated_emission_speed"] != 0.2 or config["fixture_role"] != "diagnostic_accelerated_growth":
                raise ValueError("Accelerated configuration differs")
        elif config["profile"] == "package_defaults":
            if config["accelerated_emission_speed"] is not None or config["fixture_role"] != "unchanged_package_parameter_defaults":
                raise ValueError("Default configuration changes phyllochron settings")
        else:
            raise ValueError("Unsupported XP scientific profile")
    else:
        raise ValueError("Only current PB/XP single-scene protocols can become timing evidence")
    if any(config.get(key) != value for key, value in expected.items()) or config.get("placebo_pair") != ["ordinary_a","ordinary_b"]:
        raise ValueError("Changed preparation/scientific/statistical scope")
    return protocol


def warm_summary(screen):
    config, samples, warmups = screen["config"], screen["samples"], screen["warmups"]
    protocol = config_checks(config)
    if not samples or screen["baseline"] != "ordinary_a":
        raise ValueError("Need ordinary scalar-scene baseline and nonempty samples")
    order = screen["orders"][0]
    if len(order) != len(set(order)) or not set(BASE_ARMS) <= set(order):
        raise ValueError("Both ordinary aliases, graph and typed-graph arms required")
    list(map(mapped_arm, order))
    if len(screen["orders"]) != screen["repetitions"] or screen["repetitions"] <= 0 or any(
            row != (order if i % 2 == 0 else order[::-1]) for i,row in enumerate(screen["orders"])):
        raise ValueError("Unbalanced forward/reverse cycles")
    if [(r["cycle"],r["variant"]) for r in samples] != [(i+1,arm) for i,cycle in enumerate(screen["orders"]) for arm in cycle]:
        raise ValueError("Sample order does not match declared cycles")
    if sorted(r["variant"] for r in warmups) != sorted(order):
        raise ValueError("Need one independent warmup per arm")
    if any(r["temperature"] != "warm" for r in samples) or any(r["temperature"] != "warmup" for r in warmups):
        raise ValueError("Incorrect warm sample temperature")
    all_rows = samples+warmups
    if len({r["process_id"] for r in all_rows}) != 1 or samples[0]["process_id"] != screen["provenance"]["process_id"]:
        raise ValueError("Warm cohort mixes Julia workers")
    policy_map = config.get("policies_by_arm", config.get("dispatch_policies_by_arm", {}))
    for row in all_rows:
        arm = row["variant"]
        if policy_map.get(arm) != dispatch.policies(mapped_arm(arm)):
            raise ValueError("Configured preparation policy differs from arm")
        if row["case"] != screen["case"] or canonical(row["config"]) != canonical(config) or row["digest"] != screen["expected_digest"] or \
                canonical(row["snapshot"]) != canonical(samples[0]["snapshot"]) or canonical(row["work"]) != canonical(samples[0]["work"]):
            raise ValueError("Full scene science/history/RNG/types/work/digest/config differs")
        science_checks(row["snapshot"],row["work"],config)
        phase_checks(row)
        coverage_checks(row["coverage"],row["work"],config,arm)
    indexed = {(r["cycle"],r["variant"]):r for r in samples}
    comparisons = []
    for control in order:
        for arm in order:
            if arm == control:
                continue
            paired = []
            for cycle in range(1,screen["repetitions"]+1):
                a,b = indexed[cycle,arm],indexed[cycle,control]
                ratios = {p:a["phases"][p]["seconds"]/b["phases"][p]["seconds"] for p in ("pse_preparation","execution")}
                ratios["complete"] = a["complete_seconds"]/b["complete_seconds"]
                paired.append(dict(cycle=cycle,**ratios))
            comparisons.append(dict(variant=arm,control=control,cycle_ratios=paired,
                medians={k:statistics.median(r[k] for r in paired) for k in ratios},
                ranges={k:[min(r[k] for r in paired),max(r[k] for r in paired)] for k in ratios},
                wins={k:sum(r[k]<1 for r in paired) for k in ratios}))
    rows = []
    for arm in order:
        selected = [r for r in samples if r["variant"]==arm]
        rows.append(dict(variant=arm,samples=len(selected),phases={p:dict(
            seconds=statistics.median(r["phases"][p]["seconds"] for r in selected),
            allocated_bytes=statistics.median(r["phases"][p]["allocated_bytes"] for r in selected)) for p in MODEL_PHASES},
            complete_seconds=statistics.median(r["complete_seconds"] for r in selected),
            complete_allocated_bytes=statistics.median(r["complete_allocated_bytes"] for r in selected),
            phase_events=prior.phase_events(selected),
            actual_work=[coverage_checks(r["coverage"],r["work"],config,arm) for r in selected]))
    return dict(case=screen["case"],kind=config["kind"],protocol=protocol,config=config,baseline="ordinary_a",
        repetitions=screen["repetitions"],orders=screen["orders"],expected_digest=screen["expected_digest"],
        sample_cohort_sha256=sha(canonical(samples)),warmup_cohort_sha256=sha(canonical(warmups)),
        scientific_work=samples[0]["work"],source_epoch=shared.source_epoch(screen),rows=rows,comparisons=comparisons,
        warmup_phase_events=prior.phase_events(warmups),statistical_unit="one_fresh_single_scene_not_batch_replica",
        reference_identity_evidence="separate_untimed_per_step_preservation_checks_not_added_to_product_timing",
        ratio_method="median_of_paired_cycle_ratios",old_results_used_as_current_baseline=False)


def cold_summary(data):
    worker, first, warm = data["worker"], data["record"], data["warm_companion"]
    config = first["config"]
    config_checks(config)
    kind, arm, pid = data["kind"], data["arm"], worker["pid"]
    if arm not in ("ordinary_a","bounded_graph","typed_graph") or config["kind"] != kind or \
            isinstance(pid,bool) or not isinstance(pid,int) or pid <= 0:
        raise ValueError("Unsupported first-use kind/arm/worker")
    freshness = worker["freshness"]
    if not all(freshness.get(k) is True for k in
            ("new_process","no_prior_case_execution","no_prior_ir_probe")) or freshness.get("pid") != pid or \
            freshness.get("previous_pid") == pid or pid in freshness.get("prior_pids",[]):
        raise ValueError("First-use worker lacks a fresh unrun PID attestation")
    if Path(worker["project"]).resolve() != (ROOT/"Project.toml").resolve():
        raise ValueError("Cold worker used a different active project")
    preload = worker["preimport"]
    for key in ("in_main","in_loaded_modules"):
        if set(preload[key]) != COLD_PACKAGES or not all(isinstance(v,bool) for v in preload[key].values()):
            raise ValueError("Incomplete package preimport facts")
        if any(preload[key].values()):
            raise ValueError("Cold controller requires scientific packages absent before imports")
    if preload.get("scope") != "facts_before_this_driver_imports_packages_not_a_claim_of_empty_disk_caches":
        raise ValueError("Preimport facts misrepresented as empty disk/package caches")
    for row, temperature in ((first,"first_use"),(warm,"warm_fresh_instance_after_first_case_and_diagnostics")):
        if row["arm"] != arm or row["temperature"] != temperature or canonical(row["config"]) != canonical(config):
            raise ValueError("First/warm config or arm differs")
        if row.get("complete_cost_scope") != "fresh_construction_enablement_pse_preparation_lowering_first_and_remaining_execution" or \
                row.get("diagnostic_timing") != "after_all_five_model_phases" or \
                row.get("scientific_executor") != "ordinary_PSE_with_original_downstream_models":
            raise ValueError("Cold model/diagnostic timing scope differs")
        phase_checks(row,COLD_MODEL_PHASES)
        science_checks(row["snapshot"],row["work"],config)
        coverage_checks(row["coverage"],row["work"],config,arm)
    if first["digest"] != warm["digest"] or canonical(first["snapshot"]) != canonical(warm["snapshot"]) or \
            canonical(first["work"]) != canonical(warm["work"]):
        raise ValueError("Cold/fresh-warm full science/history/RNG/types/work differ")
    parity = data["parity"]
    if not all(parity.get(key) is True for key in ("passed","full_snapshot_rng_history_types_equal","work_equal",
            "independent_models","canonical_status_types_equal","canonical_reference_types_equal",
            "cross_instance_statuses_disjoint","cross_instance_canonical_references_disjoint")) or \
            parity.get("reference_transition_scope") != "separate_per_step_feature_gates_no_preexecution_cold_probe":
        raise ValueError("Cold/fresh-warm posttiming Status/Ref independence proof incomplete")
    setup = data["setup_phases"]
    if set(setup) != {"package_imports","driver_load","case_registration"}:
        raise ValueError("Missing setup phase")
    for phase in [data["bootstrap_phase"],*setup.values()]:
        for key in ("seconds","allocated_bytes","gc_seconds","compilation_seconds","recompilation_seconds"):
            value=phase.get(key)
            if isinstance(value,bool) or not isinstance(value,(int,float)) or not math.isfinite(value) or value<0:
                raise ValueError("Invalid cold bootstrap/setup phase measurement")
    accounted = data["bootstrap_phase"]["seconds"]+sum(p["seconds"] for p in setup.values())+first["complete_seconds"]
    elapsed, overhead = data["first_use_elapsed_seconds"], data["unassigned_first_use_overhead_seconds"]
    if not all(isinstance(v,(int,float)) and not isinstance(v,bool) and math.isfinite(v) and v>=0
            for v in (accounted,elapsed,overhead)) or not math.isclose(accounted,data["accounted_first_use_phase_seconds"],rel_tol=1e-12,abs_tol=1e-9) or \
            elapsed+1e-6<accounted or not math.isclose(max(0,elapsed-accounted),overhead,rel_tol=1e-9,abs_tol=1e-9):
        raise ValueError("Inclusive first-use clock/accounted/unassigned overhead disagree")
    expected_scopes = dict(
        first_use_clock_scope="caller_before_driver_include_through_first_scientific_completion_excludes_Kaimon_startup",
        first_use_phase_accounting="bootstrap_plus_imports_definitions_registration_and_five_model_phases",
        warm_scope="one_new_independent_model_after_first_case_and_diagnostics_not_a_reused_timeline_or_steady_state_trial",
        source_image_verified_before_after=True)
    if any(data.get(k)!=v for k,v in expected_scopes.items()):
        raise ValueError("Cold clock/warm/source-verification scope differs")
    if data["setup_scope"] != dict(
            package_imports="common_PSE_PB_XP_PlantGeom_union_same_for_every_kind_and_arm",
            driver_load="experimental_definitions_and_model_descriptors_no_scientific_kernel_execution",
            case_registration="charged_inclusive_including_XP_weather_IO_and_registration_compilation",
            registered_warm_config_forcing_exclusion_overridden_by_charged_cold_registration=True):
        raise ValueError("Cold import/definition/forcing registration scope differs")
    if data["cache_state"] != dict(new_process_attested=True,normal_disk_and_package_caches_retained=True,
            environment_setup_outside_case=True,package_preload_facts_recorded=True):
        raise ValueError("Cold cache/setup facts differ")
    image=data["source_image"]
    if not COLD_REQUIRED_IMAGE<=set(image) or any(Path(p).is_absolute() or ".." in Path(p).parts or
            not isinstance(h,str) or len(h)!=64 or any(c not in "0123456789abcdef" for c in h) for p,h in image.items()):
        raise ValueError("Unsafe/incomplete cold source image")
    provenance=data["provenance"]
    if provenance["process_id"] != pid or provenance["julia"] != worker["julia"] or \
            Path(provenance["active_project"]).resolve() != Path(worker["project"]).resolve() or \
            provenance["active_project_sha256"] != image["Project.toml"] or provenance["active_manifest_sha256"] != image["Manifest.toml"]:
        raise ValueError("Cold worker/project/source provenance differs")
    return dict(kind=kind,arm=arm,pid=pid,config=config,freshness=freshness,preimport=preload,
        all_scientific_packages_unloaded_before_import=not any(v for key in ("in_main","in_loaded_modules") for v in preload[key].values()),
        first_use_elapsed_seconds=elapsed,accounted_first_use_phase_seconds=accounted,
        unassigned_first_use_overhead_seconds=overhead,bootstrap_phase=data["bootstrap_phase"],setup_phases=setup,
        model_first_use={k:first[k] for k in ("phases","complete_seconds","complete_allocated_bytes","complete_gc_seconds","digest","work","coverage")},
        fresh_warm_companion={k:warm[k] for k in ("phases","complete_seconds","complete_allocated_bytes","complete_gc_seconds","digest","work","coverage")},
        parity=parity,source_image=image,source_epoch=shared.source_epoch(dict(provenance=provenance)),
        record_sha256=sha(canonical(first)),config_sha256=sha(canonical(config)),
        interpretation="one_descriptive_first_use_pilot_with_separate_fresh_warm_companion_not_a_robust_median")


def cold_cpu_health(cpu_record):
    health=cpu_record["sampler_health"]
    if not all(health.get(key) is True for key in
            ("healthy","thread_entered","thread_exited","thread_stopped","initial_and_final_samples_required")) or \
            health.get("sampler_errors") != [] or health.get("sample_command_timeout_seconds") != 10 or \
            health.get("allowed_maximum_gap_seconds") != 15:
        raise ValueError("Cold CPU sampler was not healthy and bounded")
    observations=cpu_record["observations"]
    if len(observations)<2 or health.get("observations") != len(observations):
        raise ValueError("Cold CPU initial/final observations missing")
    times=[region_validation.utc(row["at"]).timestamp() for row in observations]
    gaps=[b-a for a,b in zip(times,times[1:])]
    largest=max(gaps,default=0)
    if any(gap<0 for gap in gaps) or largest>15 or not math.isclose(
            largest,health["maximum_observed_gap_seconds"],rel_tol=1e-9,abs_tol=1e-6):
        raise ValueError("Cold CPU sampler gap proof differs from observations")
    return health


def summarize(parsed, raw):
    bindings = shared.qualification_bindings(parsed,raw)
    regions = region_validation.adjudicated_regions(parsed,raw)
    warm, excluded, cold, checks, excluded_attempts, excluded_science = [],[],[],[],[],[]
    relocations={}
    for note_name,note in parsed.items():
        if "/" not in note_name and isinstance(note,dict) and {"original","retained_as","sha256","reason"}<=set(note):
            target=note["retained_as"]
            if target not in raw or sha(raw[target]) != note["sha256"] or target in relocations:
                raise ValueError("Missing, stale or duplicate excluded-artifact relocation binding")
            relocations[target]=dict(source=note_name,**note)
    for name,data in sorted(parsed.items()):
        if "/" in name:
            continue
        if name.startswith(("excluded-","failed-")):
            excluded_attempts.append(dict(source=name,raw_sha256=sha(raw[name]),
                interpretation="retained_failed_or_excluded_attempt_not_qualified_timing"))
            if isinstance(data,dict) and data.get("protocol")==COLD_PROTOCOL and "record" in data:
                if name in bindings:
                    raise ValueError("An explicitly excluded cold artifact cannot have timing qualification")
                try:
                    result=cold_summary(data)
                except (ValueError,KeyError) as error:
                    excluded_attempts[-1]["validation_error"]=str(error)
                else:
                    if name not in relocations:
                        raise ValueError("Scientifically validated excluded cold artifact lacks an exact relocation note")
                    excluded_science.append(dict(source=name,kind=result["kind"],arm=result["arm"],pid=result["pid"],
                        config=result["config"],config_sha256=result["config_sha256"],preimport=result["preimport"],parity=result["parity"],
                        digest=result["model_first_use"]["digest"],work=result["model_first_use"]["work"],
                        source_image=result["source_image"],record_sha256=result["record_sha256"],
                        relocation=relocations[name],scientific_validated=True,timing_qualified=False,
                        interpretation="science_parity_only_all_elapsed_costs_remain_raw_and_excluded_from_timing_summaries"))
            continue
        for location,value in shared.walk(data):
            if isinstance(value.get("samples"),list) and "baseline" in value and "orders" in value:
                result = warm_summary(value)
                cpu = shared.cpu_qualification(name,bindings)
                if not cpu["qualified"]:
                    cpu = regions.get((name,location),cpu)
                row = dict(source=name,location=location,cpu=cpu,**result)
                (warm if cpu["qualified"] else excluded).append(row)
            if value.get("protocol") == COLD_PROTOCOL and "record" in value:
                cpu = shared.cpu_qualification(name,bindings)
                try:
                    result = cold_summary(value)
                except (ValueError,KeyError) as error:
                    if cpu["qualified"]:
                        raise
                    excluded_attempts.append(dict(source=name,location=location,raw_sha256=sha(raw[name]),
                        interpretation="unqualified_cold_attempt_failed_schema_or_semantic_validation_raw_retained",
                        validation_error=str(error)))
                    continue
                if cpu["qualified"]:
                    if set(cpu.get("optional_evidence",{})) != {"script","receipt"}:
                        raise ValueError("Qualified cold artifact lacks exact script/completion receipt bindings")
                    cpu=dict(cpu,sampler_health=cold_cpu_health(parsed[cpu["record"]]))
                cold.append(dict(source=name,location=location,cpu=cpu,qualified_first_use=cpu["qualified"],**result))
            if isinstance(value.get("passed"),bool):
                checks.append(dict(source=name,location=location,**{key:shared.compact(value[key]) for key in
                    ("passed","kind","arm","case","config","work","test_counts","preservation_scope") if key in value}))
    unique,duplicates = {},[]
    for row in warm:
        key=row["sample_cohort_sha256"]
        if key in unique:
            duplicates.append(dict(source=row["source"],location=row["location"],canonical_source=unique[key]["source"],sample_cohort_sha256=key))
        else:
            unique[key]=row
    cold_unique,cold_duplicates={},[]
    for row in cold:
        key=row["record_sha256"]
        if key in cold_unique:
            original=cold_unique[key]
            if row["pid"] != original["pid"] or row["source_image"] != original["source_image"]:
                raise ValueError("Conflicting duplicated first-use record")
            cold_duplicates.append(dict(source=row["source"],location=row["location"],canonical_source=original["source"],record_sha256=key))
            if row["qualified_first_use"] and not original["qualified_first_use"]:
                cold_unique[key]=row
        else:
            cold_unique[key]=row
    cold=list(cold_unique.values())
    if len({r["pid"] for r in cold}) != len(cold):
        raise ValueError("One Julia PID supplied multiple distinct first-use pilots")
    cold_comparisons=[]
    for kind in ("pb","xp"):
        rows=[r for r in cold if r["kind"]==kind and r["qualified_first_use"]]
        if not rows:
            continue
        if len({r["arm"] for r in rows}) != len(rows):
            raise ValueError("Multiple first-use pilots per kind/arm require explicit new cohort separation")
        controls=[r for r in rows if r["arm"]=="ordinary_a"]
        if not controls:
            continue
        control=controls[0]
        for row in rows:
            if row["arm"]=="ordinary_a":
                continue
            if row["config_sha256"] != control["config_sha256"] or canonical(row["preimport"]) != canonical(control["preimport"]) or \
                    row["source_image"] != control["source_image"] or row["model_first_use"]["digest"] != control["model_first_use"]["digest"] or \
                    canonical(row["model_first_use"]["work"]) != canonical(control["model_first_use"]["work"]):
                raise ValueError("Cold comparison mixes science/config/preimport/source cohorts")
            cold_comparisons.append(dict(kind=kind,variant=row["arm"],control="ordinary_a",samples_per_arm=1,
                inclusive_first_use_ratio=row["first_use_elapsed_seconds"]/control["first_use_elapsed_seconds"],
                model_first_use_ratio=row["model_first_use"]["complete_seconds"]/control["model_first_use"]["complete_seconds"],
                first_use_preparation_ratio=row["model_first_use"]["phases"]["pse_preparation"]["seconds"]/control["model_first_use"]["phases"]["pse_preparation"]["seconds"],
                interpretation="one_descriptive_pilot_pair_not_a_robust_speedup_or_median"))
    for row in excluded_science:
        controls=[r for r in cold if r["kind"]==row["kind"] and r["arm"]=="ordinary_a" and r["qualified_first_use"]]
        if len(controls)!=1:
            raise ValueError("Excluded scientific completion lacks a unique qualified ordinary science control")
        control=controls[0]
        if row["config_sha256"]!=control["config_sha256"] or canonical(row["preimport"])!=canonical(control["preimport"]) or \
                row["source_image"]!=control["source_image"] or row["digest"]!=control["model_first_use"]["digest"] or \
                canonical(row["work"])!=canonical(control["model_first_use"]["work"]):
            raise ValueError("Excluded scientific completion mixes science/config/preimport/source cohorts")
    science_cells={(r["kind"],r["arm"]) for r in cold+excluded_science}
    qualified_cells={(r["kind"],r["arm"]) for r in cold if r["qualified_first_use"]}
    expected_cells={(k,a) for k in ("pb","xp") for a in ("ordinary_a","bounded_graph","typed_graph")}
    return dict(warm_screens=list(unique.values()),excluded_warm_screens=excluded,cold_pilots=cold,
        excluded_cold_scientific_results=excluded_science,
        qualified_first_use=[r for r in cold if r["qualified_first_use"]],duplicate_screen_exports=duplicates,
        duplicate_cold_exports=cold_duplicates,cold_descriptive_comparisons=cold_comparisons,
        cold_matrix_status=dict(expected=[dict(kind=k,arm=a) for k in ("pb","xp") for a in
            ("ordinary_a","bounded_graph","typed_graph")],
            qualified=[dict(kind=r["kind"],arm=r["arm"],pid=r["pid"]) for r in cold if r["qualified_first_use"]],
            scientific_completed=[dict(kind=k,arm=a) for k,a in sorted(science_cells)],
            scientific_complete=science_cells==expected_cells,
            qualified_timing_complete=qualified_cells==expected_cells,
            required_ordinary_vs_combined_pairs_qualified=all((k,a) in qualified_cells
                for k in ("pb","xp") for a in ("ordinary_a","typed_graph")),
            unqualified_timing_cells=[dict(kind=k,arm=a) for k,a in sorted(expected_cells-qualified_cells)],
            robust_median_claim=False),
        checks=checks,excluded_attempts=excluded_attempts,
        unparsed_raw_evidence=[dict(source=name,**value) for name,value in parsed.items()
            if isinstance(value,dict) and "_archive_parse_error" in value],
        old_results_used_as_current_baseline=False,
        limitations=["Preparation metadata completion is not optimized scientific-kernel work.",
            "PB has no organ growth; preparation and steady execution are separate.",
            "Package-default XP may have no newborns and receives no newborn optimization credit.",
            "One first-use pilot per kind/arm is descriptive, not a robust cold median.",
            "Fresh-instance A/A spread includes cache/OS/timer effects, not isolated timer noise.",
            "No million-organ, peak-RSS, AMAPSim or MAESPA scalability claim follows from these cases."])


def source_inputs():
    paths=set()
    for directory in ("src","ext","benchmark/native_downstream",
            "benchmark/compiled_regions","benchmark/generated_program"):
        pending=[ROOT/directory]
        while pending:
            parent=pending.pop()
            if parent.is_symlink() or not parent.is_dir():
                continue
            for path in sorted(parent.iterdir()):
                if path.is_symlink() or path.name in (".git","results"):
                    continue
                if path.is_dir():
                    pending.append(path)
                elif path.is_file() and path.suffix==".jl":
                    paths.add(path)
    paths.update(ROOT/name for name in ("Project.toml","Manifest.toml"))
    paths.update(Path(module.__file__).resolve() for module in (dispatch,prior,shared,region_validation))
    paths.add(Path(__file__).resolve())
    return {p.relative_to(ROOT).as_posix():p.read_bytes() for p in sorted(paths)}


def validate_manifests(parsed):
    for name,data in parsed.items():
        if "/" in name:
            continue
        for location,value in shared.walk(data):
            if not isinstance(value.get("files"),list) or "aggregate_sha256" not in value or "root" not in value:
                continue
            files=value["files"]
            if not all(isinstance(row,dict) and set(row)>={"path","sha256"} for row in files):
                raise ValueError("Malformed recorded source manifest")
            paths=[row["path"] for row in files]
            if paths != sorted(set(paths)) or any(Path(p).is_absolute() or ".." in Path(p).parts for p in paths):
                raise ValueError("Recorded source paths unsafe, duplicated or unordered")
            aggregate=sha("\n".join(row["path"]+"\0"+row["sha256"] for row in files).encode())
            if aggregate != value["aggregate_sha256"]:
                raise ValueError(f"Source manifest aggregate differs: {name}:{location}")


def scientific_sources(parsed,raw,current,summary):
    # The old primitive requires all three scientific packages for every old
    # qualified record. This round deliberately records PSE+PB or PSE+XP. Read
    # all exact source bytes with an empty qualified list, then check per kind.
    adapted={}
    for name,data in parsed.items():
        if "/" in name:
            continue
        found=[]
        for location,value in shared.walk(data):
            packages=[p for p in value.get("packages",[]) if isinstance(p,dict) and
                p.get("name") in COLD_PACKAGES and "root" in p and
                isinstance(p.get("sources",{}).get("files"),list)]
            node={key:value[key] for key in ("experimental_sources","source_manifest") if key in value}
            if packages:
                node["packages"]=packages
            if node:
                found.append(dict(original_location=location,**node))
        # Keep references to small provenance subtrees, not copies of every
        # scientific row in potentially large single-trajectory observations.
        adapted[name]=dict(provenance_records=found)
    original_packages=shared.SCIENTIFIC_PACKAGES
    try:
        # PlantGeom imports are deliberately included in every cold worker.
        shared.SCIENTIFIC_PACKAGES=original_packages|{"PlantGeom"}
        records,blobs=prior.scientific_sources(adapted,raw,current,dict(warm_screens=[],qualified_first_use=[]))
    finally:
        shared.SCIENTIFIC_PACKAGES=original_packages
    for row in summary["warm_screens"]+summary["qualified_first_use"]:
        required={"PlantSimEngine","PlantBiophysics" if row["kind"]=="pb" else "XPalm"}
        selected=[r for r in records if r["record"]==row["source"]]
        present={r["name"] for r in selected if r["files"]}
        if not required<=present or any(r["missing_exact_source_bytes"] for r in selected):
            raise ValueError("Qualified timing lacks exact required scientific/harness source bytes")
        if row in summary["qualified_first_use"] and not COLD_PACKAGES<=present:
            raise ValueError("Cold common union lacks exact PSE/PB/XP/PlantGeom source manifests")
    available={sha(value):value for value in [*raw.values(),*current.values(),*blobs.values()]}
    for row in summary["cold_pilots"]+summary["excluded_cold_scientific_results"]:
        missing=[name for name,key in row["source_image"].items() if key not in available]
        if missing and row.get("qualified_first_use"):
            raise ValueError("Qualified first-use source-image bytes are missing: "+str(missing))
        row["missing_exact_source_image_bytes"]=missing
        for key in row["source_image"].values():
            if key in available:
                blobs[key]=available[key]
    return records,blobs


def forcing_sources(summary,raw):
    available={sha(value):value for value in raw.values()}
    records=[];blobs={}
    for row in summary["warm_screens"]+summary["excluded_warm_screens"]+summary["cold_pilots"]:
        if row["kind"]!="xp":
            continue
        forcing=row["config"]["forcing"]
        key=forcing["sha256"]
        path=Path(forcing["path"])
        if key not in available and path.is_file():
            value=path.read_bytes()
            if sha(value)==key:
                available[key]=value
        qualified=row in summary["warm_screens"] or row.get("qualified_first_use") is True
        if key not in available and qualified:
            raise ValueError("Qualified XP forcing bytes are missing or changed: "+str(path))
        if key in available:
            blobs[key]=available[key]
        records.append(dict(source=row["source"],location=row["location"],path=str(path),
            sha256=key,requested_rows=forcing["rows"],full_file_captured=key in available,
            blob="forcing-blobs/"+key+".gz" if key in available else None,
            interpretation="exact_full_original_weather_file_requested_prefix_copied_per_simulation"))
    return records,blobs


def archive(raw,sources,scientific,blobs,forcing,forcing_blobs,summary):
    if DEST.exists():
        raise FileExistsError(f"Immutable archive already exists: {DEST}")
    DEST.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".preparation-scaling-",dir=DEST.parent) as temporary:
        stage=Path(temporary)/"preparation-scaling"
        stage.mkdir()
        manifest=[]
        def put(name,value,kind,origin):
            encoded=gzip.compress(value,mtime=0)
            if gzip.decompress(encoded)!=value:
                raise ValueError("Compression round-trip failed")
            path=stage/name
            path.parent.mkdir(parents=True,exist_ok=True)
            path.write_bytes(encoded)
            manifest.append(dict(kind=kind,origin=origin,artifact=name,raw_bytes=len(value),
                raw_sha256=sha(value),compressed_sha256=sha(encoded),encoding="gzip"))
        for name,value in sorted(raw.items()):
            put("raw/"+name+".gz",value,"raw_evidence",name)
        for name,value in sorted(sources.items()):
            put("qualified-source/"+name+".gz",value,"source_snapshot",name)
        for key,value in sorted(blobs.items()):
            put("source-blobs/"+key+".gz",value,"scientific_source_blob",key)
        for key,value in sorted(forcing_blobs.items()):
            put("forcing-blobs/"+key+".gz",value,"forcing_data_blob",key)
        for name,value in (("summary.json",summary),("scientific-provenance.json",scientific),
                ("forcing-provenance.json",forcing)):
            payload=json_bytes(value)
            (stage/name).write_bytes(payload)
            manifest.append(dict(kind="derived_metadata",origin=name,artifact=name,raw_bytes=len(payload),raw_sha256=sha(payload),encoding="identity"))
        for row in manifest:
            payload=(stage/row["artifact"]).read_bytes()
            if row["encoding"]=="gzip":
                if sha(payload)!=row["compressed_sha256"]:
                    raise ValueError("Written compressed bytes differ")
                payload=gzip.decompress(payload)
            if len(payload)!=row["raw_bytes"] or sha(payload)!=row["raw_sha256"]:
                raise ValueError("Written artifact round-trip differs")
        (stage/"manifest.json").write_bytes(json_bytes(sorted(manifest,key=lambda r:r["artifact"])))
        if raw!=inventory(SOURCE) or sources!=source_inputs():
            raise RuntimeError("Raw evidence/source changed while archiving")
        if DEST.exists():
            raise FileExistsError(DEST)
        stage.rename(DEST)


def self_test():
    """Mutation checks use copied current records; never alter raw evidence."""
    candidates=[]
    for path in sorted(SOURCE.glob("*.json")):
        if path.name.startswith(("failed-","excluded-")):
            continue
        value=json.loads(path.read_bytes())
        for _,item in shared.walk(value):
            if isinstance(item.get("samples"),list) and "orders" in item and "baseline" in item:
                candidates.append(item)
    if not candidates:
        raise ValueError("Self-test needs one complete current warm screen")
    screen=candidates[0]
    warm_summary(screen)
    rejected=[]
    for mutation in ("science","phase_sum","control_policy","batch_config","jit_counter"):
        changed=copy.deepcopy(screen)
        if mutation=="science":
            changed["samples"][0]["snapshot"]["scientific_rngs"]={"corrupt":True}
        elif mutation=="phase_sum":
            changed["samples"][0]["complete_seconds"]+=1
        elif mutation=="control_policy":
            control=next(r for r in changed["samples"] if r["variant"]=="ordinary_a")
            control["coverage"]["graph_projection"]["enabled"]=True
        elif mutation=="batch_config":
            changed["config"]["batch_size"]=8
        else:
            changed["samples"][0]["phases"]["execution"]["compilation_seconds"]=None
        try:
            warm_summary(changed)
        except (ValueError,KeyError):
            rejected.append(mutation)
        else:
            raise AssertionError(f"Invalid evidence was accepted: {mutation}")
    raw={"screen.json":b"{}","cpu.json":json_bytes(dict(qualified=True,observations=[dict(other_busy=[])]))}
    manifest=dict(artifacts=[dict(artifact="screen.json",artifact_sha256="0"*64,
        cpu_record="cpu.json",cpu_sha256=sha(raw["cpu.json"]))])
    parsed={"screen.json":{},"cpu.json":json.loads(raw["cpu.json"]),"qualification.json":manifest}
    try:
        shared.qualification_bindings(parsed,raw)
    except ValueError:
        rejected.append("stale_CPU_binding")
    else:
        raise AssertionError("Stale CPU qualification was accepted")
    return dict(passed=True,unmodified_warm_screen_accepted=True,rejected_mutations=rejected,
        raw_evidence_modified=False,archive_written=False)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    mode=parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check-only",action="store_true")
    mode.add_argument("--archive-frozen",action="store_true")
    mode.add_argument("--self-test",action="store_true")
    args=parser.parse_args()
    if args.self_test:
        print(json.dumps(self_test(),sort_keys=True))
        return
    if args.archive_frozen and DEST.exists():
        raise FileExistsError("Refusing immutable archive overwrite")
    raw=inventory(SOURCE)
    parsed=shared.documents(raw)
    validate_manifests(parsed)
    summary=summarize(parsed,raw)
    sources=source_inputs()
    scientific,blobs=scientific_sources(parsed,raw,sources,summary)
    forcing,forcing_blobs=forcing_sources(summary,raw)
    if raw!=inventory(SOURCE) or sources!=source_inputs():
        raise RuntimeError("Evidence/source changed during validation; retry after freeze")
    if args.archive_frozen:
        archive(raw,sources,scientific,blobs,forcing,forcing_blobs,summary)
    print(json.dumps(dict(archived=bool(args.archive_frozen),raw_files=len(raw),source_files=len(sources),
        scientific_source_blobs=len(blobs),qualified_warm_screens=len(summary["warm_screens"]),
        forcing_data_blobs=len(forcing_blobs),
        excluded_warm_screens=len(summary["excluded_warm_screens"]),cold_pilots=len(summary["cold_pilots"]),
        excluded_cold_scientific_records=len(summary["excluded_cold_scientific_results"]),
        cold_scientific_cells=len(summary["cold_matrix_status"]["scientific_completed"]),
        cold_scientific_complete=summary["cold_matrix_status"]["scientific_complete"],
        cold_timing_complete=summary["cold_matrix_status"]["qualified_timing_complete"],
        required_cold_pairs_qualified=summary["cold_matrix_status"]["required_ordinary_vs_combined_pairs_qualified"],
        qualified_first_use=len(summary["qualified_first_use"]),checks=len(summary["checks"]),
        lossless_roundtrip_verified=bool(args.archive_frozen)),sort_keys=True))


if __name__=="__main__":
    main()
