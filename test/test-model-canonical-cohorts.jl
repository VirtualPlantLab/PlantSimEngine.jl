module CanonicalCohortChecks

using PlantSimEngine, Random, Test
using PlantSimEngine.Diagnostics
const PSE = PlantSimEngine

PSE.@process "canonical_cohort_accumulator" verbose=false
PSE.@process "canonical_cohort_random" verbose=false
PSE.@process "canonical_cohort_caller" verbose=false

struct Accumulator{T} <: AbstractCanonical_Cohort_AccumulatorModel
    increment::T
end
struct ScaledAccumulator{T} <: AbstractCanonical_Cohort_AccumulatorModel
    increment::T
end
PSE.outputs_(model::Union{Accumulator,ScaledAccumulator}) = (value=zero(model.increment), visits=0)
function PSE.run!(model::Accumulator, status, environment, constants, ::RunContext)
    status.value += model.increment
    status.visits += 1
    return nothing
end
function PSE.run!(model::ScaledAccumulator, status, environment, constants, ::RunContext)
    status.value += 2 * model.increment
    status.visits += 1
    return nothing
end

struct RandomProbe{R,V} <: AbstractCanonical_Cohort_RandomModel
    rng::R
    trace::V
end
PSE.outputs_(::RandomProbe) = (draw=0.0, visits=0)
function PSE.run!(model::RandomProbe, status, environment, constants, context::RunContext)
    push!(model.trace, object_id(context))
    status.draw = rand(model.rng)
    status.visits += 1
    return nothing
end

struct Caller{C} <: AbstractCanonical_Cohort_CallerModel
    context::C
end
PSE.outputs_(::Caller) = (total=0,)
function PSE.run!(model::Caller, status, environment, constants, context::RunContext)
    model.context[] = context
    status.total = 0
    for target in run_call!(context, :work; publish=true)
        status.total += target.status.visits
    end
    return nothing
end

function aliased_status(value)
    reference = Ref(value)
    return Status((value=reference, alias=reference, visits=Ref(0)))
end

function execution_target(simulation, application_id, object_id)
    id = ObjectId(object_id)
    return only(target for batch in simulation.execution_plan.batches
        if batch.application.id == application_id
        for target in batch.targets if target.object_id == id)
end

function assert_canonical_storage(simulation)
    batches = simulation.execution_plan.batches
    @test !isempty(batches)
    store = simulation.execution_plan.cohorts
    @test store isa PSE.ExecutionCohortStore
    report = explain_execution_plan(simulation)
    @test length(report) == length(batches)
    for (row, batch) in zip(report, batches)
        @test row.target_storage === :cohort
        @test row.cohort_schema === eltype(batch.targets)
    end
    for batch in batches
        view = batch.targets
        @test view isa PSE.ExecutionCohortRows
        @test view.store === store
        @test view.cohort.application_id == batch.application.id
        @test isconcretetype(eltype(view))
        @test length(view.indices) == length(view)
        for (index, target) in enumerate(view)
            @test view.cohort.rows[view.indices[index]] === target
            location = PSE.cohort_location(store, batch.application.id, target.object_id)
            @test location.cohort === view.cohort
            @test location.row == view.indices[index]
            @test target.status_view === simulation.compiled.status_views_by_target[
                (batch.application.id, target.object_id)]
            @test target.status_view.canonical_status === model_status(simulation.model, target.object_id)
        end
    end
    return store
end

