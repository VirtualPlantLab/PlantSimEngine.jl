module CallEvaluationChecks

using Dates, PlantSimEngine, Test

const PSE = PlantSimEngine
const EA = PSE.EnvironmentAPI

# Test-only equations and instrumentation. A mutable call count is deliberately
# observable so accepting an evaluation cannot silently rerun a scientific kernel.
PSE.@process "call_evaluation_owner_probe" verbose=false
PSE.@process "call_evaluation_leaf_probe" verbose=false
PSE.@process "call_evaluation_middle_probe" verbose=false
PSE.@process "call_evaluation_writer_probe" verbose=false
PSE.@process "call_evaluation_sequence_probe" verbose=false
PSE.@process "call_evaluation_distributed_probe" verbose=false
PSE.@process "call_evaluation_membership_probe" verbose=false

struct CaptureOwner{C} <: AbstractCall_Evaluation_Owner_ProbeModel
    capture::C
end
PSE.inputs_(::CaptureOwner) = NamedTuple()
PSE.outputs_(::CaptureOwner) = (visits=0,)
PSE.environment_inputs_(::CaptureOwner) = NamedTuple()
PSE.environment_outputs_(::CaptureOwner) = NamedTuple()
function PSE.run!(model::CaptureOwner, status, environment, constants, context)
    model.capture[] = context
    status.visits += 1
    return nothing
end

struct CountingLeaf{T} <: AbstractCall_Evaluation_Leaf_ProbeModel
    zero_value::T
    commit::Bool
end
CountingLeaf(; commit=false) = CountingLeaf(0.0, commit)
PSE.inputs_(model::CountingLeaf) = (driver=Default(model.zero_value), fail_next=Default(false))
PSE.outputs_(model::CountingLeaf) = (seen=model.zero_value, calls=0,
    payload=zeros(typeof(model.zero_value), 2))
PSE.environment_inputs_(model::CountingLeaf) = (T=model.zero_value,)
PSE.environment_outputs_(model::CountingLeaf) = model.commit ? (T=model.zero_value,) : NamedTuple()
function PSE.run!(model::CountingLeaf, status, environment, constants, context)
    status.calls += 1
    status.seen = status.driver + oftype(status.seen, environment.T)
    status.payload[1] = status.seen
    status.payload[2] = status.seen + one(status.seen)
    if status.fail_next
        status.fail_next = false
        error("intentional call-evaluation failure")
    end
    model.commit && commit_environment!(context, (T=environment.T,))
    return nothing
end

struct TrialAtmosphere{T}
    values::NTuple{2,T}
end
struct ThrowingTrialAtmosphere end
mutable struct EvaluationBackend <: EA.AbstractEnvironmentBackend
    values::Dict{Symbol,Float64}
    writes::Vector{NamedTuple}
end
EvaluationBackend() = EvaluationBackend(Dict(:a => 10.0, :b => 20.0), NamedTuple[])
EA.base_step_seconds(::EvaluationBackend) = 3600.0
EA.get_nsteps(::EvaluationBackend) = 4
EA.environment_variables(::EvaluationBackend) = Set((:T,))
function EA.bind_environment(backend::EvaluationBackend, object::PSE.Object, context, config)
    location = geometry(object)
    cell = isnothing(location) ? :a : location.cell
    sink = isnothing(config) ? nothing : get(config, :sink, nothing)
    return (; cell, application=context.application, sink)
end
EA.sample(backend::EvaluationBackend, handle, ::Symbol, time) = backend.values[handle.cell]
EA.sample(::EvaluationBackend, handle, state::TrialAtmosphere, ::Symbol, time) =
    state.values[handle.cell === :a ? 1 : 2]
EA.sample(::EvaluationBackend, handle, ::ThrowingTrialAtmosphere, ::Symbol, time) =
    error("intentional environment-sampling failure")
function EA.commit_environment!(backend::EvaluationBackend, handle, state, time)
    handle.sink === :evaluation_probe || error("evaluation probe has no commit sink")
    backend.values[handle.cell] = state.T
    push!(backend.writes, (application=handle.application, cell=handle.cell,
        value=Float64(state.T), time=Float64(time)))
    return nothing
