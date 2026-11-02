#!/usr/bin/env python3
"""Copy a frozen AMAP package and repair adapter/finite-payload inference typing; never run Julia."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import shutil

REPAIRED = ("dev/native/pse.jl", "dev/native/pse_projection.jl",
            "dev/native/geometry.jl", "dev/native/parameters.jl", "dev/native/engine.jl")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def repair(relative, source):
    if relative == REPAIRED[0]:
        old = "mutable struct NativePSEState{N,F,C,D,G}\n"
        new = "mutable struct NativePSEState{N,F,C,D,G,I<:PSE.ObjectId,R<:PSE.ObjectId}\n"
        assert source.count(old) == 1
        source = source.replace(old, new)
        assert source.count("    plant_id::PSE.ObjectId\n") == 1
        source = source.replace("    plant_id::PSE.ObjectId\n", "    plant_id::I\n")
        old = "    registered::Dict{Tuple{Symbol,Int},PSE.ObjectId}\n"
        assert source.count(old) == 1
        source = source.replace(old, "    registered::Dict{Tuple{Symbol,Int},R}\n")
        needle = 'struct NativePropertyPublisher{D,P} <: AbstractNativePropertiesModel\n'
        assert source.count(needle) == 1
        metadata = '''# Fixed property names/sources are adapter metadata, not scientific values.
# Keep them visible to the compiler while retaining the original publisher kernel.
struct _StaticProperties{PAIRS} end
Base.length(::_StaticProperties{PAIRS}) where {PAIRS} = length(PAIRS)
Base.iterate(::_StaticProperties{PAIRS}) where {PAIRS} = iterate(PAIRS)
Base.iterate(::_StaticProperties{PAIRS}, state) where {PAIRS} = iterate(PAIRS, state)
Base.eltype(::Type{<:_StaticProperties}) = Tuple{Symbol,Symbol}
_static_properties(properties) = _StaticProperties{Tuple((name, source) for (name, source) in properties)}()

'''
        return source.replace(needle, metadata + needle)
    if relative == "dev/native/engine.jl":
        def helper(name, optionals, keywords):
            def branch(i, values, indent):
                if i == len(optionals):
                    old = values[0]
                    kwargs = ",".join(f"{key}={value}" for key,value in zip(keywords,values[1:]))
                    return indent+f"return AMAPSim.{name}(rng,zone,age,pos,{old};{kwargs})\n"
                var=optionals[i]
                return (indent+f"if {var}===nothing\n"+branch(i+1,values+["nothing"],indent+"    ")+
                        indent+"else\n"+branch(i+1,values+[var],indent+"    ")+indent+"end\n")
            return (f"function _closed_{name}(rng,zone,age,pos,{','.join(optionals)})\n"+
                    branch(0,[],"    ")+"end\n")
        storage = "# Explicit finite optional-argument barriers; every leaf invokes the original sampler.\n"
        storage += helper("sample_immediate_markov_state",["old","previous_branching","previous_position"],
                          ["previous_branching","previous_position"])
        storage += helper("sample_cycle_delayed_markov_state",["old","previous_initial_probability"],
                          ["previous_initial_probability"])
        storage += helper("sample_traumatic_markov_state",["old","previous_initial_probability"],
                          ["previous_initial_probability"])
        old="function _closed_sample_immediate_markov_state(rng,zone,age,pos,old,previous_branching,previous_position)\n"
        new="function _closed_sample_immediate_markov_state(rng,zone,age,pos,old,lp,previous_zone::Int,previous_pos::Float64)\n    previous_branching=previous_zone==0 ? nothing : lp.zones[previous_zone].branching\n    previous_position=isnan(previous_pos) ? nothing : previous_pos\n"
        assert storage.count(old)==1
        storage=storage.replace(old,new)
        marker="function immediate!("
        idx=source.index(marker)
        source=source[:idx]+storage+source[idx:]
        replacements = (
          ("""AMAPSim.sample_immediate_markov_state(plant.rng,zone,age,pos,previous;
                previous_branching=previous_zone==0 ? nothing : lp.zones[previous_zone].branching,
                previous_position=isnan(previous_pos) ? nothing : previous_pos)""",
           """_closed_sample_immediate_markov_state(plant.rng,zone,age,pos,previous,lp,previous_zone,previous_pos)"""),
          ("""AMAPSim.sample_cycle_delayed_markov_state(plant.rng,zone,age,pos,old;
                previous_initial_probability=prev_p)""",
           "_closed_sample_cycle_delayed_markov_state(plant.rng,zone,age,pos,old,prev_p)"),
          ("""AMAPSim.sample_traumatic_markov_state(plant.rng,zone,age,pos,old;
                    previous_initial_probability=prev_p)""",
           "_closed_sample_traumatic_markov_state(plant.rng,zone,age,pos,old,prev_p)"))
        for old,new in replacements:
            assert source.count(old)==1
            source=source.replace(old,new)
        return source
    if relative == "dev/native/geometry.jl":
        old = """function geometry!(plant::Engine.NativePlant;geometry_draws=nothing,rng=Random.Xoshiro(0),
    geometry_parameters=nothing, dimension_provider=nothing, observation_times=nothing)
