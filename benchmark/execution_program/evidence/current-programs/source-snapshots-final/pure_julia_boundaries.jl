module PureJuliaBoundaries

using PlantSimEngine
const PSE = PlantSimEngine
const Pure = Main.PureJuliaReference

export NoInlinePlainPBContext, advance_pure_noinline_pb!, register_pb_boundaries_case!

"""The same flat scientific state/model payload with a child call boundary."""
struct NoInlinePlainPBContext{M,S,C,N}
    models::M
    status::S
    constants::C
    counts::N
end

# Deliberately preserve one specialized call frame per original dependency.
# Do not force-inline the scientific body inside this helper. This changes
# neither the numerical method nor the state header passed to descendants.
@noinline function _invoke_child!(model, status, environment, constants, context)
    PSE.run!(model, status, environment, constants, context)
    return nothing
end

@inline function _plain_call!(context::NoInlinePlainPBContext,
    ::Val{:photosynthesis}, environment)
    Pure._count_photo!(context.counts)
    _invoke_child!(context.models.photosynthesis, context.status,
        environment, context.constants, context)
    return nothing
end
@inline function _plain_call!(context::NoInlinePlainPBContext,
    ::Val{:stomatal_conductance}, environment)
    Pure._count_stomata!(context.counts)
    _invoke_child!(context.models.stomata, context.status,
        environment, context.constants, context)
    return nothing
end
@noinline _plain_call!(context::NoInlinePlainPBContext,
    ::Val{Name}, environment) where {Name} =
    throw(ArgumentError("Plain PB boundary reference has no call $(Name)"))

@inline Base.@constprop :aggressive function PSE.run_call!(
    context::NoInlinePlainPBContext, name::Symbol;
    sampled_environment, publish::Bool=false,
)
    publish && throw(ArgumentError("The plain PB lower bound has no publication service"))
    return _plain_call!(context, Val(name), sampled_environment)
end

@inline function _plain_call_model(context::NoInlinePlainPBContext,
    ::Val{:stomatal_conductance})
    Pure._count_lookup!(context.counts)
    return context.models.stomata
end
@noinline _plain_call_model(context::NoInlinePlainPBContext, ::Val{Name}) where {Name} =
    throw(ArgumentError("Plain PB boundary reference has no model lookup $(Name)"))
@inline Base.@constprop :aggressive PSE.call_model(context::NoInlinePlainPBContext, name::Symbol) =
    _plain_call_model(context, Val(name))

"""
    advance_pure_noinline_pb!(program::PureJuliaReference.PlainPBProgram; steps=1)

The same time/object order, full flat RefValue status, original Monteith root
and original Fvcb/Medlyn methods as `advance_pure_pb!`. Only child invocation
crosses a noinline helper. This isolates the call boundary and foregone
cross-child compiler optimization from PSE guards, wrappers and projected
headers. It supplies the same narrow numerical protocol, not PSE services.
"""
@noinline function advance_pure_noinline_pb!(program::Pure.PlainPBProgram;
    steps::Integer=1)
    steps >= 0 || throw(ArgumentError("steps must be nonnegative"))
    last_step = program.current_step + steps
    last_step <= length(program.weather) || throw(ArgumentError("Not enough forcing rows"))
    for step in (program.current_step + 1):last_step
        environment = program.weather[step]
        for status in program.rows
            context = NoInlinePlainPBContext(program.models, status,
                program.constants, program.counts)
            Pure._count_root!(program.counts)
            Base.@inline PSE.run!(program.models.energy, status,
                environment, program.constants, context)
        end
        program.current_step = step
    end
    return program
end

"""
Register ordinary/direct-reference/forced-inline/plain-noinline arms using the
same scientific task and measurement phases. The added arm reuses the existing
plain fixture and preparation, so no setup/layout difference is introduced.
"""
function register_pb_boundaries_case!(name::Symbol=:pb_boundaries_small;
    nobjects::Int=2, steps::Int=2, include_direct::Bool=true, replace::Bool=false)
    measurements = getfield(Main, :NativeDownstreamMeasurements)
    base = Pure.register_pure_pb_case!(name; nobjects, steps, include_direct, replace)
    pure_variant = measurements.VariantSpec(:pure_julia)
    variants = (base.variants..., measurements.VariantSpec(:pure_noinline))
    is_boundary(variant) = variant.name === :pure_noinline
    return measurements.register_case!(name; config=base.config, replace=true,
        packages=base.packages, variants,
        construct=(config, variant) -> base.construct(config,
            is_boundary(variant) ? pure_variant : variant),
        prepare=(fixture, config, variant) -> base.prepare(fixture, config,
            is_boundary(variant) ? pure_variant : variant),
        lower=base.lower,
        execute! = (simulation, program, fixture, config, variant) ->
            is_boundary(variant) ? advance_pure_noinline_pb!(simulation; steps=config.steps) :
                base.execute!(simulation, program, fixture, config, variant),
        fingerprint=base.fingerprint,
        coverage=(simulation, program, fixture, config, variant) -> begin
            coverage = base.coverage(simulation, program, fixture, config,
                is_boundary(variant) ? pure_variant : variant)
            is_boundary(variant) || return coverage
            report = (; coverage.report...,
                strategy=:plain_julia_original_PB_noinline_children,
                root_boundary=:forced_inline,
                child_boundary=:specialized_noinline_helper_default_scientific_inlining)
            return (; coverage..., report)
        end,
        work=base.work)
end

end # module
