module SingleCallSnapshotCacheChecks

using Dates, PlantSimEngine, Test

const PSE = PlantSimEngine
const EA = PSE.EnvironmentAPI

PSE.@process "single_snapshot_owner_probe" verbose=false
PSE.@process "single_snapshot_leaf_probe" verbose=false
PSE.@process "single_snapshot_middle_probe" verbose=false

mutable struct TrialA{T}
    temperatures::NTuple{2,T}
end
struct TrialB{T}
    temperatures::NTuple{2,T}
end
mutable struct ProbeBackend{T} <: EA.AbstractEnvironmentBackend
    temperatures::NTuple{2,T}
    samples::Int
end
EA.base_step_seconds(::ProbeBackend) = 3600.0
EA.get_nsteps(::ProbeBackend) = 8
EA.environment_variables(::ProbeBackend) = Set((:T,))
EA.bind_environment(::ProbeBackend, object::Object, context, config) =
    (; cell=isnothing(geometry(object)) ? 1 : geometry(object).cell)
function EA.sample(backend::ProbeBackend, handle, ::Symbol, time)
    backend.samples += 1
    base = backend.temperatures[handle.cell]
    return base + oftype(base, time)
end
function EA.sample(backend::ProbeBackend, handle, state::Union{TrialA,TrialB}, ::Symbol, time)
    backend.samples += 1
    return state.temperatures[handle.cell]
end

struct CaptureOwner{T,C} <: AbstractSingle_Snapshot_Owner_ProbeModel
    initial::T
    capture::C
end
PSE.outputs_(model::CaptureOwner) = (drive=model.initial, visits=0)
function PSE.run!(model::CaptureOwner, status, environment, constants, context)
    model.capture[] = context
    status.visits += 1
    status.drive = oftype(status.drive, status.visits + 1)
    return nothing
end

struct Leaf{T} <: AbstractSingle_Snapshot_Leaf_ProbeModel
    initial::T
end
PSE.inputs_(model::Leaf) = (driver=Default(model.initial), fail_next=Default(false))
PSE.outputs_(model::Leaf) = (seen=model.initial, calls=0)
PSE.environment_inputs_(model::Leaf) = (T=model.initial,)
function PSE.run!(::Leaf, status, environment, constants, context)
    status.calls += 1
    status.seen = status.driver + environment.T
    if status.fail_next
        status.fail_next = false
        error("intentional singleton snapshot failure")
    end
    return nothing
end

struct Middle{T,C,H} <: AbstractSingle_Snapshot_Middle_ProbeModel
    initial::T
    capture::C
    hook::H
end
PSE.outputs_(model::Middle) = (seen=model.initial, temperature=model.initial, calls=0)
PSE.environment_inputs_(model::Middle) = (T=model.initial,)
function PSE.run!(model::Middle, status, environment, constants, context)
    # Obtain the outer child before reentry: a nested call must not replace its
    # captured environment/publication metadata or its descendant wrappers.
    child = only(call_targets(context, :leaf))
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

function fixture(::Type{S}; outputs=:all) where {S}
    capture, child_capture = Ref{Any}(), Ref{Any}()
    hook = Ref{Any}(nothing)
    backend = ProbeBackend((S(10), S(20)), 0)
    model = CompositeModel(Object(:owner; scale=:Scene),
        Object(:middle; scale=:Branch, parent=:owner, geometry=(cell=1,)),
        Object(:leaf; scale=:Leaf, parent=:middle, geometry=(cell=2,),
            status=Status(seen=S(-999))); applications=(
            ModelSpec(CaptureOwner(zero(S), capture); name=:owner, on=One(id=:owner), calls=(
                one=One(id=:leaf, within=SceneScope(), application=:leaf),
                optional=OptionalOne(id=:leaf, within=SceneScope(), application=:leaf),
                many=Many(scale=:Leaf, within=SceneScope(), application=:leaf),
                optional_newborn=OptionalOne(id=:newborn, within=SceneScope(), application=:leaf),
                newborn=Many(id=:newborn, within=SceneScope(), application=:leaf),
                middle=One(id=:middle, within=SceneScope(), application=:middle),)),
            ModelSpec(Middle(zero(S), child_capture, hook); name=:middle, on=One(id=:middle),
                calls=(leaf=One(id=:leaf, within=Subtree(), application=:leaf),),
                environment=Environment(provider=:snapshot_probe)),
            ModelSpec(Leaf(zero(S)); name=:leaf, on=Many(scale=:Leaf),
                inputs=(driver=One(id=:owner, within=SceneScope(), application=:owner, var=:drive),),
                output_routing=(seen=:stream_only,),
                environment=Environment(provider=:snapshot_probe)),
        ), environment=backend, type_promotion=Dict(Float64 => S))
    simulation = run!(model; steps=1, outputs)
    return (; model, simulation, capture, child_capture, hook, backend)