end

function basic_scene(::Type{S}=Float64; backend=nothing) where {S}
    capture = Ref{Any}()
    environment = isnothing(backend) ? (T=10.0, duration=Hour(1)) : backend
    leaf_environment = isnothing(backend) ? nothing :
        Environment(provider=:evaluation_probe, sink=:evaluation_probe)
    model = CompositeModel(
        Object(:owner; scale=:Scene),
        Object(:leaf_a; scale=:Leaf, parent=:owner, geometry=(cell=:a,)),
        Object(:leaf_b; scale=:Leaf, parent=:owner, geometry=(cell=:b,));
        applications=(
            ModelSpec(CaptureOwner(capture); name=:owner, on=One(id=:owner), calls=(
                one=One(id=:leaf_a, within=SceneScope(), application=:leaf),
                many=Many(scale=:Leaf, within=SceneScope(), application=:leaf),
                optional_absent=OptionalOne(id=:missing, within=SceneScope(), application=:leaf),
                empty=Many(id=:missing, within=SceneScope(), application=:leaf),
            )),
            ModelSpec(CountingLeaf(commit=!isnothing(backend)); name=:leaf,
                on=Many(scale=:Leaf), environment=leaf_environment),
        ), environment, type_promotion=Dict(Float64 => S))
    return (; model, capture)
end

raw(simulation, application, object, variable) =
    outputs(simulation)[(application, ObjectId(object), variable)]

@testset "accepting the latest evaluation runs no additional kernel" begin
    for S in (Float32, Float64)
        fixture = basic_scene(S)
        simulation = run!(fixture.model; steps=1, outputs=:all)
        context = fixture.capture[]
        target = only(call_targets(context, :one))
        target.status.driver = S(2)
        previous = evaluate_call!(context, :one; sampled_environment=(T=30.0,))
        @test previous isa PSE.CallEvaluation
        @test length(call_targets(previous)) == 1
        @test only(call_targets(previous)).object_id == ObjectId(:leaf_a)
        @test target.status.calls == 1
        @test target.status.seen === S(32)
        @test isempty(raw(simulation, :leaf, :leaf_a, :seen))

        # Saving an earlier candidate means saving scientific inputs, then
        # reevaluating them. Tokens do not promise rollback of arbitrary state.
        saved_driver = S(2)
        target.status.driver = S(4)
        latest = evaluate_call!(target; sampled_environment=(T=50.0,))
        @test target.status.calls == 2
        @test target.status.seen === S(54)
        @test_throws ArgumentError accept_call!(previous)
        @test isempty(raw(simulation, :leaf, :leaf_a, :seen))
        @test accept_call!(latest) === latest
        @test target.status.calls == 2
        @test raw(simulation, :leaf, :leaf_a, :seen) == [(1.0, S(54))]
        @test only(raw(simulation, :leaf, :leaf_a, :payload))[2] == S[54, 55]
        @test_throws ArgumentError accept_call!(latest)
        @test target.status.calls == 2

        target.status.driver = saved_driver
        earlier_again = evaluate_call!(target; sampled_environment=(T=30.0,))
        accept_call!(earlier_again)
        @test target.status.calls == 3
        @test raw(simulation, :leaf, :leaf_a, :seen) == [(1.0, S(32))]
        # Retained arrays own their values after acceptance.
        target.status.payload .= S(-999)
        @test only(raw(simulation, :leaf, :leaf_a, :payload))[2] == S[32, 33]
    end
end

