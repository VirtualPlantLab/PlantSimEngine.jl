module ColdCallSchemaActivationChecks

using PlantSimEngine, Random, Test
const PSE = PlantSimEngine

PSE.@process "cold_schema_activation_root" verbose=false
PSE.@process "cold_schema_activation_middle" verbose=false
PSE.@process "cold_schema_activation_leaf" verbose=false

struct Root <: AbstractCold_Schema_Activation_RootModel
    capture::Base.RefValue{Any}
    kernels::Dict{Symbol,Int}
end
struct Middle <: AbstractCold_Schema_Activation_MiddleModel
    contexts::Dict{Symbol,Any}
    kernels::Dict{Symbol,Int}
end
struct Leaf{R} <: AbstractCold_Schema_Activation_LeafModel
    rng::R
    kernels::Dict{Symbol,Int}
end

PSE.inputs_(::Root) = NamedTuple()
PSE.inputs_(::Middle) = NamedTuple()
PSE.inputs_(::Leaf) = NamedTuple()
PSE.outputs_(::Root) = (visits=0,)
PSE.outputs_(::Middle) = (visits=0, total=0.0)
PSE.outputs_(::Leaf) = (visits=0, value=0.0, payload=zeros(2))

function PSE.run!(model::Root, status, environment, constants, context)
    model.kernels[:root] += 1
    model.capture[] = context
    status.visits += 1
    return nothing
end
function PSE.run!(model::Middle, status, environment, constants, context)
    model.kernels[:middle] += 1
    model.contexts[context.object_id.value] = context
    status.visits += 1
    children = run_call!(context, :leaf; publish=true)
    status.total = sum(child.status.value for child in children; init=0.0)
    return nothing
end
function PSE.run!(model::Leaf, status, environment, constants, context)
    model.kernels[:leaf] += 1
    status.visits += 1
    status.value = rand(model.rng)
    status.payload[1] = status.value
    status.payload[2] = status.visits
    return nothing
end

# All statuses below belong to real scenario objects. No kernel or callback is
# executed to manufacture a status, a future organ, or an execution batch type.
function fixture(; leaves=true)
    capture = Ref{Any}(nothing)
    contexts = Dict{Symbol,Any}()
    kernels = Dict(:root => 0, :middle => 0, :leaf => 0)
    rng = Xoshiro(917)
    objects = Object[
        Object(:root; scale=:Scene, status=Status(visits=0)),
        Object(:middle_a; scale=:Branch, parent=:root,
            status=Status(visits=0, total=0.0)),
        Object(:middle_b; scale=:Branch, parent=:root,
            status=Status(visits=0, total=0.0)),
    ]
    if leaves
        append!(objects, (
            Object(:leaf_a; scale=:Leaf, parent=:middle_a,
                status=Status(visits=0, value=0.0, payload=zeros(2))),
            Object(:leaf_b; scale=:Leaf, parent=:middle_b,
                status=Status(visits=0, value=0.0, payload=zeros(2))),
        ))
    end
    model = CompositeModel(objects...; applications=(
        ModelSpec(Root(capture, kernels); name=:root, on=One(id=:root),
            calls=(middle=Many(scale=:Branch, within=Subtree(), application=:middle),)),
        ModelSpec(Middle(contexts, kernels); name=:middle, on=Many(scale=:Branch),
            calls=(leaf=Many(scale=:Leaf, within=Subtree(), application=:leaf),)),
        ModelSpec(Leaf(rng, kernels); name=:leaf, on=Many(scale=:Leaf)),
    ))
    simulation = run!(model; steps=0, outputs=:all)
    return (; model, simulation, capture, contexts, kernels, rng)
end

root_target(simulation) = only(only(only(simulation.execution_plan.groups).batches).targets)
status_cells(model) = Dict((object.id, name) => PSE.refvalue(object.status, name)
    for object in model_objects(model) for name in keys(object.status))
scientific_state(model) = Dict(object.id => deepcopy(NamedTuple(object.status))
    for object in model_objects(model))