@testset "ordinary run owns typed cohorts for same-scale effective model schemas" begin
    default_status = aliased_status(10.0f0)
    override_status = aliased_status(20.0)
    default_reference = PSE.refvalue(default_status, :value)
    override_reference = PSE.refvalue(override_status, :value)
    template = CompositeModelTemplate((
        ModelSpec(Accumulator(2.0f0); name=:accumulate, on=Many(scale=:Leaf)),
    ))
    instance = ObjectInstance(:plant, template;
        root=Object(:plant; scale=:Plant),
        objects=(
            Object(:leaf_default; scale=:Leaf, parent=:plant, status=default_status),
            Object(:leaf_override; scale=:Leaf, parent=:plant, status=override_status),
        ),
        object_overrides=(Override(object=:leaf_override, application=:accumulate,
            model=ScaledAccumulator(3.0)),),
    )
    model = CompositeModel(instance)
    simulation = run!(model; steps=0, outputs=:all)
    store = assert_canonical_storage(simulation)
    default_target = execution_target(simulation, :plant__accumulate, :leaf_default)
    override_target = execution_target(simulation, :plant__accumulate, :leaf_override)
    @test default_target.model isa Accumulator{Float32}
    @test override_target.model isa ScaledAccumulator{Float64}
    @test PSE.cohort_location(store, :plant__accumulate, ObjectId(:leaf_default)).cohort !==
          PSE.cohort_location(store, :plant__accumulate, ObjectId(:leaf_override)).cohort
    @test default_target.status_view.canonical_status === default_status
    @test override_target.status_view.canonical_status === override_status

    continue!(simulation; steps=2)
    @test assert_canonical_storage(simulation) === store
    @test default_status.value === 14.0f0
    @test override_status.value === 32.0
    @test default_status.visits == override_status.visits == 2
    @test PSE.refvalue(default_status, :value) === default_reference === PSE.refvalue(default_status, :alias)
    @test PSE.refvalue(override_status, :value) === override_reference === PSE.refvalue(override_status, :alias)
    @test last.(outputs(simulation)[(:plant__accumulate, ObjectId(:leaf_default), :value)]) == Float32[12, 14]
    @test last.(outputs(simulation)[(:plant__accumulate, ObjectId(:leaf_override), :value)]) == [26.0, 32.0]

    # A new timeline on the same authored model owns new execution shells while
    # the public model continues to own its mutable scientific status.
    restarted = run!(model; steps=0, outputs=:none)
    restarted_store = assert_canonical_storage(restarted)
    restarted_target = execution_target(restarted, :plant__accumulate, :leaf_default)
    @test restarted_store !== store
    @test restarted_target !== default_target
    @test restarted_target.context !== default_target.context
    @test restarted_target.status_view.canonical_status === default_status
    @test current_step(restarted) == 0
    step!(restarted)
    @test default_status.value === 16.0f0
    @test override_status.value === 38.0
    @test default_target.context.time == 2.0
    @test restarted_target.context.time == 1.0
    @test current_step(simulation) == 2
end

@testset "cohort families preserve object order and the authored shared RNG" begin
    rng = Xoshiro(392)
    reference_rng = Xoshiro(392)
    trace = ObjectId{Int}[]
    status(marker) = Status(draw=0.0, visits=0, marker=marker)
    model = CompositeModel(
        Object(3; scale=:Leaf, status=status(1)),
        Object(1; scale=:Leaf, status=status(1)),
        Object(2; scale=:Leaf, status=status(1.0));
        applications=(ModelSpec(RandomProbe(rng, trace); name=:draw, on=Many(scale=:Leaf)),),
    )
    simulation = run!(model; steps=1, outputs=:all)
    store = assert_canonical_storage(simulation)
    expected = [rand(reference_rng) for _ in 1:3]
    @test trace == ObjectId.([1, 2, 3])
    @test [model_status(model, id).draw for id in 1:3] == expected
    @test all(model_status(model, id).visits == 1 for id in 1:3)
    @test length(simulation.execution_plan.batches) == 3
    @test first(simulation.execution_plan.batches).targets.cohort ===
          last(simulation.execution_plan.batches).targets.cohort
    @test rand(copy(rng), UInt64) == rand(copy(reference_rng), UInt64)
    original_targets = Dict(id => execution_target(simulation, :draw, id) for id in 1:3)
    original_locations = Dict(id => PSE.cohort_location(store, :draw, ObjectId(id)) for id in 1:3)

    # A lower-ID newborn is appended to storage but executes first by identity.
    register_object!(model, Object(0; scale=:Leaf, status=status(1.0)))
    continue!(simulation)
    @test assert_canonical_storage(simulation) === store
    expected = [rand(reference_rng) for _ in 0:3]
    @test trace == ObjectId.([1, 2, 3, 0, 1, 2, 3])
    @test [model_status(model, id).draw for id in 0:3] == expected
    @test model_status(model, 0).visits == 1
    @test all(model_status(model, id).visits == 2 for id in 1:3)
    @test rand(copy(rng), UInt64) == rand(copy(reference_rng), UInt64)
    for id in 1:3
        @test execution_target(simulation, :draw, id) === original_targets[id]
        location = PSE.cohort_location(store, :draw, ObjectId(id))
        @test location.cohort === original_locations[id].cohort
        @test location.row == original_locations[id].row
    end
