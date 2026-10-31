"""Validate and archive frozen newborn-binding evidence without starting Julia.

Use --check-only first. --archive-frozen creates a NEW immutable evidence folder;
it never overwrites one. Every input byte is preserved, including failed checks,
receipts, diagnostics, reproduction helpers and source-before-* snapshots.
Compact summaries are derived views, not substitutes for scientific snapshots.
Warm promotion requires actual newborn producer instructions for growing XP
and generic cases. Prepared instructions, initial-only work and from-status
work do not substitute for that evidence. No Julia or inference is run here.
"""

from pathlib import Path
import argparse
import gzip
import hashlib
import json
import math
import re
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "benchmark/native_downstream/results/newborn-binding"
DEST = Path(__file__).resolve().parent / "evidence/newborn-bindings"
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
        try:
            if name.endswith(".json"):
                parsed[name] = json.loads(raw)
            elif name.endswith(".jsonl"):
                for line in raw.splitlines():
                    if line.strip():
                        json.loads(line)
        except (ValueError, UnicodeError) as error:
            # Interrupted/failed attempts remain lossless raw evidence. They
            # cannot become a timing record through a qualification binding.
            parsed[name] = dict(_archive_parse_error=str(error),
                _raw_sha256=sha(raw), interpretation="raw_only_unparsed_evidence")
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
        if any(isinstance(parsed[name], dict) and "_archive_parse_error" in parsed[name]
                for name in (artifact, cpu_name)):
            raise ValueError("Malformed raw evidence cannot be CPU-qualified")
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


def source_epoch(screen):
    """Bind a case to its recorded source cohort, without pooling other cohorts."""
    provenance = screen.get("provenance", {})
    packages = [{key: item.get(key) for key in ("name", "path", "revision")}
        | {"source_manifest_sha256": item.get("sources", {}).get("aggregate_sha256")}
        for item in provenance.get("packages", [])]
    projection = {key: provenance.get(key) for key in
        ("julia", "active_project", "active_project_sha256", "active_manifest_sha256")}
    projection.update(packages=packages,
        harness_sha256=provenance.get("harness", {}).get("aggregate_sha256"),
        experimental_sources_sha256=provenance.get("experimental_sources", {}).get("aggregate_sha256"))
    return dict(sha256=sha(canonical(projection)), recorded=projection,
        process_id=provenance.get("process_id"),
        interpretation="recorded_per_screen_source_cohort_not_independently_reinferred_types")


def validate_phase_sums(sample):
    phases = sample["phases"]
    for name, phase in phases.items():
        seconds = phase["seconds"]
        if not isinstance(seconds, (int, float)) or not math.isfinite(seconds) or seconds < 0:
            raise ValueError(f"Invalid phase time: {name}")
        if phase.get("allocated_bytes", 0) < 0:
            raise ValueError(f"Invalid phase allocation count: {name}")
    if not math.isclose(sum(phase["seconds"] for phase in phases.values()),
            sample["complete_seconds"], rel_tol=1e-12, abs_tol=1e-9):
        raise ValueError("Complete cost omits or duplicates a recorded phase")
    if "complete_allocated_bytes" in sample and sum(
            phase["allocated_bytes"] for phase in phases.values()) != sample["complete_allocated_bytes"]:
        raise ValueError("Complete allocations do not equal phase sum")


