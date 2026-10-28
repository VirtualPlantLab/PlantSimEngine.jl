module MaterializedCallDispatchChecks

using Dates, PlantSimEngine, Test
const PSE = PlantSimEngine
const EA = PSE.EnvironmentAPI

PSE.@process "materialized_dispatch_owner_probe" verbose=false
PSE.@process "materialized_dispatch_source_probe" verbose=false
PSE.@process "materialized_dispatch_leaf_probe" verbose=false
PSE.@process "materialized_dispatch_middle_probe" verbose=false
PSE.@process "materialized_dispatch_optional_parent_probe" verbose=false
PSE.@process "materialized_dispatch_optional_child_probe" verbose=false

mutable struct TrialA{T}
    temperatures::NTuple{2,T}
end
struct TrialB{T}
    temperatures::NTuple{2,T}
end
mutable struct ProbeBackend <: EA.AbstractEnvironmentBackend
    temperatures::Dict{Symbol,Float64}
    writes::Vector{NamedTuple}
end
ProbeBackend() = ProbeBackend(Dict(:a => 10.0, :b => 20.0), NamedTuple[])
EA.base_step_seconds(::ProbeBackend) = 3600.0
EA.get_nsteps(::ProbeBackend) = 4
EA.environment_variables(::ProbeBackend) = Set((:T,))
function EA.bind_environment(::ProbeBackend, object::Object, context, config)
    location = geometry(object)
    return (; cell=isnothing(location) ? :a : location.cell, application=context.application)
end
EA.sample(backend::ProbeBackend, handle, ::Symbol, time) = backend.temperatures[handle.cell] + time
EA.sample(::ProbeBackend, handle, state::Union{TrialA,TrialB}, ::Symbol, time) =
    state.temperatures[handle.cell === :a ? 1 : 2]
function EA.commit_environment!(backend::ProbeBackend, handle, state, time)
    backend.temperatures[handle.cell] = state.T
    push!(backend.writes, (application=handle.application, cell=handle.cell,
        temperature=state.T, time=time))
    return nothing
end

struct CaptureOwner{C} <: AbstractMaterialized_Dispatch_Owner_ProbeModel
    capture::C
end
PSE.inputs_(::CaptureOwner) = (ready=Default(0.0),)
PSE.outputs_(::CaptureOwner) = (visits=0,)
function PSE.run!(model::CaptureOwner, status, environment, constants, context)
    model.capture[] = context
    status.visits += 1
    return nothing
end
struct Source{T} <: AbstractMaterialized_Dispatch_Source_ProbeModel
    initial::T
end
PSE.outputs_(model::Source) = (drive=model.initial, signal=model.initial)
function PSE.run!(model::Source, status, environment, constants, context)
    status.drive = oftype(model.initial, 7 * context.time)
    status.signal = oftype(model.initial, 5 * context.time)
    return nothing
end

const PAD_NAMES = ntuple(i -> Symbol(:padding_, i), 48)
struct WideLeaf{T,C,H} <: AbstractMaterialized_Dispatch_Leaf_ProbeModel
    coefficients::NTuple{64,T}
    capture::C
    hook::H
    commit::Bool
end
PSE.inputs_(model::WideLeaf{T}) where {T} =
    (driven=Default(zero(T)), prior=Default(zero(T)), fail_next=Default(false))
PSE.outputs_(model::WideLeaf{T}) where {T} = merge(
    (seen=zero(T), calls=0, payload=zeros(T, 2)),
    NamedTuple{PAD_NAMES}(ntuple(i -> model.coefficients[i], Val(48))))
PSE.environment_inputs_(::WideLeaf{T}) where {T} = (T=zero(T),)
PSE.environment_outputs_(model::WideLeaf{T}) where {T} = model.commit ? (T=zero(T),) : NamedTuple()
function PSE.run!(model::WideLeaf, status, environment, constants, context)
    model.capture[] = status
    status.calls += 1
    hook = model.hook[]
    if !isnothing(hook)
        model.hook[] = nothing
        hook()
    end
    status.seen = status.driven + status.prior + environment.T + model.coefficients[3]
    status.payload[1] = status.seen
    status.payload[2] = status.seen + one(status.seen)
    if status.fail_next
        status.fail_next = false
        error("intentional materialized wide-leaf failure")
    end
    model.commit && commit_environment!(context, (T=environment.T,))
    return nothing