rng_probe(rng) = rand(copy(rng), UInt64, 8)
history(simulation) = Dict(key => [(time, deepcopy(value)) for (time, value) in stream]
    for (key, stream) in outputs(simulation))
raw(simulation, application, object, variable) =
    get(outputs(simulation), (application, ObjectId(object), variable), ())

function assert_same_cells(model, before)
    current = status_cells(model)
    @test Set(keys(current)) == Set(keys(before))
    @test all(current[key] === reference for (key, reference) in before)
end

# Materialize the ordinary cached Many metadata at step zero, without invoking
# the models. A borrowed LeafB, when supplied, comes from another REAL scene.
function observed_schemas(simulation; borrowed_leaf_batch=nothing)
    root = root_target(simulation)
    middle_calls = call_targets(root.context, :middle)
    @test middle_calls.execution_batches isa PSE.LazyCallExecutionBatches
    @test isnothing(middle_calls.execution_batches.batches)
    middle_batch = only(PSE._materialize_call_execution_batches!(middle_calls))
    leaf_calls = call_targets(first(middle_batch.targets).context, :leaf)
    @test leaf_calls.execution_batches isa PSE.LazyCallExecutionBatches
    @test isnothing(leaf_calls.execution_batches.batches)
    leaf_batches = PSE._materialize_call_execution_batches!(leaf_calls)
    LeafB = if isnothing(borrowed_leaf_batch)
        typeof(only(leaf_batches))
    else
        @test isempty(leaf_batches)
        borrowed_leaf_batch
    end
    LeafTarget = eltype(fieldtype(LeafB, :targets))
    LeafContext = fieldtype(LeafTarget, :context)
    @test fieldtype(LeafB, :application) === typeof(simulation.compiled.applications_by_id[:leaf])
    @test fieldtype(LeafContext, :compiled) === typeof(simulation.compiled)
    @test fieldtype(LeafContext, :temporal_streams) === typeof(simulation.temporal_streams)
    @test fieldtype(LeafContext, :output_retention) === typeof(simulation.output_retention)
    @test fieldtype(LeafContext, :constants) === typeof(simulation.constants)
    leaf_schema = PSE.PreparedExecutionBatchSchema{Vector{LeafB}}()
    MiddleB = PSE._execution_batch_type_with_call_schemas(typeof(middle_batch),
        (leaf=leaf_schema,))
    middle_schema = PSE.PreparedExecutionBatchSchema{Vector{MiddleB}}()
    RootB = PSE._execution_batch_type_with_call_schemas(
        typeof(only(only(simulation.execution_plan.groups).batches)),
        (middle=middle_schema,))
    root_schema = PSE.PreparedExecutionBatchSchema{Vector{RootB}}()
    return (; schemas=(root=root_schema, middle=middle_schema, leaf=leaf_schema),
        LeafB, MiddleB, RootB)
end

function assert_prepared_tree(simulation)
    root = root_target(simulation)
    @test root.status_view.canonical_status === model_status(simulation.model, :root)
    middle_calls = call_targets(root.context, :middle)
    @test middle_calls.batch_schema isa PSE.PreparedExecutionBatchSchema
    @test middle_calls.execution_batches isa Vector
    @test middle_calls.tracks_full_membership
    middle_batches = PSE._materialize_call_execution_batches!(middle_calls)
    @test middle_calls.execution_batches_materialized
    @test middle_batches === middle_calls.execution_batches
    for middle_batch in middle_batches, middle in middle_batch.targets
        @test middle_batch.targets.store === simulation.execution_plan.cohorts
        @test middle.status_view.canonical_status === model_status(simulation.model, middle.object_id)
        @test !middle.call_context_cache.in_use
        leaves = call_targets(middle.context, :leaf)
        @test leaves.batch_schema isa PSE.PreparedExecutionBatchSchema
        @test leaves.execution_batches isa Vector
        @test leaves.tracks_full_membership
        leaf_batches = PSE._materialize_call_execution_batches!(leaves)
        @test leaves.execution_batches_materialized
        @test leaf_batches === leaves.execution_batches
        for leaf_batch in leaf_batches, leaf in leaf_batch.targets
            @test leaf_batch.targets.store === simulation.execution_plan.cohorts
            @test leaf.status_view.canonical_status === model_status(simulation.model, leaf.object_id)
            @test PSE.refvalue(leaf.status_view.status, :value) ===
                PSE.refvalue(model_status(simulation.model, leaf.object_id), :value)
            @test !leaf.call_context_cache.in_use
        end
    end
    return nothing
