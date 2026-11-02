#!/usr/bin/env python3
"""Create an inventoried inference-typing variant without changing equations."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import shutil
import sys

sys.dont_write_bytecode = True
import downstream_maespa_runtime_typing as runtime_typing
import downstream_maespa_closed_fields as closed_fields
import downstream_maespa_leaf_outputs as leaf_outputs

BASE_REPAIRED = (
    "src/config/species_physiology.jl",
    "src/processes/species_physiology_process.jl",
    "src/config/species_structure.jl",
    "src/processes/canopy_air_trial_evaluation.jl",
)
HELPERS = (runtime_typing, closed_fields, leaf_outputs)
REPAIRED = tuple(dict.fromkeys(BASE_REPAIRED + tuple(
    relative for helper in HELPERS for relative in helper.REPAIRED)))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(root):
    files = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Frozen-source copying refuses symlinks: {path}")
        if path.is_file():
            files[str(path.relative_to(root))] = digest(path)
    return files


def replace_exact(source, old, new, count=1):
    if source.count(old) != count:
        raise ValueError(f"Expected {count} exact source occurrences: {old!r}")
    return source.replace(old, new)


def _repair_base(relative, source):
    if relative == BASE_REPAIRED[0]:
        source = replace_exact(
            source,
            "struct SpeciesPhysiologyConfig{T<:AbstractFloat}\n",
            "struct SpeciesPhysiologyConfig{T<:AbstractFloat,S<:AbstractStomatalParameters{T}}\n",
        )
        source = replace_exact(
            source, "    stomatal::AbstractStomatalParameters{T}\n", "    stomatal::S\n"
        )
        # Update the four EXISTING shorter constructors and the parser's full
        # construction call. Do not add a legacy full-constructor forwarder,
        # alias, fallback method, or parallel API to the changed type.
        return replace_exact(
            source,
            "    return SpeciesPhysiologyConfig{T}(\n",
            "    return SpeciesPhysiologyConfig{T,typeof(stomatal)}(\n",
            count=5,
        )
    if relative == BASE_REPAIRED[2]:
        source = replace_exact(
            source,
            "    days = getfield.(distribution.dates, :days_since_1950)\n",
            "    days = [item.days_since_1950 for item in distribution.dates]\n",
        )
        return replace_exact(
            source,
            "    days = getfield.(density.dates, :days_since_1950)\n",
            "    days = [item.days_since_1950 for item in density.dates]\n",
        )
    if relative == BASE_REPAIRED[3]:
        source = replace_exact(
            source,
            "@noinline function _throw_canopy_air_trial_evaluation(\n",
            "# Error text is fixed authoring metadata; do not invoke Tuple/Symbol\n"
            "# display from the native runtime's validation branch.\n"
            "const _MAESPA_CANOPY_AIR_TRIAL_LEAF_EXCHANGE_DESCRIPTION =\n"
            "    string(_MAESPA_CANOPY_AIR_TRIAL_LEAF_EXCHANGE_PROCESSES)\n\n"
            "@noinline function _throw_canopy_air_trial_evaluation(\n",
        )
        return replace_exact(
            source,
            '"$(_MAESPA_CANOPY_AIR_TRIAL_LEAF_EXCHANGE_PROCESSES)"',
            '"$(_MAESPA_CANOPY_AIR_TRIAL_LEAF_EXCHANGE_DESCRIPTION)"',
        )
    source = replace_exact(
        source,
        "struct MAESPASpeciesPhysiologyTrajectory{T<:AbstractFloat} <:\n",
        "struct MAESPASpeciesPhysiologyTrajectory{T<:AbstractFloat,S<:AbstractStomatalParameters{T}} <:\n",
    )
    return replace_exact(
        source,
        "    config::SpeciesPhysiologyConfig{T}\n",
        "    config::SpeciesPhysiologyConfig{T,S}\n",
    )


def repair(relative, source):
    if relative not in REPAIRED:
        raise ValueError("Not an owned source-typing path: " + relative)
    if relative in BASE_REPAIRED:
        source = _repair_base(relative, source)
    # Compose every applicable transform, including both the positional
    # inference annotation and literal NamedTuple restore on soil_water_balance.
    for helper in HELPERS:
        if relative in helper.REPAIRED:
            source = helper.repair(relative, source)
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-root", type=Path, required=True)
    parser.add_argument("--typed-root", type=Path, required=True)
    parser.add_argument("--patch", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    baseline = args.baseline_root.resolve()
    typed = args.typed_root.resolve()
    if not baseline.is_dir():
        raise ValueError("Baseline root must exist")
    if typed == baseline or baseline in typed.parents or typed in baseline.parents:
        raise ValueError("Baseline and typed destinations must be disjoint")
    if typed.exists():
        raise ValueError("Refuse to overwrite an existing source copy")
    before = inventory(baseline)
    typed.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(baseline, typed, symlinks=False)
    patch = []
    for relative in REPAIRED:
        original = (baseline / relative).read_text()
        modified = repair(relative, original)
        (typed / relative).write_text(modified)
        patch.extend(difflib.unified_diff(
            original.splitlines(keepends=True), modified.splitlines(keepends=True),
            fromfile="a/" + relative, tofile="b/" + relative,
        ))
    after = inventory(typed)
    if set(before) != set(after):
        raise ValueError("Source copy added or removed files")
    changed = sorted(path for path in before if before[path] != after[path])
    if changed != sorted(REPAIRED):
        raise ValueError(f"Unexpected source changes: {changed}")
    if inventory(baseline) != before:
        raise ValueError("Original frozen baseline changed while copying")
    args.patch.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.patch.write_text("".join(patch))
    args.manifest.write_text(json.dumps({
        "format_version": 1,
        "baseline_root": str(baseline), "typed_root": str(typed),
        "scope": "concrete stomatal config/model parameters, existing constructor targets, literal dated/status/forcing/snapshot projections and diagnostics, concrete identity/tuple storage, finite Nothing-tag argument dispatch to original kernels, fixed error text at authoring, compiler annotations, and one uncaptured local rename; equations/checks/order unchanged",
        "unchanged_scientific_equations_and_declared_interfaces": True,
        "new_compatibility_wrappers_or_dual_apis": False,
        "existing_constructor_implementation_calls_updated": 5,
        "qualification": "static typing variant; ordinary parity/control and native verifier qualification remain required",
        "changes": [{"path": path, "before_sha256": before[path], "after_sha256": after[path]}
                    for path in changed],
        "all_baseline_files": before, "all_typed_files": after,
        "patch_sha256": digest(args.patch), "script_sha256": digest(Path(__file__)),
        "helper_script_sha256": {Path(helper.__file__).name: digest(Path(helper.__file__))
                                 for helper in HELPERS},
    }, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"typed_root": str(typed), "changed": changed,
                      "unchanged_files": len(before) - len(changed),
                      "patch_sha256": digest(args.patch)}))


if __name__ == "__main__":
    main()
