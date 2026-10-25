module TransientRunContextCacheChecks

using Dates
using PlantSimEngine
using Test

const PSE = PlantSimEngine
const EA = PlantSimEngine.EnvironmentAPI

# Test-only probes. These roles do not add any production process or equation.
PSE.@process "transient_context_cache_owner_probe" verbose=false
PSE.@process "transient_context_cache_middle_probe" verbose=false
PSE.@process "transient_context_cache_leaf_probe" verbose=false

struct CacheTrialA{T}
    cell_a::T
    cell_b::T
end
struct CacheTrialB{T}
    values::NTuple{2,T}
end
trial_value(state::CacheTrialA, cell) = cell === :cell_a ? state.cell_a : state.cell_b
trial_value(state::CacheTrialB, cell) = state.values[cell === :cell_a ? 1 : 2]

const CacheCommit = NamedTuple{
    (:application, :cell, :value, :time), Tuple{Symbol,Symbol,Float64,Float64},
}
mutable struct CacheProbeBackend <: EA.AbstractEnvironmentBackend
    values::Dict{Symbol,Float64}
    writes::Vector{CacheCommit}
end
CacheProbeBackend() = CacheProbeBackend(
    Dict(:cell_a => 10.0, :cell_b => 20.0), CacheCommit[])

EA.base_step_seconds(::CacheProbeBackend) = 3600.0
EA.get_nsteps(::CacheProbeBackend) = 8
EA.environment_variables(::CacheProbeBackend) = Set((:T, :clock_index))
function EA.bind_environment(backend::CacheProbeBackend, object::PSE.Object, context, config)
    location = geometry(object)
    cell = isnothing(location) ? :cell_a : location.cell
    sink = isnothing(config) ? nothing : get(config, :sink, nothing)
    return (; cell, application=context.application, sink)
end
function EA.sample(backend::CacheProbeBackend, handle, variable::Symbol, time)
    variable === :clock_index && return float(time)
    variable === :T && return backend.values[handle.cell]
    error("Unexpected cache-probe variable $variable")
end
function EA.sample(backend::CacheProbeBackend, handle, state::Union{CacheTrialA,CacheTrialB},
                   variable::Symbol, time)
    variable === :clock_index && return float(time)
    variable === :T && return trial_value(state, handle.cell)
    error("Unexpected transient cache-probe variable $variable")
end
function EA.commit_environment!(backend::CacheProbeBackend, handle, state, time)
    handle.sink === :cache_probe || error("Cache probe has no commit sink")
    backend.values[handle.cell] = state.T
    push!(backend.writes, (application=handle.application, cell=handle.cell,
        value=Float64(state.T), time=Float64(time)))
    return nothing
end

struct CacheOwner{C} <: AbstractTransient_Context_Cache_Owner_ProbeModel
    capture::C
end
PSE.inputs_(::CacheOwner) = NamedTuple()
PSE.outputs_(::CacheOwner) = (visits=0,)
PSE.environment_inputs_(::CacheOwner) = NamedTuple()
PSE.environment_outputs_(::CacheOwner) = NamedTuple()
function PSE.run!(model::CacheOwner, status, environment, constants, context)
    model.capture[] = context
    status.visits += 1
    return nothing
end

struct CacheLeaf <: AbstractTransient_Context_Cache_Leaf_ProbeModel end
PSE.inputs_(::CacheLeaf) = (fail_next=Default(false),)
PSE.outputs_(::CacheLeaf) = (seen=0.0, seen_step=0.0, calls=0)
PSE.environment_inputs_(::CacheLeaf) = (T=0.0, clock_index=0.0)
PSE.environment_outputs_(::CacheLeaf) = (T=0.0,)
function PSE.run!(::CacheLeaf, status, environment, constants, context)
    status.calls += 1
    status.seen = environment.T
    status.seen_step = environment.clock_index
    if status.fail_next
        status.fail_next = false
        error("intentional cache-probe failure")
    end
    # Every invocation requests a commit. The engine must suppress this in
    # an unpublished ancestor, even when the immediate caller publishes.
    commit_environment!(context, (T=environment.T,))
    return nothing
end

struct CacheMiddle <: AbstractTransient_Context_Cache_Middle_ProbeModel
    individual::Bool