def base_binding_coverage(sample, config):
    """Revalidate actual counters, source-proof protocol and independent flags."""
    coverage = sample["coverage"]
    arm = sample.get("variant", sample.get("arm"))
    policy = coverage["binding_policies"]
    expected = config.get("binding_policies_by_arm", {}).get(arm, policy)
    if canonical(policy) != canonical(expected):
        raise ValueError("Enabled binding policies differ from case configuration")
    if coverage.get("binding_arm") != arm:
        raise ValueError("Binding coverage names a different arm")
    program, counters = coverage["binding_program"], coverage["binding_program"]["counters"]
    if program.get("enabled") is not policy["instructions"]:
        raise ValueError("Instruction flag/control contamination")
    executed = counters["instruction_executions"]
    born = counters["newborn_positive_executions"]
    producer_born = counters["newborn_producer_executions"]
    for value in counters.values():
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise ValueError("Instruction counters must be nonnegative actual integers")
    if counters["synthesized_bindings"] != executed or sum(counters[key] for key in
            ("initial_positive_executions", "existing_positive_executions", "newborn_positive_executions")) != executed:
        raise ValueError("Completed instruction counters are inconsistent")
    if counters["newborn_status_executions"] + producer_born != born:
        raise ValueError("Newborn status/producer split is inconsistent")
    if counters["status_instruction_executions"] + counters["producer_instruction_executions"] != executed:
        raise ValueError("Status/producer instruction split is inconsistent")
    if counters["newborn_targeted_executions"] + counters["newborn_global_refresh_executions"] != born:
        raise ValueError("Newborn targeted/global-refresh split is inconsistent")
    if sum(row["executions"] for row in program["per_input"]) != executed:
        raise ValueError("Per-input execution totals differ from completed instructions")
    if not policy["instructions"] and any(counters.values()):
        raise ValueError("Disabled control contains instruction work")
    required = config.get("require_actual_newborn_instruction", config.get("kind") in ("xp", "generic"))
    if policy["instructions"] and required:
        if not (executed > 0 and born > 0 and producer_born > 0):
            raise ValueError("Growing candidate lacks actual newborn producer instruction work")
        if not sample["work"].get("added_ids"):
            raise ValueError("Growing instruction candidate has no actual additions")
    for field, count in (("actual_binding_instructions", executed),
            ("actual_newborn_binding_instructions", born),
            ("actual_newborn_producer_instructions", producer_born)):
        if coverage.get(field) != count:
            raise ValueError(f"Public coverage differs from backend actual counter: {field}")
    if coverage.get("newborn_producer_coverage") != "actual_completion_counter":
        raise ValueError("Producer-newborn work was inferred rather than counted")
    if counters["producer_instruction_executions"] > 0:
        if counters["declaration_proofs_built"] <= 0:
            raise ValueError("Producer execution lacks a built declaration certificate")
        if program.get("declaration_safety") != "concrete_output_names_and_strict_consistent_effect_free_nothrow_proof":
            raise ValueError("Unrecognized declaration-certificate protocol")
        if program.get("policy_safety") != "explicit_HoldLast_or_core_default_output_policy_only":
            raise ValueError("Unrecognized source-policy certificate protocol")
        if program.get("program_scope") != "weak_logical_application_identity_per_full_compilation":
            raise ValueError("Unrecognized logical application source epoch")
    if any(program.get(field) is not False for field in
            ("cached_bindings", "cached_source_membership", "cached_defaults")):
        raise ValueError("Instruction protocol unexpectedly caches live binding data")
    bounded = coverage["bounded"]
    if bounded["enabled"] is not policy["bounded"] or bool(bounded["scene_entries"]) is not policy["bounded"]:
        raise ValueError("Bounded metadata policy/control contamination")
    if coverage.get("metadata_work_is_not_kernel_work") is not True:
        raise ValueError("Metadata and numerical work are not distinguished")
    if policy["typed"] and config.get("kind") == "pb" and coverage["driver_units"] <= 0:
        raise ValueError("PB typed arm executed no actual numerical batch")
    return dict(executed=executed, newborn=born, newborn_producers=producer_born,
        newborn_targeted=counters["newborn_targeted_executions"],
        newborn_global_refresh=counters["newborn_global_refresh_executions"],
        numerical_batch_entries=coverage["driver_units"],
        initial_preparation_instruction_completions=counters["initial_positive_executions"],
        runtime_binding_instruction_completions=born + counters["existing_positive_executions"],
        newborn_producer_optimization_credit=producer_born > 0,
        proof_interpretation="reported_certificate_protocol_plus_archived_source_not_Python_reinference")


