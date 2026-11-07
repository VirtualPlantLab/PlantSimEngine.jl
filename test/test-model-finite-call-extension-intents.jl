module FiniteCallExtensionIntentChecks

using PlantSimEngine, Random, Test
const PSE = PlantSimEngine
const MANUAL_NAMES = (:a, :alias_a, :b, :c, :d, :e, :f)
const APP_NAMES = (:leaf_a, :leaf_b, :leaf_c, :leaf_d, :leaf_e, :leaf_f)

PSE.@process "finite_extension_root" verbose=false
PSE.@process "finite_extension_leaf" verbose=false
struct Root{Names} <: AbstractFinite_Extension_RootModel end
struct Leaf{N,R} <: AbstractFinite_Extension_LeafModel
    rng::R
end
PSE.inputs_(::Union{Root,Leaf}) = NamedTuple()
PSE.outputs_(::Root) = (root_visits=0,)
PSE.outputs_(::Leaf) = (visits=0, value=0.0)
function PSE.run!(::Root{Names}, status, environment, constants, context) where {Names}
    status.root_visits += 1
    for name in Names
        run_call!(context, name; publish=false)
    end
    return nothing
end
function PSE.run!(model::Leaf, status, environment, constants, context)
    status.visits += 1
    status.value = rand(model.rng)
    return nothing
end

root_target(simulation) = only(only(only(group for group in simulation.execution_plan.groups
    if group.application.id === :root).batches).targets)

# Every batch witness comes from these real objects and the canonical factories.
# Six distinct models exceed the compiler's small-union splitting heuristic;
# alias_a also supplies two same-type batches with different execution owners.
function fixture(; prepared=true, wide=false)
    rng = Xoshiro(4031)
    objects = Object[Object(1; scale=:Scene, status=Status(root_visits=0))]
    for (index, kind) in enumerate((:a, :b, :c, :d, :e, :f, :seed))
        push!(objects, Object(100index; kind, scale=index == 7 ? :Seed : :Leaf, parent=1,
            status=Status(visits=0, value=0.0)))
    end
    manual = (a=Many(scale=:Leaf, kind=:a, application=:leaf_a),
        alias_a=Many(scale=:Leaf, kind=:a, application=:leaf_a),
        b=Many(scale=:Leaf, kind=:b, application=:leaf_b),
        c=Many(scale=:Leaf, kind=:c, application=:leaf_c),
        d=Many(scale=:Leaf, kind=:d, application=:leaf_d),
        e=Many(scale=:Leaf, kind=:e, application=:leaf_e),
        f=Many(scale=:Leaf, kind=:f, application=:leaf_f))
    names = wide ? (MANUAL_NAMES..., :all) : MANUAL_NAMES
    manual = wide ? (; manual..., all=Many(scale=:Leaf)) : manual
    specs = ntuple(6) do index
        ModelSpec(Leaf{index,typeof(rng)}(rng); name=APP_NAMES[index],
            on=Many(scale=:Leaf, kind=(:a, :b, :c, :d, :e, :f)[index]))
    end
    model = CompositeModel(objects...; applications=(
        ModelSpec(Root{names}(); name=:root, on=One(id=1, scale=:Scene), calls=(; manual...,
            initialize=Initializer(One(scale=:Seed, kind=:seed, application=:seed)))),
        specs...,
        ModelSpec(Leaf{7,typeof(rng)}(rng); name=:seed, on=Many(scale=:Seed, kind=:seed)),
    ))
    simulation = run!(model; steps=0, outputs=:none)
    target = root_target(simulation)
    manual_bindings = filter(binding -> PSE._compiled_call_mode(binding) === :manual,
        target.call_bindings)
    @test Set(id for binding in manual_bindings for id in binding.callee_application_ids) == Set(APP_NAMES)
    @test all(binding -> !(:seed in binding.plan.potential_callee_application_ids), manual_bindings)
    initializer_binding = only(binding for binding in target.call_bindings
        if PSE._compiled_call_mode(binding) === :initializer)
    @test initializer_binding.callee_application_ids == [:seed]
    @test !(:visits in keys(PSE.outputs_(Root{names}())))
    call_schemas = map(names) do name
        calls = call_targets(target.context, name)
        batches = PSE._materialize_call_execution_batches!(calls)
        Batch = Union{map(typeof, batches)...}
        PSE.PreparedExecutionBatchSchema{Vector{Batch}}()
    end
    seed_batch = only(only(group for group in simulation.execution_plan.groups
        if group.application.id === :seed).batches)
    seed_schema = PSE.PreparedExecutionBatchSchema{Vector{typeof(seed_batch)}}()
    schemas = NamedTuple{(names..., :initialize)}((call_schemas..., seed_schema))
    RootB = PSE._execution_batch_type_with_call_schemas(
        typeof(only(only(group for group in simulation.execution_plan.groups
            if group.application.id === :root).batches)), schemas)
    application_schemas = (root=PSE.PreparedExecutionBatchSchema{Vector{RootB}}(),
        leaf_a=schemas.a, leaf_b=schemas.b, leaf_c=schemas.c,
        leaf_d=schemas.d, leaf_e=schemas.e, leaf_f=schemas.f, seed=seed_schema)
    result = prepared ? PSE._prepare_execution_batch_schemas(simulation, application_schemas) : simulation
    return (; model, simulation=result, rng)
