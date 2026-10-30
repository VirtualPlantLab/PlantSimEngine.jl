# Generic fixtures for the generated-program experiment. This file also loads
# by itself in a module against the unmodified original PSE revision.

PSE.@process "generated_program_chain_stage" verbose=false

"""A row-local, stateful kernel; K is a port schema, not an object identity."""
struct ChainStage{K,T,E} <: AbstractGenerated_Program_Chain_StageModel
    gain::T
    bias::T
end

_stage_name(index::Integer) = Symbol(:stage_, index)
_visits_name(index::Integer) = Symbol(:visits_, index)

function PSE.inputs_(::ChainStage{K,T}) where {K,T}
    return K == 1 ? NamedTuple() :
        NamedTuple{(_stage_name(K - 1),)}((PSE.Required(T),))
end

function PSE.outputs_(model::ChainStage{K,T}) where {K,T}
    return NamedTuple{(_stage_name(K), _visits_name(K))}((zero(T), 0))
end

PSE.environment_inputs_(::ChainStage{K,T,false}) where {K,T} = NamedTuple()
PSE.environment_inputs_(::ChainStage{K,T,true}) where {K,T} = (driver=one(T),)

@generated function PSE.run!(model::ChainStage{K,T,E}, status, environment,
    constants, context) where {K,T,E}
    # Literal field names reproduce ordinary handwritten scientific kernels.
    # Constructing Symbols in every invocation would benchmark symbol interning
    # rather than framework overhead. Only the port schema K controls this code.
    current = QuoteNode(_stage_name(K))
    previous = K == 1 ? :(model.bias) :
        :(getproperty(status, $(QuoteNode(_stage_name(K - 1)))))
    visits = QuoteNode(_visits_name(K))
    forcing = E ? :(environment.driver) : :(one(model.gain))
    return quote
        source = $previous
        forcing = $forcing
        value = getproperty(status, $current)
        setproperty!(status, $current, value + source * model.gain + model.bias * forcing)
        setproperty!(status, $visits, getproperty(status, $visits) + 1)
        nothing
    end
end

# Explicit author promise used only by experimental lowering. The kernel has
# no effects outside this object's declared scalar ports and reads no context.
# The standalone original-baseline module does not define this trait.
if isdefined(@__MODULE__, :program_effects)
    program_effects(::Type{<:ChainStage}) = :local
end

function _chain_status(nmodels::Int, ::Type{T}, extras::Int, marker::Int) where {T}
    names = Tuple(name for index in 1:nmodels for name in (_stage_name(index), _visits_name(index)))
    values = Tuple(value for _ in 1:nmodels for value in (zero(T), 0))
    unused_names = ntuple(index -> Symbol(:unused_, index), extras)
    unused_values = ntuple(index -> T(index + marker), extras)
    return PSE.Status((; NamedTuple{names}(values)...,
        NamedTuple{unused_names}(unused_values)...))
end

"""
    fixture_builder(; nobjects=32, nmodels=4, value_type=Float64, extras=0,
                      environment_used=false)

An ordinary PSE scenario with N arbitrary units and a stateful same-object chain.
Every arm executes these exact model methods. Neither lowering nor fixtures use
biology-specific object labels. Existing scalar status fields make row schemas
homogeneous without changing canonical state ownership.
"""
function fixture_builder(; nobjects::Int=32, nmodels::Int=4,
    value_type::Type=Float64, extras::Int=0, environment_used::Bool=false)
    nobjects > 0 || throw(ArgumentError("nobjects must be positive"))
    nmodels > 0 || throw(ArgumentError("nmodels must be positive"))
    extras >= 0 || throw(ArgumentError("extras must be nonnegative"))
    T = value_type
    objects = [PSE.Object(index; scale=:unit, kind=:arbitrary_unit,
        status=_chain_status(nmodels, T, extras, index)) for index in 1:nobjects]
    applications = [PSE.ModelSpec(ChainStage{index,T,environment_used}(T(0.5), T(index));
        name=_stage_name(index), on=PSE.Many(kind=:arbitrary_unit), every=Hour(1))
        for index in 1:nmodels]
    return PSE.CompositeModel(objects...; applications,
        environment=(driver=one(T), duration=Hour(1)))