end

struct Middle{T,C,H} <: AbstractMaterialized_Dispatch_Middle_ProbeModel
    initial::T
    capture::C
    hook::H
end
PSE.inputs_(model::Middle) = (driver=Default(model.initial),)
PSE.outputs_(model::Middle) = (seen=zero(model.initial), temperature=zero(model.initial), calls=0)
PSE.environment_inputs_(model::Middle) = (T=zero(model.initial),)
function PSE.run!(model::Middle, status, environment, constants, context)
    child = only(call_targets(context, :leaf))
    child.status.driven = status.driver
    hook = model.hook[]
    if !isnothing(hook)
        model.hook[] = nothing
        hook()
    end
    run_call!(child; publish=true)
    model.capture[] = child
    status.seen = child.status.seen
    status.temperature = environment.T
    status.calls += 1
    return nothing
end

function fixture(::Type{S}; commit=false, prior_policy=HoldLast()) where {S}
    capture, leaf_capture, child_capture = Ref{Any}(), Ref{Any}(), Ref{Any}()
    leaf_hook, middle_hook = Ref{Any}(nothing), Ref{Any}(nothing)
    backend = ProbeBackend()
    leaf = WideLeaf(ntuple(i -> S(i), 64), leaf_capture, leaf_hook, commit)
    model = CompositeModel(Object(:owner; scale=:Scene),
        Object(:middle; scale=:Branch, parent=:owner, geometry=(cell=:a,)),
        Object(:leaf; scale=:Leaf, parent=:middle, geometry=(cell=:b,),
            status=Status(seen=S(-999), payload=S[-77, -78])); applications=(
            ModelSpec(Source(zero(S)); name=:source, on=One(id=:leaf)),
            ModelSpec(CaptureOwner(capture); name=:owner, on=One(id=:owner),
                inputs=(ready=One(id=:leaf, within=SceneScope(), application=:source, var=:drive),),
                calls=(leaf=One(id=:leaf, within=SceneScope(), application=:leaf),
                    middle=One(id=:middle, within=SceneScope(), application=:middle),)),
            ModelSpec(Middle(S(2), child_capture, middle_hook); name=:middle,
                on=One(id=:middle), calls=(leaf=One(id=:leaf, within=Subtree(), application=:leaf),),
                environment=Environment(provider=:materialized_probe)),
            ModelSpec(leaf; name=:leaf, on=One(id=:leaf), inputs=(
                driven=One(within=Self(), application=:source, var=:drive),
                prior=One(within=Self(), application=:source, var=:signal, policy=prior_policy),),
                output_routing=(seen=:stream_only, payload=:stream_only),
                environment=Environment(provider=:materialized_probe)),
        ), environment=backend, type_promotion=Dict(Float64 => S))
    simulation = run!(model; steps=1, outputs=:all)
    return (; model, simulation, capture, leaf_capture, child_capture,
        leaf_hook, middle_hook, backend, leaf)
end

raw(data, application=:leaf, variable=:seen) =
    outputs(data.simulation)[(application, ObjectId(application === :middle ? :middle : :leaf), variable)]