end

function add_leaves!(data)
    for (index, kind) in enumerate((:a, :b, :c, :d, :e, :f))
        register_object!(data.model, Object(100index + 1; kind, scale=:Leaf, parent=1,
            status=Status(visits=0, value=0.0)))
    end
    return nothing
end

function refreshed_owners(data)
    compiled = PSE.Advanced.refresh_bindings!(data.model)
    environment = PSE.Advanced.refresh_environment_bindings!(data.model, compiled)
    return (; compiled, environment)
end

function extend!(algorithm, target, owners, simulation)
    function_ = algorithm === :prefix ? PSE._extend_execution_target_call_batches_by_prefix! :
        PSE._extend_execution_target_call_batches_for_pure_addition!
    return function_(target, owners.compiled, owners.environment,
        simulation.temporal_streams, simulation.output_retention, simulation.constants)
end

function call_snapshot(simulation)
    target = root_target(simulation)
    return [(calls=calls, binding=calls.binding, preparation=calls.preparation,
        batches=calls.execution_batches,
        rows=[(rows=batch.targets, indices=copy(batch.targets.indices),
            payloads=collect(batch.targets)) for batch in PSE._cached_call_execution_batches(calls)])
        for calls in target.context.calls if PSE._compiled_call_mode(calls.binding) === :manual]
end

function assert_snapshot(snapshot)
    for old in snapshot
        @test old.calls.binding === old.binding
        @test old.calls.preparation === old.preparation
        @test old.calls.execution_batches === old.batches
        for entry in old.rows
            @test entry.rows.indices == entry.indices
            @test all(a === b for (a, b) in zip(entry.rows, entry.payloads))
        end
    end
end

state(model) = Dict(object.id => deepcopy(NamedTuple(object.status)) for object in model_objects(model))
random_state(rng) = rand(copy(rng), UInt64, 8)

@testset "both canonical extensions keep finite intents, order and real references" begin
    for algorithm in (:prefix, :pure_addition)
        wide = algorithm === :prefix
        ordinary, data = fixture(; prepared=false, wide), fixture(; wide)
        simulation = data.simulation
        target = root_target(simulation)
        scope = PSE._context_call_schema(target.context)
        @test scope isa PSE.PreparedContextCallSchema
        append_buffer = PSE._execution_append_intent_buffer(scope)
        binding_buffer = PSE._execution_binding_intent_buffer(scope)
        @test length(Base.uniontypes(eltype(append_buffer))) == 6
        @test length(Base.uniontypes(eltype(binding_buffer))) == (wide ? 9 : 8)
        if wide
            all_calls = call_targets(target.context, :all)
            @test length(Base.uniontypes(eltype(all_calls.execution_batches))) == 6
            @test length(all_calls.execution_batches) == 6
        end
        @test eltype(append_buffer) !== Tuple{Any,Any}
        @test eltype(binding_buffer) !== Tuple{Any,Any}
        initializer = only(calls for calls in target.context.calls
            if PSE._compiled_call_mode(calls.binding) === :initializer)
        @test PSE._compiled_call_name(initializer.binding) === :initialize
        @test_throws ArgumentError call_targets(target.context, :initialize)
        @test initializer.execution_batches === ()
        @test PSE._stage_execution_binding!(binding_buffer, scope, initializer, initializer.binding)
        @test length(binding_buffer) == 1
        @test isempty(append_buffer)
        original_rows = [only(call_targets(target.context, name).execution_batches).targets
            for name in MANUAL_NAMES]
        original_targets = [only(rows) for rows in original_rows]
        original_cells = [PSE.refvalue(child.status_view.status, :value) for child in original_targets]
        before_random = random_state(data.rng)
        add_leaves!(data)
        add_leaves!(ordinary)
        owners = refreshed_owners(data)
        @test owners.compiled.status_view_refresh_is_pure_addition
        before_state = state(data.model)
        @test extend!(algorithm, target, owners, simulation) === true
        @test state(data.model) == before_state
        @test random_state(data.rng) == before_random
        @test all(isempty, values(outputs(simulation)))
        for (index, name) in enumerate(MANUAL_NAMES)
            calls = call_targets(target.context, name)
            rows = only(calls.execution_batches).targets
            @test rows === original_rows[index]
            @test first(rows) === original_targets[index]
            @test PSE.refvalue(first(rows).status_view.status, :value) === original_cells[index]
            kind_index = name === :alias_a ? 1 : findfirst(==(name), (:a,:b,:c,:d,:e,:f))
            @test getproperty.(collect(rows), :object_id) == [ObjectId(100kind_index), ObjectId(100kind_index + 1)]
            @test last(rows).status_view.canonical_status === model_status(data.model, 100kind_index + 1)
            @test last(rows).context.temporal_streams === simulation.temporal_streams
            @test !last(rows).call_context_cache.in_use
        end
        left = only(call_targets(target.context, :a).execution_batches).targets
        right = only(call_targets(target.context, :alias_a).execution_batches).targets
        @test left.cohort !== right.cohort
        @test last(left) !== last(right)
        @test last(left).context !== last(right).context
        @test PSE.refvalue(last(left).status_view.status, :value) ===
            PSE.refvalue(last(right).status_view.status, :value)
        continue!(simulation; steps=2)
        continue!(ordinary.simulation; steps=2)
        @test state(data.model) == state(ordinary.model)
        @test random_state(data.rng) == random_state(ordinary.rng)
        @test collect_outputs(simulation) == collect_outputs(ordinary.simulation)
    end