ACTUAL_FIELDS = ("instruction_executions", "synthesized_bindings",
    "newborn_positive_executions", "initial_positive_executions", "existing_positive_executions",
    "producer_instruction_executions", "status_instruction_executions",
    "newborn_producer_executions", "newborn_status_executions",
    "newborn_targeted_executions", "newborn_global_refresh_executions")


def actual_partition(report, details):
    counts = report["counters"]
    if any(not isinstance(v, int) or isinstance(v, bool) or v < 0 for v in counts.values()):
        raise ValueError("Non-integer or negative sequence/base counter")
    actual = {key: counts[key] for key in ACTUAL_FIELDS}
    completed = actual["instruction_executions"]
    equalities = (
        actual["synthesized_bindings"],
        sum(actual[k] for k in ("newborn_positive_executions", "initial_positive_executions", "existing_positive_executions")),
        actual["producer_instruction_executions"] + actual["status_instruction_executions"],
    )
    if any(value != completed for value in equalities):
        raise ValueError("Actual sequence/base completion partitions disagree")
    born = actual["newborn_positive_executions"]
    if actual["newborn_producer_executions"] + actual["newborn_status_executions"] != born or \
            actual["newborn_targeted_executions"] + actual["newborn_global_refresh_executions"] != born:
        raise ValueError("Actual sequence/base newborn partitions disagree")
    if details:
        if sum(row["executions"] for row in report["per_input"]) != completed:
            raise ValueError("Detailed sequence/base per-input totals disagree")
    elif report["per_input"] or report["misses"]:
        raise ValueError("Detailed dictionaries populated despite details=false")
    return actual