end
PSE.inputs_(::CacheMiddle) = NamedTuple()
PSE.outputs_(::CacheMiddle) = (seen=0.0, seen_step=0.0, leaf_seen=0.0)
PSE.environment_inputs_(::CacheMiddle) = (T=0.0, clock_index=0.0)
PSE.environment_outputs_(::CacheMiddle) = NamedTuple()
function PSE.run!(model::CacheMiddle, status, environment, constants, context)
    status.seen = environment.T
    status.seen_step = environment.clock_index
    if model.individual
        target = only(call_targets(context, :leaf))
        run_call!(target; publish=true)
    else
        target = only(run_call!(context, :leaf; publish=true))
    end
    status.leaf_seen = target.status.seen
    return nothing
end

struct CacheManyMiddle <: AbstractTransient_Context_Cache_Middle_ProbeModel end
PSE.inputs_(::CacheManyMiddle) = NamedTuple()
PSE.outputs_(::CacheManyMiddle) = (
    seen=0.0, seen_step=0.0, child_ids=ObjectId[], child_values=Float64[],
)
PSE.environment_inputs_(::CacheManyMiddle) = (T=0.0, clock_index=0.0)
PSE.environment_outputs_(::CacheManyMiddle) = NamedTuple()
function PSE.run!(::CacheManyMiddle, status, environment, constants, context)
    status.seen = environment.T
    status.seen_step = environment.clock_index
    children = run_call!(context, :leaf; publish=true)
    status.child_ids = [child.object_id for child in children]
    status.child_values = [child.status.seen for child in children]
    return nothing
end

function cache_scene(::Type{S}; individual=false, many=false) where {S}
    capture = Ref{Any}()
    backend = CacheProbeBackend()
    leaf_selector = many ?
        Many(scale=:Leaf, within=Subtree(), application=:cache_leaf) :
        One(id=:cache_leaf_a, within=Subtree(), application=:cache_leaf)
    middle = many ? CacheManyMiddle() : CacheMiddle(individual)
    model = CompositeModel(
        Object(:cache_owner; scale=:Scene, geometry=(cell=:cell_a,)),
        Object(:cache_middle; scale=:Plant, parent=:cache_owner, geometry=(cell=:cell_a,)),
        Object(:cache_outside; scale=:Plant, parent=:cache_owner, geometry=(cell=:cell_b,)),
        Object(:cache_leaf_a; scale=:Leaf, parent=:cache_middle, geometry=(cell=:cell_b,));
        applications=(
            ModelSpec(CacheOwner(capture); name=:cache_owner, on=One(id=:cache_owner),
                calls=(middle=One(id=:cache_middle, application=:cache_middle),)),
            ModelSpec(middle; name=:cache_middle, on=One(id=:cache_middle),
                calls=(leaf=leaf_selector,), environment=Environment(provider=:cache_probe)),
            ModelSpec(CacheLeaf(); name=:cache_leaf, on=Many(scale=:Leaf),
                environment=Environment(provider=:cache_probe, sink=:cache_probe)),
        ),
        environment=backend, type_promotion=Dict(Float64 => S),
    )
    return (; model, backend, capture)
end

function retained(simulation, application, object; variable=:seen)
    rows = filter(row -> row.application_id === application,
        collect_outputs(simulation, object, variable; sink=nothing))
    return sort!(rows; by=row -> row.timestep)
end

function assert_current(scene, ::Type{S}, middle, leaf, step) where {S}
    @test model_status(scene.model, :cache_middle).seen === S(middle)
    @test model_status(scene.model, :cache_middle).seen_step === S(step)
    @test model_status(scene.model, :cache_middle).leaf_seen === S(leaf)
    @test model_status(scene.model, :cache_leaf_a).seen === S(leaf)
    @test model_status(scene.model, :cache_leaf_a).seen_step === S(step)
end

