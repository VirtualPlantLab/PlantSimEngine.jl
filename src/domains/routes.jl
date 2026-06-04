abstract type RouteCardinality end

"""
    ManyToOneVector()

Route cardinality that materializes one value per resolved producer.
"""
struct ManyToOneVector <: RouteCardinality end

"""
    ManyToOneAggregate(reducer=sum)

Route cardinality that reduces resolved producer values to one scalar.
"""
struct ManyToOneAggregate{F} <: RouteCardinality
    reducer::F
end

ManyToOneAggregate() = ManyToOneAggregate(sum)

"""
    OneToManyBroadcast()
    SpatialSample()
    SpatialScatterAdd()

Reserved route cardinalities for the MTG/spatial domain runner.
"""
struct OneToManyBroadcast <: RouteCardinality end
struct SpatialSample <: RouteCardinality end
struct SpatialScatterAdd <: RouteCardinality end

"""
    DomainRouteTarget(domain; scale=:Default, var, process=nothing)

Target of an explicit cross-domain route.
"""
struct DomainRouteTarget
    domain::Symbol
    scale::Symbol
    var::Symbol
    process::Union{Nothing,Symbol}
end

function Base.show(io::IO, target::DomainRouteTarget)
    terms = ["domain=:$(target.domain)"]
    target.scale == :Default || push!(terms, "scale=:$(target.scale)")
    push!(terms, "var=:$(target.var)")
    isnothing(target.process) || push!(terms, "process=:$(target.process)")
    print(io, "DomainRouteTarget(", join(terms, ", "), ")")
end

function DomainRouteTarget(
    domain::Union{Symbol,AbstractString};
    scale::Union{Symbol,AbstractString}=:Default,
    var,
    process=nothing,
)
    return DomainRouteTarget(
        Symbol(domain),
        Symbol(scale),
        Symbol(var),
        isnothing(process) ? nothing : Symbol(process),
    )
end

"""
    Route(from, to; cardinality=ManyToOneVector(), policy=nothing)
    Route(; from, to, cardinality=ManyToOneVector(), policy=nothing)

Explicit cross-domain route materialized into a target domain status before
that domain runs.
"""
struct Route{F,T,C<:RouteCardinality,P<:SchedulePolicy}
    from::F
    to::T
    cardinality::C
    policy::P
end

function Route(from::AllDomains, to::DomainRouteTarget; cardinality::RouteCardinality=ManyToOneVector(), policy=nothing)
    route_policy = isnothing(policy) ? from.policy : _as_schedule_policy(policy; context="Route policy")
    isnothing(from.var) && error(
        "Route source `AllDomains(...)` must declare `var=:source_variable` so the runtime knows what to materialize."
    )
    return Route(from, to, cardinality, route_policy)
end

Route(; from, to, cardinality::RouteCardinality=ManyToOneVector(), policy=nothing) =
    Route(from, to; cardinality=cardinality, policy=policy)