def sequence_binding_coverage(sample, config):
    coverage = sample["coverage"]
    arm = sample.get("variant", sample.get("arm"))
    policy = coverage["sequence_policies"]
    expected = config.get("sequence_policies_by_arm", {}).get(arm, policy)
    if canonical(policy) != canonical(expected) or coverage.get("sequence_arm") != arm:
        raise ValueError("Sequence policy differs from registered arm")
    protocol = "base_vs_consumer_sequence_v1"
    if config.get("measurement_protocol") != protocol or coverage.get("measurement_protocol") != protocol:
        raise ValueError("Unrecognized sequence measurement protocol")
    if config.get("shared_world_cache") is not False or coverage.get("declaration_cache_scope") != \
            "fresh_model_program_state_no_shared_world_cache":
        raise ValueError("Unexpected shared declaration cache in sequence cohort")
    base, sequence = coverage["base_program"], coverage["sequence_program"]
    if canonical(base) != canonical(sequence["base_program"]):
        raise ValueError("Sequence embedded base report differs from separately reported base")
    if config.get("sequence_details") is not False or coverage.get("sequence_details") is not False or \
            sequence.get("details_enabled") is not False:
        raise ValueError("Normal timing must use fixed counters with detailed instrumentation disabled")
    if sequence.get("counter_scope") != "actual_fixed_aggregate_counts_with_optional_detail_dictionaries":
        raise ValueError("Unrecognized fixed-counter scope")
    a, b = actual_partition(base, True), actual_partition(sequence, False)
    total = {key: a[key] + b[key] for key in ACTUAL_FIELDS}
    for key, value in (("base_actual", a), ("sequence_actual", b), ("total_actual", total)):
        if canonical(coverage.get(key)) != canonical(value):
            raise ValueError(f"Separate actual-counter accounting differs: {key}")
    if coverage.get("counter_accounting") != "base_actual_plus_sequence_actual_once_not_embedded_base_twice":
        raise ValueError("Missing explicit no-double-counting convention")
    if coverage.get("actual_newborn_producer_instructions") != total["newborn_producer_executions"] or \
            coverage.get("actual_sequence_newborn_producer_instructions") != b["newborn_producer_executions"]:
        raise ValueError("Public producer-newborn counters disagree with namespaces")
    mechanism = policy["mechanism"]
    if mechanism == "ordinary":
        if base["enabled"] or sequence["enabled"] or any(base["counters"].values()) or any(sequence["counters"].values()):
            raise ValueError("Instruction policy contaminated sequence-cohort ordinary control")
    elif mechanism == "base":
        if not base["enabled"] or sequence["enabled"] or any(sequence["counters"].values()):
            raise ValueError("Base arm is missing or contaminated by sequence work")
    elif mechanism == "sequence":
        if not base["enabled"] or not sequence["enabled"]:
            raise ValueError("Sequence/base preparation missing")
    else:
        raise ValueError("Unknown sequence mechanism")
    required = config.get("require_actual_newborn_instruction", config.get("kind") in ("xp", "generic"))
    if required and mechanism != "ordinary":
        own = b if mechanism == "sequence" else a
        if own["newborn_producer_executions"] <= 0 or not sample["work"].get("added_ids"):
            raise ValueError("Candidate has no OWN actual producer instruction on newborn consumers")
        if mechanism == "sequence" and sequence["counters"]["consumer_program_executions"] <= 0:
            raise ValueError("Sequence entered no consumer program")
    if total["producer_instruction_executions"] > 0:
        if base["counters"]["declaration_proofs_built"] <= 0 or base.get("declaration_safety") != \
                "concrete_output_names_and_strict_consistent_effect_free_nothrow_proof" or \
                base.get("policy_safety") != "explicit_HoldLast_or_core_default_output_policy_only":
            raise ValueError("Sequence producer execution lacks recognized base type/effect certificate")
        if base.get("program_scope") != "weak_logical_application_identity_per_full_compilation":
            raise ValueError("Unrecognized base source epoch")
    for report in (base, sequence):
        if any(report.get(key) is not False for key in
                ("cached_bindings", "cached_source_membership", "cached_defaults")):
            raise ValueError("Sequence/base unexpectedly caches live binding data")
    if sequence.get("sequence_scope") != "weak_logical_application_identity_per_full_compilation":
        raise ValueError("Unrecognized sequence source epoch")
    bounded = coverage["bounded"]
    if bounded["enabled"] is not policy["bounded"] or bool(bounded["scene_entries"]) is not policy["bounded"]:
        raise ValueError("Bounded flag/control contamination in sequence cohort")
    if coverage.get("metadata_work_is_not_kernel_work") is not True:
        raise ValueError("Sequence metadata credited as numerical work")
    if policy["typed"] and config.get("kind") == "pb" and coverage["driver_units"] <= 0:
        raise ValueError("PB typed sequence control entered no numerical batch")
    return dict(protocol=protocol, base=a, sequence=b, total=total,
        numerical_batch_entries=coverage["driver_units"],
        own_sequence_newborn_producer_credit=b["newborn_producer_executions"] > 0,
        details_enabled=False,
        proof_interpretation="reported_base_type_effect_certificates_and_separate_sequence_counts_not_Python_reinference")


def binding_coverage(sample, config):
    if "sequence_policies" in sample["coverage"]:
        return sequence_binding_coverage(sample, config)
    return base_binding_coverage(sample, config)


