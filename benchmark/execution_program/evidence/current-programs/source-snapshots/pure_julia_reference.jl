module PureJuliaReference

using Dates, PlantBiophysics, PlantMeteo, PlantSimEngine

const PB = PlantBiophysics
const PM = PlantMeteo
const PSE = PlantSimEngine

export PlainPBStatus, PlainPBProgram, plain_pb_fixture, prepare_pure_pb,
    advance_pure_pb!, pure_pb_snapshot, pure_pb_report, register_pure_pb_case!

"""Independent scalar cells; no registry Status, binding or execution cache."""
struct PlainPBStatus{N}
    cells::N
end

@inline Base.@constprop :aggressive Base.getproperty(status::PlainPBStatus, name::Symbol) =
    getfield(getfield(status, :cells), name)[]
@inline Base.@constprop :aggressive Base.setproperty!(status::PlainPBStatus, name::Symbol, value) =
    (getfield(getfield(status, :cells), name)[] = value)
Base.propertynames(status::PlainPBStatus, private::Bool=false) = keys(getfield(status, :cells))
Base.keys(status::PlainPBStatus) = keys(getfield(status, :cells))
Base.NamedTuple(status::PlainPBStatus) = map(reference -> reference[], getfield(status, :cells))

mutable struct PlainPBCounters
    roots::Int
    photosynthesis::Int
    stomata::Int
    model_lookups::Int
end
PlainPBCounters() = PlainPBCounters(0, 0, 0, 0)

@inline _count_root!(::Nothing) = nothing
@inline _count_root!(counts::PlainPBCounters) = (counts.roots += 1; nothing)
@inline _count_photo!(::Nothing) = nothing
@inline _count_photo!(counts::PlainPBCounters) = (counts.photosynthesis += 1; nothing)
@inline _count_stomata!(::Nothing) = nothing
@inline _count_stomata!(counts::PlainPBCounters) = (counts.stomata += 1; nothing)
@inline _count_lookup!(::Nothing) = nothing
@inline _count_lookup!(counts::PlainPBCounters) = (counts.model_lookups += 1; nothing)

"""
A numerical protocol for this exact fixed PB stack. Original PB methods call
PSE.run_call!/call_model, so narrowly dispatch those names to ordinary Julia
calls. This is not a RunContext and implements no general PSE service.
"""
struct PlainPBContext{M,S,C,N}
    models::M
    status::S
    constants::C
    counts::N
end

@inline function _plain_call!(context::PlainPBContext, ::Val{:photosynthesis}, environment)
    _count_photo!(context.counts)
    Base.@inline PSE.run!(context.models.photosynthesis, context.status,
        environment, context.constants, context)
    return nothing
end
@inline function _plain_call!(context::PlainPBContext, ::Val{:stomatal_conductance}, environment)
    _count_stomata!(context.counts)
    Base.@inline PSE.run!(context.models.stomata, context.status,
        environment, context.constants, context)
    return nothing
end
@noinline _plain_call!(context::PlainPBContext, ::Val{Name}, environment) where {Name} =
    throw(ArgumentError("Plain PB numerical reference has no call $(Name)"))

# Both original Monteith and Fvcb ignore these unpublished calls' return value.
# Reject publication/other keywords rather than silently pretending to supply
# CallTargets, accepted evaluations, lifecycle or output history semantics.
@inline Base.@constprop :aggressive function PSE.run_call!(
    context::PlainPBContext, name::Symbol; sampled_environment, publish::Bool=false,
)
    publish && throw(ArgumentError("The plain PB lower bound has no publication service"))
    return _plain_call!(context, Val(name), sampled_environment)
end

@inline function _plain_call_model(context::PlainPBContext, ::Val{:stomatal_conductance})
    _count_lookup!(context.counts)
    return context.models.stomata
end
@noinline _plain_call_model(context::PlainPBContext, ::Val{Name}) where {Name} =
    throw(ArgumentError("Plain PB numerical reference has no model lookup $(Name)"))
@inline Base.@constprop :aggressive PSE.call_model(context::PlainPBContext, name::Symbol) =
    _plain_call_model(context, Val(name))