@testset "bulk, filtered, optional and empty evaluations preserve identities" begin
    fixture = basic_scene()
    simulation = run!(fixture.model; steps=1, outputs=:all)
    context = fixture.capture[]
    model_status(fixture.model, :leaf_a).driver = 3.0
    model_status(fixture.model, :leaf_b).driver = 4.0
    evaluated = evaluate_call!(context, :many; sampled_environment=(T=2.0,))
    @test Set(target.object_id for target in call_targets(evaluated)) ==
        Set((ObjectId(:leaf_a), ObjectId(:leaf_b)))
    @test all(isempty(raw(simulation, :leaf, id, :seen)) for id in (:leaf_a, :leaf_b))
    accept_call!(evaluated)
    @test raw(simulation, :leaf, :leaf_a, :seen) == [(1.0, 5.0)]
    @test raw(simulation, :leaf, :leaf_b, :seen) == [(1.0, 6.0)]

    selected = evaluate_call!(context, :many; objects=(:leaf_b,), sampled_environment=(T=8.0,))
    @test only(call_targets(selected)).object_id == ObjectId(:leaf_b)
    accept_call!(selected)
    @test model_status(fixture.model, :leaf_a).calls == 1
    @test model_status(fixture.model, :leaf_b).calls == 2
    @test raw(simulation, :leaf, :leaf_a, :seen) == [(1.0, 5.0)]
    @test raw(simulation, :leaf, :leaf_b, :seen) == [(1.0, 12.0)]
    for name in (:optional_absent, :empty)
        empty_evaluation = evaluate_call!(context, name)
        @test isempty(call_targets(empty_evaluation))
        @test accept_call!(empty_evaluation) === empty_evaluation
    end
end

struct NestedMiddle <: AbstractCall_Evaluation_Middle_ProbeModel
    evaluate_child::Bool
end
PSE.inputs_(::NestedMiddle) = NamedTuple()
PSE.outputs_(::NestedMiddle) = (middle_seen=0.0, middle_calls=0)
PSE.environment_inputs_(::NestedMiddle) = NamedTuple()
PSE.environment_outputs_(::NestedMiddle) = NamedTuple()
function PSE.run!(model::NestedMiddle, status, environment, constants, context)
    status.middle_calls += 1
    leaf = only(call_targets(context, :leaf))
    leaf.status.driver = 1.0
    if model.evaluate_child
        evaluate_call!(leaf)
        leaf.status.driver = 2.0
        accept_call!(evaluate_call!(leaf))
    else
        run_call!(leaf; publish=false)
        leaf.status.driver = 2.0
        run_call!(leaf; publish=true)
    end
    status.middle_seen = leaf.status.seen
    return nothing
end

function nested_scene(; evaluate_child, backend=nothing)
    capture = Ref{Any}()
    environment = isnothing(backend) ? (T=10.0, duration=Hour(1)) : backend
    leaf_environment = isnothing(backend) ? nothing :
        Environment(provider=:evaluation_probe, sink=:evaluation_probe)
    model = CompositeModel(Object(:owner; scale=:Scene),
        Object(:middle; scale=:Plant, parent=:owner),
        Object(:leaf; scale=:Leaf, parent=:middle); applications=(
            ModelSpec(CaptureOwner(capture); name=:owner, on=One(id=:owner),
                calls=(middle=One(id=:middle, within=Subtree(), application=:middle),)),
            ModelSpec(NestedMiddle(evaluate_child); name=:middle, on=One(id=:middle),
                calls=(leaf=One(id=:leaf, within=Subtree(), application=:leaf),)),
            ModelSpec(CountingLeaf(commit=!isnothing(backend)); name=:leaf,
                on=One(id=:leaf), environment=leaf_environment),
        ), environment)
    return (; model, capture)
end

@testset "nested publication intent remains transactional without replay" begin
    for evaluate_child in (false, true)
        backend = EvaluationBackend()
        fixture = nested_scene(; evaluate_child, backend)
        simulation = run!(fixture.model; steps=1, outputs=:all)
        context = fixture.capture[]
        middle = only(call_targets(context, :middle))
        # A false ordinary ancestor suppresses even an explicit nested accept.
        run_call!(middle; publish=false)
        @test isempty(raw(simulation, :middle, :middle, :middle_seen))
        @test isempty(raw(simulation, :leaf, :leaf, :seen))
        @test isempty(backend.writes)

        outer = evaluate_call!(context, :middle)
        @test model_status(fixture.model, :middle).middle_calls == 2
        @test model_status(fixture.model, :leaf).calls == 4
        @test isempty(raw(simulation, :middle, :middle, :middle_seen))
        @test isempty(raw(simulation, :leaf, :leaf, :seen))
        @test isempty(backend.writes)
        accept_call!(outer)
        @test model_status(fixture.model, :middle).middle_calls == 2
        @test model_status(fixture.model, :leaf).calls == 4
        @test raw(simulation, :middle, :middle, :middle_seen) == [(1.0, 12.0)]
        @test raw(simulation, :leaf, :leaf, :seen) == [(1.0, 12.0)]
        @test raw(simulation, :leaf, :leaf, :calls) == [(1.0, 4)]
        @test backend.writes == [(application=:leaf, cell=:a, value=10.0, time=1.0)]
    end
