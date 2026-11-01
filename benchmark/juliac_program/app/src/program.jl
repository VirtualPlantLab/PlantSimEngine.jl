module ReusableProgram

using PlantSimEngine
using Dates
const PSE = PlantSimEngine

# Deliberately outside src/: this is an admitted subset, not a second public API.
struct Region{M,I,O,E}
    model_type::Type{M}
    input_type::Type{I}
    output_type::Type{O}
    environment_type::Type{E}
    slot::Int
    name::Symbol
    kind::Symbol
end

struct Program{R,S}
    regions::R                    # immutable tuple in dependency order
    status_type::Type{S}
    cadence_ms::Int64
end

struct BoundRegion{M,S}
    model::M                      # parameters belong to this simulation
    rows::Vector{S}                # the canonical vector, shared by all regions
end

mutable struct State{P,R,S,I,D}
    const program::P
    const regions::R
    const ids::Vector{I}
    const kinds::Vector{Symbol}
    const statuses::Vector{S}      # canonical Ref-backed storage
    const defaults::D
    step::Int
end

_input_seed(x::PSE.Default) = x.value
_input_seed(::PSE.Required) = nothing # overwritten by its unique producer
_input_seeds(::Tuple{}) = NamedTuple()
_input_seeds(models::Tuple) = merge(map(_input_seed, PSE.inputs_(first(models))), _input_seeds(Base.tail(models)))
_output_seeds(::Tuple{}) = NamedTuple()
_output_seeds(models::Tuple) = merge(PSE.outputs_(first(models)), _output_seeds(Base.tail(models)))
_seeds(models::Tuple) = merge(_input_seeds(models), _output_seeds(models))

function _admit(spec)
    spec.applies_to isa Many || throw(ArgumentError("only Many(kind=...) targets are admitted"))
    c = PSE.criteria(spec.applies_to)
    keys(c) == (:selectors, :kind) && isempty(c.selectors) || throw(ArgumentError("only kind targets are admitted"))
    isempty(spec.inputs) || throw(ArgumentError("explicit input routing is not admitted"))
    isempty(spec.calls) && isempty(PSE.dep(spec)) || throw(ArgumentError("calls are not admitted"))
    isempty(spec.outputs_to) || throw(ArgumentError("distributed outputs are not admitted"))
    isempty(spec.output_routing) && isempty(spec.updates) || throw(ArgumentError("writer routing is not admitted"))
    isnothing(spec.environment) && isempty(spec.environment_bindings) && isnothing(spec.environment_window) ||
        throw(ArgumentError("custom environment bindings are not admitted"))
    isempty(PSE.environment_outputs_(spec)) || throw(ArgumentError("environment commits are not admitted"))
    PSE._is_default_clock(PSE.timespec(spec.model)) || throw(ArgumentError("model time defaults are not admitted yet"))
    isnothing(spec.name) && throw(ArgumentError("name every application"))
    spec.timestep isa Dates.Period || throw(ArgumentError("declare an explicit fixed cadence"))
    all(x -> isbits(x) && !(x isa PSE.Distributed), values(PSE.outputs_(spec))) || throw(ArgumentError("only scalar isbits outputs are admitted"))
    all(x -> x isa Union{PSE.Required,PSE.Default}, values(PSE.inputs_(spec))) ||
        throw(ArgumentError("invalid input declarations"))
    all(x -> !(x isa PSE.Default) || isbits(x.value), values(PSE.inputs_(spec))) ||
        throw(ArgumentError("mutable defaults are not admitted"))
    return c.kind
end

"""Prepare once from existing contracts, without constructing a CompositeModel or Simulation.
Only unique same-object writers, one fixed cadence and plain global rows are admitted.
Unknown context operations fail in the original kernel (context is nothing).
"""
function prepare(specs::Tuple)
    isempty(specs) && throw(ArgumentError("empty program"))
    kinds = map(_admit, specs)
    all(==(first(kinds)), kinds) || throw(ArgumentError("one object category per program is admitted"))
    cadence = Dates.value(convert(Millisecond, first(specs).timestep))
    cadence > 0 || throw(ArgumentError("cadence must be positive"))
    all(s -> Dates.value(convert(Millisecond, s.timestep)) == cadence, specs) ||
        throw(ArgumentError("mixed cadences are not admitted"))
    length(unique(map(s -> s.name, specs))) == length(specs) || throw(ArgumentError("duplicate application names"))
    writers = Dict{Tuple{Symbol,Symbol},Int}()
    for (i, spec) in enumerate(specs), var in keys(PSE.outputs_(spec))
        key = (kinds[i], var)
        haskey(writers, key) && throw(ArgumentError("duplicate writer"))
        writers[key] = i
    end
    defaults = Dict{Symbol,Any}()
    for spec in specs, (var, declaration) in pairs(PSE.inputs_(spec))
        declaration isa PSE.Default || continue
        haskey(writers, (first(kinds), var)) && continue
        if haskey(defaults, var) && !(typeof(defaults[var]) === typeof(declaration.value) && isequal(defaults[var], declaration.value))
            throw(ArgumentError("contradictory input defaults"))
        end
        defaults[var] = declaration.value
    end
    edges = [Int[] for _ in specs]
    for (i, spec) in enumerate(specs), (var, declaration) in pairs(PSE.inputs_(spec))
        producer = get(writers, (kinds[i], var), 0)
        if producer == 0
            declaration isa PSE.Default || throw(ArgumentError("unresolved required input"))
        else
            value = PSE.outputs_(specs[producer])[var]
            value isa PSE._input_expected_type(declaration) || throw(ArgumentError("incompatible producer/input types"))
            producer != i && push!(edges[i], producer)
        end
    end
    order = Int[]
    while length(order) < length(specs)
        ready = findfirst(i -> !(i in order) && all(in(order), edges[i]), eachindex(specs))
        isnothing(ready) && throw(ArgumentError("same-step dependency cycle"))
        push!(order, ready)
    end
    regions = map(Tuple(order)) do i
        s = specs[i]
        Region(typeof(s.model), typeof(PSE.inputs_(s)), typeof(PSE.outputs_(s)),
            typeof(PSE.environment_inputs_(s)), i, s.name, kinds[i])
    end
    defaults = _seeds(map(s -> s.model, specs))
    # A single canonical schema is intentionally conservative. Different variable
    # types across categories require separate cohorts in a later milestone.
    return Program(regions, typeof(Status(defaults)), cadence)
