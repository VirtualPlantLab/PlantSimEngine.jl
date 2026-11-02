"""Value-preserving literal-call inference transforms for the MAESPA copy.

The central recipe owns source copying/inventories. These transforms only add
compiler annotations and rename one accidentally captured local variable.
"""
import re

REPAIRED = (
    "src/coupling/canopy_environment.jl",
    "src/processes/radiation/radiation_transmission.jl",
    "src/processes/soil_water_balance.jl",
)


def replace_exact(source, old, new, count=1):
    if source.count(old) != count:
        raise ValueError(f"Expected {count} occurrences: {old!r}")
    return source.replace(old, new)


def repair(relative, source):
    if relative == REPAIRED[0]:
        source = replace_exact(source,
            "function _sample_canopy_air_trial_metadata(\n",
            "@inline Base.@constprop :aggressive function _sample_canopy_air_trial_metadata(\n")
        source = replace_exact(source,
            "@inline function _sample_canopy_atmosphere(\n",
            "@inline Base.@constprop :aggressive function _sample_canopy_atmosphere(\n")
        source = replace_exact(source,
            "@noinline function _missing_committed_canopy_atmosphere(variable::Symbol)\n",
            "@noinline Base.@constprop :aggressive function _missing_committed_canopy_atmosphere(variable::Symbol)\n")
        source = replace_exact(source,
            "function PlantSimEngine.EnvironmentAPI.sample(\n",
            "@inline Base.@constprop :aggressive function PlantSimEngine.EnvironmentAPI.sample(\n",
            count=3)
        return replace_exact(source,
            "function PlantSimEngine.EnvironmentAPI.commit_environment!(\n",
            "@inline Base.@constprop :aggressive function PlantSimEngine.EnvironmentAPI.commit_environment!(\n")
    if relative == REPAIRED[1]:
        start = source.index("    function uniform_state(crown_index)\n")
        end = source.index("\n    modes = map(eachindex(neighbourhood.tree_ids))", start)
        body = source[start:end]
        if body.count("        values = common_values(crown_index)\n") != 1:
            raise ValueError("Unexpected uniform_state local binding")
        # The outer function also assigns `values`. Reusing its name inside
        # this nested function captures Core.Box; a distinct local is identical
        # here because no caller observes that incidental outer assignment.
        modified, count = re.subn(r"\bvalues\b", "uniform_values", body)
        if count != 11:
            raise ValueError(f"Unexpected uniform_state binding references: {count}")
        return source[:start] + modified + source[end:]
    if relative == REPAIRED[2]:
        return replace_exact(source,
            "function _load_layer_flux!(\n",
            "@inline Base.@constprop :aggressive function _load_layer_flux!(\n")
    raise ValueError("Not an owned runtime-typing source: " + relative)
