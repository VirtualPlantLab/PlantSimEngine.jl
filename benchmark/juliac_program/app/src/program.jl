module ReusableProgram

using PlantSimEngine
using Dates
const PSE = PlantSimEngine

# Deliberately outside src/: this is an admitted subset, not a second public API.
struct Region{M,I,O,E,C,D}
    model_type::Type{M}
    input_type::Type{I}
    output_type::Type{O}
    environment_type::Type{E}
    slot::Int
    name::Symbol
    kind::Symbol
    calls::C
    dependencies::D
end

struct Program{R,S,X}
    regions::R                    # immutable tuple in dependency order
    status_type::Type{S}
    cadence_ms::Int64
    external_type::Type{X}
    model_count::Int
end

struct BoundRegion{M,S,C}
    model::M                      # parameters belong to this simulation
    rows::Vector{S}                # the canonical vector, shared by all regions
    calls::C
    slot::Int
    name::Symbol
end

struct Publication{I,V}
    application::Symbol
    object_id::I
    step::Int
    values::V
end

mutable struct State{P,R,S,I,D,V}
    const program::P
    const regions::R
    const ids::Vector{I}
    const kinds::Vector{Symbol}
    const statuses::Vector{S}      # canonical Ref-backed storage
    const defaults::D
    step::Int
    const publications::Vector{Publication{I,V}}
    retain::Bool
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
    isempty(PSE.dep(spec)) || throw(ArgumentError("legacy dependencies are not admitted"))
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
function prepare(specs::Tuple; initial=NamedTuple())
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
    call_slots = map(specs) do spec
        map(values(spec.calls)) do selector
            _resolve_call_slot(specs, selector)
        end
    end
    # Only trees with one owning root are currently admitted. All selected calls
    # are same-object; the parent controls their scientific order and conditions.
    parents = zeros(Int,length(specs))
    for i in eachindex(specs), child in call_slots[i]
        parents[child] == 0 || parents[child] == i || throw(ArgumentError("shared call owners are not admitted"))
        parents[child] = i
    end
    for i in eachindex(specs)
        _call_root(i,parents)
    end
    roots = findall(iszero,parents)
    edges = [Int[] for _ in specs]
    for (i, spec) in enumerate(specs), (var, declaration) in pairs(PSE.inputs_(spec))
        producer = get(writers, (kinds[i], var), 0)
        if producer == 0
            if declaration isa PSE.Required
                haskey(initial,var) && initial[var] isa PSE._input_expected_type(declaration) ||
                    throw(ArgumentError("unresolved required input"))
            end
        else
            value = PSE.outputs_(specs[producer])[var]
            value isa PSE._input_expected_type(declaration) || throw(ArgumentError("incompatible producer/input types"))
            owner = _call_root(i,parents)
            source_owner = _call_root(producer,parents)
            # Ordinary PSE does not infer soft ordering for call-only targets.
            i == owner && owner != source_owner && push!(edges[owner],source_owner)
        end
    end
    order = Int[]
    while length(order) < length(roots)
        ready = findfirst(i -> !(i in order) && all(in(order), edges[i]), roots)
        isnothing(ready) && throw(ArgumentError("same-step dependency cycle"))
        push!(order, roots[ready])
    end
    regions = map(i -> _recipe(specs,call_slots,kinds,i),Tuple(order))
    defaults = _seeds(map(s -> s.model, specs))
    all(k -> haskey(defaults,k),keys(initial)) || throw(ArgumentError("unknown external input"))
    all(isbits,values(initial)) || throw(ArgumentError("external inputs must be scalar isbits values"))
    defaults = merge(defaults,initial)
    # A single canonical schema is intentionally conservative. Different variable
    # types across categories require separate cohorts in a later milestone.
    return Program(regions, typeof(Status(defaults)), cadence, typeof(initial), length(specs))
end

function _resolve_call_slot(specs,selector)
    selector isa Union{One,Many} || throw(ArgumentError("only same-object manual calls are admitted"))
    criteria = PSE.criteria(selector)
    all(k -> k in (:selectors,:within,:process,:application),keys(criteria)) ||
        throw(ArgumentError("cross-object calls are not admitted"))
    all(x -> x isa PSE.Self,criteria.selectors) || throw(ArgumentError("call scope must be Self"))
    get(criteria,:within,PSE.Self()) isa PSE.Self || throw(ArgumentError("call scope must be Self"))
    matches = findall(eachindex(specs)) do i
        (!haskey(criteria,:application) || specs[i].name === criteria.application) &&
        (!haskey(criteria,:process) || PSE.process(specs[i]) === criteria.process)
    end
    length(matches) == 1 || throw(ArgumentError("call must identify one application"))
    return only(matches)
end
function _call_root(i,parents)
    seen = Set{Int}()
    while parents[i] != 0
        i in seen && throw(ArgumentError("hard call cycle"))
        push!(seen,i)
        i = parents[i]
    end
    return i
end
function _recipe(specs,slots,kinds,i)
    spec = specs[i]
    children = map(child -> _recipe(specs,slots,kinds,child),slots[i])
    calls = NamedTuple{keys(spec.calls)}(children)
    return Region(typeof(spec.model),typeof(PSE.inputs_(spec)),typeof(PSE.outputs_(spec)),
        typeof(PSE.environment_inputs_(spec)),i,spec.name,kinds[i],calls,PSE.dep(spec.model))