end

"""Deep canonical state and keyed raw retained/temporal samples, outside timings."""
function fingerprint(simulation)
    model = PSE.runtime_model(simulation)
    states = Dict(object.id => deepcopy(PSE.final_state(simulation, object.id))
        for object in PSE.model_objects(model))
    histories = Dict(key => deepcopy(collect(stream))
        for (key, stream) in pairs(PSE.outputs(simulation)))
    return (; step=PSE.current_step(simulation), states, histories)
end

function check_fixture_counts(observed; nobjects::Int, nmodels::Int,
    steps::Int, value_type::Type=Float64)
    length(observed.states) == nobjects || error("Unexpected object count")
    observed.step == steps || error("Unexpected final step")
    # Independent dense recurrence: no Status, PSE models, bindings, generated
    # property access, or executor participates in this reference calculation.
    T = value_type
    expected = zeros(T, nmodels)
    for _ in 1:steps, stage in 1:nmodels
        source = stage == 1 ? T(stage) : expected[stage - 1]
        expected[stage] = expected[stage] + source * T(0.5) + T(stage) * one(T)
    end
    for index in 1:nobjects, stage in 1:nmodels
        state = observed.states[PSE.ObjectId(index)]
        getproperty(state, _visits_name(stage)) == steps || error("Kernel count mismatch")
        typeof(getproperty(state, _stage_name(stage))) === value_type ||
            error("Scalar numeric type changed")
        isequal(getproperty(state, _stage_name(stage)), expected[stage]) ||
            error("Independent recurrence mismatch at object $(index), stage $(stage)")
    end
    return nothing
end

PSE.@process "generated_program_reduction" verbose=false
struct ProgramReduction <: AbstractGenerated_Program_ReductionModel end
PSE.inputs_(::ProgramReduction) = (sources=PSE.Required(Vector{Float64}),)
PSE.outputs_(::ProgramReduction) = (total=0.0, source_count=0)
function PSE.run!(::ProgramReduction, status, environment, constants, context)
    status.total = sum(status.sources)
    status.source_count = length(status.sources)
    return nothing
end

"""A Many input requires all source rows before the reduction runs."""
function reduction_fixture(; nobjects::Int=5)
    objects = [PSE.Object(index; kind=:arbitrary_unit,
        status=_chain_status(2, Float64, 0, index)) for index in 1:nobjects]
    push!(objects, PSE.Object(:aggregate; kind=:aggregate))
    applications = (
        PSE.ModelSpec(ChainStage{1,Float64,false}(0.5, 1.0);
            name=:stage_1, on=PSE.Many(kind=:arbitrary_unit), every=Hour(1)),
        PSE.ModelSpec(ChainStage{2,Float64,false}(0.5, 2.0);
            name=:stage_2, on=PSE.Many(kind=:arbitrary_unit), every=Hour(1)),
        PSE.ModelSpec(ProgramReduction(); name=:reduction,
            on=PSE.One(id=:aggregate), every=Hour(1),
            inputs=(sources=PSE.Many(kind=:arbitrary_unit,
                within=PSE.SceneScope(), application=:stage_2, var=:stage_2),)),
    )
    return PSE.CompositeModel(objects...; applications, environment=(duration=Hour(1),))
end

PSE.@process "generated_program_call_worker" verbose=false
PSE.@process "generated_program_call_controller" verbose=false
struct ProgramCallWorker <: AbstractGenerated_Program_Call_WorkerModel end
struct ProgramCallController <: AbstractGenerated_Program_Call_ControllerModel end
PSE.inputs_(::ProgramCallWorker) = (driver=PSE.Default(1.0),)
PSE.outputs_(::ProgramCallWorker) = (value=0.0, visits=0)
PSE.inputs_(::ProgramCallController) = NamedTuple()
PSE.outputs_(::ProgramCallController) = (trial=0.0, accepted=0.0, visits=0)
function PSE.run!(::ProgramCallWorker, status, environment, constants, context)
    status.value = status.driver
    status.visits += 1
    return nothing