@testset "transient call contexts update values, types, time and publication" begin
    for S in (Float32, Float64), individual in (false, true)
        @testset "storage=$S individual-child=$individual" begin
            scene = cache_scene(S; individual)
            simulation = run!(scene.model; steps=1, outputs=:all)
            context = scene.capture[]
            @test current_step(simulation) == 1
            @test isempty(retained(simulation, :cache_middle, :cache_middle))
            @test isempty(retained(simulation, :cache_leaf, :cache_leaf_a))

            # Same concrete transient type, different values: neither a cached
            # first value nor a backend-global value may leak into descendants.
            for trial in (CacheTrialA(30.0, 40.0), CacheTrialA(31.0, 41.0))
                run_call!(context, :middle; environment=trial, publish=false)
                assert_current(scene, S, trial.cell_a, trial.cell_b, 1)
                @test isempty(scene.backend.writes)
                @test isempty(retained(simulation, :cache_middle, :cache_middle))
                @test isempty(retained(simulation, :cache_leaf, :cache_leaf_a))
            end
            @test scene.backend.values == Dict(:cell_a => 10.0, :cell_b => 20.0)

            # Different transient type and numeric specialization, accepted.
            run_call!(context, :middle; environment=CacheTrialB((50.0f0, 60.0f0)), publish=true)
            assert_current(scene, S, 50, 60, 1)
            @test scene.backend.writes == [
                (application=:cache_leaf, cell=:cell_b, value=60.0, time=1.0)]
            accepted_prefix = deepcopy(retained(simulation, :cache_leaf, :cache_leaf_a))
            @test getproperty.(accepted_prefix, :timestep) == [1]
            @test getproperty.(accepted_prefix, :value) == [S(60)]

            # Publication allowed on the previous cached invocation must NOT
            # leak into an immediately following rejected trial.
            run_call!(context, :middle; environment=CacheTrialA(32.0, 42.0), publish=false)
            assert_current(scene, S, 32, 42, 1)
            @test length(scene.backend.writes) == 1
            @test isequal(retained(simulation, :cache_leaf, :cache_leaf_a), accepted_prefix)

            # Omitting an override restores each target's committed backend
            # view, not the previously cached A/B transient environment.
            run_call!(context, :middle; publish=false)
            assert_current(scene, S, 10, 60, 1)
            @test length(scene.backend.writes) == 1
            @test isequal(retained(simulation, :cache_leaf, :cache_leaf_a), accepted_prefix)

            step!(simulation)
            context = scene.capture[]
            run_call!(context, :middle; environment=CacheTrialB((70.0f0, 80.0f0)), publish=true)
            assert_current(scene, S, 70, 80, 2)
            for (application, object, expected) in (
                (:cache_middle, :cache_middle, S[50, 70]),
                (:cache_leaf, :cache_leaf_a, S[60, 80]),
            )
                rows = retained(simulation, application, object)
                @test getproperty.(rows, :timestep) == [1, 2]
                @test getproperty.(rows, :value) == expected
            end
            @test scene.backend.writes == [
                (application=:cache_leaf, cell=:cell_b, value=60.0, time=1.0),
                (application=:cache_leaf, cell=:cell_b, value=80.0, time=2.0),
            ]

            # sampled_environment is forwarded only to this target. It is not
            # inherited by the nested leaf as a backend override.
            before_sampled = deepcopy(retained(simulation, :cache_leaf, :cache_leaf_a))
            run_call!(context, :middle;
                sampled_environment=(T=91.0, clock_index=-91.0), publish=false)
            @test model_status(scene.model, :cache_middle).seen === S(91)
            @test model_status(scene.model, :cache_middle).seen_step === S(-91)
            @test model_status(scene.model, :cache_middle).leaf_seen === S(80)
            @test model_status(scene.model, :cache_leaf_a).seen_step === S(2)
            @test length(scene.backend.writes) == 2
            @test isequal(retained(simulation, :cache_leaf, :cache_leaf_a), before_sampled)

            # A throwing unpublished invocation may mutate Status; no rollback
            # is promised. It must not poison later context/environment reuse.
            leaf = model_status(scene.model, :cache_leaf_a)
            calls_before = leaf.calls
            leaf.fail_next = true
            @test_throws "intentional cache-probe failure" run_call!(context, :middle;
                environment=CacheTrialA(33.0, 43.0), publish=false)
            @test leaf.calls == calls_before + 1
            @test !leaf.fail_next
            @test length(scene.backend.writes) == 2
            @test isequal(retained(simulation, :cache_leaf, :cache_leaf_a), before_sampled)

            step!(simulation)
            context = scene.capture[]
            run_call!(context, :middle; environment=CacheTrialB((77.0f0, 88.0f0)), publish=true)
            assert_current(scene, S, 77, 88, 3)
            rows = retained(simulation, :cache_leaf, :cache_leaf_a)
            @test getproperty.(rows, :timestep) == [1, 2, 3]
            @test getproperty.(rows, :value) == S[60, 80, 88]
            @test isequal(rows[1:1], accepted_prefix)
            @test all(row -> row.value isa S, rows)
            middle_rows = retained(simulation, :cache_middle, :cache_middle)
            @test getproperty.(middle_rows, :timestep) == [1, 2, 3]
            @test getproperty.(middle_rows, :value) == S[50, 70, 77]
            @test last(scene.backend.writes) ==
                (application=:cache_leaf, cell=:cell_b, value=88.0, time=3.0)
            @test length(scene.backend.writes) == 3
        end
    end