@testset "materialized execution keeps wide models private status and shared HoldLast references" begin
    for S in (Float32, Float64)
        data = fixture(S)
        target = only(call_targets(data.capture[], :leaf))
        canonical = model_status(data.model, :leaf)
        @test !ismutabletype(typeof(data.leaf))
        @test sizeof(data.leaf.coefficients) == 64 * sizeof(S)
        @test length(propertynames(target.status)) >= 50
        @test target.status !== canonical
        @test target.canonical_status === canonical
        @test PSE.refvalue(target.status, :driven) === PSE.refvalue(canonical, :drive)
        # Same-cadence HoldLast uses a live reference, rather than private
        # temporal storage. Retaining a target does not freeze that value.
        @test PSE.refvalue(target.status, :prior) === PSE.refvalue(canonical, :signal)
        @test run_call!(target; sampled_environment=(T=30.0f0,), publish=false) === target
        @test data.leaf_capture[] === target.status
        @test target.status.seen === S(45)
        @test target.status.prior === S(5)
        @test target.status.calls == 1
        @test canonical.seen === S(-999)
        @test canonical.payload == S[-77, -78]
        @test isempty(raw(data))

        trial = TrialA((40.0, 41.0))
        run_call!(target; environment=trial, publish=false)
        @test target.status.seen === S(56)
        trial.temperatures = (41.0, 42.0)
        run_call!(target; environment=trial, publish=false)
        @test target.status.seen === S(57)
        run_call!(target; environment=TrialB((43.0f0, 44.0f0)), publish=true)
        @test target.status.seen === S(59)
        @test raw(data) == [(1.0, S(59))]
        @test data.leaf_capture[] === target.status
        @test canonical.seen === S(-999)

        step!(data.simulation)
        current = only(call_targets(data.capture[], :leaf))
        run_call!(current; publish=true)
        @test current.status.seen === S(49)
        @test current.status.prior === S(10)
        @test target.time == 1 && current.time == 2
        run_call!(target; publish=true)
        @test target.status.seen === S(48) # live drive/prior=14/10, captured backend time=1
        @test sort(raw(data); by=first) == [(1.0, S(48)), (2.0, S(49))]
    end
end

@testset "materialized dispatch preserves private PreviousTimeStep input storage" begin
    for S in (Float32, Float64)
        data = fixture(S; prior_policy=PreviousTimeStep(:prior))
        target = only(call_targets(data.capture[], :leaf))
        canonical = model_status(data.model, :leaf)
        @test target.status !== canonical
        @test PSE.refvalue(target.status, :driven) === PSE.refvalue(canonical, :drive)
        @test PSE.refvalue(target.status, :prior) !== PSE.refvalue(canonical, :signal)
        run_call!(target; sampled_environment=(T=30.0f0,), publish=false)
        @test data.leaf_capture[] === target.status
        @test canonical.signal === S(5)
        @test target.status.prior === zero(S)
        @test target.status.seen === S(40) # drive7 + initial prior0 + T30 + coefficient3
        @test isempty(raw(data))

        step!(data.simulation)
        current = only(call_targets(data.capture[], :leaf))
        run_call!(current; publish=true)
        @test data.leaf_capture[] === current.status
        @test current.status.prior === S(5)
        @test canonical.signal === S(10)
        @test current.status.seen === S(44) # drive14 + previous signal5 + T22 + coefficient3
        run_call!(target; publish=true)
        @test data.leaf_capture[] === target.status
        @test target.status.prior === zero(S)
        @test target.status.seen === S(38) # live drive14 + initial prior0 + captured T21 + coefficient3
        @test canonical.signal === S(10)
        @test sort(raw(data); by=first) == [(1.0, S(38)), (2.0, S(44))]
    end
end

@testset "sampled parent rows do not replace inherited backend trials" begin
    for S in (Float32, Float64)
        data = fixture(S)
        parent = only(call_targets(data.capture[], :middle))
        run_call!(parent; sampled_environment=(T=S(91),), publish=false)
        @test parent.status.temperature === S(91)
        @test parent.status.seen === S(31) # child committed T=21, not sampled parent 91
        rejected = data.child_capture[]
        @test !rejected.publication_allowed
        @test isempty(raw(data))
        trial = TrialA((30.0, 40.0))
        run_call!(parent; environment=trial, publish=true)
        @test parent.status.temperature === S(30)
        @test parent.status.seen === S(50)
        accepted = data.child_capture[]
        @test accepted.environment === trial
        @test accepted.publication_allowed
        run_call!(rejected; sampled_environment=(T=S(99),), publish=true)
        @test rejected.status.seen === S(109)
        @test raw(data) == [(1.0, S(50))]
        @test !rejected.publication_allowed
    end
end