end

raw(data) = outputs(data.simulation)[(:leaf, ObjectId(:leaf), :seen)]

@testset "singleton snapshots retain live references and sample mutable backends every run" begin
    for S in (Float32, Float64)
        data = fixture(S)
        canonical = model_status(data.model, :leaf)
        owner = model_status(data.model, :owner)
        count_before = data.backend.samples
        for name in (:one, :optional, :many)
            targets = call_targets(data.capture[], name)
            a, b = only(targets), only(targets)
            @test a.object_id == ObjectId(:leaf)
            @test a.status === b.status
            @test a.model === b.model
            @test a.status !== canonical
            @test a.canonical_status === canonical
            @test PSE.refvalue(a.status, :driver) === PSE.refvalue(owner, :drive)
            @test a.time == b.time == 1
            @test a.publication_allowed && b.publication_allowed
            @test a.environment === data.capture[].environment
        end
        @test data.backend.samples == count_before # lookup does no numerical sampling
        targets = call_targets(data.capture[], :one)
        old = only(targets)
        run_call!(old; publish=false)
        @test old.status.seen === S(23)
        @test data.backend.samples == count_before + 1
        only(targets).status.driver = S(7)
        @test owner.drive === S(7)
        run_call!(only(targets); publish=false)
        @test old.status.seen === S(28)
        data.backend.temperatures = (S(10), S(40))
        run_call!(only(targets); publish=false)
        @test old.status.seen === S(48)
        @test old.status.calls == 3
        @test data.backend.samples == count_before + 3
        @test canonical.seen === S(-999)
        @test isempty(raw(data))
    end
end

@testset "singleton snapshot metadata follows nested trials without caching sampled values" begin
    for S in (Float32, Float64)
        data = fixture(S)
        parent = only(call_targets(data.capture[], :middle))
        initial_samples = data.backend.samples
        trial = TrialA((S(30), S(40)))
        run_call!(parent; environment=trial, publish=false)
        rejected = data.child_capture[]
        @test rejected.environment === trial
        @test !rejected.publication_allowed
        @test rejected.time == 1
        @test rejected.status.seen === S(42)
        @test data.backend.samples == initial_samples + 2
        @test isempty(raw(data))

        run_call!(parent; environment=trial, publish=true)
        accepted = data.child_capture[]
        @test accepted.environment === trial
        @test accepted.publication_allowed
        @test !rejected.publication_allowed
        @test raw(data) == [(1.0, S(42))]
        trial.temperatures = (S(31), S(41))
        run_call!(accepted; publish=true)
        @test accepted.status.seen === S(43)
        @test data.backend.samples == initial_samples + 5
        @test raw(data) == [(1.0, S(43))]

        trial_b = TrialB((S(50), S(60)))
        run_call!(parent; environment=trial_b, publish=true)
        changed_type = data.child_capture[]
        @test changed_type.environment === trial_b
        @test changed_type.status.seen === S(62)
        @test accepted.environment === trial
        @test accepted.publication_allowed
        trial_a2 = TrialA((S(70), S(80)))
        run_call!(parent; environment=trial_a2, publish=false)
        changed_identity = data.child_capture[]
        @test changed_identity.environment === trial_a2
        @test !changed_identity.publication_allowed
        @test changed_identity.status.seen === S(82)
        @test accepted.environment === trial
        @test trial.temperatures == (S(31), S(41))
        @test raw(data) == [(1.0, S(62))]

        step!(data.simulation)
        current_parent = only(call_targets(data.capture[], :middle))
        run_call!(current_parent; publish=true)
        current = data.child_capture[]
        @test current.time == 2
        @test current.environment === data.capture[].environment
        @test current.publication_allowed
        @test current.status.seen === S(25) # live drive3 + committed T22
        @test accepted.time == rejected.time == changed_type.time == 1
        @test accepted.environment === trial
        @test !rejected.publication_allowed
        run_call!(accepted; publish=true)
        @test accepted.status.seen === S(44) # live drive3 + captured mutable trial T41
        @test sort(raw(data); by=first) == [(1.0, S(44)), (2.0, S(25))]
    end