end

function _bind(recipe::Region{M,I,O,E}, models, statuses) where {M,I,O,E}
    model = models[recipe.slot]::M
    isempty(PSE.dep(model)) && isempty(PSE.environment_outputs_(model)) &&
        PSE._is_default_clock(PSE.timespec(model)) || throw(ArgumentError("changed model dependencies or clock"))
    typeof(PSE.inputs_(model)) === I && typeof(PSE.outputs_(model)) === O &&
        typeof(PSE.environment_inputs_(model)) === E || throw(ArgumentError("changed declaration schema"))
    return BoundRegion(model, statuses)
end

function _validate_defaults(models::Tuple)
    for model in models, (var, declaration) in pairs(PSE.inputs_(model))
        declaration isa PSE.Default || continue
        any(other -> haskey(PSE.outputs_(other), var), models) && continue
        for other in models
            input = PSE.inputs_(other)
            haskey(input, var) || continue
            candidate = input[var]
            candidate isa PSE.Default || continue
            typeof(candidate.value) === typeof(declaration.value) &&
                isequal(candidate.value, declaration.value) || throw(ArgumentError("contradictory input defaults"))
        end
    end
    return nothing
end

function instantiate(program::Program, models::Tuple, ids::Vector{I}, kinds::Vector{Symbol}; initial=NamedTuple()) where {I}
    length(ids) == length(kinds) || throw(ArgumentError("unaligned object columns"))
    length(unique(ids)) == length(ids) || throw(ArgumentError("duplicate object IDs"))
    all(==(first(program.regions).kind), kinds) || throw(ArgumentError("unsupported object category"))
    length(models) == length(program.regions) || throw(ArgumentError("wrong model count"))
    _validate_defaults(models)
    defaults = _seeds(models)
    typeof(Status(defaults)) === program.status_type || throw(ArgumentError("changed status schema"))
    seed = _initial(defaults, initial)
    statuses = [Status(seed) for _ in ids]
    regions = map(r -> _bind(r, models, statuses), program.regions)
    return State(program, regions, copy(ids), copy(kinds), statuses, defaults, 0)
end

function _initial(defaults, initial)
    all(k -> haskey(defaults, k), keys(initial)) || throw(ArgumentError("unknown initial variable"))
    seed = merge(defaults, initial)
    typeof(seed) === typeof(defaults) || throw(ArgumentError("changed initial field type"))
    return seed
end

"""Add one object at a timestep boundary; existing statuses/references stay live.
All schema/model families are known even when a region initially has no rows.
"""
function add_object!(state::State{P,R,S,I}, id::I, kind::Symbol; initial=NamedTuple()) where {P,R,S,I}
    id in state.ids && throw(ArgumentError("duplicate object ID"))
    kind === first(state.program.regions).kind || throw(ArgumentError("unsupported object category"))
    status = Status(_initial(state.defaults, initial))::S
    push!(state.ids, id); push!(state.kinds, kind); push!(state.statuses, status)
    return status
end
_run!(::Tuple{}, environment, constants) = nothing
function _run!(regions::Tuple, environment, constants)
    region = first(regions)
    _run_region!(region, environment, constants)
    _run!(Base.tail(regions), environment, constants)
end
function _run_region!(region::BoundRegion, environment, constants)
    for status in region.rows
        PSE.run!(region.model, status, environment, constants, nothing)
    end
end
_validate_environment(::Tuple{}, row) = nothing
function _validate_environment(regions::Tuple, row)
    schema = PSE.environment_inputs_(first(regions).model)
    for (name, declaration) in pairs(schema)
        haskey(row, name) || throw(ArgumentError("missing environment input"))
        expected = declaration isa Union{PSE.Default,PSE.Required} ? PSE._input_expected_type(declaration) : typeof(declaration)
        row[name] isa expected || throw(ArgumentError("changed environment field type"))
    end
    _validate_environment(Base.tail(regions), row)
end

function step!(state::State, environment; constants=nothing)
    _validate_environment(state.regions, environment)
    _run!(state.regions, environment, constants)
    state.step += 1
    return state
end

end
