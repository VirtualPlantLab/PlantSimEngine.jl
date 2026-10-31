module NativeGenericDriver

using Dates
using PlantSimEngine

const PSE = PlantSimEngine
const CR = Main.CompiledRegionsExperiment
const GP = CR.GP
const Measurements = Main.NativeDownstreamMeasurements
const Scalar = Main.NativeScalarDriver

export generic_native_fixture, register_generic_case!, register_width_cases!,
    register_object_scaling_cases!, generic_fixture_checks

_numeric_type(name::Symbol) = name === :Float64 ? Float64 : name === :Float32 ? Float32 :
    throw(ArgumentError("This scalar screen supports :Float32 or :Float64"))

"""
Use the existing generic scientific ChainStage kernels and One/Many consumers,
with new canonical storage allocated by PSE.NativeColumnStorage. Every stage K
has a distinct concrete model/port type; increasing nmodels changes compilation
width rather than duplicating one model type. Initial source fields are supplied
raw before registration. No existing Status or RefValue is repacked.
"""
function generic_native_fixture(; native::Bool, nobjects::Int=4, nmodels::Int=4,
    value_type::Symbol=:Float64, seed::Int=1)
    nobjects > 0 && nmodels > 0 || throw(ArgumentError("Objects and model width must be positive"))
    T = _numeric_type(value_type)
    storage = native ? PSE.NativeColumnStorage() : nothing
    # The established schema helper creates values only for this fresh fixture;
    # its temporary references never belong to a registered canonical status.
    initial = [NamedTuple(GP._chain_status(nmodels, T, 0, row)) for row in 1:nobjects]
    objects = PSE.Object[PSE.Object(row; kind=:native_unit, status=initial[row])
        for row in 1:nobjects]
    push!(objects, PSE.Object(:echo; status=(observed=zero(T), visits=0)))
    push!(objects, PSE.Object(:sum; status=(total=zero(T), source_count=0)))
    models = [GP.ChainStage{stage,T,false}(T(0.5), T(stage)) for stage in 1:nmodels]
    applications = PSE.ModelSpec[PSE.ModelSpec(model;
        name=GP._stage_name(stage), on=PSE.Many(kind=:native_unit), every=Hour(1))
        for (stage, model) in enumerate(models)]
    push!(applications, PSE.ModelSpec(CR.NativeColumnEcho{T}(); name=:echo,
        on=PSE.One(id=:echo), every=Hour(1),
        inputs=(supply=PSE.One(id=1, within=PSE.SceneScope(),
            application=GP._stage_name(nmodels), var=GP._stage_name(nmodels)),)))
    push!(applications, PSE.ModelSpec(CR.NativeColumnSum{T}(); name=:sum,
        on=PSE.One(id=:sum), every=Hour(1),
        inputs=(sources=PSE.Many(kind=:native_unit, within=PSE.SceneScope(),
            application=GP._stage_name(nmodels), var=GP._stage_name(nmodels)),)))
    model = native ? PSE.CompositeModel(objects...; applications,
        environment=(duration=Hour(1),), status_storage=storage) :
        PSE.CompositeModel(objects...; applications, environment=(duration=Hour(1),))
    distinct_model_types = Tuple(string(typeof(model)) for model in models)
    length(unique(distinct_model_types)) == nmodels || error("Model width did not create distinct model types")
    return (; model, storage, native, nobjects, nmodels, value_type, seed,
        distinct_model_types, source_ids=collect(1:nobjects))
end

function _generic_snapshot(simulation, fixture, config)
    observed = CR.downstream_fingerprint(simulation)
    states = [(id=repr(id.value), fields=sort!([
        (name=string(name), type=string(typeof(CR._native_comparison_value(value))),
            value=repr(CR._native_comparison_value(value)))
        for (name, value) in pairs(state)]; by=row -> row.name))
        for (id, state) in observed.states]
    sort!(states; by=row -> row.id)
    history = sort!([(key=repr(key), samples=repr(value))
        for (key, value) in observed.histories]; by=row -> row.key)
    return (; step=observed.step, states, history)
end

function _generic_coverage(simulation, program, fixture, config, variant)
    storage = PSE.native_storage_report(fixture.model)
    if isnothing(program)
        return (native_fields=fixture.native ? storage.active_native_fields : 0,
            driver_units=0, native_driver_units=0, storage,
            ordinary_kernel_invocations=(fixture.nmodels * fixture.nobjects + 2) * config.steps,
            model_types=fixture.distinct_model_types)
    end
    report = Scalar.native_scalar_report(program)
    # Native mode lowers only actual native declared ports. Its row counter
    # excludes all ordinary fallback groups and therefore describes executed
    # ownership/driver intersection, including arbitrary physical row indices.
    native_driver_units = fixture.native && report.executed_native_column_fields > 0 ?
        report.driver_row_executions : 0
    return (native_fields=report.executed_native_column_fields,
        driver_units=report.driver_row_executions, native_driver_units, storage,
        model_types=fixture.distinct_model_types, report)
end