end

function scoped_fixture()
    return CompositeModel(
        Object(:scene; scale=:Scene, status=aliased_status(0)),
        Object(:plant_a; scale=:Plant, parent=:scene),
        Object(:plant_b; scale=:Plant, parent=:scene),
        Object(:a; scale=:Leaf, parent=:plant_a, status=aliased_status(0)),
        Object(:b; scale=:Leaf, parent=:plant_a, status=aliased_status(0)),
        Object(:c; scale=:Leaf, parent=:plant_b, status=aliased_status(0));
        applications=(
            ModelSpec(Accumulator(1); name=:leaves, on=Many(scale=:Leaf, within=Scope(ObjectId(:plant_a)))),
            ModelSpec(Accumulator(1); name=:scene, on=One(id=:scene)),
        ),
    )
end

@testset "ordinary structural refresh preserves survivor slots and canonical aliases" begin
    model = scoped_fixture()
    a_status = model_status(model, :a)
    removed_status = model_status(model, :b)
    a_reference = PSE.refvalue(a_status, :value)
    simulation = run!(model; steps=1, outputs=:all)
    store = assert_canonical_storage(simulation)
    scene_target = execution_target(simulation, :scene, :scene)
    removed_target = execution_target(simulation, :leaves, :b)
    @test a_status.value == removed_status.value == 1

    newborn_status = aliased_status(0)
    newborn_reference = PSE.refvalue(newborn_status, :value)
    register_object!(model, Object(:d; scale=:Leaf, parent=:plant_a, status=newborn_status))
    continue!(simulation)
    newborn_target = execution_target(simulation, :leaves, :d)
    newborn_location = PSE.cohort_location(store, :leaves, ObjectId(:d))
    @test assert_canonical_storage(simulation) === store
    @test a_status.value == removed_status.value == 2
    @test newborn_status.value == 1

    remove_object!(model, :b)
    reparent_object!(model, :a, :plant_b)
    continue!(simulation)
    @test assert_canonical_storage(simulation) === store
    @test [target.object_id for batch in simulation.execution_plan.batches
        if batch.application.id == :leaves for target in batch.targets] == [ObjectId(:d)]
    @test execution_target(simulation, :leaves, :d) === newborn_target
    @test execution_target(simulation, :scene, :scene) === scene_target
    @test PSE.cohort_location(store, :leaves, ObjectId(:d)).cohort === newborn_location.cohort
    @test PSE.cohort_location(store, :leaves, ObjectId(:d)).row == newborn_location.row
    @test a_status.value == removed_status.value == newborn_status.value == 2
    @test model_status(model, :c).value == 0
    @test PSE.refvalue(a_status, :value) === a_reference === PSE.refvalue(a_status, :alias)
    @test PSE.refvalue(newborn_status, :value) === newborn_reference === PSE.refvalue(newborn_status, :alias)

    replacement_status = aliased_status(0)
    reparent_object!(model, :a, :plant_a)
    register_object!(model, Object(:b; scale=:Leaf, parent=:plant_a, status=replacement_status))
    continue!(simulation)
    @test assert_canonical_storage(simulation) === store
    @test a_status.value == newborn_status.value == 3
    @test replacement_status.value == 1
    @test removed_status.value == 2
    @test model_status(model, :scene).value == 4
    @test execution_target(simulation, :leaves, :b) !== removed_target
    @test PSE.refvalue(replacement_status, :value) !== PSE.refvalue(removed_status, :value)
    @test first.(outputs(simulation)[(:leaves, ObjectId(:a), :value)]) == [1.0, 2.0, 4.0]
    @test last.(outputs(simulation)[(:leaves, ObjectId(:b), :value)]) == [1, 2, 1]
end

function assert_manual_location(store, application, target, owner)
    location = PSE.cohort_location(store, application, object_id(target); owner)
    @test location.cohort.rows[location.row] === target.execution_target
    return nothing
end