end

@testset "bottom-up call activation changes metadata without science or references" begin
    data = fixture()
    before = scientific_state(data.model)
    cells = status_cells(data.model)
    random_state = rng_probe(data.rng)
    original_root = root_target(data.simulation)
    streams = Dict(key => stream for (key, stream) in outputs(data.simulation))
    learned = observed_schemas(data.simulation)
    @test data.kernels == Dict(:root => 0, :middle => 0, :leaf => 0)
    @test scientific_state(data.model) == before
    @test rng_probe(data.rng) == random_state
    @test data.capture[] === nothing && isempty(data.contexts)
    assert_same_cells(data.model, cells)
    prepared = PSE._prepare_execution_batch_schemas(data.simulation, learned.schemas)
    @test prepared !== data.simulation
    @test prepared.temporal_streams !== data.simulation.temporal_streams
    @test prepared.temporal_streams.streams === data.simulation.temporal_streams.streams
    @test prepared.execution_plan.cohorts !== data.simulation.execution_plan.cohorts
    @test root_target(prepared) !== original_root
    @test prepared.execution_plan.groups isa Tuple
    @test prepared.execution_plan.groups_by_application_slot isa Tuple
    @test current_step(prepared) == 0
    @test isempty(prepared.execution_plan.schedule.due_entry_indices)
    @test data.kernels == Dict(:root => 0, :middle => 0, :leaf => 0)
    @test scientific_state(data.model) == before
    @test rng_probe(data.rng) == random_state
    @test data.capture[] === nothing && isempty(data.contexts)
    @test all(isempty, values(outputs(prepared)))
    @test Set(keys(outputs(prepared))) == Set(keys(streams))
    @test all(outputs(prepared)[key] === stream for (key, stream) in streams)
    assert_same_cells(data.model, cells)
    pending = call_targets(root_target(prepared).context, :middle)
    @test pending.execution_batches isa Vector{learned.MiddleB}
    @test isempty(pending.execution_batches)
    @test !pending.execution_batches_materialized
    @test !PSE._call_execution_batches_materialized(pending)
    @test PSE._cached_call_execution_batches(pending) === nothing
    @test PSE._call_targets_preparation_is_current(pending, pending.compiled,
        pending.environment_bindings, pending.temporal_streams, pending.output_retention, pending.constants)
    # Retrieving or explaining the call does not request the complete view.
    @test call_targets(root_target(prepared).context, :middle) === pending
    PSE.Diagnostics.explain_calls(prepared.compiled)
    @test !PSE._call_execution_batches_materialized(pending)
    # A full Middle request constructs its contexts, not their Leaf memberships.
    middle_batches = PSE._materialize_call_execution_batches!(pending)
    for batch in middle_batches, middle in batch.targets
        leaves = call_targets(middle.context, :leaf)
        @test !PSE._call_execution_batches_materialized(leaves)
        @test PSE._cached_call_execution_batches(leaves) === nothing
        @test call_targets(middle.context, :leaf) === leaves
        PSE.Diagnostics.explain_calls(prepared.compiled)
        @test !PSE._call_execution_batches_materialized(leaves)
    end
    assert_prepared_tree(prepared) # Full inspection is explicit and still metadata-only.
    @test scientific_state(data.model) == before
    @test rng_probe(data.rng) == random_state
    assert_same_cells(data.model, cells)
    @test typeof(root_target(prepared)) === eltype(fieldtype(learned.RootB, :targets))
