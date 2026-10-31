module NativeXPDriver

using PlantSimEngine
using XPalm
using Random
using SHA
using Test
using MultiScaleTreeGraph

const PSE = PlantSimEngine
if !isdefined(Main, :CompiledRegionsExperiment)
    Base.include(Main, joinpath(@__DIR__, "../compiled_regions/CompiledRegionsExperiment.jl"))
end
const CR = Main.CompiledRegionsExperiment
const GP = CR.GP
if !isdefined(Main, :NativeScalarDriver)
    Base.include(Main, joinpath(@__DIR__, "scalar_driver.jl"))
end
const NS = Main.NativeScalarDriver

include("storage_checks.jl")

# Preserve the logical carrier kind and every scientific type, including
# empty retained-stream schemas. Only RefVector's backing-reference parameter
# and ObjectRefVector's physical reference-vector parameter are erased.
_xp_logical_type(type) = string(type)
_xp_logical_type(::Type{<:PSE.RefVector{T}}) where {T} =
    (:RefVector, _xp_logical_type(T))
_xp_logical_type(::Type{<:PSE.ObjectRefVector}) = (:ObjectRefVector, "Any")
_xp_logical_type(type::Type{<:Tuple}) =
    (:Tuple, map(_xp_logical_type, type.parameters))
_xp_logical_type(type::Type{<:NamedTuple}) =
    (:NamedTuple, type.parameters[1], _xp_logical_type(type.parameters[2]))
_xp_logical_type(type::Type{<:Array}) =
    (:Array, _xp_logical_type(eltype(type)), ndims(type))

_xp_logical_value(value) = (type=_xp_logical_type(typeof(value)), value=repr(value))
_xp_logical_value(value::PSE.RefVector) = (
    type=_xp_logical_type(typeof(value)), shape=size(value),
    values=map(_xp_logical_value, collect(value)),
)
_xp_logical_value(value::PSE.ObjectRefVector) = (
    type=_xp_logical_type(typeof(value)), shape=size(value),
    values=map(_xp_logical_value, collect(value)),
)
_xp_logical_value(value::Tuple) = (
    type=_xp_logical_type(typeof(value)), values=map(_xp_logical_value, value),
)
_xp_logical_value(value::NamedTuple) = (
    type=_xp_logical_type(typeof(value)), names=keys(value),
    values=map(_xp_logical_value, values(value)),
)
_xp_logical_value(value::Array) = (
    type=_xp_logical_type(typeof(value)), shape=size(value),
    values=[_xp_logical_value(element) for element in value],
)

function xp_portable_snapshot(simulation)
    observed = CR.downstream_fingerprint(simulation)
    states = [(id=repr(id.value), fields=sort!([
        (name=string(name), observation=_xp_logical_value(value))
        for (name, value) in pairs(state)]; by=field -> field.name))
        for (id, state) in observed.states]
    sort!(states; by=state -> state.id)
    history = sort!([(key=repr(key), samples=_xp_logical_value(samples))
        for (key, samples) in observed.histories]; by=stream -> stream.key)
    return (; step=observed.step, states, history)
end

xp_semantic_digest(simulation) = bytes2hex(sha256(repr(xp_portable_snapshot(simulation))))

function xp_carrier_snapshot_diagnostic(reference, candidate)
    raw_reference = CR.portable_downstream_snapshot(reference)
    raw_candidate = CR.portable_downstream_snapshot(candidate)
    left = Dict((state.id, field.name) => (field.type, field.value)
        for state in raw_reference.states for field in state.fields)
    right = Dict((state.id, field.name) => (field.type, field.value)
        for state in raw_candidate.states for field in state.fields)
    changed_fields = [(id=key[1], name=key[2], reference=get(left, key, nothing),
        candidate=get(right, key, nothing)) for key in union(keys(left), keys(right))
        if !isequal(get(left, key, nothing), get(right, key, nothing))]
    normalized_reference = xp_portable_snapshot(reference)
    normalized_candidate = xp_portable_snapshot(candidate)
    return (raw_changed_fields=changed_fields,
        raw_histories_equal=isequal(raw_reference.history, raw_candidate.history),
        normalized_states_equal=isequal(normalized_reference.states, normalized_candidate.states),
        normalized_histories_equal=isequal(normalized_reference.history, normalized_candidate.history),
        normalized_equal=isequal(normalized_reference, normalized_candidate),
        normalization=:only_physical_reference_parameters_of_logical_carriers,
        empty_history_schema_preserved=true)
end

"""The exact XPalm import values, before allocating any reference cells."""
function xpalm_initial_values(node)
    attrs = MultiScaleTreeGraph.node_attributes(node)
    data = Dict{Symbol,Any}()
    for (key, value) in pairs(attrs)
        name = Symbol(key)
        name == :plantsimengine_status && error("Legacy XPalm runtime status attribute")
        data[name] = value
    end
    # This is XPalm's scientific import policy, not a compiler selection rule.
    if MultiScaleTreeGraph.symbol(node) in (:Phytomer, :Internode, :Leaf, :Male, :Female)
        for (name, value) in pairs((plant_age=-9999, initiation_age=0,
            TT_since_init=0.0, state=:undetermined, sex=:undetermined))
            get!(data, name, value)
        end
    end
    data[:node] = node
    return (; data...)
end