function _generic_work(simulation, fixture, config)
    return (source_objects=fixture.nobjects, total_objects=fixture.nobjects + 2,
        chain_width=fixture.nmodels, distinct_chain_model_types=length(fixture.distinct_model_types),
        steps=PSE.current_step(simulation), seed=fixture.seed,
        expected_logical_chain_kernels=fixture.nobjects * fixture.nmodels * config.steps,
        one_consumers=1, many_reductions=1,
        streams=length(PSE.outputs(simulation)), interpretation=:generic_arbitrary_units)
end

"""
Register one 2x2 ownership/execution comparison in NativeDownstreamMeasurements.
For a first-use case register and immediately measure ONE arm in a new Kaimon
process; no correctness gate, code_typed or warm screen may precede it.
"""
function register_generic_case!(name::Symbol; nobjects::Int=4, nmodels::Int=4,
    steps::Int=1, value_type::Symbol=:Float64, seed::Int=1, outputs=:none,
    context_strategy::Symbol=:thin, replace=false)
    steps > 0 || throw(ArgumentError("steps must be positive"))
    config = (; nobjects, nmodels, steps, value_type, seed, outputs, context_strategy)
    return Measurements.register_case!(name; config, replace,
        packages=(PSE,),
        construct=(config, variant) -> generic_native_fixture(;
            native=variant.needs_native, nobjects=config.nobjects, nmodels=config.nmodels,
            value_type=config.value_type, seed=config.seed),
        prepare=(fixture, config, variant) -> PSE.run!(fixture.model; steps=0, outputs=config.outputs),
        lower=(simulation, fixture, config, variant) -> variant.needs_driver ?
            Scalar.compile_native_scalar(simulation;
                state_strategy=variant.needs_native ? :native : :references,
                context_strategy=config.context_strategy) : nothing,
        execute! = (simulation, program, fixture, config, variant) ->
            isnothing(program) ? PSE.continue!(simulation; steps=config.steps) :
                Scalar.advance_native_scalar!(program; steps=config.steps),
        fingerprint=_generic_snapshot, coverage=_generic_coverage, work=_generic_work)
end

register_width_cases!(; widths=(4, 16, 64), kwargs...) = [
    register_generic_case!(Symbol(:width_, width); nobjects=4, nmodels=width, steps=1, kwargs...)
    for width in widths]

register_object_scaling_cases!(; counts=(256, 1024), nmodels=4, steps=256, kwargs...) = [
    register_generic_case!(Symbol(:objects_, count); nobjects=count, nmodels, steps, kwargs...)
    for count in counts]

function _check_generic_recurrence(simulation, fixture, steps)
    T = _numeric_type(fixture.value_type)
    expected = zeros(T, fixture.nmodels)
    for _ in 1:steps, stage in 1:fixture.nmodels
        source = stage == 1 ? T(stage) : expected[stage - 1]
        expected[stage] += source * T(0.5) + T(stage)
    end
    for object in fixture.source_ids
        state = PSE.final_state(simulation, object)
        for stage in 1:fixture.nmodels
            @assert isequal(getproperty(state, GP._stage_name(stage)), expected[stage])
            @assert typeof(getproperty(state, GP._stage_name(stage))) === T
            @assert getproperty(state, GP._visits_name(stage)) == steps
        end
    end
    @assert isequal(PSE.final_state(simulation, :echo).observed, last(expected))
    @assert PSE.final_state(simulation, :echo).visits == steps
    @assert isequal(PSE.final_state(simulation, :sum).total, sum(fill(last(expected), fixture.nobjects)))
    @assert PSE.final_state(simulation, :sum).source_count == fixture.nobjects
    return nothing
end

"""Tiny independent dense recurrence plus backend/ordinary-continuation parity."""
function generic_fixture_checks(; nobjects=4, nmodels=4, context_strategy=:thin)
    reports = Any[]
    for value_type in (:Float32, :Float64)
        reference = generic_native_fixture(; native=false, nobjects, nmodels, value_type)
        candidate = generic_native_fixture(; native=true, nobjects, nmodels, value_type)
        control = PSE.run!(reference.model; steps=0, outputs=:all)
        simulation = PSE.run!(candidate.model; steps=0, outputs=:all)
        source = PSE.model_status(candidate.model, 1)
        external_ref = PSE.refvalue(source, GP._stage_name(1))
        program = Scalar.compile_native_scalar(simulation; state_strategy=:native, context_strategy)
        Scalar.advance_native_scalar!(program; steps=1)
        PSE.continue!(control; steps=1)
        @assert isequal(CR.downstream_fingerprint(simulation), CR.downstream_fingerprint(control))
        _check_generic_recurrence(simulation, candidate, 1)
        PSE.continue!(simulation; steps=1)
        PSE.continue!(control; steps=1)
        @assert isequal(CR.downstream_fingerprint(simulation), CR.downstream_fingerprint(control))
        _check_generic_recurrence(simulation, candidate, 2)
        @assert source === PSE.model_status(candidate.model, 1)
        @assert external_ref === PSE.refvalue(source, GP._stage_name(1))
        report = Scalar.native_scalar_report(program)
        @assert report.driver_row_executions > 0 && report.executed_native_column_fields > 0
        @assert !report.numerical_scalar_copies
        push!(reports, (; value_type, passed=true, report,
            native_storage=PSE.native_storage_report(candidate.model)))
    end
    return (; passed=true, cases=length(reports), reports,
        qualification=:generic_recurrence_and_feature_gate_not_downstream_validation)
end

end