end

@testset "singleton membership refresh handles newborns and changing Many cardinality" begin
    for S in (Float32, Float64)
        data = fixture(S; outputs=:none)
        context = data.capture[]
        @test_throws ArgumentError only(call_targets(context, :optional_newborn))
        original = only(call_targets(context, :many))
        register_object!(data.model, Object(:newborn; scale=:Leaf, parent=:middle,
            geometry=(cell=2,), status=Status(seen=S(-999))))
        newborn = only(call_targets(context, :newborn; objects=(:newborn,)))
        @test newborn.object_id == ObjectId(:newborn)
        run_call!(newborn; publish=false)
        @test newborn.status.seen === S(23)
        @test newborn.status.calls == 1
        @test model_status(data.model, :newborn).seen === S(-999)

        step!(data.simulation)
        current_context = data.capture[]
        @test_throws ArgumentError only(call_targets(current_context, :many))
        for name in (:one, :optional)
            current = only(call_targets(current_context, name))
            @test current.object_id == ObjectId(:leaf)
            @test current.time == 2
            @test original.time == 1
            @test current.canonical_status === model_status(data.model, :leaf)
            @test PSE.refvalue(current.status, :driver) ===
                PSE.refvalue(model_status(data.model, :owner), :drive)
            run_call!(current; publish=false)
            @test current.status.seen === S(25)
        end
        @test only(call_targets(current_context, :optional_newborn)).object_id == ObjectId(:newborn)
        remove_object!(data.model, :newborn)
        step!(data.simulation)
        remaining = only(call_targets(data.capture[], :many))
        @test remaining.object_id == ObjectId(:leaf)
        @test remaining.time == 3
        @test_throws ArgumentError only(call_targets(data.capture[], :optional_newborn))
        run_call!(remaining; publish=false)
        @test remaining.status.seen === S(27)
    end
end

@testset "singleton caching leaves collection borrowed-buffer and bulk-call behavior intact" begin
    for S in (Float32, Float64)
        data = fixture(S)
        targets = call_targets(data.capture[], :many)
        cached = only(targets)
        first_copy, second_copy = collect(targets), collect(targets)
        @test first_copy !== second_copy
        @test only(first_copy).status === cached.status
        pop!(first_copy)
        @test isempty(first_copy) && length(second_copy) == length(targets) == 1
        samples = data.backend.samples
        with_call_targets(targets) do borrowed
            @test borrowed isa Vector{<:CallTarget}
            @test isconcretetype(eltype(borrowed))
            @test only(borrowed).status === cached.status
            only(borrowed).status.driver = S(9)
        end
        @test data.backend.samples == samples
        @test cached.status.driver === S(9)
        @test run_call!(data.capture[], :many; publish=true) === targets
        @test cached.status.calls == 1
        @test cached.status.seen === S(30)
        @test data.backend.samples == samples + 1
        @test raw(data) == [(1.0, S(30))]
    end
end