@testset "materialized evaluated calls capture private payloads and commits without replay" begin
    for S in (Float32, Float64)
        data = fixture(S; commit=true)
        target = only(call_targets(data.capture[], :leaf))
        rejected = evaluate_call!(target; sampled_environment=(T=S(30),))
        accepted = evaluate_call!(target; sampled_environment=(T=S(31),))
        @test target.status.calls == 2
        @test data.leaf_capture[] === target.status
        @test isempty(raw(data))
        @test isempty(data.backend.writes)
        @test_throws ArgumentError accept_call!(rejected)
        @test accept_call!(accepted) === accepted
        @test target.status.calls == 2
        @test raw(data) == [(1.0, S(46))]
        @test only(data.backend.writes).temperature === S(31)
        target.status.payload .= S(-1)
        @test only(raw(data, :leaf, :payload))[2] == S[46, 47]
        @test model_status(data.model, :leaf).seen === S(-999)
    end
end

@testset "reentrant materialized leases retain outer descendants and release after failure" begin
    for S in (Float32, Float64)
        data = fixture(S)
        parent = only(call_targets(data.capture[], :middle))
        outer_trial = TrialA((30.0, 40.0))
        data.middle_hook[] = () -> begin
            run_call!(parent; environment=TrialB((31.0f0, 41.0f0)), publish=false)
            @test parent.context_cache.in_use
        end
        run_call!(parent; environment=outer_trial, publish=true)
        @test parent.status.seen === S(50)
        @test parent.status.temperature === S(30)
        outer_child = data.child_capture[]
        @test outer_child.environment === outer_trial
        @test outer_child.publication_allowed
        @test raw(data) == [(1.0, S(50))]
        @test !parent.context_cache.in_use
        @test !outer_child.context_cache.in_use
        outer_child.status.fail_next = true
        @test_throws ErrorException run_call!(parent; environment=TrialA((32.0, 42.0)), publish=true)
        @test !parent.context_cache.in_use
        @test !outer_child.context_cache.in_use
        @test raw(data) == [(1.0, S(50))]
        run_call!(parent; environment=TrialB((33.0f0, 43.0f0)), publish=true)
        @test parent.status.seen === S(53)
        @test parent.status.temperature === S(33)
        @test raw(data) == [(1.0, S(53))]
    end
end

struct OptionalParent{T} <: AbstractMaterialized_Dispatch_Optional_Parent_ProbeModel
    initial::T
end
PSE.outputs_(model::OptionalParent) = (seen=model.initial, calls=0)
function PSE.run!(::OptionalParent, status, environment, constants, context)
    children = call_targets(context, :child)
    if !isempty(children)
        child = only(children)
        run_call!(child; publish=true)
        status.seen = child.status.value
    end
    status.calls += 1
    return nothing
end
struct OptionalChild{T} <: AbstractMaterialized_Dispatch_Optional_Child_ProbeModel
    initial::T
end
PSE.outputs_(model::OptionalChild) = (value=model.initial, calls=0)
function PSE.run!(::OptionalChild, status, environment, constants, context)
    status.value += one(status.value)
    status.calls += 1
    return nothing
end