end

@testset "warmed transient Many refreshes target membership and spatial handles" begin
    scene = cache_scene(Float64; many=true)
    simulation = run!(scene.model; steps=1, outputs=:all)
    run_call!(scene.capture[], :middle; environment=CacheTrialA(1.0, 2.0), publish=false)
    middle = model_status(scene.model, :cache_middle)
    @test Dict(zip(middle.child_ids, middle.child_values)) ==
        Dict(ObjectId(:cache_leaf_a) => 2.0)
    @test isempty(scene.backend.writes)

    register_object!(scene.model,
        Object(:cache_leaf_b; scale=:Leaf, parent=:cache_middle, geometry=(cell=:cell_a,)))
    step!(simulation)
    run_call!(scene.capture[], :middle; environment=CacheTrialB((11.0f0, 22.0f0)), publish=false)
    middle = model_status(scene.model, :cache_middle)
    @test Dict(zip(middle.child_ids, middle.child_values)) ==
        Dict(ObjectId(:cache_leaf_a) => 22.0, ObjectId(:cache_leaf_b) => 11.0)
    @test isempty(scene.backend.writes)

    # The already-warmed leaf changes its own compiled environment handle.
    move_object!(scene.model, :cache_leaf_a, (cell=:cell_a,))
    step!(simulation)
    run_call!(scene.capture[], :middle; environment=CacheTrialA(33.0, 44.0), publish=true)
    middle = model_status(scene.model, :cache_middle)
    @test Dict(zip(middle.child_ids, middle.child_values)) ==
        Dict(ObjectId(:cache_leaf_a) => 33.0, ObjectId(:cache_leaf_b) => 33.0)
    @test all(write -> write.cell === :cell_a && write.value == 33.0 && write.time == 3.0,
        scene.backend.writes)
    @test length(scene.backend.writes) == 2
    leaf_history = deepcopy(retained(simulation, :cache_leaf, :cache_leaf_a))
    @test getproperty.(leaf_history, :timestep) == [3]
    @test getproperty.(leaf_history, :value) == [33.0]

    # Reparent one target outside the declared scope and remove the other.
    # The now-empty accepted Many call must not execute stale cached targets.
    reparent_object!(scene.model, :cache_leaf_b, :cache_outside)
    remove_object!(scene.model, :cache_leaf_a)
    step!(simulation)
    run_call!(scene.capture[], :middle; environment=CacheTrialB((55.0f0, 66.0f0)), publish=true)
    middle = model_status(scene.model, :cache_middle)
    @test isempty(middle.child_ids)
    @test isempty(middle.child_values)
    @test length(scene.backend.writes) == 2
    @test model_status(scene.model, :cache_leaf_b).seen == 33.0
    @test isequal(retained(simulation, :cache_leaf, :cache_leaf_a), leaf_history)
    @test getproperty.(retained(simulation, :cache_leaf, :cache_leaf_b), :timestep) == [3]
end

# These two narrowly internal cache tests pin the optimization mechanism;
# the behavioral testsets above deliberately use only public execution APIs.
function prepare_test_cache(cache, target, environment; time=target.time, publish=false)
    return PSE._prepare_cached_call_context!(
        cache, true, target.compiled, target.environment_bindings,
        target.application, target.object_id, target.bound_inputs, target.output_targets,
        target.temporal_streams, target.output_retention, time, target.constants,
        publish, environment)
end