end

@testset "prepared Many selection and cloned shells leave complete membership cold" begin
    witness = fixture()
    learned = observed_schemas(witness.simulation)
    ordinary, activated = fixture(), fixture() # No membership/cache/RNG owner is borrowed.
    prepared = PSE._prepare_execution_batch_schemas(activated.simulation, learned.schemas)
    prototype = call_targets(root_target(prepared).context, :middle)
    @test !PSE._call_execution_batches_materialized(prototype)
    @test !PSE._compiled_call_membership_is_observed(prototype.binding)
    owner = root_target(prepared).context
    cloned_calls = @inferred PSE._clone_runtime_call_targets(owner.calls,
        owner.compiled, owner.environment_bindings, owner.temporal_streams,
        owner.output_retention, owner.time, owner.constants, owner.publication_allowed, owner.environment)
    cloned = only(cloned_calls)
    @test typeof(cloned_calls) === typeof(owner.calls)
    @test cloned !== prototype && cloned.binding === prototype.binding
    @test cloned.execution_batches !== prototype.execution_batches
    @test !cloned.execution_batches_materialized
    @test PSE._cached_call_execution_batches(cloned) === nothing
    @test isnothing(cloned.evaluation) && isnothing(cloned.target_buffer_cache)

    for (data, simulation) in ((ordinary, ordinary.simulation), (activated, prepared))
        step!(simulation)
        full = call_targets(data.capture[], :middle)
        selected = only(call_targets(data.capture[], :middle; objects=(:middle_a,)))
        @test !PSE._call_execution_batches_materialized(full)
        @test !PSE._compiled_call_membership_is_observed(full.binding)
        run_call!(selected; publish=false)
        @test data.kernels == Dict(:root => 1, :middle => 1, :leaf => 1)
        @test model_status(data.model, :middle_b).visits == 0
        @test model_status(data.model, :leaf_b).visits == 0
        @test !selected.context_cache.in_use
        @test call_targets(data.capture[], :middle) === full
        @test !PSE._call_execution_batches_materialized(full)
        @test !PSE._compiled_call_membership_is_observed(full.binding)
        state, random_state = scientific_state(data.model), rng_probe(data.rng)
        @test getproperty.(collect(full), :object_id) == ObjectId[ObjectId(:middle_a), ObjectId(:middle_b)]
        @test PSE._call_execution_batches_materialized(full)
        @test PSE._compiled_call_membership_is_observed(full.binding)
        @test scientific_state(data.model) == state
        @test rng_probe(data.rng) == random_state
    end
    @test scientific_state(ordinary.model) == scientific_state(activated.model)
    @test rng_probe(ordinary.rng) == rng_probe(activated.rng)
    @test history(ordinary.simulation) == history(prepared)

    warm = call_targets(activated.capture[], :middle)
    warm_owner = activated.capture[]
    warm_clone = only(@inferred PSE._clone_runtime_call_targets(warm_owner.calls,
        warm_owner.compiled, warm_owner.environment_bindings, warm_owner.temporal_streams,
        warm_owner.output_retention, warm_owner.time, warm_owner.constants,
        warm_owner.publication_allowed, warm_owner.environment))
    @test warm_clone.execution_batches_materialized
    @test warm_clone.execution_batches !== warm.execution_batches
    @test length(PSE._cached_call_execution_batches(warm_clone)) == length(warm.execution_batches)
    @test isnothing(warm_clone.evaluation) && isnothing(warm_clone.target_buffer_cache)
end