end

struct OrderedWriter <: AbstractCall_Evaluation_Writer_ProbeModel
    increment::Float64
end
PSE.inputs_(::OrderedWriter) = NamedTuple()
PSE.outputs_(::OrderedWriter) = (shared_value=0.0, private_value=0.0, payload=zeros(2))
function PSE.run!(model::OrderedWriter, status, environment, constants, context)
    status.shared_value += model.increment
    status.private_value = 10 * status.shared_value
    status.payload .= (status.shared_value, status.shared_value + 1)
    return nothing
end
struct WriterSequence <: AbstractCall_Evaluation_Sequence_ProbeModel end
PSE.outputs_(::WriterSequence) = (sequence_value=0.0,)
function PSE.run!(::WriterSequence, status, environment, constants, context)
    first_writer = only(run_call!(context, :first; publish=true))
    last_writer = only(run_call!(context, :second; publish=true))
    status.sequence_value = last_writer.status.shared_value
    # The first writer already requested publication. Later work in this same
    # evaluation may overwrite its live array; its event must own its values.
    first_writer.status.payload .= -999.0
    return nothing
end

@testset "journal events snapshot shared, private and mutable output values" begin
    capture = Ref{Any}()
    routing = (private_value=:stream_only, payload=:stream_only)
    model = CompositeModel(Object(:owner; scale=:Scene),
        Object(:sequence; scale=:Plant, parent=:owner),
        Object(:leaf; scale=:Leaf, parent=:sequence); applications=(
            ModelSpec(CaptureOwner(capture); name=:owner, on=One(id=:owner),
                calls=(sequence=One(id=:sequence, within=Subtree(), application=:sequence),)),
            ModelSpec(WriterSequence(); name=:sequence, on=One(id=:sequence), calls=(
                first=One(id=:leaf, within=Subtree(), application=:first_writer),
                second=One(id=:leaf, within=Subtree(), application=:second_writer),)),
            ModelSpec(OrderedWriter(1.0); name=:first_writer, on=One(id=:leaf), output_routing=routing),
            ModelSpec(OrderedWriter(2.0); name=:second_writer, on=One(id=:leaf), output_routing=routing,
                updates=Updates(:shared_value; after=:first_writer)),
        ), environment=(duration=Hour(1),))
    simulation = run!(model; steps=1, outputs=:all)
    evaluation = evaluate_call!(capture[], :sequence)
    @test model_status(model, :leaf).shared_value == 3.0
    @test isempty(raw(simulation, :first_writer, :leaf, :shared_value))
    accept_call!(evaluation)
    @test model_status(model, :leaf).shared_value == 3.0
    @test raw(simulation, :first_writer, :leaf, :shared_value) == [(1.0, 1.0)]
    @test raw(simulation, :second_writer, :leaf, :shared_value) == [(1.0, 3.0)]
    @test raw(simulation, :first_writer, :leaf, :private_value) == [(1.0, 10.0)]
    @test raw(simulation, :second_writer, :leaf, :private_value) == [(1.0, 30.0)]
    @test only(raw(simulation, :first_writer, :leaf, :payload))[2] == [1.0, 2.0]
    @test only(raw(simulation, :second_writer, :leaf, :payload))[2] == [3.0, 4.0]
    @test !hasproperty(model_status(model, :leaf), :private_value)
end

struct DistributedWriter <: AbstractCall_Evaluation_Distributed_ProbeModel end
PSE.inputs_(::DistributedWriter) = (driver=Default(0.0),)
PSE.outputs_(::DistributedWriter) = (distributed_value=Distributed(Default(0.0)), writer_calls=0)
function PSE.run!(::DistributedWriter, status, environment, constants, context)
    status.writer_calls += 1
    destinations = output_targets(context, (:distributed_value,))
    for (index, id) in enumerate(object_ids(destinations))
        destinations.columns.distributed_value[index] =
            status.driver + (id == ObjectId(:destination_a) ? 10 : 20)
    end
    return nothing