def warm_summary(screen):
    samples, warmups = screen["samples"], screen.get("warmups", [])
    if not samples:
        raise ValueError("Empty warm screen")
    expected = screen["expected_digest"]
    if any(row["digest"] != expected for row in samples + warmups):
        raise ValueError("Scientific digest mismatch")
    if any(canonical(row["snapshot"]) != canonical(samples[0]["snapshot"]) or
           canonical(row["work"]) != canonical(samples[0]["work"])
           for row in samples + warmups):
        raise ValueError("Stored scientific/RNG snapshot or work differs")
    for row in samples + warmups:
        if canonical(row["config"]) != canonical(screen["config"]):
            raise ValueError("Sample config differs from registered case")
        if row["case"] != screen["case"]:
            raise ValueError("Sample identifies a different case")
        validate_phase_sums(row)
        if set(row["phases"]) != {"construction", "pse_preparation", "backend_lowering", "execution"}:
            raise ValueError("Warm comparison lacks explicit normal preparation/lowering cost")
        binding_coverage(row, screen["config"])
    first_order = screen["orders"][0]
    if len(first_order) != len(set(first_order)) or screen["baseline"] not in first_order:
        raise ValueError("Duplicate arm or absent ordinary baseline")
    if len(screen["orders"]) != screen["repetitions"] or screen["repetitions"] <= 0:
        raise ValueError("Incorrect recorded repetition count")
    if sorted(row["variant"] for row in warmups) != sorted(first_order):
        raise ValueError("Need exactly one independent warmup per arm")
    if any(row.get("temperature") != "warm" for row in samples) or any(
            row.get("temperature") != "warmup" for row in warmups):
        raise ValueError("Warm samples/warmups are mislabeled")
    pids = {row["process_id"] for row in samples + warmups}
    if len(pids) != 1 or next(iter(pids)) != screen["provenance"]["process_id"]:
        raise ValueError("Warm source cohort mixes recorded workers")
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
            phases={name: dict(seconds=statistics.median(x["phases"][name]["seconds"] for x in selected),
                allocated_bytes=statistics.median(x["phases"][name]["allocated_bytes"] for x in selected))
                for name in selected[0]["phases"]},
            phase_counter_availability={key: all(isinstance(phase.get(key), (int, float))
                for x in selected for phase in x["phases"].values()) for key in
                ("compilation_seconds", "recompilation_seconds", "gc_seconds")},
            phase_events=events, coverage=[compact(x["coverage"]) for x in selected],
            actual_instruction_work=[binding_coverage(x, screen["config"]) for x in selected],
            retained=[compact(x.get("retained")) for x in selected]))
    indexed = {(x["cycle"], x["variant"]): x for x in samples}
    comparisons = []
    for control_arm in first_order:
        if control_arm not in (screen["baseline"], "bounded_preparation", "typed_driver", "bounded_typed"):
            continue
        for arm in first_order:
            if arm == control_arm:
                continue
            paired = []
            for cycle in range(1, screen["repetitions"] + 1):
                a, c = indexed[cycle, arm], indexed[cycle, control_arm]
                paired.append(dict(cycle=cycle,
                    execution=a["phases"]["execution"]["seconds"] / c["phases"]["execution"]["seconds"],
                    preparation=a["phases"]["pse_preparation"]["seconds"] / c["phases"]["pse_preparation"]["seconds"],
                    complete=a["complete_seconds"] / c["complete_seconds"]))
            comparisons.append(dict(variant=arm, control=control_arm, cycle_ratios=paired,
                medians={key: statistics.median(x[key] for x in paired)
                    for key in ("execution", "preparation", "complete")},
                wins={key: sum(x[key] < 1 for x in paired)
                    for key in ("execution", "preparation", "complete")}))
    return dict(case=screen["case"], config=screen["config"], baseline=screen["baseline"],
        measurement_protocol=screen["config"].get("measurement_protocol", "per_binding_program_v1"),
        repetitions=screen["repetitions"], orders=screen["orders"], expected_digest=expected,
        sample_cohort_sha256=sha(canonical(samples)), warmup_cohort_sha256=sha(canonical(warmups)),
        rows=rows, comparisons=comparisons, source_epoch=source_epoch(screen),
        verification="stored_snapshots_RNG_work_digests_and_order_agree",
        complete_cost_scope="construction_enablement_normal_preparation_lowering_execution_phase_sum",
        ratio_method="median_of_paired_cycle_ratios_not_ratio_of_independent_medians")


def cold_summary(data, cpu):
    record = data["record"]
    freshness = record.get("freshness") or record.get("config", {}).get("freshness") or {}
    pid = record.get("pid", record.get("process_id"))
    fresh = all(freshness.get(key) is True for key in
        ("new_process", "no_prior_case_execution", "no_prior_ir_probe"))
    fresh = fresh and freshness.get("pid") == pid and freshness.get("previous_pid") != pid
    phases = record["phases"]
    validate_phase_sums(record)
    if record.get("temperature") != "first_use":
        raise ValueError("Cold record is not labeled first_use")
    work = binding_coverage(record, record["config"])
    return dict(kind=record["config"].get("kind"), arm=record.get("arm", record.get("variant")), pid=pid,
        qualified_first_use=fresh and cpu["qualified"], freshness=freshness, cpu=cpu,
        config=record["config"], phases=phases, complete_seconds=record["complete_seconds"],
        complete_allocated_bytes=record.get("complete_allocated_bytes"),
        digest=record["digest"], work=compact(record["work"]), coverage=compact(record["coverage"]),
        actual_instruction_work=work,
        loader_seconds=data.get("loader_seconds"), loader_scope=data.get("loader_scope"),
        external_import_seconds=data.get("external_import_seconds"), source_image=data.get("source_image"),
        source_epoch=source_epoch(data),
        interpretation="single_first_use_observation_not_a_paired_warm_ratio")


