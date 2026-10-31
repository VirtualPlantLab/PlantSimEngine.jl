module GraphRowProjection

using PlantSimEngine
const PSE = PlantSimEngine
isdefined(Main, :BoundedPreparation) || error("Load BoundedPreparation first")
const BP = getfield(Main, :BoundedPreparation)
isdefined(PSE, :_try_freeze_scenario_relation_rows) || error("Graph projection requires its optional core hook")

export enable_graph_row_projection!, graph_row_projection_report

struct RowLayout
    ids::Vector{Symbol}
    slots::Vector{Int}
    ranks::Dict{Symbol,Int}
end
mutable struct ProjectionCounters
    projection_attempts::Int
    projections_completed::Int
    rows_projected::Int
    edges_projected::Int
    unknown_neighbors_ignored::Int
    layouts_built::Int
    layouts_reused::Int
    declines::Int
end
ProjectionCounters() = ProjectionCounters(0,0,0,0,0,0,0,0)
mutable struct ProjectionState
    layouts::WeakKeyDict{Any,RowLayout}
    counts::ProjectionCounters
    decline_reasons::Dict{Symbol,Int}
end
ProjectionState() = ProjectionState(WeakKeyDict{Any,RowLayout}(), ProjectionCounters(), Dict{Symbol,Int}())
const _enabled = WeakKeyDict{BP.BoundedCounters,ProjectionState}()

"""Enable sparse graph-row projection before preparation, using bounded metadata.

Only authored application IDs, their enumeration ranks and original slots are
cached. Every relation row is read anew and passed through the original bounded
ID/table factories. Numerical models, targets, memberships and values are not
cached or replaced. Unsupported metadata declines before any factory is called.
"""
function enable_graph_row_projection!(model::PSE.CompositeModel)
    counts = get(BP._enabled, model, nothing)
    counts !== nothing && haskey(_enabled, counts) && return model
    isnothing(model.binding_cache) || throw(ArgumentError(
        "Enable graph row projection before initial logical compilation"))
    BP.enable_bounded_preparation!(model)
    _enabled[BP._enabled[model]] = ProjectionState()
    return model
end

function _decline!(state, reason)
    state.counts.declines += 1
    state.decline_reasons[reason] = get(state.decline_reasons, reason, 0) + 1
    return nothing
end

# Read only declared fields: custom getproperty implementations and mutable
# IDs/slots are outside this narrow metadata fast path. Compiled applications
# have a const plan; experimental heap plans retain const ID/slot fields.
Base.@nospecializeinfer @noinline function _identity(application)
    @nospecialize application
    record = if application isa NamedTuple
        application
    elseif application isa PSE.CompiledModelApplication
        getfield(application, :plan)
    else
        return nothing
    end
    record_type = typeof(record)
    hasfield(record_type, :id) && hasfield(record_type, :slot) || return nothing
    if ismutabletype(record_type)
        isconst(record_type, :id) && isconst(record_type, :slot) || return nothing
    end
    id, slot = getfield(record, :id), getfield(record, :slot)
    id isa Symbol && slot isa Int || return nothing
    return (id, slot)
end

Base.@nospecializeinfer @noinline function _layout!(state, applications)
    @nospecialize applications
    applications isa Union{Vector,Tuple} || return nothing
    previous = applications isa Vector ? get(state.layouts, applications, nothing) : nothing
    matches = previous !== nothing && length(previous.ids) == length(applications)
    ids = Symbol[]; slots = Int[]
    for (index, application) in pairs(applications)
        identity = _identity(application)
        identity === nothing && return nothing
        id, slot = identity
        if matches
            matches = previous.ids[index] === id && previous.slots[index] == slot
        end
        push!(ids, id); push!(slots, slot)
    end
    if matches
        state.counts.layouts_reused += 1
        return previous
    end
    ranks = Dict(id => rank for (rank,id) in pairs(ids))
    length(ranks) == length(ids) && length(Set(slots)) == length(slots) || return nothing
    layout = RowLayout(ids, slots, ranks)
    applications isa Vector && (state.layouts[applications] = layout)
    state.counts.layouts_built += 1
    return layout
end

Base.@nospecializeinfer @noinline function PSE._try_freeze_scenario_relation_rows(
    applications, relations, policy::BP.BoundedPolicy,
)
    @nospecialize applications relations
    state = get(_enabled, policy.counts, nothing)
    state === nothing && return nothing
    state.counts.projection_attempts += 1
    # These exact standard containers are what the ordinary graph builder
    # produces. Their Symbol membership/iteration has no user callbacks.
    relations isa Dict{Symbol,Set{Symbol}} || return _decline!(state, :relation_container)
    layout = _layout!(state, applications)
    layout === nothing && return _decline!(state, :application_layout)
    rows = Any[]
    sizehint!(rows, length(layout.ids))
    edges = unknown = 0
    for id in layout.ids
        neighbors = get(relations, id, nothing)
        ranks = Int[]
        if neighbors !== nothing
            sizehint!(ranks, length(neighbors))
            for neighbor in neighbors
                rank = get(layout.ranks, neighbor, 0)
                if iszero(rank)
                    unknown += 1
                else
                    push!(ranks, rank)
                end
            end
            # Rank is authored enumeration order, never numerical slot order.
            sort!(ranks)
        end
        push!(rows, PSE._scenario_metadata_ids(policy, (layout.ids[rank] for rank in ranks)))
        edges += length(ranks)
    end
    table = PSE._scenario_metadata_symbol_table(policy, layout.ids, rows, layout.slots)
    # Credit only completed original-factory tables, not enablement/attempts.
    state.counts.projections_completed += 1
    state.counts.rows_projected += length(layout.ids)
    state.counts.edges_projected += edges
    state.counts.unknown_neighbors_ignored += unknown
    return table
end

Base.@nospecializeinfer @noinline function graph_row_projection_report(value)
    @nospecialize value
    model = value isa PSE.Simulation ? value.model : value
    model isa PSE.CompositeModel || throw(ArgumentError("Expected CompositeModel or Simulation"))
    policy_counts = get(BP._enabled, model, nothing)
    state = policy_counts === nothing ? nothing : get(_enabled, policy_counts, nothing)
    fields = fieldnames(ProjectionCounters)
    counters = NamedTuple{fields}(Tuple(state === nothing ? 0 : getfield(state.counts, field)
        for field in fields))
    return (enabled=state !== nothing, counters,
        decline_reasons=state === nothing ? Dict{Symbol,Int}() : copy(state.decline_reasons),
        row_order=:authored_application_enumeration_not_numerical_slot_order,
        representation=:original_bounded_ID_and_symbol_table_factories,
        cached_metadata=:application_IDs_original_slots_and_enumeration_ranks_only,
        cached_memberships=false, cached_scientific_values=false,
        completion_scope=:actual_returned_relation_tables_not_attempts)
end

end # module