end
function PSE.run!(::ProgramCallController, status, environment, constants, context)
    worker = only(PSE.call_targets(context, :worker))
    worker.status.driver = 2.0
    PSE.run_call!(worker; publish=false)
    status.trial = worker.status.value
    worker.status.driver = 3.0
    evaluation = PSE.evaluate_call!(worker)
    status.accepted = only(PSE.call_targets(evaluation)).status.value
    PSE.accept_call!(evaluation)
    status.visits += 1
    return nothing
end
function call_fixture()
    return PSE.CompositeModel(PSE.Object(:controller), PSE.Object(:worker);
        applications=(
            PSE.ModelSpec(ProgramCallController(); name=:controller,
                on=PSE.One(id=:controller), every=Hour(1),
                calls=(worker=PSE.One(id=:worker, within=PSE.SceneScope(),
                    application=:worker),)),
            PSE.ModelSpec(ProgramCallWorker(); name=:worker,
                on=PSE.One(id=:worker), every=Hour(1)),
        ), environment=(duration=Hour(1),))
end

PSE.@process "generated_program_lagged" verbose=false
struct ProgramLagged <: AbstractGenerated_Program_LaggedModel end
PSE.inputs_(::ProgramLagged) = (previous=PSE.Required(Float64),)
PSE.outputs_(::ProgramLagged) = (observed=0.0, visits=0)
function PSE.run!(::ProgramLagged, status, environment, constants, context)
    status.observed = status.previous
    status.visits += 1
    return nothing
end
function temporal_fixture()
    return PSE.CompositeModel(
        PSE.Object(:source; status=_chain_status(1, Float64, 0, 1)),
        PSE.Object(:reader; status=PSE.Status(previous=0.0));
        applications=(
            PSE.ModelSpec(ChainStage{1,Float64,false}(0.5, 1.0);
                name=:stage_1, on=PSE.One(id=:source), every=Hour(1)),
            PSE.ModelSpec(ProgramLagged(); name=:lagged,
                on=PSE.One(id=:reader), every=Hour(2),
                inputs=(PSE.PreviousTimeStep(:previous) =>
                    PSE.One(id=:source, within=PSE.SceneScope(),
                        application=:stage_1, var=:stage_1),)),
        ), environment=(duration=Hour(1),))
end

PSE.@process "generated_program_growth" verbose=false
struct ProgramGrowth <: AbstractGenerated_Program_GrowthModel end
PSE.inputs_(::ProgramGrowth) = NamedTuple()
PSE.outputs_(::ProgramGrowth) = (created=0,)
function PSE.run!(::ProgramGrowth, status, environment, constants, context)
    model = PSE.runtime_model(context)
    if context.time == 2 && !(PSE.ObjectId(:new_unit) in PSE.object_ids(model))
        PSE.register_object!(model, PSE.Object(:new_unit; kind=:arbitrary_unit,
            status=_chain_status(2, Float64, 0, 91)))
        status.created += 1
    end
    return nothing
end
function growth_fixture()
    return PSE.CompositeModel(
        PSE.Object(:coordinator),
        PSE.Object(:old_unit; kind=:arbitrary_unit,
            status=_chain_status(2, Float64, 0, 1));
        applications=(
            PSE.ModelSpec(ProgramGrowth(); name=:a_growth,
                on=PSE.One(id=:coordinator), every=Hour(1)),
            PSE.ModelSpec(ChainStage{1,Float64,false}(0.5, 1.0);
                name=:stage_1, on=PSE.Many(kind=:arbitrary_unit), every=Hour(1)),
            PSE.ModelSpec(ChainStage{2,Float64,false}(0.5, 2.0);
                name=:stage_2, on=PSE.Many(kind=:arbitrary_unit), every=Hour(1)),
        ), environment=(duration=Hour(1),))