@testset "prepared Many stays cold through growth removal and newborn selection" begin
    witness = fixture()
    learned = observed_schemas(witness.simulation)
    ordinary, activated = fixture(), fixture()
    prepared = PSE._prepare_execution_batch_schemas(activated.simulation, learned.schemas)
    for (data, simulation) in ((ordinary, ordinary.simulation), (activated, prepared))
        step!(simulation)
        retained = call_targets(data.capture[], :middle)
        @test !PSE._call_execution_batches_materialized(retained)
        @test !PSE._compiled_call_membership_is_observed(retained.binding)
        register_object!(data.model, Object(:middle_new; scale=:Branch, parent=:root,
            status=Status(visits=0, total=0.0)))
        register_object!(data.model, Object(:leaf_new; scale=:Leaf, parent=:middle_new,
            status=Status(visits=0, value=0.0, payload=zeros(2))))
        remove_object!(data.model, :leaf_b)
        remove_object!(data.model, :middle_b)
        continue!(simulation; steps=1)
        full = call_targets(data.capture[], :middle)
        @test full === retained
        @test !PSE._call_execution_batches_materialized(full)
        @test !PSE._compiled_call_membership_is_observed(full.binding)
        newborn = only(call_targets(data.capture[], :middle; objects=(:middle_new,)))
        @test newborn.object_id == ObjectId(:middle_new)
        @test newborn.status === model_status(data.model, :middle_new)
        run_call!(newborn; publish=true)
        @test data.kernels == Dict(:root => 2, :middle => 1, :leaf => 1)
        @test model_status(data.model, :middle_a).visits == 0
        @test model_status(data.model, :leaf_a).visits == 0
        @test !newborn.context_cache.in_use
        @test !PSE._call_execution_batches_materialized(full)
        @test !PSE._compiled_call_membership_is_observed(full.binding)
        state, random_state, streams = scientific_state(data.model), rng_probe(data.rng), history(simulation)
        @test getproperty.(collect(full), :object_id) == ObjectId[ObjectId(:middle_a), ObjectId(:middle_new)]
        @test PSE._call_execution_batches_materialized(full)
        @test PSE._compiled_call_membership_is_observed(full.binding)
        @test scientific_state(data.model) == state
        @test rng_probe(data.rng) == random_state
        @test history(simulation) == streams
    end
    @test scientific_state(ordinary.model) == scientific_state(activated.model)
    @test rng_probe(ordinary.rng) == rng_probe(activated.rng)
    @test history(ordinary.simulation) == history(prepared)
end

@testset "pending prepared Many does not admit an unselected Status variant" begin
    witness = fixture()
    learned = observed_schemas(witness.simulation)
    data = fixture()
    # A real registered object, never a fabricated Type witness. The existing
    # Middle kernel is unchanged; its extra canonical field is outside learned.
    register_object!(data.model, Object(:middle_z_extra; scale=:Branch, parent=:root,
        status=Status(visits=0, total=0.0, unselected_marker=0)))
    fresh = run!(data.model; steps=0, outputs=:all)
    # Check owner compatibility before activation: only the real Status variant
    # is outside the learned target schema, not another owner/ABI fixture.
    ExpectedTarget = eltype(fieldtype(learned.MiddleB, :targets))
    ExpectedContext = fieldtype(ExpectedTarget, :context)
    fresh_owner = root_target(fresh).context
    @test fresh.compiled.applications_by_id[:middle] isa fieldtype(ExpectedContext, :application)
    for name in (:compiled, :environment_bindings, :temporal_streams,
        :output_retention, :constants, :environment)
        @test getfield(fresh_owner, name) isa fieldtype(ExpectedContext, name)
    end
    prepared = PSE._prepare_execution_batch_schemas(fresh, learned.schemas)
    step!(prepared)
    full = call_targets(data.capture[], :middle)
    PSE.Diagnostics.explain_calls(prepared.compiled)
    @test !PSE._call_execution_batches_materialized(full)
    selected = only(call_targets(data.capture[], :middle; objects=(:middle_a,)))
    run_call!(selected; publish=false)
    @test data.kernels == Dict(:root => 1, :middle => 1, :leaf => 1)
    @test model_status(data.model, :middle_z_extra).visits == 0
    @test !PSE._call_execution_batches_materialized(full)
    @test PSE._cached_call_execution_batches(full) === nothing
    state, random_state, cells = scientific_state(data.model), rng_probe(data.rng), status_cells(data.model)
    @test_throws ArgumentError PSE._materialize_call_execution_batches!(full)
    @test !full.execution_batches_materialized
    @test PSE._cached_call_execution_batches(full) === nothing
    @test isempty(full.execution_batches) # No partial vector is published on rejection.
    @test scientific_state(data.model) == state
    @test rng_probe(data.rng) == random_state
    assert_same_cells(data.model, cells)