"""
        new = """function geometry!(plant::Engine.NativePlant;geometry_draws=nothing,rng=Random.Xoshiro(0),
    geometry_parameters=nothing, dimension_provider=nothing, observation_times=nothing)
    return _geometry_typed!(plant,geometry_draws,rng,geometry_parameters,dimension_provider,observation_times)
end
# A positional callback barrier preserves its concrete closure type. The entire
# scientific geometry body below is unchanged.
function _geometry_typed!(plant::Engine.NativePlant,geometry_draws::F,rng,
    geometry_parameters,dimension_provider,observation_times) where {F}
"""
        assert source.count(old) == 1
        return source.replace(old,new)
    if relative == "dev/native/parameters.jl":
        fields = (
            ("reference_age","Float64"),("starts_growth_unit","Bool"),("starts_cycle","Bool"),
            ("growth_unit_sympody","Union{Nothing,AMAPSim.SympodialTransition}"),
            ("cycle_sympody","Union{Nothing,AMAPSim.SympodialTransition}"),
            ("starts_neoformed_zone","Bool"),("creates_test_site","Bool"),("zone_kind","Symbol"),
            ("zone_test_index","Int"),("realized","Bool"),("cycle_ended","Bool"),
            ("growth_unit_ended","Bool"),("axis_ended","Bool"),("mortality_position","Int"),
            ("mortality_death_position","Union{Nothing,Int}"),("survived","Bool"),("bud_died","Bool"),
            ("cycle_tail_test_count","Int"),("cycle_tail_survival_test_count","Int"),
            ("theoretical_growth_unit_test_count","Int"),("theoretical_growth_unit_end_time","Float64"),
            ("theoretical_growth_unit_duration","Union{Nothing,Float64}"),("branch_position","Int"),
            ("branching_zone_index","Int"),("bearer_axis_internode_index","Int"),
            ("immediate_branches","Vector{NamedTuple}"),("floating_cleanup_lateral_indices","Vector{Int}"),
            ("next_time","Union{Nothing,Float64}"))
        storage = """# Closed storage for the ORIGINAL planner's finite native payload. Every
# scientific value and vector reference is preserved; optional values remain
# optional. No outcome or branch is inferred from benchmark parameter values.
struct NativeApicalPlan\n"""
        storage += ''.join(f"    {name}::{typ}\n" for name,typ in fields) + "end\n"
        storage += "function _closed_plan(plan)\n    return NativeApicalPlan(\n"
        storage += ',\n'.join(f"        getfield(plan,:{name})::{typ}" for name,typ in fields) + ")\nend\n"
        storage += """@generated function Base.merge(plan::NativeApicalPlan,overrides::NamedTuple{N}) where {N}
    names=fieldnames(NativeApicalPlan)
    all(name->name in names,N) || return :(throw(ArgumentError("unknown NativeApicalPlan override field")))
    values=[name in N ? :(getfield(overrides,$(QuoteNode(name)))) : :(getfield(plan,$i))
        for (i,name) in enumerate(names)]
    return :(NativeApicalPlan($(values...)))