end

struct RootDistributedWriter <: AbstractCall_Evaluation_Distributed_ProbeModel end
PSE.inputs_(::RootDistributedWriter) = (base_driver=Default(0.0),)
PSE.outputs_(::RootDistributedWriter) = (distributed_value=Distributed(Default(0.0)),
    writer_calls=0, source_calls_before_accept=0, source_calls_after_accept=0)
PSE.dep(::RootDistributedWriter) = (
    source=Call(One(within=Self(), process=:call_evaluation_leaf_probe)),)
function PSE.run!(::RootDistributedWriter, status, environment, constants, context)
    status.writer_calls += 1
    source = only(call_targets(context, :source))
    source.status.driver = status.base_driver + 3
    evaluate_call!(source)
    source.status.driver = status.base_driver + 8
    accepted = evaluate_call!(source)
    status.source_calls_before_accept = source.status.calls
    accept_call!(accepted)
    status.source_calls_after_accept = source.status.calls
    destinations = output_targets(context, (:distributed_value,))
    for (index, id) in enumerate(object_ids(destinations))
        destinations.columns.distributed_value[index] =
            source.status.seen + (id == ObjectId(:destination_a) ? 10 : 20)
    end
    return nothing
end

@testset "root-scheduled distributed outputs consume accepted scalar evaluations" begin
    # evaluate_call! does not relax the existing prohibition on distributed
    # applications that run exclusively as manual call targets.
    capture = Ref{Any}()
    unsupported = CompositeModel(Object(:owner; scale=:Scene),
        Object(:writer; scale=:Plant, parent=:owner),
        Object(:destination_b; scale=:Leaf, parent=:writer),
        Object(:destination_a; scale=:Leaf, parent=:writer); applications=(
            ModelSpec(CaptureOwner(capture); name=:owner, on=One(id=:owner),
                calls=(writer=One(id=:writer, within=Subtree(), application=:writer),)),
            ModelSpec(DistributedWriter(); name=:writer, on=One(id=:writer), outputs_to=(
                OutputTo(Many(scale=:Leaf, within=Subtree()); vars=(:distributed_value,)),)),
        ), environment=(duration=Hour(1),), type_promotion=Dict(Float64 => Float32))
    @test_throws "manual-call-only" PSE.Advanced.refresh_bindings!(unsupported)

    model = CompositeModel(Object(:writer; scale=:Plant),
        Object(:destination_b; scale=:Leaf, parent=:writer),
        Object(:destination_a; scale=:Leaf, parent=:writer); applications=(
            ModelSpec(RootDistributedWriter(); name=:writer, on=One(id=:writer), outputs_to=(
                OutputTo(Many(scale=:Leaf, within=Subtree()); vars=(:distributed_value,)),)),
            ModelSpec(CountingLeaf(); name=:source, on=One(id=:writer)),
        ), environment=(T=0.0, duration=Hour(1),), type_promotion=Dict(Float64 => Float32))
    simulation = run!(model; steps=1, outputs=:all)
    writer = final_state(simulation, :writer)
    @test writer.writer_calls == 1
    @test writer.calls == writer.source_calls_before_accept == writer.source_calls_after_accept == 2
    @test raw(simulation, :source, :writer, :seen) == [(1.0, 8.0f0)]
    @test raw(simulation, :writer, :destination_a, :distributed_value) == [(1.0, 18.0f0)]
    @test raw(simulation, :writer, :destination_b, :distributed_value) == [(1.0, 28.0f0)]
end