end

@testset "a later inadmissible binding rejects before any earlier append" begin
    for algorithm in (:prefix, :pure_addition), mismatch in (:type, :owner)
        data = fixture()
        simulation = data.simulation
        target = root_target(simulation)
        before = call_snapshot(simulation)
        original_bindings = target.call_bindings
        locations = copy(simulation.temporal_streams.cohorts.locations)
        add_leaves!(data)
        owners = refreshed_owners(data)
        key = (:root, ObjectId(1))
        current = owners.compiled.call_bindings_by_target[key]
        # Either a different real call declaration type, or the same exact
        # declaration schema with a foreign execution owner. No Status, model
        # default or kernel is constructed to exercise either negative.
        last_binding = last(current)
        wrong = mismatch === :type ? first(current) : PSE.CompiledModelCallBinding(
            last_binding.plan, ObjectId(999), copy(last_binding.callee_object_ids),
            copy(last_binding.callee_application_ids))
        incompatible = (Base.front(current)..., wrong)
        scope = PSE._context_call_schema(target.context)
        if mismatch === :type
            @test isnothing(PSE._admitted_current_execution_call_bindings(scope, target, incompatible))
        else
            @test typeof(incompatible) === typeof(target.call_bindings)
            @test !PSE._preflight_current_execution_calls(scope, target.context.calls,
                incompatible, owners.compiled, owners.environment)
        end
        before_random = random_state(data.rng)
        before_state = state(data.model)
        owners.compiled.call_bindings_by_target[key] = incompatible
        try
            expected = algorithm === :prefix ? false : nothing
            @test extend!(algorithm, target, owners, simulation) === expected
        finally
            owners.compiled.call_bindings_by_target[key] = current
        end
        @test target.call_bindings === original_bindings
        @test simulation.temporal_streams.cohorts.locations == locations
        assert_snapshot(before)
        @test state(data.model) == before_state
        @test random_state(data.rng) == before_random
    end
end

@testset "multi-application pure addition retains its prefix fallback without writes" begin
    data = fixture(; wide=true)
    simulation = data.simulation
    target = root_target(simulation)
    before = call_snapshot(simulation)
    locations = copy(simulation.temporal_streams.cohorts.locations)
    add_leaves!(data)
    owners = refreshed_owners(data)
    @test extend!(:pure_addition, target, owners, simulation) === nothing
    assert_snapshot(before)
    @test simulation.temporal_streams.cohorts.locations == locations
    @test extend!(:prefix, target, owners, simulation) === true
    all_calls = call_targets(target.context, :all)
    @test length(all_calls.execution_batches) == 6
    @test all(length(batch.targets) == 2 for batch in all_calls.execution_batches)
end

@testset "same-type rows from a different call owner cannot be staged" begin
    data = fixture()
    target = root_target(data.simulation)
    scope = PSE._context_call_schema(target.context)
    left, right = call_targets(target.context, :a), call_targets(target.context, :alias_a)
    rows = only(right.execution_batches).targets
    candidate = only(only(left.execution_batches).targets)
    staged = PSE._execution_append_intent_buffer(scope)
    @test !PSE._stage_execution_append!(staged, scope, left, left.binding, rows, candidate)
    @test isempty(staged)
    @test length(rows) == 1
    # The ordinary path retains its existing tuple representation and does not
    # introduce closed admission into a dynamic scene.
    open = PSE.OpenContextCallSchema()
    raw = PSE._execution_append_intent_buffer(open)
    @test eltype(raw) === Tuple{Any,Any}
    @test PSE._stage_execution_append!(raw, open, left, left.binding, rows, candidate)
    @test only(raw) == (rows, candidate)
end

end # module FiniteCallExtensionIntentChecks