@testset "retained hard-call identities use the same canonical store" begin
    captured = Ref{Any}()
    model = CompositeModel(
        Object(:plant_a; scale=:Plant),
        Object(:plant_b; scale=:Plant),
        Object(:b; scale=:Leaf, parent=:plant_a, status=aliased_status(0));
        applications=(
            ModelSpec(Caller(captured); name=:caller, on=One(id=:plant_a),
                calls=(work=Many(scale=:Leaf, within=Subtree(), application=:work),)),
            ModelSpec(Accumulator(1); name=:work, on=Many(scale=:Leaf)),
        ),
    )
    simulation = run!(model; steps=1, outputs=:all)
    store = assert_canonical_storage(simulation)
    retained = only(call_targets(captured[], :work))
    call_owner = PSE._execution_call_owner(only(captured[].calls).binding)
    retained_execution_target = retained.execution_target
    retained_status = retained.status
    @test object_id(retained) == ObjectId(:b)
    @test model_status(model, :plant_a).total == 1
    assert_manual_location(store, :work, retained, call_owner)

    register_object!(model, Object(:a; scale=:Leaf, parent=:plant_a, status=aliased_status(0)))
    continue!(simulation)
    current = collect(call_targets(captured[], :work))
    @test object_id.(current) == ObjectId.([:a, :b])
    @test model_status(model, :plant_a).total == 3
    @test retained.status === retained_status === model_status(model, :b)
    @test retained.execution_target === retained_execution_target
    @test retained_status.value == retained_status.visits == 2
    @test retained.time == 1.0
    for target in current
        assert_manual_location(store, :work, target, call_owner)
    end

    remove_object!(model, :a)
    continue!(simulation)
    @test model_status(model, :plant_a).total == 3
    @test retained_status.value == retained_status.visits == 3
    @test only(call_targets(captured[], :work)).execution_target === retained_execution_target
    reparent_object!(model, :b, :plant_b)
    continue!(simulation)
    @test assert_canonical_storage(simulation) === store
    @test isempty(call_targets(captured[], :work))
    @test model_status(model, :plant_a).total == 0
    @test retained.status === model_status(model, :b)
    @test retained_status.value == retained_status.visits == 3
    @test retained.time == 1.0
end

@testset "diagnostics leave live cohort membership and pending changes untouched" begin
    model = scoped_fixture()
    simulation = run!(model; steps=1, outputs=:all, performance=true)
    store = assert_canonical_storage(simulation)
    views = [batch.targets for batch in simulation.execution_plan.batches]
    memberships = [copy(view.indices) for view in views]
    row_counts = [length(view.cohort.rows) for view in views]
    source_target = execution_target(simulation, :leaves, :a)
    source_reference = PSE.refvalue(model_status(model, :a), :value)
    retained = outputs(simulation)[(:leaves, ObjectId(:a), :value)]
    retained_samples = copy(retained)
    counts = copy(Advanced.runtime_performance(simulation).counts)
    register_object!(model, Object(:d; scale=:Leaf, parent=:plant_a, status=aliased_status(10)))

    rows = explain_execution_plan(model)
    @test any(row -> row.application_id == :leaves && :d in row.object_ids, rows)
    for explain in (explain_bindings, explain_schedule, explain_writers,
        explain_output_bindings, explain_output_retention, explain_initialization)
        @test explain(model) isa AbstractVector
    end
    @test assert_canonical_storage(simulation) === store
    @test Advanced.bindings_dirty(model)
    @test Advanced.environment_bindings_dirty(model)
    @test [copy(view.indices) for view in views] == memberships
    @test [length(view.cohort.rows) for view in views] == row_counts
    @test execution_target(simulation, :leaves, :a) === source_target
    @test PSE.refvalue(model_status(model, :a), :value) === source_reference
    @test model_status(model, :a).value == 1
    @test model_status(model, :d).value == 10
    @test outputs(simulation)[(:leaves, ObjectId(:a), :value)] === retained
    @test retained == retained_samples
    @test Advanced.runtime_performance(simulation).counts == counts

    continue!(simulation)
    @test assert_canonical_storage(simulation) === store
    @test model_status(model, :a).value == 2
    @test model_status(model, :d).value == 11
end

end # module CanonicalCohortChecks