@testset "explicit transient sampling and environment commits are deferred" begin
    backend = EvaluationBackend()
    fixture = basic_scene(; backend)
    simulation = run!(fixture.model; steps=1, outputs=:all)
    context = fixture.capture[]
    model_status(fixture.model, :leaf_b).driver = 2.0
    candidate = evaluate_call!(context, :many; objects=(:leaf_b,),
        environment=TrialAtmosphere((30.0, 40.0)))
    @test only(call_targets(candidate)).status.seen == 42.0
    @test backend.values == Dict(:a => 10.0, :b => 20.0)
    @test isempty(backend.writes)
    @test isempty(raw(simulation, :leaf, :leaf_b, :seen))
    accept_call!(candidate)
    @test backend.values == Dict(:a => 10.0, :b => 40.0)
    @test backend.writes == [(application=:leaf, cell=:b, value=40.0, time=1.0)]
    @test model_status(fixture.model, :leaf_b).calls == 1
    @test raw(simulation, :leaf, :leaf_b, :seen) == [(1.0, 42.0)]

    target = only(call_targets(context, :one))
    forwarded = evaluate_call!(target; sampled_environment=(T=7.0,))
    @test target.status.seen == 7.0
    @test length(backend.writes) == 1
    accept_call!(forwarded)
    @test backend.values[:a] == 7.0
    @test length(backend.writes) == 2
    count_before = target.status.calls
    for evaluate in (
        () -> evaluate_call!(context, :one; environment=TrialAtmosphere((1.0, 2.0)),
            sampled_environment=(T=3.0,)),
        () -> evaluate_call!(target; environment=TrialAtmosphere((1.0, 2.0)),
            sampled_environment=(T=3.0,)),
    )
        @test_throws ArgumentError evaluate()
    end
    @test target.status.calls == count_before
end

@testset "failed or stale evaluations publish nothing" begin
    fixture = basic_scene()
    simulation = run!(fixture.model; steps=1, outputs=:all)
    target = only(call_targets(fixture.capture[], :one))
    pending = evaluate_call!(target)
    run_call!(target; publish=false)
    @test_throws ArgumentError accept_call!(pending)
    @test isempty(raw(simulation, :leaf, :leaf_a, :seen))

    pending = evaluate_call!(target)
    target.status.fail_next = true
    @test_throws ErrorException evaluate_call!(target)
    @test_throws ArgumentError accept_call!(pending)
    @test isempty(raw(simulation, :leaf, :leaf_a, :seen))
    recovered = evaluate_call!(target)
    calls_before = target.status.calls
    accept_call!(recovered)
    @test target.status.calls == calls_before
    @test length(raw(simulation, :leaf, :leaf_a, :seen)) == 1

    for change in (:timestep, :topology, :geometry)
        fixture = basic_scene()
        simulation = run!(fixture.model; steps=1, outputs=:all)
        pending = evaluate_call!(fixture.capture[], :one)
        if change === :timestep
            step!(simulation)
        elseif change === :topology
            register_object!(fixture.model, Object(:new_leaf; scale=:Leaf, parent=:owner))
        else
            update_geometry!(fixture.model, :leaf_a, (cell=:b,))
        end
        @test_throws ArgumentError accept_call!(pending)
        @test isempty(raw(simulation, :leaf, :leaf_a, :seen))
    end
end

@testset "sampling failure invalidates pending evaluations across call forms" begin
    for pending_form in (:individual, :bulk)
        backend = EvaluationBackend()
        fixture = basic_scene(; backend)
        simulation = run!(fixture.model; steps=1, outputs=:all)
        context = fixture.capture[]
        target = only(call_targets(context, :one))
        pending = pending_form === :individual ? evaluate_call!(target) :
            evaluate_call!(context, :one)
        @test target.status.calls == 1
        if pending_form === :individual
            @test_throws ErrorException evaluate_call!(context, :one;
                environment=ThrowingTrialAtmosphere())
        else
            @test_throws ErrorException evaluate_call!(target;
                environment=ThrowingTrialAtmosphere())
        end
        @test target.status.calls == 1 # Sampling failed before the next kernel.
        @test_throws ArgumentError accept_call!(pending)
        @test isempty(raw(simulation, :leaf, :leaf_a, :seen))
        @test isempty(backend.writes)
    end
end

struct MembershipController <: AbstractCall_Evaluation_Membership_ProbeModel end
PSE.outputs_(::MembershipController) = (iteration=0,)
function PSE.run!(::MembershipController, status, environment, constants, context)
    status.iteration += 1
    accept_call!(evaluate_call!(context, :leaves))
    model = runtime_model(context)
    if status.iteration == 1
        register_object!(model, Object(:newborn; scale=:Leaf, parent=:owner))
    elseif status.iteration == 3
        remove_object!(model, :newborn)
        register_object!(model, Object(:last_born; scale=:Leaf, parent=:owner))
    end
    return nothing