def summarize(parsed, raw_files):
    warm, excluded, checks, profiles, cold = [], [], [], [], []
    bindings = qualification_bindings(parsed, raw_files)
    for name, data in sorted(parsed.items()):
        if "/" in name:
            continue
        if isinstance(data, dict) and isinstance(data.get("record"), dict) and \
                isinstance(data["record"].get("phases"), dict):
            cold.append(dict(source=name, **cold_summary(data, cpu_qualification(name, bindings))))
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
    qualified_cold = [row for row in cold if row["qualified_first_use"]]
    if len({row["pid"] for row in qualified_cold}) != len(qualified_cold):
        raise ValueError("Qualified cold cases require distinct workers")
    groups = {}
    for row in qualified_cold:
        config = {key: row["config"].get(key) for key in
            ("kind", "steps", "nobjects", "additions", "seed", "emission_speed", "outputs")}
        groups.setdefault(canonical(dict(config=config,
            source_epoch=row["source_epoch"]["sha256"], source_image=row["source_image"])), []).append(row)
    for group in groups.values():
        if any(row["digest"] != group[0]["digest"] or row["work"] != group[0]["work"] for row in group):
            raise ValueError("Qualified cold scientific digest/work differs")
    unparsed = [dict(source=name, **value) for name, value in parsed.items()
        if isinstance(value, dict) and "_archive_parse_error" in value]
    return dict(warm_screens=list(unique.values()), duplicate_screen_exports=duplicates, cold=cold,
        qualified_first_use=qualified_cold,
        excluded_warm_screens=excluded, checks=checks, diagnostics=profiles,
        unparsed_raw_evidence=unparsed,
        scope="independent_binding_instructions_bounded_metadata_and_typed_driver_with_actual_newborn_producer_work",
        limitations=["Allocation sampling byte estimates do not establish a causal speedup.",
            "Allocation volume is not retained memory or peak RSS.",
            "Type/effect certificates are reported protocol plus exact source, not independently rerun by Python.",
            "Per-binding and consumer-sequence cohorts retain separate source epochs and protocols.",
            "A static PB driver benefit is not a newborn binding instruction benefit.",
            "Targeted gates are not a completed full regression suite."])


def source_inputs():
    paths = set((ROOT / "src").rglob("*.jl"))
    paths.update(ROOT / name for name in ("Project.toml", "Manifest.toml"))
    native = ROOT / "benchmark/native_downstream"
    pending = list(native.glob("newborn_binding*.jl")) + [native / name for name in
        ("direct_planner_fixtures.jl", "direct_planner_measurements.jl", "load_direct_planner_experiment.jl",
         "growth_input_reuse_checks.jl", "load_growth_input_experiment.jl")]
    pending.extend(native.glob("load_newborn_binding*.jl"))
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
    qualified_records = {x["source"] for x in summary["warm_screens"] + summary["qualified_first_use"]}
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
    with tempfile.TemporaryDirectory(prefix=".newborn-bindings-", dir=DEST.parent) as temporary:
        stage = Path(temporary) / "newborn-bindings"
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
        qualified_first_use=len(summary["qualified_first_use"]),
        excluded_warm_screens=len(summary["excluded_warm_screens"]), checks=len(summary["checks"]),
        unparsed_raw_evidence=len(summary["unparsed_raw_evidence"])), sort_keys=True))


if __name__ == "__main__":
    main()