end

@testset "a nonempty Tuple batch schema keeps prepared Many pending" begin
    witness = fixture()
    learned = observed_schemas(witness.simulation)
    leaf_schema = PSE.PreparedExecutionBatchSchema{Tuple{learned.LeafB}}()
    MiddleB = PSE._execution_batch_type_with_call_schemas(learned.MiddleB, (leaf=leaf_schema,))
    middle_schema = PSE.PreparedExecutionBatchSchema{Tuple{MiddleB}}()
    RootB = PSE._execution_batch_type_with_call_schemas(learned.RootB, (middle=middle_schema,))
    schemas = (root=PSE.PreparedExecutionBatchSchema{Vector{RootB}}(),
        middle=middle_schema, leaf=leaf_schema)
    ordinary, activated = fixture(), fixture()
    prepared = PSE._prepare_execution_batch_schemas(activated.simulation, schemas)
    owner = root_target(prepared).context
    pending = call_targets(owner, :middle)
    @test pending.batch_schema === middle_schema
    @test !pending.execution_batches_materialized
    @test PSE._cached_call_execution_batches(pending) === nothing
    cloned = only(@inferred PSE._clone_runtime_call_targets(owner.calls,
        owner.compiled, owner.environment_bindings, owner.temporal_streams,
        owner.output_retention, owner.time, owner.constants, owner.publication_allowed, owner.environment))
    @test typeof(cloned) === typeof(pending)
    @test !cloned.execution_batches_materialized
    @test PSE._cached_call_execution_batches(cloned) === nothing
    for (data, simulation) in ((ordinary, ordinary.simulation), (activated, prepared))
        step!(simulation)
        run_call!(data.capture[], :middle; publish=true)
        @test data.kernels == Dict(:root => 1, :middle => 2, :leaf => 2)
    end
    warm_owner = activated.capture[]
    warm = call_targets(warm_owner, :middle)
    @test warm.execution_batches_materialized
    @test warm.execution_batches isa Tuple{MiddleB}
    warm_clone = only(@inferred PSE._clone_runtime_call_targets(warm_owner.calls,
        warm_owner.compiled, warm_owner.environment_bindings, warm_owner.temporal_streams,
        warm_owner.output_retention, warm_owner.time, warm_owner.constants,
        warm_owner.publication_allowed, warm_owner.environment))
    @test warm_clone.execution_batches_materialized
    @test PSE._cached_call_execution_batches(warm_clone) === warm.execution_batches
    @test scientific_state(ordinary.model) == scientific_state(activated.model)
    @test rng_probe(ordinary.rng) == rng_probe(activated.rng)
    @test history(ordinary.simulation) == history(prepared)
end