"""
    plain_pb_fixture(; nobjects=2, steps=2)

The same model parameters, initial scientific values and varying hourly
Atmosphere forcing as NativePBDriver.pb_native_fixture. Construct independent
values without preparing a CompositeModel or borrowing an oracle's state.
No scientific equation or iteration is reimplemented.
"""
function plain_pb_fixture(; nobjects::Int=2, steps::Int=2)
    nobjects > 0 && steps > 0 || throw(ArgumentError("Positive objects/steps required"))
    models = (energy=PB.Monteith(), photosynthesis=PB.Fvcb(), stomata=PB.Medlyn(0.03, 12.0))
    initial = [(Ra_SW_f=150.0 + mod(index, 7), sky_fraction=0.8,
        aPPFD=(150.0 + mod(index, 7)) * 0.48 * 4.57, d=0.03)
        for index in 1:nobjects]
    weather = PM.Weather([
        PM.Atmosphere(T=24.0 + 0.25 * mod(step - 1, 5), Wind=1.5,
            P=101.325, Rh=0.65, Cₐ=410.0, duration=Hour(1)) for step in 1:steps])
    return (; models, initial, weather, nobjects, steps)
end

mutable struct PlainPBProgram{R,W,M,C,N}
    rows::R
    weather::W
    models::M
    constants::C
    counts::N
    current_step::Int
end

"""
    prepare_pure_pb(fixture; count_calls=false, constants=PlantMeteo.Constants())

Allocate fresh RefValue cells for the union of original model output defaults
and supplied inputs, preserving every individual value type. `count_calls=true`
is an independent work audit; normal timing uses Nothing so its counter code
is removed by specialization. Numerical state never aliases a PSE oracle.
"""
function prepare_pure_pb(fixture; count_calls::Bool=false, constants=PM.Constants())
    models = fixture.models
    defaults = merge(PSE.outputs_(models.energy), PSE.outputs_(models.photosynthesis),
        PSE.outputs_(models.stomata))
    counts = count_calls ? PlainPBCounters() : nothing
    rows = [begin
        values = merge(defaults, initial)
        PlainPBStatus(map(value -> Base.RefValue(value), values))
    end for initial in fixture.initial]
    return PlainPBProgram(rows, fixture.weather, models, constants, counts, 0)
end

"""
Advance only the scientific numerical loop: time outside objects, identical
hourly forcing, and the original Monteith iterative kernel including every
original Fvcb/Medlyn call. No scheduler, binding refresh, cached targets,
publication, output collection or lifecycle operation is emulated.
"""
@noinline function advance_pure_pb!(program::PlainPBProgram; steps::Integer=1)
    steps >= 0 || throw(ArgumentError("steps must be nonnegative"))
    last_step = program.current_step + steps
    last_step <= length(program.weather) || throw(ArgumentError("Not enough forcing rows"))
    for step in (program.current_step + 1):last_step
        environment = program.weather[step]
        for status in program.rows
            # Immutable transient context: original kernels do not retain it,
            # so specialization can eliminate its construction completely.
            context = PlainPBContext(program.models, status, program.constants, program.counts)
            _count_root!(program.counts)
            Base.@inline PSE.run!(program.models.energy, status,
                environment, program.constants, context)
        end
        program.current_step = step
    end
    return program
end

"""Match CR.portable_downstream_snapshot for this fixed outputs=:none task."""
function pure_pb_snapshot(program::PlainPBProgram)
    states = [(id=repr(index), fields=sort!([
        (name=string(name), type=string(typeof(value)), value=repr(value))
        for (name, value) in pairs(NamedTuple(status))]; by=row -> row.name))
        for (index, status) in enumerate(program.rows)]
    sort!(states; by=row -> row.id)
    history = NamedTuple{(:key,:samples),Tuple{String,String}}[]
    return (step=program.current_step, states, history)
end