end

PSE.@process "generated_program_updates" verbose=false
struct ProgramUpdate{T} <: AbstractGenerated_Program_UpdatesModel
    amount::T
end
PSE.inputs_(::ProgramUpdate) = NamedTuple()
PSE.outputs_(model::ProgramUpdate) = (updated=zero(model.amount), visits=0)
function PSE.run!(model::ProgramUpdate, status, environment, constants, context)
    status.updated += model.amount
    status.visits += 1
    return nothing
end
if isdefined(@__MODULE__, :program_effects)
    program_effects(::Type{<:ProgramUpdate}) = :local
end
function updates_fixture()
    return PSE.CompositeModel(
        (PSE.Object(i; kind=:arbitrary_unit,
            status=PSE.Status(updated=0.0, visits=0)) for i in 1:3)...;
        applications=(
            PSE.ModelSpec(ProgramUpdate(1.0); name=:first,
                on=PSE.Many(kind=:arbitrary_unit), every=Hour(1)),
            PSE.ModelSpec(ProgramUpdate(10.0); name=:second,
                on=PSE.Many(kind=:arbitrary_unit), every=Hour(1),
                updates=PSE.Updates(:updated, :visits; after=:first)),
        ), environment=(duration=Hour(1),))
end

"""Two rows alias a live writer cell; organ-major fusion would change values."""
function alias_fixture()
    shared = Ref(0.0)
    objects = [PSE.Object(index; kind=:arbitrary_unit,
        status=PSE.Status((stage_1=shared, visits_1=Ref(0),
            stage_2=Ref(0.0), visits_2=Ref(0)))) for index in 1:3]
    return PSE.CompositeModel(objects...;
        applications=(
            PSE.ModelSpec(ChainStage{1,Float64,false}(0.5, 1.0);
                name=:stage_1, on=PSE.Many(kind=:arbitrary_unit), every=Hour(1)),
            PSE.ModelSpec(ChainStage{2,Float64,false}(0.5, 2.0);
                name=:stage_2, on=PSE.Many(kind=:arbitrary_unit), every=Hour(1)),
        ), environment=(duration=Hour(1),))
end

"""Aliases within one row are legal for fusion and must remain live locally."""
function within_row_alias_fixture()
    objects = PSE.Object[]
    for index in 1:3
        shared = Ref(0.0)
        push!(objects, PSE.Object(index; kind=:arbitrary_unit,
            status=PSE.Status((stage_1=shared, visits_1=Ref(0),
                stage_2=shared, visits_2=Ref(0)))))
    end
    return PSE.CompositeModel(objects...;
        applications=(
            PSE.ModelSpec(ChainStage{1,Float64,false}(0.5, 1.0);
                name=:stage_1, on=PSE.Many(kind=:arbitrary_unit), every=Hour(1)),
            PSE.ModelSpec(ChainStage{2,Float64,false}(0.5, 2.0);
                name=:stage_2, on=PSE.Many(kind=:arbitrary_unit), every=Hour(1)),
        ), environment=(duration=Hour(1),))
end

PSE.@process "generated_program_ordered_trace" verbose=false
struct ProgramOrderedTrace{K,L} <: AbstractGenerated_Program_Ordered_TraceModel
    log::L
end
PSE.inputs_(::ProgramOrderedTrace) = NamedTuple()
PSE.outputs_(::ProgramOrderedTrace{K}) where {K} =
    NamedTuple{(Symbol(:ordinal_, K),)}((0,))
function PSE.run!(model::ProgramOrderedTrace{K}, status, environment, constants,
    context) where {K}
    push!(model.log, (Int(context.time), K, context.object_id.value))
    setproperty!(status, Symbol(:ordinal_, K), length(model.log))
    return nothing