@testset "cold real Many calls retain public evaluation, history and lease behavior" begin
    ordinary, activated = fixture(), fixture()
    learned = observed_schemas(activated.simulation)
    prepared = PSE._prepare_execution_batch_schemas(activated.simulation, learned.schemas)
    simulations = (ordinary.simulation, prepared)
    fixtures = (ordinary, activated)
    cells = map(data -> status_cells(data.model), fixtures)

    # The root scheduler runs normally. Call-only applications remain cold.
    for (data, simulation) in zip(fixtures, simulations)
        step!(simulation)
        @test data.kernels == Dict(:root => 1, :middle => 0, :leaf => 0)
        @test data.capture[] isa PSE.RunContext
        run_call!(data.capture[], :middle; publish=false)
        @test data.kernels == Dict(:root => 1, :middle => 2, :leaf => 2)
        @test all(isempty(raw(simulation, :leaf, id, :value)) for id in (:leaf_a, :leaf_b))
        @test all(isempty(raw(simulation, :middle, id, :total)) for id in (:middle_a, :middle_b))
    end
    @test scientific_state(ordinary.model) == scientific_state(activated.model)
    @test rng_probe(ordinary.rng) == rng_probe(activated.rng)
    @test history(ordinary.simulation) == history(prepared)

    for (data, simulation) in zip(fixtures, simulations)
        evaluation = evaluate_call!(data.capture[], :middle)
        @test Set(target.object_id for target in call_targets(evaluation)) ==
            Set((ObjectId(:middle_a), ObjectId(:middle_b)))
        @test all(isempty(raw(simulation, :leaf, id, :value)) for id in (:leaf_a, :leaf_b))
        counts = copy(data.kernels)
        state = scientific_state(data.model)
        random_state = rng_probe(data.rng)
        @test accept_call!(evaluation) === evaluation
        @test data.kernels == counts
        @test scientific_state(data.model) == state
        @test rng_probe(data.rng) == random_state
        @test_throws ArgumentError accept_call!(evaluation)
        for id in (:leaf_a, :leaf_b)
            leaf = model_status(data.model, id)
            @test leaf.visits == 2
            @test raw(simulation, :leaf, id, :value) == [(1.0, leaf.value)]
            payload = deepcopy(only(raw(simulation, :leaf, id, :payload))[2])
            leaf.payload .= -999.0
            @test only(raw(simulation, :leaf, id, :payload))[2] == payload
        end
    end
    @test scientific_state(ordinary.model) == scientific_state(activated.model)
    @test rng_probe(ordinary.rng) == rng_probe(activated.rng)
    @test history(ordinary.simulation) == history(prepared)

    # A descendant reexecution invalidates a pending parent evaluation. Its
    # already accepted histories survive, and every acquired lease is released.
    for (data, simulation) in zip(fixtures, simulations)
        step!(simulation)
        previous_history = history(simulation)
        pending = evaluate_call!(data.capture[], :middle)
        held_leaf = only(call_targets(data.contexts[:middle_a], :leaf))
        run_call!(held_leaf; publish=false)
        @test_throws ArgumentError accept_call!(pending)
        @test history(simulation) == previous_history
        selected = only(call_targets(data.capture[], :middle; objects=(:middle_a,)))
        latest = evaluate_call!(selected)
        counts = copy(data.kernels)
        random_state = rng_probe(data.rng)
        accept_call!(latest)
        @test data.kernels == counts
        @test rng_probe(data.rng) == random_state
        @test !selected.context_cache.in_use
        @test !held_leaf.context_cache.in_use
        @test first.(raw(simulation, :leaf, :leaf_a, :value)) == [1.0, 2.0]
        @test first.(raw(simulation, :leaf, :leaf_b, :value)) == [1.0]
    end
    for (data, before_cells) in zip(fixtures, cells)
        assert_same_cells(data.model, before_cells)
    end
    assert_prepared_tree(prepared)
    @test scientific_state(ordinary.model) == scientific_state(activated.model)
    @test rng_probe(ordinary.rng) == rng_probe(activated.rng)
    @test history(ordinary.simulation) == history(prepared)
end

