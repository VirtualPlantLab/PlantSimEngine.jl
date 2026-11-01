"""Validate frozen AMAPSim, MAESPA and coupled preparation-only evidence.

Python only: this script neither launches Julia nor runs any scientific model.
Default/--check-only prints a derived report; --archive-frozen creates a new,
lossless source/evidence archive and refuses to overwrite an existing archive.
Unrelated original checkout diffs are represented by hashes, not republished.
"""

from pathlib import Path
import argparse
import gzip
import json
import math
import re
import statistics
import tempfile

import summarize_cached_owner as previous

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "benchmark/native_downstream/results/ecosystem-qualification"
DEST = Path(__file__).resolve().parent / "evidence/ecosystem-qualification"
shared = previous.shared
shared.SOURCE = SOURCE
sha, canonical, json_bytes = previous.sha, previous.canonical, previous.json_bytes
inventory, number, ratio = previous.inventory, previous.number, previous.ratio
PROTOCOL = "ecosystem_preparation_qualification_v1"
ARMS = ("ordinary_a", "ordinary_b", "graph_only", "prep_candidate")
REFERENCES = ("ordinary_a", "graph_only")
KINDS = {"amapsim", "maespa", "coupled"}
PHASES = previous.PHASES
COSTS = previous.COSTS
BP_COUNTS = ("scene_entries", "scene_shells", "scenario_plans", "metadata_sequences",
    "metadata_id_sequences", "metadata_symbol_tables", "metadata_schedules", "selector_indexes", "maximum_table_entries")
CLOCK_OUTPUTS = [["native_radiation", "geometry_seconds"], ["native_radiation", "light_seconds"]]