end
function ordered_effect_fixture()
    log = Tuple{Int,Int,Int}[]
    return PSE.CompositeModel(
        (PSE.Object(index; kind=:arbitrary_unit,
            status=PSE.Status(ordinal_1=0, ordinal_2=0)) for index in 1:3)...;
        applications=(
            PSE.ModelSpec(ProgramOrderedTrace{1,typeof(log)}(log); name=:trace_1,
                on=PSE.Many(kind=:arbitrary_unit), every=Hour(1)),
            PSE.ModelSpec(ProgramOrderedTrace{2,typeof(log)}(log); name=:trace_2,
                on=PSE.Many(kind=:arbitrary_unit), every=Hour(1)),
        ), environment=(duration=Hour(1),))
end

PSE.@process "generated_program_phase_tick" verbose=false
struct ProgramPhaseTick{K} <: AbstractGenerated_Program_Phase_TickModel end
PSE.inputs_(::ProgramPhaseTick) = NamedTuple()
PSE.outputs_(::ProgramPhaseTick{K}) where {K} =
    NamedTuple{(Symbol(:tick_, K),)}((0,))
function PSE.run!(::ProgramPhaseTick{K}, status, environment, constants,
    context) where {K}
    name = Symbol(:tick_, K)
    setproperty!(status, name, getproperty(status, name) + 1)
    return nothing
end
if isdefined(@__MODULE__, :program_effects)
    program_effects(::Type{<:ProgramPhaseTick}) = :local
end
function phase_fixture()
    return PSE.CompositeModel(
        (PSE.Object(index; kind=:arbitrary_unit,
            status=PSE.Status(tick_1=0, tick_2=0)) for index in 1:3)...;
        applications=(
            PSE.ModelSpec(ProgramPhaseTick{1}(); name=:phase_0,
                on=PSE.Many(kind=:arbitrary_unit), every=PSE.ClockSpec(2, 0)),
            PSE.ModelSpec(ProgramPhaseTick{2}(); name=:phase_1,
                on=PSE.Many(kind=:arbitrary_unit), every=PSE.ClockSpec(2, 1)),
        ), environment=(duration=Hour(1),))
end

PSE.@process "generated_program_distributed_writer" verbose=false
PSE.@process "generated_program_distributed_reader" verbose=false
struct ProgramDistributedWriter <: AbstractGenerated_Program_Distributed_WriterModel end
struct ProgramDistributedReader <: AbstractGenerated_Program_Distributed_ReaderModel end
PSE.inputs_(::ProgramDistributedWriter) = NamedTuple()
PSE.outputs_(::ProgramDistributedWriter) =
    (visits=0, energy=PSE.Distributed(PSE.Default(0.0)))
PSE.inputs_(::ProgramDistributedReader) = (energy=PSE.Required(Float64),)
PSE.outputs_(::ProgramDistributedReader) = (seen=0.0, visits=0)
function PSE.run!(::ProgramDistributedWriter, status, environment, constants, context)
    status.visits += 1
    destinations = PSE.output_targets(context, (:energy,))
    for row in eachindex(PSE.object_ids(destinations))
        destinations.columns.energy[row] = Float64(row + status.visits)
    end
    return nothing
end
function PSE.run!(::ProgramDistributedReader, status, environment, constants, context)
    status.seen = status.energy
    status.visits += 1
    return nothing
end
if isdefined(@__MODULE__, :program_effects)
    program_effects(::Type{<:ProgramDistributedReader}) = :local
end
function distributed_fixture()
    return PSE.CompositeModel(PSE.Object(:coordinator),
        (PSE.Object(index; kind=:arbitrary_unit) for index in 1:3)...;
        applications=(
            PSE.ModelSpec(ProgramDistributedWriter(); name=:writer,
                on=PSE.One(id=:coordinator), every=Hour(1), outputs_to=(
                    PSE.OutputTo(PSE.Many(kind=:arbitrary_unit,
                        within=PSE.SceneScope()); vars=(:energy,)),)),
            PSE.ModelSpec(ProgramDistributedReader(); name=:reader,
                on=PSE.Many(kind=:arbitrary_unit), every=Hour(1)),
        ), environment=(duration=Hour(1),))
end
