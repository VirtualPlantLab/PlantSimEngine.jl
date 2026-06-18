"""
    OutputRequest(scale, var; name=var, process=nothing, application=nothing,
                  policy=HoldLast(), clock=nothing)

Request retention and optional resampling of one scene output stream.
"""
struct OutputRequest{P<:Union{Nothing,Symbol},A<:Union{Nothing,Symbol},POL<:SchedulePolicy,C}
    scale::Symbol
    var::Symbol
    name::Symbol
    process::P
    application::A
    policy::POL
    clock::C
end

function OutputRequest(
    scale::Symbol,
    var::Symbol;
    name::Symbol=var,
    process=nothing,
    application=nothing,
    policy::SchedulePolicy=HoldLast(),
    clock=nothing,
)
    proc = isnothing(process) ? nothing : Symbol(process)
    app = isnothing(application) ? nothing : Symbol(application)
    return OutputRequest(scale, var, name, proc, app, policy, clock)
end

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
        "`tracked_outputs` must be `nothing`, an `OutputRequest`, or a vector of `OutputRequest`."
    )
    return collect(requests)
end