def apply_exact_unified_patch(before, patch, relative):
    """Apply one textual file patch in memory, checking every original byte.

    No patch command or external source mutation is performed. Context/removal
    lines and declared hunk ranges must match exactly; extra file patches and
    malformed/truncated hunks are rejected rather than ignored.
    """
    original = before.decode("utf8").splitlines(keepends=True)
    lines = patch.decode("utf8").splitlines(keepends=True)
    index = 0
    while index < len(lines) and lines[index].startswith(("diff --git ", "index ")):
        index += 1
    expected = ("--- a/" + relative, "+++ b/" + relative)
    if index + 1 >= len(lines) or tuple(line.rstrip("\r\n") for line in lines[index:index+2]) != expected:
        raise ValueError("Compatibility patch must name exactly its declared source file")
    index += 2
    cursor, output, hunks = 0, [], 0
    while index < len(lines):
        match = re.fullmatch(r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@[^\n]*\n?", lines[index])
        if not match:
            raise ValueError("Unexpected extra file or malformed compatibility patch hunk")
        old_start, old_count, new_start, new_count = (int(value) if value is not None else 1 for value in match.groups())
        start = old_start - 1 if old_count else old_start
        if start < cursor or start > len(original):
            raise ValueError("Compatibility patch hunk overlaps or escapes original source")
        output.extend(original[cursor:start]);cursor = start
        expected_new_start = new_start - 1 if new_count else new_start
        if len(output) != expected_new_start:
            raise ValueError("Compatibility patch new hunk position differs")
        removed, added = 0, 0
        index += 1
        while index < len(lines) and not lines[index].startswith("@@ "):
            line = lines[index]
            if not line or line[0] not in " +-":
                raise ValueError("Compatibility patch has an unsupported hunk line")
            tag, text = line[0], line[1:]
            index += 1
            if index < len(lines) and lines[index].startswith("\\ No newline at end of file"):
                text = text.removesuffix("\n");index += 1
            if tag in " -":
                if cursor >= len(original) or original[cursor] != text:
                    raise ValueError("Compatibility patch context/removal does not match exact original bytes")
                cursor += 1;removed += 1
            if tag in " +":
                output.append(text);added += 1
        if removed != old_count or added != new_count:
            raise ValueError("Compatibility patch hunk length differs")
        hunks += 1
    if hunks == 0:
        raise ValueError("Empty compatibility patch")
    output.extend(original[cursor:])
    return "".join(output).encode("utf8")


def compatibility_patches(freeze, raw):
    result = {}
    for row in freeze.get("applied_patches", []):
        key = row["package"], row["path"]
        relative = Path(row["path"])
        if key in result or row["package"] not in freeze["packages"] or relative.is_absolute() or \
                ".." in relative.parts or row["path"] == "Manifest.toml":
            raise ValueError("Duplicate/unsafe/unknown frozen compatibility patch")
        for name in ("before_sha256", "after_sha256", "patch_sha256"):
            if not re.fullmatch(r"[0-9a-f]{64}", row[name]):
                raise ValueError("Malformed compatibility patch checksum")
        for artifact in (row["before_artifact"], row["patch_artifact"]):
            path = Path(artifact)
            if path.is_absolute() or ".." in path.parts or artifact not in raw:
                raise ValueError("Missing or unsafe exact compatibility patch evidence")
        before, patch = raw[row["before_artifact"]], raw[row["patch_artifact"]]
        if sha(before) != row["before_sha256"] or sha(patch) != row["patch_sha256"]:
            raise ValueError("Frozen compatibility before/patch bytes differ from declared checksums")
        after = apply_exact_unified_patch(before, patch, row["path"])
        if sha(after) != row["after_sha256"]:
            raise ValueError("Compatibility patch does not yield exact declared after bytes")
        package = freeze["packages"][row["package"]]
        if package["source_files"].get(row["path"]) != row["before_sha256"] or \
                package["frozen_files"].get(row["path"]) != row["after_sha256"]:
            raise ValueError("Compatibility patch does not bridge original and frozen source inventories")
        result[key] = dict(row, exact_patch_application_verified=True,
            original_bytes_present_in_raw_evidence=True, after_bytes_present_in_frozen_source=True)
    return result


def source_inputs():
    current = previous.source_inputs()
    current[Path(__file__).resolve().relative_to(ROOT).as_posix()] = Path(__file__).read_bytes()
    return dict(sorted(current.items()))


def policy(arm):
    if arm not in ARMS:
        raise ValueError(f"Unknown ecosystem arm: {arm}")
    selected = arm in ("graph_only", "prep_candidate")
    return dict(bounded=selected, graph=selected, typed_output=arm == "prep_candidate")


def counter_partition(report, attempts, completed):
    counts, declines = report["counters"], report["decline_reasons"]
    for value in (*counts.values(), *declines.values()):
        number(value, integer=True)
    if counts[attempts] != counts[completed] + counts["declines"] or sum(declines.values()) != counts["declines"]:
        raise ValueError("Completed/declined preparation accounting differs")
    return counts


def coverage_checks(coverage, arm):
    expected = policy(arm)
    if coverage["arm"] != arm or coverage["policy"] != expected or \
            coverage["executor"] != "ordinary_PSE_compiled_batches" or \
            coverage["admission_scope"] != "completed_preparation_counters_not_inferred_kernel_execution" or \
            any(coverage[key] != 0 for key in ("native_fields", "driver_units", "native_driver_units")):
        raise ValueError("Ecosystem arm changed executor/storage or misrepresented completed work")
    bp, gr, tp = coverage["bounded"], coverage["graph"], coverage["typed_output_preparation"]
    if bp["enabled"] is not expected["bounded"] or gr["enabled"] is not expected["graph"] or \
            tp["enabled"] is not expected["typed_output"]:
        raise ValueError("A preparation policy contaminated an independent control")
    for key in BP_COUNTS:
        number(bp[key], integer=True)
    if bp["metadata_only"] is not True or any(bp[key] is not False for key in
            ("cached_memberships", "cached_sampled_environments", "copied_scientific_values")):
        raise ValueError("Bounded preparation cached scientific or live membership state")
    if expected["bounded"]:
        if bp["scene_entries"] <= 0 or bp["scenario_plans"] <= 0:
            raise ValueError("Bounded arm did no actual scene/plan preparation")
    elif any(bp[key] for key in BP_COUNTS):
        raise ValueError("Disabled bounded arm recorded completed work")
    gc = counter_partition(gr, "projection_attempts", "projections_completed")
    tc = counter_partition(tp, "application_attempts", "applications_completed")
    if gr["completion_scope"] != "actual_returned_relation_tables_not_attempts" or \
            any(gr[key] is not False for key in ("cached_memberships", "cached_scientific_values")) or \
            any(tp[key] is not False for key in ("cached_defaults", "cached_memberships", "copied_scientific_values")):
        raise ValueError("Graph/typed preparation changed its completion or scientific-state boundary")
    if expected["graph"]:
        if gc["projections_completed"] <= 0 or gc["rows_projected"] <= 0:
            raise ValueError("Graph arm completed no actual relation rows")
    elif any(gc.values()):
        raise ValueError("Disabled graph control contains preparation work")
    if expected["typed_output"]:
        if tc["applications_completed"] <= 0 or tc["objects_prepared"] <= 0:
            raise ValueError("Typed output candidate completed no actual application/object preparation")
    elif any(tc.values()):
        raise ValueError("Disabled typed-output control contains preparation work")
    if tc["applications_completed"] != tc["initial_applications_completed"] + tc["growth_applications_completed"] or \
            tc["objects_prepared"] != tc["initial_objects_prepared"] + tc["growth_objects_prepared"] or \
            coverage["actual_projection_rows"] != gc["rows_projected"] or \
            coverage["actual_typed_objects"] != tc["objects_prepared"]:
        raise ValueError("Initial/growth or public actual-work counter partition differs")
    return dict(bounded={key: bp[key] for key in BP_COUNTS}, graph=gc,
        graph_declines=gr["decline_reasons"], typed_output=tc, typed_declines=tp["decline_reasons"],
        numerical_executor="ordinary_PSE_compiled_batches")


def science_checks(snapshot, work, config):
    kind = config["kind"]
    if work["steps"] != config["steps"] or number(work["objects"], integer=True) <= 0:
        raise ValueError("Actual scientific step/object work differs from configuration")
    if kind == "amapsim":
        if snapshot["step"] != config["steps"] or not snapshot["native"] or \
                not all(re.fullmatch(r"[0-9a-f]{64}", snapshot[key]) for key in ("registry_sha256", "outputs_sha256")):
            raise ValueError("AMAP native/registry/history fingerprint is incomplete")
        for key in ("internodes", "qualification_invocations", "active_consumer_bindings", "reference_consumer_bindings"):
            if number(work[key], integer=True) <= 0:
                raise ValueError("AMAP screen contains no actual organ consumer work")
        if not work["added_ids"] or work["active_consumer_bindings"] != work["reference_consumer_bindings"]:
            raise ValueError("AMAP screen lacks actual newborns/live reference carriers")
    elif kind == "maespa":
        if snapshot["scientific"]["step"] != config["steps"] or \
                not snapshot["scientific"]["states"] or not snapshot["topology"] or "scientific_rngs" not in snapshot:
            raise ValueError("MAESPA state/history/types/topology/RNG fingerprint is incomplete")
        if work["ordinary_executor_verified"] is not True or \
                work["allocated_leaf_slots"] != config["logical_leaf_units"] or \
                work["active_leaf_slots"] <= 0 or work["accepted_leaf_slots"] != work["active_leaf_slots"] or \
                work["accepted_leaf_trials"] < work["active_leaf_slots"]:
            raise ValueError("MAESPA did not complete actual accepted leaf calculations")
    elif kind == "coupled":
        if snapshot["step"] != config["steps"] or not snapshot["objects"] or snapshot["native"] is None:
            raise ValueError("Coupled scientific/native fingerprint is incomplete")
        normal = snapshot["normalization"]
        if normal["excluded_clock_outputs"] != CLOCK_OUTPUTS or \
                normal["address_tokens"] != "LocalDevelopment_plant_identity_checked_against_logical_owner" or \
                normal["backend_cache"] != "not_scientific_state_physical_scene_retained":
            raise ValueError("Coupled snapshot introduced undeclared exclusions/identity normalization")
        owners = [value["matches_owning_native_plant"] for _, value in shared.walk(snapshot)
            if "matches_owning_native_plant" in value]
        if not owners or any(value is not True for value in owners):
            raise ValueError("Coupled normalized native identity does not match its actual owner")
        for key in ("positive_area_lit_leaves", "nonzero_assimilation_rows", "opening_radiative_leaves", "light_epochs"):
            if number(work[key], integer=True) <= 0:
                raise ValueError("Final coupled screen lacks positive executed radiation/physiology work")
        if work["light_epochs"] != config["steps"] or work["actual_PB_kernel_call_count"] is not None or \
                work["kernel_count_scope"] != "uncollected_do_not_infer_from_target_counts":
            raise ValueError("Coupled work inferred PB calls from preparation/target counts")
    else:
        raise ValueError(f"Unsupported ecosystem scientific case: {kind}")


def nested_clock_report(coverage, kind):
    value = coverage.get("nested_clocks")
    if kind != "coupled":
        if value is not None:
            raise ValueError("Non-coupled fixture unexpectedly contains nested physical/timer exclusions")
        return None
    if not isinstance(value, dict) or value["interpretation"] != \
            "nested_wall_clocks_not_exclusive_phase_cost_or_PSE_overhead":
        raise ValueError("Nested wall clocks lost their nonexclusive diagnostic meaning")
    for key in ("geometry_seconds", "light_seconds"):
        number(value["last_completed_step"][key])
    for rows in value["retained_clock_history"].values():
        for row in rows:
            number(row["seconds"])
    return value


def screen_summary(screen):
    config = screen["config"]
    if config.get("protocol") != PROTOCOL or config.get("kind") not in KINDS or screen["baseline"] != "ordinary_a" or \
            config.get("statistical_unit") != "one_fresh_independent_scientific_scene" or \
            config.get("storage") != "ordinary_canonical_references" or \
            config.get("executor") != "ordinary_PSE_compiled_batches":
        raise ValueError("Unsupported ecosystem protocol, storage or execution boundary")
    warmups, samples, orders = screen["warmups"], screen["samples"], screen["orders"]
    cycles = number(screen["repetitions"], integer=True)
    if cycles < 1 or len(warmups) != len(ARMS) or {r["variant"] for r in warmups} != set(ARMS) or len(orders) != cycles:
        raise ValueError("Missing factorial warmup/arm/cycle")
    first_order = [r["variant"] for r in samples if r["cycle"] == 1]
    if len(first_order) != len(ARMS) or set(first_order) != set(ARMS) or len(samples) != cycles * len(ARMS):
        raise ValueError("Missing or duplicated four-arm sample")
    for cycle, order in enumerate(orders, 1):
        expected = first_order if cycle % 2 else list(reversed(first_order))
        if order != expected or [r["variant"] for r in samples if r["cycle"] == cycle] != expected:
            raise ValueError("Samples do not follow alternating recorded balanced orders")
    reference = next(r for r in warmups if r["variant"] == "ordinary_a")
    snapshot, work = canonical(reference["snapshot"]), canonical(reference["work"])
    actual, nested = [], []
    for row in warmups + samples:
        if row["case"] != screen["case"] or row["process_id"] != screen["provenance"]["process_id"] or \
                row["digest"] != screen["expected_digest"] or canonical(row["config"]) != canonical(config) or \
                canonical(row["snapshot"]) != snapshot or canonical(row["work"]) != work:
            raise ValueError("Exact scientific/history/RNG/work/configuration/PID parity differs")
        science_checks(row["snapshot"], row["work"], config)
        if set(row["phases"]) != set(PHASES):
            raise ValueError("Four charged construction/preparation/lowering/execution phases required")
        shared.validate_phase_sums(row)
        for phase in row["phases"].values():
            for key in COSTS:
                number(phase[key], integer=key == "allocated_bytes")
        if not math.isclose(sum(p["gc_seconds"] for p in row["phases"].values()), row["complete_gc_seconds"], abs_tol=1e-12):
            raise ValueError("Complete GC cost omits or duplicates a phase")
        counters = coverage_checks(row["coverage"], row["variant"])
        clocks = nested_clock_report(row["coverage"], config["kind"])
        if "cycle" in row:
            actual.append(dict(arm=row["variant"], cycle=row["cycle"], **counters))
            if clocks is not None:
                nested.append(dict(arm=row["variant"], cycle=row["cycle"], **clocks))
    controls = {arm: {r["cycle"]: r for r in samples if r["variant"] == arm} for arm in REFERENCES}
    reports = []
    for arm in first_order:
        rows = [r for r in samples if r["variant"] == arm]
        paired = {}
        for baseline in REFERENCES:
            pairs = []
            for row in rows:
                control = controls[baseline][row["cycle"]]
                ratios = {phase: {key: ratio(row["phases"][phase][key], control["phases"][phase][key])
                    for key in ("seconds", "allocated_bytes")} for phase in PHASES}
                pairs.append(dict(cycle=row["cycle"], phases=ratios,
                    complete_seconds=ratio(row["complete_seconds"], control["complete_seconds"]),
                    complete_allocated_bytes=ratio(row["complete_allocated_bytes"], control["complete_allocated_bytes"])))
            paired[baseline] = dict(cycles=pairs,
                preparation_ratio=statistics.median(p["phases"]["pse_preparation"]["seconds"] for p in pairs),
                execution_ratio=statistics.median(p["phases"]["execution"]["seconds"] for p in pairs),
                complete_ratio=statistics.median(p["complete_seconds"] for p in pairs))
        reports.append(dict(arm=arm, samples=len(rows),
            phase_medians={phase: {key: statistics.median(r["phases"][phase][key] for r in rows)
                for key in COSTS} for phase in PHASES},
            complete_medians={key: statistics.median(sum(r["phases"][phase][key] for phase in PHASES)
                for r in rows) for key in COSTS}, paired=paired,
            jit_events=[dict(cycle=r["cycle"], phase=name, compilation_seconds=p["compilation_seconds"],
                recompilation_seconds=p["recompilation_seconds"]) for r in rows for name,p in r["phases"].items()
                if p["compilation_seconds"] or p["recompilation_seconds"]],
            actual_preparation_work=[r for r in actual if r["arm"] == arm],
            nested_wall_clocks=[r for r in nested if r["arm"] == arm],
            reachable_memory_after_clocks=[value for value in (previous._retained(r) for r in rows) if value is not None]))
    return dict(kind=config["kind"], case=screen["case"], config=config, cycles=cycles,
        digest=screen["expected_digest"], snapshot_sha256=sha(snapshot), work=reference["work"],
        sample_cohort_sha256=sha(canonical(samples)), source_epoch=shared.source_epoch(screen),
        arms=reports, ordinary_A_A=next(r for r in reports if r["arm"] == "ordinary_b"),
        normalization=reference["snapshot"].get("normalization"),
        cold_compilation_claim=False, peak_RSS_claim=False,
        interpretation="small_warm_fresh_scene_preparation_screen_not_calibration_or_robust_speedup_evidence")


def frozen_sources(parsed, raw):
    freeze = parsed.get("source-freeze.json")
    if not isinstance(freeze, dict) or not isinstance(freeze.get("packages"), dict):
        raise ValueError("Missing independently frozen downstream scientific package cohort")
    parent = Path(freeze["root"]).resolve()
    patches = compatibility_patches(freeze, raw)
    captured, records = {}, []
    for name, package in sorted(freeze["packages"].items()):
        root = Path(package["frozen"]).resolve()
        if not root.is_relative_to(parent) or root == parent or not re.fullmatch(r"[0-9a-f]{40}", package["revision"]):
            raise ValueError("Unsafe frozen package root or inexact origin revision")
        files = package["frozen_files"]
        if not files or "Project.toml" not in files:
            raise ValueError("Frozen package lacks its exact project/source inventory")
        for relative, expected in sorted(files.items()):
            path = Path(relative)
            if path.is_absolute() or ".." in path.parts or ".git" in path.parts or not re.fullmatch(r"[0-9a-f]{64}", expected):
                raise ValueError("Unsafe frozen scientific file path/hash")
            full = root / path
            if full.is_symlink() or not full.resolve().is_relative_to(root) or not full.is_file():
                raise ValueError("Frozen scientific input missing or escaping package")
            payload = full.read_bytes()
            if sha(payload) != expected:
                raise ValueError(f"Frozen scientific source changed: {name}:{relative}")
            original = package["source_files"].get(relative)
            if original != expected and relative != "Manifest.toml" and (name, relative) not in patches:
                raise ValueError("Scientific frozen source differs without an explicit exact compatibility patch")
            if relative == "Manifest.toml" and expected != package.get("relocated_manifest_sha256", original):
                raise ValueError("Relocated manifest lacks its explicit frozen checksum")
            captured[f"{name}/{relative}"] = payload
        diff_name = f"source-origin/{name}.diff"
        if diff_name not in raw or sha(raw[diff_name]) != package["tracked_diff_sha256"]:
            raise ValueError("Recorded original dirty-worktree diff digest differs")
        records.append(dict(name=name, original=package["original"], frozen=str(root),
            revision=package["revision"], tracked_status=package["tracked_status"],
            tracked_diff_sha256=package["tracked_diff_sha256"],
            original_source_files=package["source_files"], frozen_files=files,
            applied_patches=[row for (package_name, _), row in patches.items() if package_name == name],
            diff_archival="digest_only_unrelated_checkout_diff_content_not_republished"))
    loaded = parsed.get("loaded-packages.json")
    if isinstance(loaded, list):
        roots = {row["name"]: Path(row["root"]).resolve() for row in loaded}
        for name, package in freeze["packages"].items():
            if roots.get(name) != Path(package["frozen"]).resolve():
                raise ValueError("Loaded scientific package does not use its frozen source root")
    return records, captured


def scientific_sources(screens, raw, current, frozen):
    records, blobs = [], {sha(v): v for v in (*raw.values(), *current.values(), *frozen.values())}
    declared = json.loads(raw["source-freeze.json"])["packages"]
    common, packages = None, {}
    for name, screen in screens.items():
        provenance = screen["provenance"]
        # Scientific cases may use independent Kaimon workers/environments.
        # Each screen already requires one PID for every arm. Only the shared
        # source cohort is compared across different scientific cases here.
        projection = dict(harness=provenance["harness"]["aggregate_sha256"],
            experimental_sources=provenance["experimental_sources"]["aggregate_sha256"])
        if common is not None and projection != common:
            raise ValueError("Final ecosystem screens mix PSE experiment source cohorts")
        common = projection
        manifests = [(p["name"], p["root"], p["sources"]) for p in provenance["packages"]]
        manifests += [("harness", provenance["harness"]["root"], provenance["harness"]),
            ("experimental_sources", provenance["experimental_sources"]["root"], provenance["experimental_sources"])]
        if "PlantSimEngine" not in {row[0] for row in manifests}:
            raise ValueError("Missing exact PSE package provenance")
        for package, root_name, manifest in manifests:
            previous.old.validate_manifest(manifest)
            root = Path(root_name).resolve()
            if package in declared and root != Path(declared[package]["frozen"]).resolve():
                raise ValueError("Scientific screen loaded an unfrozen downstream package root")
            key = (package, str(root))
            aggregate = manifest["aggregate_sha256"]
            if key in packages and packages[key] != aggregate:
                raise ValueError("A scientific package source changed between final cases")
            packages[key] = aggregate
            for row in manifest["files"]:
                full = root / row["path"]
                if full.is_symlink() or not full.resolve().is_relative_to(root):
                    raise ValueError("Scientific package provenance escaped declared root")
                expected = row["sha256"]
                if expected not in blobs and full.is_file():
                    payload = full.read_bytes()
                    if sha(payload) == expected:
                        blobs[expected] = payload
                if expected not in blobs or not full.is_file() or sha(full.read_bytes()) != expected:
                    raise ValueError(f"Current/exact scientific source bytes missing: {name}:{package}:{row['path']}")
            records.append(dict(source=name, name=package, root=str(root),
                aggregate_sha256=aggregate, files=manifest["files"]))
    referenced = {row["sha256"] for manifest in records for row in manifest["files"]}
    return records, {key: blobs[key] for key in sorted(referenced)}


def summarize(parsed, raw):
    scope = parsed.get("run-scope.json", {})
    repairs = parsed.get("source-freeze.json", {}).get("applied_patches", [])
    if repairs and scope.get("downstream_compatibility_repair") is not True:
        raise ValueError("A frozen downstream repair must be explicit in the run scope")
    bindings = previous.strict_qualification(parsed, raw)
    candidates = {name: value for name,value in parsed.items() if "/" not in name and name.endswith("-screen.json")}
    declared = scope.get("final_screens", sorted(candidates))
    if len(declared) != len(set(declared)) or not set(declared) <= set(candidates):
        raise ValueError("Missing or duplicate declared final ecosystem screen")
    qualified, unqualified, selected = [], [], {}
    for name in declared:
        record = dict(source=name, cpu=shared.cpu_qualification(name, bindings), **screen_summary(candidates[name]))
        if record["cpu"]["qualified"]:
            qualified.append(record);selected[name] = candidates[name]
        else:
            unqualified.append(record)
    workers = scope.get("workers_by_screen", {})
    for row in qualified:
        worker = workers.get(row["source"], scope.get("worker"))
        if worker is not None:
            expected = worker["pid"] if isinstance(worker, dict) else worker
            if row["source_epoch"]["process_id"] != expected:
                raise ValueError("Timing did not run in its explicitly declared per-screen Kaimon worker")
    gates = []
    for name in scope.get("final_gates", []):
        if name not in parsed or "/" in name or not isinstance(parsed[name], dict):
            raise ValueError("Missing declared final correctness artifact")
        flags = [value["passed"] for _,value in shared.walk(parsed[name]) if "passed" in value]
        if not flags or any(flag is not True for flag in flags):
            raise ValueError("Declared final gate contains absent or failed assertions")
        gates.append(dict(source=name, sha256=sha(raw[name]), passed=True))
    return dict(protocol=PROTOCOL, run_scope=scope, qualified_warm_screens=qualified,
        unqualified_declared_final_screens=unqualified, final_gates=gates,
        downstream_compatibility_repair=bool(repairs),
        downstream_compatibility_scope="same_exact_frozen_repair_in_all_ordinary_and_candidate_arms" if repairs else "unmodified_frozen_scientific_packages",
        old_results_used_as_baselines=False, cold_claim=False, peak_RSS_claim=False,
        limitations=["Independent original scientific states in every arm; no native-only execution used as a speed baseline.",
            "A few alternating cycles are a screen, not robust speedup evidence.",
            "Completed preparation counters are not numerical kernel invocation counts.",
            "Nested geometry/light wall clocks overlap execution and are never subtracted as exclusive PSE overhead.",
            "Coupled normalization excludes exactly two qualified wall-clock outputs; physical time, RNG, geometry and ownership checks remain.",
            "No calibrated-science, full ecosystem feature matrix, million-organ, cold-compilation or case peak-RSS claim follows."]), selected


def source_guard(scope, parsed, raw):
    names = scope.get("source_images", {})
    if names:
        if not isinstance(names, dict) or set(names) != set(scope.get("final_screens", [])):
            raise ValueError("Per-screen source images must cover exactly the declared final screens")
        names = sorted(set(names.values()))
    else:
        names = [scope.get("source_image", "screen-source-image.json")]
    if any(name not in parsed for name in names):
        return dict(verified=False, reason="controller_has_not_supplied_before_after_source_guard")
    roots = {"PSE": ROOT}
    roots.update({key: Path(value["frozen"]) for key,value in parsed["source-freeze.json"]["packages"].items()})
    # Controller images may wrap the package map in `sources`; the concrete
    # hashes must remain directly auditable, not only an aggregate assertion.
    reports = []
    for name in names:
        image = parsed[name]
        mapping = image.get("sources", image)
        count = 0
        for package, paths in mapping.items():
            if package not in roots:
                raise ValueError(f"Unknown source-guard package: {package}")
            for relative, expected in paths.items():
                path = Path(relative)
                if path.is_absolute() or ".." in path.parts or not re.fullmatch(r"[0-9a-f]{64}", expected):
                    raise ValueError("Unsafe source-guard path/hash")
                full = roots[package] / path
                if full.is_symlink() or not full.is_file() or sha(full.read_bytes()) != expected:
                    raise ValueError("Current source differs from before/after screen guard")
                count += 1
        if set(mapping) != set(roots):
            raise ValueError("Whole-cohort source guard omits a frozen package or PSE")
        reports.append(dict(artifact=name, sha256=sha(raw[name]), files=count))
    return dict(verified=True, images=reports,
        interpretation="controller_before_after_assertion_plus_exact_current_source_revalidation")


def archive(raw, current, frozen, science, blobs, summary):
    if DEST.exists():
        raise FileExistsError("Refusing immutable evidence overwrite")
    required = set(summary["run_scope"].get("required_kinds", sorted(KINDS)))
    if summary["run_scope"].get("frozen") is not True or not summary["core_base"]["verified"] or \
            not summary["source_guard"]["verified"] or not summary["final_gates"] or \
            summary["unqualified_declared_final_screens"] or \
            not required <= {row["kind"] for row in summary["qualified_warm_screens"]}:
        raise ValueError("Archive requires frozen sources, exact core base, final gates and all required qualified scientific screens")
    DEST.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".ecosystem-qualification-", dir=DEST.parent) as temporary:
        stage = Path(temporary) / "ecosystem-qualification";stage.mkdir()
        manifest, omitted = [], []
        def put(name, value, kind, origin):
            payload = gzip.compress(value, mtime=0)
            target = stage / name;target.parent.mkdir(parents=True, exist_ok=True);target.write_bytes(payload)
            manifest.append(dict(kind=kind, origin=origin, artifact=name, encoding="gzip",
                raw_bytes=len(value), raw_sha256=sha(value), compressed_sha256=sha(payload)))
        for name,value in raw.items():
            if name.startswith("source-origin/") and name.endswith(".diff"):
                omitted.append(dict(origin=name, raw_bytes=len(value), raw_sha256=sha(value),
                    reason="original_checkout_diff_content_not_republished_frozen_scientific_files_preserved"))
            else:
                put("raw/" + name + ".gz",value,"raw_evidence",name)
        for name,value in current.items():
            put("qualified-source/" + name + ".gz",value,"PSE_source_snapshot",name)
        for name,value in frozen.items():
            put("frozen-packages/" + name + ".gz",value,"frozen_scientific_package_source",name)
        for key,value in blobs.items():
            put("source-blobs/" + key + ".gz",value,"scientific_source_blob",key)
        for name,value in (("scientific-provenance.json",science),("summary.json",summary),("omitted-original-diffs.json",omitted)):
            payload=json_bytes(value);(stage/name).write_bytes(payload)
            manifest.append(dict(kind="derived_metadata",origin=name,artifact=name,encoding="identity",
                raw_bytes=len(payload),raw_sha256=sha(payload)))
        for row in manifest:
            payload=(stage/row["artifact"]).read_bytes()
            if row["encoding"]=="gzip":
                if sha(payload)!=row["compressed_sha256"]:
                    raise ValueError("Written compressed evidence checksum differs")
                payload=gzip.decompress(payload)
            if len(payload)!=row["raw_bytes"] or sha(payload)!=row["raw_sha256"]:
                raise ValueError("Lossless archive round trip differs")
        (stage/"manifest.json").write_bytes(json_bytes(sorted(manifest,key=lambda row:row["artifact"])))
        if raw!=inventory(SOURCE) or current!=source_inputs() or frozen!=frozen_sources(shared.documents(raw),raw)[1]:
            raise RuntimeError("Frozen inputs changed while archiving")
        if DEST.exists():
            raise FileExistsError(DEST)
        stage.rename(DEST)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    mode=parser.add_mutually_exclusive_group()
    mode.add_argument("--check-only",action="store_true")
    mode.add_argument("--archive-frozen",action="store_true")
    args=parser.parse_args()
    if args.archive_frozen and DEST.exists():
        raise FileExistsError(DEST)
    raw=inventory(SOURCE);parsed=shared.documents(raw)
    summary,screens=summarize(parsed,raw)
    current=source_inputs()
    frozen_records,frozen=frozen_sources(parsed,raw)
    science,blobs=scientific_sources(screens,raw,current,frozen)
    summary["frozen_packages"]=frozen_records
    summary["core_base"]=previous.old.core_base_check(summary["run_scope"],current)
    summary["source_guard"]=source_guard(summary["run_scope"],parsed,raw)
    if raw!=inventory(SOURCE) or current!=source_inputs():
        raise RuntimeError("Source/evidence changed during validation; retry after freeze")
    if args.archive_frozen:
        archive(raw,current,frozen,science,blobs,summary)
    print(json.dumps(dict(archived=bool(args.archive_frozen),raw_files=len(raw),source_files=len(current),
        frozen_scientific_files=len(frozen),scientific_source_blobs=len(blobs),summary=summary),sort_keys=True,indent=2))


if __name__=="__main__":
    main()