end

"""
        old = 'function apical_plan!(state::NativeApicalState,parameters,rng::AbstractRNG,time::Real)'
        assert source.count(old)==1
        source=source.replace(old,storage+old)
        old = """    return AMAPSim._plan_apical_test!(state,rng,parameters,Float64(time),0,0,0.0,
        false,nothing,nothing,nothing,state.first_dispatch_time)"""
        new = """    return _closed_plan(AMAPSim._plan_apical_test!(state,rng,parameters,Float64(time),0,0,0.0,
        false,nothing,nothing,nothing,state.first_dispatch_time))"""
        assert source.count(old)==1
        source=source.replace(old,new)
        source=source.replace("state.cycle = nothing","setfield!(state,:cycle,nothing)")
        source=source.replace("state.next_time = plan.next_time === nothing ? Inf : plan.next_time",
            "setfield!(state,:next_time,plan.next_time === nothing ? Inf : (plan.next_time::Float64))")
        return source
    old = "NativePropertyPublisher(defaults, Tuple(properties), revision)"
    assert source.count(old) == 1
    source = source.replace(old, "NativePropertyPublisher(defaults, _static_properties(properties), revision)")
    old = "Dict{Tuple{Symbol,Int},PSE.ObjectId}(), geometry, status_factory,"
    assert source.count(old) == 1
    return source.replace(old, "Dict{Tuple{Symbol,Int},typeof(native_object_id(plant.id, :Internode, 1))}(), geometry, status_factory,")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline-root", type=Path, required=True)
    parser.add_argument("--typed-root", type=Path, required=True)
    parser.add_argument("--patch", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    baseline = args.baseline_root.resolve()
    typed = args.typed_root.resolve()
    assert baseline != typed
    assert baseline not in typed.parents and typed not in baseline.parents, "Source/destination must not overlap"
    assert not typed.exists(), "Refuse to overwrite an existing scientific source copy"
    before = {str(path.relative_to(baseline)): digest(path)
              for path in baseline.rglob("*") if path.is_file()}
    shutil.copytree(baseline, typed, symlinks=False)
    patch = []
    for relative in REPAIRED:
        original = (baseline / relative).read_text()
        modified = repair(relative, original)
        (typed / relative).write_text(modified)
        patch.extend(difflib.unified_diff(original.splitlines(keepends=True),
                     modified.splitlines(keepends=True), fromfile="a/" + relative,
                     tofile="b/" + relative, n=0))
    after = {str(path.relative_to(typed)): digest(path)
             for path in typed.rglob("*") if path.is_file()}
    changed = sorted(path for path in before if before[path] != after[path])
    assert changed == sorted(REPAIRED), changed
    assert set(before) == set(after)
    args.patch.parent.mkdir(parents=True, exist_ok=True)
    args.patch.write_text("".join(patch))
    args.manifest.write_text(json.dumps({
        "format_version": 1,
        "baseline_root": str(baseline), "typed_root": str(typed),
        "scope": "adapter ID/property typing, finite transient plan storage, declared field writes, optional-call and geometry callback specialization",
        "unchanged_scientific_equations_branches_event_order_and_rng": True,
        "byte_identical_scientific_sources": False,
        "changes": [{"path": path, "before_sha256": before[path],
                     "after_sha256": after[path]} for path in changed],
        "all_baseline_files": before, "all_typed_files": after,
        "patch_sha256": digest(args.patch),
        "patch_format": "unified-zero-context; regeneration script is canonical",
    }, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"typed_root": str(typed), "changed": changed,
                      "unchanged_files": len(before) - len(changed),
                      "patch_sha256": digest(args.patch)}))


if __name__ == "__main__":
    main()