@testset "materialization preserves descendants of an actively leased default context" begin
    scene = cache_scene(Float64)
    simulation = run!(scene.model; steps=1, outputs=:all)
    owner = scene.capture[]
    target = only(call_targets(owner, :middle))
    cache = target.context_cache
    active = prepare_test_cache(cache, target, target.environment; publish=true)
    @test active === cache.default
    retained_leaf_view = call_targets(active, :leaf)
    @test length(retained_leaf_view) == 1

    # Model an already-active outer lease. Materialization of the same target
    # occurs BEFORE the inner invocation acquires its lease; it must not reset
    # the outer context's retained mutable child-target view.
    cache.in_use = true
    try
        inner_owner = PSE.RunContext(
            owner.compiled, owner.environment_bindings, owner.application,
            owner.object_id, owner.calls, owner.bound_inputs, owner.output_targets,
            owner.temporal_streams, owner.output_retention, owner.time,
            owner.constants, false, CacheTrialA(31.0, 41.0))
        inner = only(call_targets(inner_owner, :middle))
        @test inner.context_cache === cache
        @test inner.calls !== active.calls
        run_call!(inner; publish=true)
        @test cache.in_use # The inner invocation must not release the outer lease.
        @test isempty(scene.backend.writes)
        @test isempty(retained(simulation, :cache_leaf, :cache_leaf_a))

        # Continue the outer invocation using its PREVIOUSLY obtained view,
        # without reacquiring call_targets(active, ...) and masking corruption.
        run_call!(only(retained_leaf_view); publish=true)
        @test model_status(scene.model, :cache_leaf_a).seen == 20.0
        @test scene.backend.writes == [
            (application=:cache_leaf, cell=:cell_b, value=20.0, time=1.0)]
        @test getproperty.(retained(simulation, :cache_leaf, :cache_leaf_a), :value) == [20.0]
        @test cache.transient === nothing
    finally
        cache.in_use = false
    end
    @test !cache.in_use
end

@testset "Nothing-default cache reuses matching types and bounds alternate specializations" begin
    scene = cache_scene(Float64)
    run!(scene.model; steps=1, outputs=:none)
    target = only(call_targets(scene.capture[], :middle))
    cache = PSE.CallContextCache(nothing)
    normal1 = prepare_test_cache(cache, target, target.environment)
    @test cache.default === nothing && cache.transient === normal1
    @test prepare_test_cache(cache, target, target.environment) === normal1

    a1 = prepare_test_cache(cache, target, CacheTrialA(1.0, 2.0))
    a2 = prepare_test_cache(cache, target, CacheTrialA(3.0, 4.0); time=2.0, publish=true)
    @test a1 === a2
    @test a2.environment === CacheTrialA(3.0, 4.0)
    @test a2.time == 2.0 && a2.publication_allowed
    @test a2 !== normal1 && cache.transient === a2

    b1 = prepare_test_cache(cache, target, CacheTrialB((5.0f0, 6.0f0)))
    b2 = prepare_test_cache(cache, target, CacheTrialB((7.0f0, 8.0f0)); time=3.0)
    @test b1 === b2
    @test b2.environment === CacheTrialB((7.0f0, 8.0f0))
    @test b2.time == 3.0 && !b2.publication_allowed
    @test b2 !== a2 && cache.transient === b2

    normal2 = prepare_test_cache(cache, target, target.environment)
    @test normal2 !== normal1 && normal2 !== b2
    @test prepare_test_cache(cache, target, target.environment) === normal2
    @test cache.default === nothing && cache.transient === normal2
end

# Coverage notes:
# - Engine behavior only, not an independent scientific-model validation.
# - Both public bulk and per-target nested execution are exercised.
# - The same concrete transient type gets new values; A/B/default transitions,
#   forwarded sampled values, storage Float32/64, real step time, ancestor
#   suppression, accepted backend commits and exception recovery are observable.
# - Final retained rows alone do not prove absence of intermediate events;
#   suppressed commit attempts are independently observed by backend.writes.
# - Lifecycle covers addition, spatial movement, scoped reparenting and removal
#   after warming real transient calls; removed-object history stays accessible.
# - Only the last two mechanism tests inspect private cache/context fields;
#   they pin active-lease isolation and Nothing-default bounded reuse. No byte
#   budget or timing claim is made. Parent-owned allocation tests should also
#   measure warmed reuse AFTER the exception (busy-cache cleanup).
end # module TransientRunContextCacheChecks
