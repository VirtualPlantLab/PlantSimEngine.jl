"""
    OutputRequest(selector, var; name=var, application=nothing, context=nothing,
                  policy=HoldLast(), clock=nothing)
    OutputRequest(scale, var; kwargs...)

Request retention and optional resampling of one model output stream.

The first form accepts the same `One`, `OptionalOne`, or `Many` selector used
by `ModelSpec` selectors/bindings and object queries. Passing a scale is a
convenience for `Many(scale=scale)`.
"""
struct OutputRequest{S<:AbstractObjectMultiplicity,A<:Union{Nothing,Symbol},CT,POL<:SchedulePolicy,C}
    selector::S
    var::Symbol
    name::Symbol
    application::A
    context::CT
    policy::POL
    clock::C
end

function OutputRequest(
    selector::AbstractObjectMultiplicity,
    var::Symbol;
    name::Symbol=var,
    application=nothing,
    context=nothing,
    policy::SchedulePolicy=HoldLast(),
    clock=nothing,
)
    _validate_selector_context(selector, :output_request)
    app = isnothing(application) ? nothing : Symbol(application)
    return OutputRequest(selector, var, name, app, context, policy, clock)
end

OutputRequest(scale::Union{Symbol,AbstractString}, var::Symbol; kwargs...) =
    OutputRequest(Many(scale=Symbol(scale)), var; kwargs...)

function _export_clock(request::OutputRequest, timeline::TimelineContext)
    isnothing(request.clock) && return ClockSpec(1.0, 0.0)
    clock = _clock_from_spec_timestep(request.clock, timeline)
    isnothing(clock) && error(
        "Unsupported clock specification `$(typeof(request.clock))` in OutputRequest `$(request.name)`."
    )
    return clock
end

function _normalize_output_requests(requests)
    isnothing(requests) && return OutputRequest[]
    requests isa OutputRequest && return OutputRequest[requests]
    requests isa AbstractVector{<:OutputRequest} || error(
        "`outputs` must be `:all`, `:none`, an `OutputRequest`, or a vector of `OutputRequest`."
    )
    return collect(requests)
end
