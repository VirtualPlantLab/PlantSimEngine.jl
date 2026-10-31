module BoundedPreparation

using PlantSimEngine
const PSE = PlantSimEngine

for name in (:_scenario_metadata_policy, :_scenario_metadata_sequence,
    :_scenario_metadata_ids, :_scenario_metadata_symbol_table,
    :_scenario_metadata_scenario_plan, :_scenario_metadata_compiled_scene,
    :_scenario_metadata_selector_index, :_scenario_metadata_schedule,
    :_compile_scene_with_metadata, :_compile_scene_impl)
    isdefined(PSE, name) || error("Bounded preparation requires the experiment's metadata factory hooks")
end

export enable_bounded_preparation!, prepare_bounded, bounded_preparation_report,
    bounded_type_report, BoundedSymbolTable

mutable struct BoundedCounters
    scene_entries::Int
    scene_shells::Int
    scenario_plans::Int
    metadata_sequences::Int
    metadata_id_sequences::Int
    metadata_symbol_tables::Int
    metadata_schedules::Int
    selector_indexes::Int
    maximum_table_entries::Int
end
BoundedCounters() = BoundedCounters(0, 0, 0, 0, 0, 0, 0, 0, 0)
struct BoundedPolicy
    counts::BoundedCounters
end
const _enabled = WeakKeyDict{Any,BoundedCounters}()

"""
An authored-order, fixed-type metadata index. Values remain their original
concrete application/plan objects behind the cold lookup boundary. Symbol keys
and property access name applications; slot lookup uses actual application
slots, including filtered non-dense inputs. No scientific state is stored here.
"""
struct BoundedSymbolTable <: AbstractDict{Symbol,Any}
    names::Vector{Symbol}
    entries::Vector{Any}
    positions::Dict{Symbol,Int}
    slot_positions::Dict{Int,Int}
end
function BoundedSymbolTable(names, entries, slots)
    names = Symbol[name for name in names]
    entries = Any[value for value in entries]
    slots = Int[slot for slot in slots]
    length(names) == length(entries) == length(slots) ||
        throw(ArgumentError("Metadata names, values and slots must align"))
    positions = Dict(name => index for (index, name) in pairs(names))
    slot_positions = Dict(slot => index for (index, slot) in pairs(slots))
    length(positions) == length(names) || throw(ArgumentError("Duplicate metadata name"))
    length(slot_positions) == length(slots) || throw(ArgumentError("Duplicate metadata slot"))
    return BoundedSymbolTable(names, entries, positions, slot_positions)
end
Base.length(table::BoundedSymbolTable) = length(getfield(table, :entries))
Base.keys(table::BoundedSymbolTable) = getfield(table, :names)
Base.values(table::BoundedSymbolTable) = getfield(table, :entries)
Base.haskey(table::BoundedSymbolTable, name::Symbol) = haskey(getfield(table, :positions), name)
Base.haskey(::BoundedSymbolTable, name) = false
Base.getindex(table::BoundedSymbolTable, name::Symbol) =
    getfield(table, :entries)[getfield(table, :positions)[name]]
Base.getindex(table::BoundedSymbolTable, slot::Integer) =
    getfield(table, :entries)[getfield(table, :slot_positions)[Int(slot)]]
function Base.get(table::BoundedSymbolTable, name, default)
    index = get(getfield(table, :positions), name, 0)
    return iszero(index) ? default : getfield(table, :entries)[index]
end
function Base.iterate(table::BoundedSymbolTable, index::Int=1)
    index > length(table) && return nothing
    return getfield(table, :names)[index] => getfield(table, :entries)[index], index + 1
end
Base.getproperty(table::BoundedSymbolTable, name::Symbol) = table[name]
Base.propertynames(table::BoundedSymbolTable, private::Bool=false) = Tuple(keys(table))
PSE._application_plans(table::BoundedSymbolTable, slot::Integer) = table[slot]

"""Enable only before first logical preparation, preserving one representation per run."""
function enable_bounded_preparation!(model::PSE.CompositeModel)
    get(_enabled, model, nothing) === nothing || return model
    isnothing(model.binding_cache) || throw(ArgumentError(
        "Enable bounded preparation before the model's first logical compilation"))
    _enabled[model] = BoundedCounters()
    return model
end

Base.@nospecializeinfer @noinline function PSE._scenario_metadata_policy(model::PSE.CompositeModel)
    @nospecialize model
    counters = get(_enabled, model, nothing)
    return counters === nothing ? Val(:ordinary) : BoundedPolicy(counters)
end

# Vector construction occurs before any all-scene Tuple/NamedTuple is built.
# Each immutable scientific declaration is retained unchanged, not recreated.
Base.@nospecializeinfer @noinline function PSE._scenario_metadata_sequence(policy::BoundedPolicy, values)
    @nospecialize values
    policy.counts.metadata_sequences += 1
    return Any[value for value in values]