@testset "leased OptionalOne owner admits a different fresh descendant tuple after addition" begin
    for S in (Float32, Float64)
        capture = Ref{Any}()
        model = CompositeModel(Object(:owner; scale=:Scene),
            Object(:parent; scale=:Branch, parent=:owner); applications=(
                ModelSpec(CaptureOwner(capture); name=:owner, on=One(id=:owner),
                    calls=(parent=One(id=:parent, within=Subtree(), application=:parent),)),
                ModelSpec(OptionalParent(zero(S)); name=:parent, on=One(id=:parent),
                    calls=(child=OptionalOne(id=:newborn, within=Subtree(), application=:child),)),
                ModelSpec(OptionalChild(zero(S)); name=:child, on=Many(scale=:Child)),
            ), environment=(duration=Hour(1),), type_promotion=Dict(Float64 => S))
        simulation = run!(model; steps=1, outputs=:none)
        owner_context = capture[]
        retained_parents = call_targets(owner_context, :parent)
        parent = only(retained_parents)
        old_owner = parent.execution_target
        cache = parent.context_cache
        active = PSE._prepare_cached_call_context!(cache, true,
            parent.compiled, parent.environment_bindings, parent.application,
            parent.object_id, parent.bound_inputs, parent.output_targets,
            parent.temporal_streams, parent.output_retention, parent.time,
            parent.constants, true, parent.environment)
        @test active === cache.default
        old_optional = call_targets(active, :child)
        old_calls = active.calls
        @test isempty(old_optional)
        @test old_optional.execution_batches === ()

        # Narrow compiler-state regression: a user callback can trigger a
        # structural refresh before the Simulation execution-owner barrier.
        # Keep that old physical owner leased, but synchronize its outer view
        # to the coherent refreshed compiler/environment pair. This deliberately
        # exposes the in-place binding update, not an obsolete environment shell.
        cache.in_use = true
        try
            register_object!(model, Object(:newborn; scale=:Child, parent=:parent))
            refreshed = Advanced.refresh_bindings!(model)
            environments = PSE.refresh_environment_bindings!(model, refreshed)
            PSE._prepare_runtime_call_targets!((retained_parents,), refreshed,
                environments, parent.temporal_streams, parent.output_retention,
                parent.time, parent.constants, true, parent.environment)
            @test old_optional.binding.callee_object_ids == ObjectId[ObjectId(:newborn)]
            inner = only(retained_parents)
            @test inner.execution_target === old_owner
            @test inner.context_cache === cache
            @test inner.calls !== old_calls
            @test typeof(inner.calls) !== typeof(old_calls)
            @test active.calls === old_calls
            @test isempty(old_optional)
            fresh_optional = only(inner.calls)
            @test fresh_optional.binding === old_optional.binding
            @test length(fresh_optional) == 1
            child = only(fresh_optional)
            @test child.object_id == ObjectId(:newborn)
            run_call!(child; publish=false)
            @test child.status.value === one(S)
            @test child.status.calls == 1
            @test isempty(old_optional)
            @test cache.in_use # A descendant cannot release the parent's lease.
        finally
            cache.in_use = false
        end
        @test !cache.in_use
        step!(simulation)
        current = only(call_targets(capture[], :parent))
        run_call!(current; publish=false)
        @test current.status.seen === S(2)
        @test model_status(model, :newborn).calls == 2
    end
end

# Separate allocation probe: the scientific kernel has no capture, hook,
# payload copying or environment commit that could hide dispatch allocations.
PSE.@process "materialized_dispatch_allocation_leaf_probe" verbose=false

mutable struct AllocationBackend <: EA.AbstractEnvironmentBackend
    row::Any
    samples::Int
end
EA.base_step_seconds(::AllocationBackend) = 3600.0
EA.get_nsteps(::AllocationBackend) = 4
EA.environment_variables(::AllocationBackend) = Set((:T,))
EA.bind_environment(::AllocationBackend, object::Object, context, config) = nothing
EA.sample(backend::AllocationBackend, handle, variable::Symbol, time) =
    getproperty(backend.row, variable)

Base.@nospecializeinfer function EA.sample_environment(
    backend::AllocationBackend, handle, time,
    prepared::EA.PreparedEnvironmentInputs{(:T,),(:T,),false},
)
    @nospecialize handle time prepared
    backend.samples += 1
    return backend.row
end

struct AllocationLeaf{T} <: AbstractMaterialized_Dispatch_Allocation_Leaf_ProbeModel
    coefficients::NTuple{16,T}
end
PSE.inputs_(::AllocationLeaf{T}) where {T} = (driver=Default(T(2)),)
PSE.outputs_(::AllocationLeaf{T}) where {T} = merge(
    (seen=zero(T), calls=0),
    NamedTuple{PAD_NAMES}(ntuple(_ -> zero(T), Val(48))))
PSE.environment_inputs_(::AllocationLeaf{T}) where {T} = (T=zero(T),)
function PSE.run!(model::AllocationLeaf, status, environment, constants, context)
    status.calls += 1
    status.seen = status.driver + first(model.coefficients) + environment.T
    status.padding_1 = last(model.coefficients)
    return nothing
end

