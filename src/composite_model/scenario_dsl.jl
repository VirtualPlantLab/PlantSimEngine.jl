"""
    ObjectAddress(selector)

Return the normalized, structured diagnostic address for an object selector.
The address preserves scope, object labels, producer/callee routing, temporal
policy/window, live-status ordering, and multiplicity.
"""
struct ObjectAddress{SC,K,SP,S,N,P,A,V,R,POL,W,FS,AF,M}
    scope::SC
    kind::K
    species::SP
    scale::S
    name::N
    process::P
    application::A
    var::V
    relation::R
    policy::POL
    window::W
    from_status::FS
    after::AF
    multiplicity::M
end

function ObjectAddress(selector::AbstractObjectMultiplicity)
    c = criteria(selector)
    scope = _criteria_scope(c)
    kind = _criteria_value(c, :kind)
    species = _criteria_value(c, :species)
    scale = _criteria_value(c, :scale)
    name = haskey(c, :name) ? c.name : nothing
    process = haskey(c, :process) ? c.process : nothing
    application = haskey(c, :application) ? c.application : nothing
    var = haskey(c, :var) ? c.var : nothing
    relation = _criteria_value(c, :relation, Relation)
    policy = haskey(c, :policy) ? c.policy : nothing
    window = haskey(c, :window) ? c.window : nothing
    from_status = haskey(c, :from_status) ? c.from_status : false
    after = haskey(c, :after) ? c.after : nothing
    return ObjectAddress(
        scope,
        kind,
        species,
        scale,
        name,
        process,
        application,
        var,
        relation,
        policy,
        window,
        from_status,
        after,
        multiplicity(selector),
    )
end

"""
    object_address(selector)

Return an [`ObjectAddress`](@ref) containing every normalized selector field.
"""
object_address(selector::AbstractObjectMultiplicity) = ObjectAddress(selector)

struct Input{S}
    selector::S
end
Input(; kwargs...) = Input(One(; kwargs...))

"""
    Call(selector::AbstractObjectMultiplicity)
    Call(; kwargs...)

Declare the target selector for a manual hard call. Applications reached only
through `Call` are removed from the root schedule and execute when their owner
invokes [`run_call!`](@ref) or [`call_targets`](@ref).
"""
struct Call{S<:AbstractObjectMultiplicity}
    selector::S
end
Call(; kwargs...) = Call(One(; kwargs...))

"""
    Initializer(selector::One)
    Initializer(; application, ...)

Declare that a normally scheduled application may also initialize one newly
registered object during the lifecycle event that created it. Initializers are
executed with [`run_initializer!`](@ref); unlike [`Call`](@ref) targets, their
callee application remains in the root schedule and retains canonical writer
ownership.
"""
struct Initializer{S<:One}
    selector::S
end

Initializer(; kwargs...) = Initializer(One(; kwargs...))

function Initializer(selector::AbstractObjectMultiplicity)
    error(
        "`Initializer` requires `One(...)` because it initializes exactly " *
        "one newly registered object per invocation; got `$(typeof(selector))`.",
    )
end

function Call(selector::Initializer)
    throw(
        ArgumentError(
            "`Call(Initializer(...))` is not a supported declaration. " *
            "Use `Initializer(...)` directly so the lifecycle mode is explicit.",
        ),
    )
end

_call_binding_selector(selector::AbstractObjectMultiplicity) = selector
_call_binding_selector(binding::Initializer) = binding.selector

function _call_binding_selector(binding)
    error(
        "Call bindings must use `One(...)`, `OptionalOne(...)`, `Many(...)`, " *
        "or `Initializer(One(...))`; got `$(typeof(binding))`.",
    )
end

_call_binding_mode(::AbstractObjectMultiplicity) = :manual
_call_binding_mode(::Initializer) = :initializer

_call_binding_with_selector(::AbstractObjectMultiplicity, selector) = selector
_call_binding_with_selector(::Initializer, selector) = Initializer(selector)

object_address(binding::Initializer) = ObjectAddress(binding.selector)

struct EnvironmentConfig{C}
    config::C
end

_normalize_application_name(name) = isnothing(name) ? nothing : Symbol(name)

function _normalize_application_bindings(bindings::NamedTuple)
    return bindings
end

function _normalize_application_bindings(bindings::Tuple)
    pairs = Pair{Symbol,Any}[]
    for binding in bindings
        binding isa Pair || error(
            "Expected `var => selector` pairs in `ModelSpec(...; inputs=...)` or ",
            "`ModelSpec(...; calls=...)`, got `$(typeof(binding))`."
        )
        key = first(binding)
        selector = last(binding)
        if key isa PreviousTimeStep
            selector isa AbstractObjectMultiplicity || error(
                "A `PreviousTimeStep(...)` input must map to `One(...)`, ",
                "`OptionalOne(...)`, or `Many(...)`."
            )
            push!(
                pairs,
                key.variable => _selector_with_previous_timestep(selector, key),
            )
        else
            key isa Union{Symbol,AbstractString} || error(
                "Binding names in `ModelSpec` inputs and calls must be symbols, ",
                "strings, or `PreviousTimeStep(:input)` markers."
            )
            push!(pairs, Symbol(key) => selector)
        end
    end
    return (; pairs...)
end

function _normalize_application_bindings(binding::Pair)
    return _normalize_application_bindings((binding,))
end

function _normalize_application_bindings(bindings)
    error(
        "Unsupported binding declaration `$(bindings)` of type `$(typeof(bindings))`. ",
        "Use pairs such as `:x => Many(...)` or keyword arguments."
    )
end

function _model_default_value_inputs(model)
    defaults = Pair{Symbol,Any}[]
    for (dep_name, selector) in pairs(dep(model))
        selector isa Input || continue
        push!(defaults, Symbol(dep_name) => selector.selector)
    end
    return (; defaults...)
end

function _model_default_model_calls(model)
    defaults = Pair{Symbol,Any}[]
    for (dep_name, declaration) in pairs(dep(model))
        if declaration isa Call
            push!(defaults, Symbol(dep_name) => declaration.selector)
        elseif declaration isa Initializer
            push!(defaults, Symbol(dep_name) => declaration)
        end
    end
    return (; defaults...)
end

function _merge_value_inputs(defaults::NamedTuple, explicit::NamedTuple)
    return (; pairs(defaults)..., pairs(explicit)...)
end

function _binding_origins(defaults::NamedTuple, explicit::NamedTuple)
    origins = Pair{Symbol,Symbol}[]
    for name in keys(defaults)
        push!(origins, Symbol(name) => :model_default)
    end
    for name in keys(explicit)
        push!(origins, Symbol(name) => :model_spec)
    end
    return (; origins...)
end

function _normalize_binding_origins(origins::NamedTuple, bindings::NamedTuple)
    normalized = Pair{Symbol,Symbol}[]
    for name in keys(bindings)
        origin = haskey(origins, name) ? Symbol(getproperty(origins, name)) : :model_spec
        origin in (:model_default, :model_spec) || error(
            "Unsupported binding origin `$(origin)` for `$(name)`."
        )
        push!(normalized, Symbol(name) => origin)
    end
    return (; normalized...)
end