@testset "active singleton owner leases preserve outer snapshots and release on failure" begin
    for S in (Float32, Float64)
        data = fixture(S)
        targets = call_targets(data.capture[], :middle)
        parent = only(targets)
        reentered = Ref{Any}()
        data.hook[] = () -> begin
            @test parent.context_cache.in_use
            inner = only(call_targets(data.capture[], :middle))
            reentered[] = inner
            @test inner.execution_target === parent.execution_target
            @test inner.calls !== parent.calls
            @test only(inner.calls) !== only(parent.calls)
            run_call!(inner; environment=TrialB((S(31), S(41))), publish=false)
            @test parent.context_cache.in_use
        end
        run_call!(parent; publish=true)
        outer_child = data.child_capture[]
        @test isassigned(reentered)
        @test parent.status.seen === S(23)
        @test parent.status.temperature === S(11)
        @test outer_child.environment === parent.environment
        @test outer_child.publication_allowed
        @test raw(data) == [(1.0, S(23))]
        @test !parent.context_cache.in_use
        @test !outer_child.context_cache.in_use
        @test only(targets).calls === parent.calls

        outer_child.status.fail_next = true
        @test_throws ErrorException run_call!(only(targets); publish=true)
        @test !parent.context_cache.in_use
        @test !outer_child.context_cache.in_use
        @test raw(data) == [(1.0, S(23))]
        run_call!(only(targets); publish=true)
        @test parent.status.seen === S(23)
        @test raw(data) == [(1.0, S(23))]
    end
end

# Escaping the immutable view through Ref{Any} distinguishes snapshot reuse
# from compiler elimination of an immediately consumed temporary. No kernel,
# sampler, callback or target-vector traversal runs inside the measured loop.
@noinline function escaped_only_loop!(sink::Base.RefValue{Any}, targets, count::Int)
    for _ in 1:count
        sink[] = only(targets)
    end
    return nothing
end

@testset "unchanged singleton snapshots have bounded warmed escaping-lookup allocation" begin
    for S in (Float32, Float64)
        data = fixture(S; outputs=:none)
        targets = call_targets(data.capture[], :one)
        sink = Ref{Any}()
        initial_calls = only(targets).status.calls
        initial_samples = data.backend.samples
        escaped_only_loop!(sink, targets, 3072)
        minimum_bytes = typemax(Int)
        for _ in 1:3
            bytes = @allocated escaped_only_loop!(sink, targets, 1024)
            minimum_bytes = min(minimum_bytes, bytes)
        end
        @test minimum_bytes <= 512 # whole 1024-lookup loop, not bytes per lookup
        @test sink[].status.driver isa S
        @test sink[].object_id == ObjectId(:leaf)
        @test only(targets).status.calls == initial_calls
        @test data.backend.samples == initial_samples
    end
end

# Keep the public keyword entry point in the measured route: materializing a
# partially inferred immutable view must not box it again to execute it. The
# actual backend sampler runs on every invocation, and the changing shared
# driver and escaped checksum make stale numerical reuse observable.
@noinline function immediate_snapshot_loop!(
    checksum::Base.RefValue{S}, targets, driver::S, count::Int,
) where {S}
    total = zero(driver)
    for index in 1:count
        target = only(targets)
        target.status.driver = driver + oftype(driver, isodd(index))
        run_call!(target; publish=false)
        total += target.status.seen
    end
    checksum[] = total
    return nothing
end

@testset "public immediate singleton execution avoids warmed boundary boxing" begin
    for S in (Float32, Float64)
        data = fixture(S; outputs=:none)
        targets = call_targets(data.capture[], :one)
        checksum = Ref(zero(S))
        initial_calls = only(targets).status.calls
        initial_samples = data.backend.samples
        immediate_snapshot_loop!(checksum, targets, S(2), 3072)
        @test checksum[] === S(3072 * 23.5)
        minimum_bytes = typemax(Int)
        for round in 1:3
            before_calls = only(targets).status.calls
            before_samples = data.backend.samples
            bytes = @allocated immediate_snapshot_loop!(checksum, targets, S(2), 1024)
            minimum_bytes = min(minimum_bytes, bytes)
            @test checksum[] === S(1024 * 23.5)
            @test only(targets).status.calls == before_calls + 1024
            @test data.backend.samples == before_samples + 1024
        end
        @test minimum_bytes <= 512 # whole public lookup/mutate/execute/read loop
        @test only(targets).status.calls == initial_calls + 6144
        @test data.backend.samples == initial_samples + 6144
        @test only(targets).status.seen === S(23) # last index is even
        @test model_status(data.model, :owner).drive === S(2)
        @test model_status(data.model, :leaf).seen === S(-999)
    end
end

end # module