end
function _bind(recipe::Region{M,I,O,E}, models, statuses) where {M,I,O,E}
    model = models[recipe.slot]::M
    isequal(PSE.dep(model),recipe.dependencies) && isempty(PSE.environment_outputs_(model)) &&
        PSE._is_default_clock(PSE.timespec(model)) || throw(ArgumentError("changed model dependencies or clock"))
    typeof(PSE.inputs_(model)) === I && typeof(PSE.outputs_(model)) === O &&
        typeof(PSE.environment_inputs_(model)) === E || throw(ArgumentError("changed declaration schema"))
    calls = map(child -> _bind(child,models,statuses),recipe.calls)
    return BoundRegion(model,statuses,calls,recipe.slot,recipe.name)
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

function instantiate(program::Program, models::Tuple, ids::Vector{I}, kinds::Vector{Symbol}; initial=NamedTuple(), retain=false) where {I}
    length(ids) == length(kinds) || throw(ArgumentError("unaligned object columns"))
    length(unique(ids)) == length(ids) || throw(ArgumentError("duplicate object IDs"))
    all(==(first(program.regions).kind), kinds) || throw(ArgumentError("unsupported object category"))
    length(models) == program.model_count || throw(ArgumentError("wrong model count"))
    _validate_defaults(models)
    external = _external_initial(program.external_type,initial)
    defaults = merge(_seeds(models),external)
    typeof(Status(defaults)) === program.status_type || throw(ArgumentError("changed status schema"))
    seed = _initial(defaults, initial)
    statuses = [Status(seed) for _ in ids]
    regions = map(r -> _bind(r, models, statuses), program.regions)
    return State(program, regions, copy(ids), copy(kinds), statuses, defaults, 0,
        Publication{I,typeof(seed)}[],Bool(retain))
end

function _external_initial(::Type{X},initial) where {X}
    names = fieldnames(X)
    all(k -> haskey(initial,k),names) || throw(ArgumentError("missing external input"))
    external = NamedTuple{names}(map(k -> initial[k],names))
    external isa X || throw(ArgumentError("changed external input type"))
    return external
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
# A context is a typed stack view, not an ordinary RunContext/CompiledCompositeModel.
# Call-only applications never enter the root schedule. The target shares exactly
# the current object's canonical status, including parent writes before a call.
struct Context{K,ST,S,E,C}
    kernel::K
    state::ST
    status::S
    row::Int
    environment::E
    constants::C
    suppress_publication::Bool
end
struct Target{C}
    context::C
end
function Base.getproperty(target::Target,name::Symbol)
    context = getfield(target,:context)
    name === :context && return context
    name === :status && return context.status
    name === :model && return context.kernel.model
    name === :object_id && return ObjectId(context.state.ids[context.row])
    throw(ArgumentError("unsupported target property"))
end
struct Targets{T} <: AbstractVector{T}
    target::T
    selected::Bool
end
Base.size(targets::Targets) = (targets.selected ? 1 : 0,)
Base.IndexStyle(::Type{<:Targets}) = IndexLinear()
function Base.getindex(targets::Targets,i::Int)
    @boundscheck checkbounds(targets,i)
    return targets.target
end
function PSE.call_targets(context::Context,name::Symbol)
    kernel = getproperty(context.kernel.calls,name)
    child = Context(kernel,context.state,context.status,context.row,
        context.environment,context.constants,context.suppress_publication)
    return Targets(Target(child),true)
end
function _publish!(context::Context)
    state = context.state
    state.retain || return nothing
    push!(state.publications,Publication(context.kernel.name,state.ids[context.row],
        state.step+1,NamedTuple(context.status)))
    return nothing
end
function _invoke!(context::Context;publish=false)
    PSE.run!(context.kernel.model,context.status,context.environment,context.constants,context)
    publish && !context.suppress_publication && _publish!(context)
    return nothing
end
function PSE.run_call!(target::Target;publish=false,environment=target.context.environment,
                      constants=target.context.constants)
    previous = target.context
    context = Context(previous.kernel,previous.state,previous.status,previous.row,
        environment,constants,previous.suppress_publication || !publish)
    _validate_environment((context.kernel,),environment)
    _invoke!(context;publish)
    return target
end
function PSE.run_call!(context::Context,name::Symbol;publish=false,objects=nothing,
                      environment=context.environment,constants=context.constants)
    targets = PSE.call_targets(context,name)
    selected = isnothing(objects) || ObjectId(context.state.ids[context.row]) == ObjectId(objects)
    selected || throw(ArgumentError("requested object is outside the call targets"))
    PSE.run_call!(targets.target;publish,environment,constants)
    return Targets(targets.target,selected)
end
_run!(::Tuple{},state,environment,constants) = nothing
function _run!(regions::Tuple,state,environment,constants)
    region = first(regions)
    for row in eachindex(region.rows)
        context = Context(region,state,region.rows[row],row,environment,constants,false)
        _invoke!(context;publish=true)
    end
    _run!(Base.tail(regions),state,environment,constants)
end
_validate_environment(::Tuple{}, row) = nothing
function _validate_environment(regions::Tuple, row)
    schema = PSE.environment_inputs_(first(regions).model)
    for (name, declaration) in pairs(schema)
        haskey(row, name) || throw(ArgumentError("missing environment input"))
        expected = declaration isa Union{PSE.Default,PSE.Required} ? PSE._input_expected_type(declaration) : typeof(declaration)
        row[name] isa expected || throw(ArgumentError("changed environment field type"))
    end
    _validate_environment(Tuple(values(first(regions).calls)),row)
    _validate_environment(Base.tail(regions), row)
end

function step!(state::State, environment; constants=nothing)
    _validate_environment(state.regions, environment)
    _run!(state.regions,state, environment, constants)
    state.step += 1
    return state
end

end