end

@testset "accepted empty Many records publication before newborn membership" begin
    start = DateTime(2026, 10, 27)
    model = CompositeModel(Object(:owner; scale=:Scene); applications=(
        ModelSpec(MembershipController(); name=:owner, on=One(id=:owner),
            calls=(leaves=Many(scale=:Leaf, within=Subtree(), application=:leaf),)),
        ModelSpec(CountingLeaf(); name=:leaf, on=Many(scale=:Leaf)),
    ), environment=[(date=start + Hour(i - 1), duration=Hour(1), T=10.0) for i in 1:3])
    request = OutputRequest(Many(scale=:Leaf), :seen; name=:leaf_seen,
        application=:leaf, policy=HoldLast(), clock=Hour(1))
    simulation = run!(model; steps=1, outputs=request)
    @test isempty(collect_outputs(simulation, :leaf_seen; sink=nothing))
    @test isempty(collect_outputs(simulation, :newborn, :seen; sink=nothing))
    step!(simulation)
    prefix = deepcopy(collect_outputs(simulation, :newborn, :seen; sink=nothing))
    step!(simulation)
    rows = collect_outputs(simulation, :leaf_seen; sink=nothing)
    @test getproperty.(rows, :timestep) == [2, 3]
    @test all(row -> row.object_id == :newborn && row.value == 10.0, rows)
    @test getproperty.(rows, :datetime) == [start + Hour(1), start + Hour(2)]
    @test collect_outputs(simulation, :newborn, :seen; sink=nothing)[1:1] == prefix
    @test isempty(collect_outputs(simulation, :last_born, :seen; sink=nothing))
end

function ordinary_call_allocations(target)
    for _ in 1:16
        run_call!(target; publish=false)
    end
    return @allocated for _ in 1:16
        run_call!(target; publish=false)
    end
end

@testset "ordinary manual calls retain their allocation path after evaluations" begin
    fixture = basic_scene()
    run!(fixture.model; steps=1, outputs=:none)
    target = only(call_targets(fixture.capture[], :one))
    ordinary_call_allocations(target)
    before = ordinary_call_allocations(target)
    accept_call!(evaluate_call!(target))
    ordinary_call_allocations(target)
    after = ordinary_call_allocations(target)
    @test after <= before + 256
end

function repeated_evaluate_accept!(context, count)
    for _ in 1:count
        accept_call!(evaluate_call!(context, :leaf; sampled_environment=(T=30.0,)))
    end
    return nothing
end

function evaluation_accept_allocations(context, count)
    return @allocated repeated_evaluate_accept!(context, count)
end

@testset "warmed evaluate and accept reuse their publication workspace" begin
    capture = Ref{Any}()
    model = CompositeModel(
        Object(:owner; scale=:Scene), Object(:leaf; scale=:Leaf, parent=:owner);
        applications=(
            ModelSpec(CaptureOwner(capture); name=:owner, on=One(id=:owner),
                calls=(leaf=One(id=:leaf, within=Subtree(), application=:leaf),)),
            ModelSpec(CountingLeaf(); name=:leaf, on=One(id=:leaf)),
        ), environment=(T=10.0, duration=Hour(1)))
    run!(model; steps=1, outputs=:none)
    context = capture[]
    # Pass the small UInt boxing cache before measuring reused execution
    # revisions and frame generations, and compile the measurement helper.
    repeated_evaluate_accept!(context, 2304)
    evaluation_accept_allocations(context, 1)
    calls_before = model_status(model, :leaf).calls
    allocated_bytes = evaluation_accept_allocations(context, 100)
    @test model_status(model, :leaf).calls == calls_before + 100
    @test model_status(model, :leaf).seen == 30.0
    # Keep a portable Julia 1.10 allowance while detecting publication-frame
    # storage that is reallocated on every evaluation rather than reused.
    @test allocated_bytes <= 100 * 256
end

end # module CallEvaluationChecks