end
Base.@nospecializeinfer @noinline function PSE._scenario_metadata_ids(policy::BoundedPolicy, values)
    @nospecialize values
    policy.counts.metadata_id_sequences += 1
    return Symbol[value for value in values]
end
Base.@nospecializeinfer @noinline function PSE._scenario_metadata_symbol_table(policy::BoundedPolicy,
    names, values, slots)
    @nospecialize names values slots
    table = BoundedSymbolTable(names, values, slots)
    policy.counts.metadata_symbol_tables += 1
    policy.counts.maximum_table_entries = max(policy.counts.maximum_table_entries, length(table))
    return table
end

function _bounded_groups(groups::AbstractDict{K}) where {K}
    return Dict{K,Vector{Int}}(key => Int[value for value in values]
        for (key, values) in groups)
end
function PSE._scenario_metadata_selector_index(policy::BoundedPolicy, index::PSE.SelectorCandidateIndex)
    policy.counts.selector_indexes += 1
    return PSE.SelectorCandidateIndex(
        Int[value for value in index.wildcard],
        _bounded_groups(index.by_scale), _bounded_groups(index.by_kind),
        _bounded_groups(index.by_species), _bounded_groups(index.by_id),
        _bounded_groups(index.by_scope_anchor), copy(index.scope_roots),
        Dict(label => copy(values) for (label, values) in index.template_label_values),
        Dict{Any,Any}(),
    )
end
function PSE._scenario_metadata_schedule(policy::BoundedPolicy, entries, always, periodic, generic)
    policy.counts.metadata_schedules += 1
    return PSE.CompiledApplicationSchedule(
        PSE.CompiledApplicationScheduleEntry[entry for entry in entries],
        Int[index for index in always], Int[index for index in periodic],
        Int[index for index in generic])
end
Base.@nospecializeinfer @noinline function PSE._scenario_metadata_scenario_plan(policy::BoundedPolicy, args...)
    @nospecialize args
    policy.counts.scenario_plans += 1
    return PSE.CompiledScenarioPlan(args...)
end
Base.@nospecializeinfer @noinline function PSE._scenario_metadata_compiled_scene(policy::BoundedPolicy, model, args...)
    @nospecialize model args
    policy.counts.scene_shells += 1
    return PSE.CompiledCompositeModel(model, args...)
end
Base.@nospecializeinfer @noinline function PSE._compile_scene_with_metadata(policy::BoundedPolicy,
    model, specs; kwargs...)
    @nospecialize model specs
    policy.counts.scene_entries += 1
    return PSE._compile_scene_impl(model, Any[spec for spec in specs]; kwargs...)
end

function prepare_bounded(model::PSE.CompositeModel; steps::Integer=0, kwargs...)
    enable_bounded_preparation!(model)
    return PSE.run!(model; steps, kwargs...)
end

function _type_width(type, seen=Set{Any}())
    type in seen && return 0
    push!(seen, type)
    type isa DataType || return 0
    width = type <: NamedTuple ? length(type.parameters[1]) :
        type <: Tuple ? length(type.parameters) : 0
    for parameter in type.parameters
        parameter isa Type || continue
        width = max(width, _type_width(parameter, seen))
    end
    return width
end
function bounded_type_report(simulation::PSE.Simulation)
    compiled = simulation.compiled
    return (scenario_type=string(typeof(compiled.scenario_plan)),
        compiled_type_bytes=ncodeunits(string(typeof(compiled))),
        simulation_type_bytes=ncodeunits(string(typeof(simulation))),
        scenario_max_tuple_width=_type_width(typeof(compiled.scenario_plan)),
        compiled_max_tuple_width=_type_width(typeof(compiled)),
        simulation_max_tuple_width=_type_width(typeof(simulation)),
        lookup_type=string(typeof(compiled.applications_by_id)),
        schedule_type=string(typeof(compiled.scenario_plan.application_schedule)),
        scientific_status_types=sort!(unique(string(typeof(view.status))
            for view in values(compiled.status_views_by_target))))
end
function bounded_preparation_report(model::PSE.CompositeModel)
    state = get(_enabled, model, nothing)
    counts = state === nothing ? BoundedCounters() : state
    return (enabled=state !== nothing, scene_entries=counts.scene_entries,
        scene_shells=counts.scene_shells, scenario_plans=counts.scenario_plans,
        metadata_sequences=counts.metadata_sequences,
        metadata_id_sequences=counts.metadata_id_sequences,
        metadata_symbol_tables=counts.metadata_symbol_tables,
        metadata_schedules=counts.metadata_schedules,
        selector_indexes=counts.selector_indexes,
        maximum_table_entries=counts.maximum_table_entries,
        metadata_only=true, cached_memberships=false, cached_sampled_environments=false,
        copied_scientific_values=false,
        scientific_payloads=:ordinary_concrete_model_status_and_carrier_objects,
        representation=:fixed_type_ordered_indexes_and_vectors_before_wide_construction)
end
bounded_preparation_report(simulation::PSE.Simulation) = bounded_preparation_report(simulation.model)

end # module