function pure_pb_report(program::PlainPBProgram)
    counts = program.counts
    work = counts === nothing ? nothing : (roots=counts.roots,
        photosynthesis=counts.photosynthesis, stomata=counts.stomata,
        model_lookups=counts.model_lookups)
    return (strategy=:plain_julia_original_PB_numerical_loop,
        current_step=program.current_step, objects=length(program.rows), work,
        counters=counts === nothing ? :compiled_out : :instrumented_companion,
        state=:independent_NamedTuple_RefValue_cells,
        scientific_methods=:original_unmodified_Monteith_Fvcb_Medlyn,
        fixture_equivalence=:scientific_state_precision_forcing_and_iterative_work,
        omitted_services=(:scheduler, :bindings, :target_views, :publication,
            :history, :lifecycle, :general_environment_backends),
        interpretation=:fixed_task_numerical_lower_bound_not_full_PSE_replacement)
end

"""
    register_pure_pb_case!(name=:pb_pure_small; nobjects=2, steps=2,
        include_direct=true, replace=false)

Register fresh ordinary/direct-reference/Pure Julia arms with the existing
measurement protocol. All arms use outputs=:none and compare the same complete
scientific field/type snapshot. Pure Julia is explicitly a numerical lower
bound, so complete-cost results do not claim equal framework capabilities.
"""
function register_pure_pb_case!(name::Symbol=:pb_pure_small;
    nobjects::Int=2, steps::Int=2, include_direct::Bool=true, replace::Bool=false)
    measurements = getfield(Main, :NativeDownstreamMeasurements)
    driver = getfield(Main, :NativePBDriver)
    regions = getfield(Main, :CompiledRegionsExperiment)
    direct = include_direct ? getfield(Main, :DirectCallCompiler) : nothing
    config = (; nobjects, steps, outputs=:none,
        qualification=:same_fixed_scientific_task_numerical_lower_bound)
    variants = [measurements.VariantSpec(:reference_executor)]
    include_direct && push!(variants, measurements.VariantSpec(:direct_reference; driver=true))
    push!(variants, measurements.VariantSpec(:pure_julia))
    return measurements.register_case!(name; config, replace, variants=Tuple(variants),
        packages=(PSE, PB, PM),
        construct=(config, variant) -> variant.name === :pure_julia ?
            plain_pb_fixture(; nobjects=config.nobjects, steps=config.steps) :
            driver.pb_native_fixture(; native=false, nobjects=config.nobjects, steps=config.steps),
        prepare=(fixture, config, variant) -> variant.name === :pure_julia ?
            prepare_pure_pb(fixture) : variant.name === :direct_reference ?
                direct.prepare_direct_calls(fixture.model; steps=0, outputs=:none,
                    state_strategy=:references, status_strategy=:direct) :
                PSE.run!(fixture.model; steps=0, outputs=:none),
        lower=(simulation, fixture, config, variant) -> nothing,
        execute! = (simulation, program, fixture, config, variant) ->
            variant.name === :pure_julia ? advance_pure_pb!(simulation; steps=config.steps) :
                PSE.continue!(simulation; steps=config.steps),
        fingerprint=(simulation, fixture, config) -> simulation isa PlainPBProgram ?
            pure_pb_snapshot(simulation) : regions.portable_downstream_snapshot(simulation),
        coverage=(simulation, program, fixture, config, variant) -> begin
            if simulation isa PlainPBProgram
                report = pure_pb_report(simulation)
                return (native_fields=0, driver_units=0, native_driver_units=0,
                    completed_plain_roots=length(simulation.rows) * simulation.current_step,
                    report, qualification=:separately_work_checked_numerical_lower_bound)
            elseif variant.name === :direct_reference
                report = direct.direct_call_report(simulation)
                report.executed_numerical_roots > 0 && report.executed_numerical_calls > 0 ||
                    error("Direct control performed no optimized original-kernel work")
                return (native_fields=0,
                    driver_units=report.executed_numerical_roots + report.executed_numerical_calls,
                    native_driver_units=0, report)
            end
            return (native_fields=0, driver_units=0, native_driver_units=0)
        end,
        work=(simulation, fixture, config) -> simulation isa PlainPBProgram ?
            (steps=simulation.current_step, objects=length(simulation.rows),
                added_ids=Int[], objects_by_scale=Dict(:diagnostic_unit => length(simulation.rows)),
                streams=0) : regions.downstream_work_report(simulation,
                    [object.id for object in PSE.model_objects(fixture.model)]))
end

end # module