function xpalm_native_fixture(; steps::Int=4, emission_speed::Real=0.2,
    seed::Int=1, weather=nothing, native::Bool=true)
    steps > 0 || throw(ArgumentError("steps must be positive"))
    Random.seed!(seed)
    parameters = XPalm.default_parameters()
    parameters["phyllochron"]["production_speed_initial"] = Float64(emission_speed)
    parameters["phyllochron"]["production_speed_mature"] = Float64(emission_speed)
    palm = XPalm.Palm(initiation_age=0, parameters=parameters)
    forcing = isnothing(weather) ? CR._xpalm_fixture_weather(steps) : copy(weather)
    native || return XPalm.xpalm_scene(palm; environment=forcing, architecture=false)
    return PSE.CompositeModel(palm.mtg;
        applications=XPalm.model_applications(palm; architecture=false),
        environment=forcing, status=xpalm_initial_values,
        status_storage=PSE.NativeColumnStorage())
end

function xp_native_small_gate(; steps::Int=4, outputs=:all)
    control = PSE.run!(xpalm_native_fixture(; steps, native=false); steps=0, outputs)
    reference_driver = PSE.run!(xpalm_native_fixture(; steps, native=false); steps=0, outputs)
    native_control = PSE.run!(xpalm_native_fixture(; steps, native=true); steps=0, outputs)
    candidate = PSE.run!(xpalm_native_fixture(; steps, native=true); steps=0, outputs)
    initial_ids = collect(PSE.object_ids(PSE.runtime_model(candidate)))
    initial_digest = xp_semantic_digest(candidate)
    initial_digest == xp_semantic_digest(control) || error("XP native construction differs")
    program = NS.compile_native_scalar(candidate)
    reference_program = NS.compile_native_scalar(reference_driver; state_strategy=:references)
    xp_semantic_digest(candidate) == initial_digest || error("XP lowering changed canonical values")
    for _ in 1:steps
        PSE.continue!(control; steps=1)
        PSE.continue!(native_control; steps=1)
        NS.advance_native_scalar!(program; steps=1)
        NS.advance_native_scalar!(reference_program; steps=1)
        expected = xp_semantic_digest(control)
        xp_semantic_digest(native_control) == expected || error("XP native storage parity failed")
        xp_semantic_digest(candidate) == expected || error("XP native typed driver parity failed")
        xp_semantic_digest(reference_driver) == expected || error("XP reference typed driver parity failed")
    end
    work = CR.downstream_work_report(candidate, initial_ids)
    report = NS.native_scalar_report(program)
    length(work.added_ids) >= 3 || error("XP small gate did not create three objects")
    report.native_row_executions > 0 || error("XP typed driver executed no canonical column rows")
    report.storage.active_native_fields > 0 || error("XP canonical columns are unused")
    newborn_native = count(PSE.model_objects(PSE.runtime_model(candidate))) do object
        object.id in initial_ids && return false
        any(reference -> reference isa Base.RefArray, PSE.refvalues(object.status))
    end
    newborn_native >= 3 || error("XP newborns lack native canonical fields")
    return (passed=true, digest=xp_semantic_digest(candidate), work, report,
        reference_driver_report=NS.native_scalar_report(reference_program),
        newborn_native_objects=newborn_native,
        source_parity=:exact_full_state_and_raw_stream_history_each_step)
end

function register_xp_case!(name::Symbol=:xpalm_small; steps::Int=4,
    emission_speed::Real=0.2, seed::Int=1, outputs=:all, replace=false)
    isdefined(Main, :NativeDownstreamMeasurements) ||
        error("Load measurements.jl before registering XPalm cases")
    measurements = Main.NativeDownstreamMeasurements
    # File I/O is outside all measured construction/execution phases.
    weather = CR._xpalm_fixture_weather(steps)
    config = (; steps, emission_speed, seed, outputs,
        scientific_interpretation=:diagnostic_accelerated_growth_not_calibration)
    return measurements.register_case!(name; config, replace, packages=(PSE, XPalm),
        construct=(config, variant) -> begin
            model = xpalm_native_fixture(; steps=config.steps,
                emission_speed=config.emission_speed, seed=config.seed, weather,
                native=variant.needs_native)
            (model=model, initial_ids=collect(PSE.object_ids(model)), native=variant.needs_native)
        end,
        prepare=(fixture, config, variant) -> PSE.run!(fixture.model; steps=0, outputs=config.outputs),
        lower=(simulation, fixture, config, variant) -> variant.needs_driver ?
            NS.compile_native_scalar(simulation;
                state_strategy=variant.needs_native ? :native : :references) : nothing,
        execute! = (simulation, program, fixture, config, variant) -> isnothing(program) ?
            PSE.continue!(simulation; steps=config.steps) :
            NS.advance_native_scalar!(program; steps=config.steps),
        fingerprint=(simulation, fixture, config) -> xp_portable_snapshot(simulation),
        coverage=(simulation, program, fixture, config, variant) -> begin
            storage = PSE.native_storage_report(fixture.model)
            if isnothing(program)
                return (native_fields=fixture.native ? storage.active_native_fields : 0,
                    driver_units=0, native_driver_units=0, storage,
                    ordinary_timeline_steps=PSE.current_step(simulation))
            end
            report = NS.native_scalar_report(program)
            return (native_fields=report.executed_native_column_fields,
                driver_units=report.driver_row_executions,
                native_driver_units=report.native_row_executions, storage, report)
        end,
        work=(simulation, fixture, config) ->
            CR.downstream_work_report(simulation, fixture.initial_ids))
end

end # module