@testset "initially empty Many admits an observed real future leaf batch" begin
    witness = fixture()
    witness_before = scientific_state(witness.model)
    witness_random = rng_probe(witness.rng)
    real_leaf_batch = observed_schemas(witness.simulation).LeafB
    @test witness.kernels == Dict(:root => 0, :middle => 0, :leaf => 0)
    @test scientific_state(witness.model) == witness_before
    @test rng_probe(witness.rng) == witness_random

    empty = fixture(; leaves=false)
    before = scientific_state(empty.model)
    cells = status_cells(empty.model)
    random_state = rng_probe(empty.rng)
    learned = observed_schemas(empty.simulation; borrowed_leaf_batch=real_leaf_batch)
    prepared = PSE._prepare_execution_batch_schemas(empty.simulation, learned.schemas)
    @test scientific_state(empty.model) == before
    @test rng_probe(empty.rng) == random_state
    @test empty.kernels == Dict(:root => 0, :middle => 0, :leaf => 0)
    @test isempty(object_ids(empty.model; scale=:Leaf))
    assert_same_cells(empty.model, cells)
    middle_calls = call_targets(root_target(prepared).context, :middle)
    @test !PSE._call_execution_batches_materialized(middle_calls)
    for batch in PSE._materialize_call_execution_batches!(middle_calls), target in batch.targets
        leaves = call_targets(target.context, :leaf)
        @test isempty(leaves.execution_batches)
        @test eltype(leaves.execution_batches) === real_leaf_batch
        @test !leaves.execution_batches_materialized
        @test PSE._cached_call_execution_batches(leaves) === nothing
        @test isempty(PSE._materialize_call_execution_batches!(leaves))
        @test leaves.execution_batches_materialized
        @test PSE._call_execution_batches_materialized(leaves)
        @test isempty(PSE._cached_call_execution_batches(leaves))
    end
    assert_prepared_tree(prepared)
    step!(prepared)
    evaluation = evaluate_call!(empty.capture[], :middle)
    @test empty.kernels == Dict(:root => 1, :middle => 2, :leaf => 0)
    @test rng_probe(empty.rng) == random_state
    counts = copy(empty.kernels)
    accept_call!(evaluation)
    @test empty.kernels == counts
    @test all(model_status(empty.model, id).total == 0.0 for id in (:middle_a, :middle_b))
    @test isempty(object_ids(empty.model; scale=:Leaf))
    assert_same_cells(empty.model, cells)
    assert_prepared_tree(prepared)
end

@testset "an empty call layout is finite and declaration changes start a new timeline" begin
    data = fixture()
    model = data.model
    original = model.applications[1]
    model.applications[1] = ModelSpec(PSE.model_(original);
        name=:root, on=One(id=:root))
    Advanced.refresh_bindings!(model; force=true)
    previous = run!(model; steps=1, outputs=:all)
    target = only(target for group in previous.execution_plan.groups
        for batch in group.batches for target in batch.targets
        if batch.application.id === :root)
    @test target.context.calls === ()
    schema = PSE._context_call_schema(target.context)
    @test schema isa PSE.PreparedContextCallSchema{Tuple{}}
    @test eltype(PSE._execution_append_intent_buffer(schema)) === Union{}
    @test eltype(PSE._execution_binding_intent_buffer(schema)) === Union{}
    @test PSE._context_call_schema(nothing) isa PSE.OpenContextCallSchema
    cells, state, random_state = status_cells(model), scientific_state(model), rng_probe(data.rng)
    previous_history = history(previous)

    model.applications[1] = original
    current = Advanced.refresh_bindings!(model; force=true)
    bindings = current.call_bindings_by_target[(:root, ObjectId(:root))]
    @test length(bindings) == 1
    @test isnothing(PSE._admitted_current_execution_call_bindings(schema, target, bindings))
    # Changing declaration layouts uses a fresh timeline, as documented.
    fresh = run!(model; steps=0, outputs=:all)
    @test fresh.compiled === current
    @test current_step(fresh) == 0
    @test scientific_state(model) == state
    @test rng_probe(data.rng) == random_state
    @test history(previous) == previous_history
    assert_same_cells(model, cells)
    step!(fresh)
    run_call!(data.capture[], :middle; publish=true)
    @test length(call_targets(data.capture[], :middle)) == 2
    @test all(model_status(model, id).visits == 2
        for id in (:middle_a, :middle_b, :leaf_a, :leaf_b))
    assert_same_cells(model, cells)
end

end # module ColdCallSchemaActivationChecks