function allocation_fixture(::Type{T}) where {T}
    capture = Ref{Any}()
    row = (T=T(10),)
    backend = AllocationBackend(row, 0) # Box the model-facing row once.
    model = CompositeModel(Object(:owner; scale=:Scene),
        Object(:allocation_leaf; scale=:Leaf, parent=:owner); applications=(
            ModelSpec(CaptureOwner(capture); name=:owner, on=One(id=:owner),
                calls=(leaf=One(id=:allocation_leaf, within=Subtree(),
                    application=:allocation_leaf),)),
            ModelSpec(AllocationLeaf(ntuple(_ -> one(T), Val(16)));
                name=:allocation_leaf, on=One(id=:allocation_leaf),
                environment=Environment(provider=:allocation_probe)),
        ), environment=backend)
    simulation = run!(model; steps=1, outputs=:none)
    target = only(call_targets(capture[], :leaf))
    return (; simulation, backend, target, row)
end

function allocation_opaque_loop!(target, operations, ::Val{Publish}) where {Publish}
    for _ in 1:operations
        run_call!(target; publish=Publish)
    end
    return nothing
end
function allocation_typed_loop!(target, row, operations, ::Val{Publish}) where {Publish}
    for _ in 1:operations
        run_call!(target; sampled_environment=row, publish=Publish)
    end
    return nothing
end
function allocation_sampler_loop!(backend, prepared, row, operations)
    for _ in 1:operations
        sampled = EA.sample_environment(backend, nothing, 1.0, prepared)
        sampled === row || error("the allocation sampler did not return its stored row")
    end
    return nothing
end

function allocation_dispatch_evidence!(target, backend, row, publication)
    prepared = EA.PreparedEnvironmentInputs((:T,), (:T,))
    warmup, operations = 3072, 1024
    initial_calls, initial_samples = target.status.calls, backend.samples
    allocation_opaque_loop!(target, warmup, publication)
    allocation_typed_loop!(target, row, warmup, publication)
    allocation_sampler_loop!(backend, prepared, row, warmup)

    samples = map(1:3) do _
        before_calls, before_samples = target.status.calls, backend.samples
        opaque_bytes = @allocated allocation_opaque_loop!(target, operations, publication)
        opaque_calls = target.status.calls - before_calls
        opaque_samples = backend.samples - before_samples
        before_calls, before_samples = target.status.calls, backend.samples
        typed_bytes = @allocated allocation_typed_loop!(target, row, operations, publication)
        typed_calls = target.status.calls - before_calls
        typed_samples = backend.samples - before_samples
        before_calls, before_samples = target.status.calls, backend.samples
        sampler_bytes = @allocated allocation_sampler_loop!(backend, prepared, row, operations)
        (; opaque_bytes, typed_bytes, sampler_bytes,
            opaque_calls, opaque_samples, typed_calls, typed_samples,
            sampler_calls=target.status.calls - before_calls,
            sampler_samples=backend.samples - before_samples)
    end
    return (; samples, operations, warmup,
        total_calls=target.status.calls - initial_calls,
        total_samples=backend.samples - initial_samples)
end

@testset "opaque sampled rows do not box wide materialized-call payloads" begin
    for T in (Float32, Float64), publication in (Val(false), Val(true))
        data = allocation_fixture(T)
        target, backend, row = data.target, data.backend, data.row
        @test !ismutabletype(typeof(target.model))
        @test sizeof(target.model.coefficients) == 16 * sizeof(T)
        @test length(keys(target.status)) == 51
        evidence = allocation_dispatch_evidence!(target, backend, row, publication)
        @test evidence.warmup > 2304
        @test evidence.operations == 1024
        @test length(evidence.samples) == 3
        @test minimum(sample.sampler_bytes for sample in evidence.samples) == 0
        # Fixed allowance for the complete 1,024-call loop, never per target.
        @test minimum(sample.opaque_bytes for sample in evidence.samples) <=
              minimum(sample.typed_bytes for sample in evidence.samples) + 64
        for sample in evidence.samples
            @test sample.opaque_calls == sample.typed_calls == evidence.operations
            @test sample.opaque_samples == sample.sampler_samples == evidence.operations
            @test sample.typed_samples == sample.sampler_calls == 0
        end
        @test evidence.total_calls == 2 * (evidence.warmup + 3 * evidence.operations)
        @test evidence.total_samples == 2 * (evidence.warmup + 3 * evidence.operations)
        @test backend.row === row
        @test target.status.seen === T(13)
        @test target.status.padding_1 === one(T)
    end
end

end # module MaterializedCallDispatchChecks
