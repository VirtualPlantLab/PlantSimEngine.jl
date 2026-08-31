using Dates
using PlantSimEngine
using Test

PlantSimEngine.@process "nested_call_leaf" verbose = false
PlantSimEngine.@process "nested_call_middle" verbose = false
PlantSimEngine.@process "nested_call_root" verbose = false
PlantSimEngine.@process "nested_many_middle" verbose = false
PlantSimEngine.@process "nested_many_root" verbose = false
PlantSimEngine.@process "many_call_controller" verbose = false
PlantSimEngine.@process "selective_many_call_controller" verbose = false
PlantSimEngine.@process "call_return_shape" verbose = false

struct NestedCallLeafModel <: AbstractNested_Call_LeafModel end
struct NestedCallMiddleModel <: AbstractNested_Call_MiddleModel end
struct NestedCallRootModel <: AbstractNested_Call_RootModel end
struct NestedManyMiddleModel <: AbstractNested_Many_MiddleModel end
struct NestedManyRootModel <: AbstractNested_Many_RootModel end
struct ManyCallControllerModel <: AbstractMany_Call_ControllerModel end
struct SelectiveManyCallControllerModel{O} <:
       AbstractSelective_Many_Call_ControllerModel
    objects::O
end
struct CallReturnShapeModel <: AbstractCall_Return_ShapeModel end

const CALL_RETURN_CONTEXT = Ref{Any}()
const NESTED_ROOT_CONTEXT = Ref{Any}()
const NESTED_MANY_MIDDLE_CONTEXT = Ref{Any}()
const MANY_CALL_CONTEXT = Ref{Any}()
const LAZY_MANY_CALL_CONTEXT = Ref{Any}()

function call_lookup_allocations(context)
    call_targets(context, :one)
    return @allocated call_targets(context, :one)
end

literal_call_targets(context::T) where {T} = call_targets(context, :one)
# Julia 1.10 needs the literal call site inlined into the allocation probe.
@inline literal_call_model(context::T) where {T} = call_model(context, :one)

function call_model_lookup_allocations(context::T) where {T}
    literal_call_model(context)
    return @allocated literal_call_model(context)
end

PlantSimEngine.inputs_(::NestedCallLeafModel) = NamedTuple()
PlantSimEngine.outputs_(::NestedCallLeafModel) = (value=0.0, calls=0)

function PlantSimEngine.run!(
    ::NestedCallLeafModel,
    status,
    environment,
    constants,
    context,
)
    status.calls += 1
    status.value += 1.0
    return nothing
end

PlantSimEngine.inputs_(::NestedCallMiddleModel) = NamedTuple()
PlantSimEngine.outputs_(::NestedCallMiddleModel) = (value=0.0, calls=0)

function PlantSimEngine.run!(
    ::NestedCallMiddleModel,
    status,
    environment,
    constants,
    context,
)
    status.calls += 1
    leaf = only(run_call!(context, :leaf; publish=true))
    status.value = leaf.status.value
    return nothing
end

PlantSimEngine.inputs_(::NestedCallRootModel) = NamedTuple()
PlantSimEngine.outputs_(::NestedCallRootModel) =
    (trial_value=0.0, accepted_value=0.0, calls=0)

function PlantSimEngine.run!(
    ::NestedCallRootModel,
    status,
    environment,
    constants,
    context,
)
    status.calls += 1
    NESTED_ROOT_CONTEXT[] = context
    middle = only(call_targets(context, :middle))
    run_call!(middle; publish=false)
    status.trial_value = middle.status.value
    run_call!(middle; publish=true)
    status.accepted_value = middle.status.value
    return nothing
end

PlantSimEngine.inputs_(::NestedManyMiddleModel) = NamedTuple()
PlantSimEngine.outputs_(::NestedManyMiddleModel) = (total=0.0, ncalls=0)

function PlantSimEngine.run!(
    ::NestedManyMiddleModel,
    status,
    environment,
    constants,
    context,
)
    NESTED_MANY_MIDDLE_CONTEXT[] = context
    leaves = run_call!(context, :leaves; publish=true)
    status.ncalls = length(leaves)
    status.total = sum((leaf.status.value for leaf in leaves); init=0.0)
    return nothing
end

PlantSimEngine.inputs_(::NestedManyRootModel) = NamedTuple()
PlantSimEngine.outputs_(::NestedManyRootModel) = (total=0.0, ncalls=0)

function PlantSimEngine.run!(
    ::NestedManyRootModel,
    status,
    environment,
    constants,
    context,
)
    middle = only(run_call!(context, :middle; publish=true))
    status.ncalls = middle.status.ncalls
    status.total = middle.status.total
    return nothing
end

PlantSimEngine.inputs_(::ManyCallControllerModel) = NamedTuple()
PlantSimEngine.outputs_(::ManyCallControllerModel) = (total=0.0, ncalls=0)

PlantSimEngine.inputs_(::SelectiveManyCallControllerModel) = NamedTuple()
PlantSimEngine.outputs_(::SelectiveManyCallControllerModel) =
    (selected_total=0.0, selected_count=0)

function PlantSimEngine.run!(
    ::ManyCallControllerModel,
    status,
    environment,
    constants,
    context,
)
    MANY_CALL_CONTEXT[] = context
    targets = run_call!(context, :children; publish=true)
    status.ncalls = length(targets)
    status.total = sum((target.status.value for target in targets); init=0.0)
    return nothing
end

function PlantSimEngine.run!(
    model::SelectiveManyCallControllerModel,
    status,
    environment,
    constants,
    context,
)
    LAZY_MANY_CALL_CONTEXT[] = context
    selected = run_call!(
        context,
        :children;
        objects=model.objects,
        publish=true,
    )
    status.selected_count = length(selected)
    status.selected_total = sum(
        (target.status.value for target in selected);
        init=0.0,
    )
    return nothing
end

PlantSimEngine.inputs_(::CallReturnShapeModel) = NamedTuple()
PlantSimEngine.outputs_(::CallReturnShapeModel) = (
    one_count=0,
    optional_count=0,
    many_count=0,
    all_vector_like=false,
    cached_view=false,
)

function PlantSimEngine.run!(
    ::CallReturnShapeModel,
    status,
    environment,
    constants,
    context,
)
    one_targets = run_call!(context, :one; publish=false)
    optional_targets = run_call!(context, :optional; publish=false)
    many_targets = run_call!(context, :many; publish=false)
    status.one_count = length(one_targets)
    status.optional_count = length(optional_targets)
    status.many_count = length(many_targets)
    status.all_vector_like = all(
        targets -> targets isa AbstractVector{CallTarget},
        (one_targets, optional_targets, many_targets),
    )
    status.cached_view = call_targets(context, :one) === call_targets(context, :one)
    CALL_RETURN_CONTEXT[] = context
    return nothing
end

@testset "nested trial publication is transactional" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene, name=:scene),
        Object(:middle; scale=:Plant, name=:middle, parent=:scene),
        Object(:leaf; scale=:Leaf, name=:leaf, parent=:middle);
        applications=(
            ModelSpec(NestedCallRootModel(); name=:root, on=One(name=:scene), calls=(:middle => One(name=:middle, within=Subtree(), application=:middle)), every=Hour(1)),
            ModelSpec(NestedCallMiddleModel(); name=:middle, on=One(name=:middle), calls=(:leaf => One(name=:leaf, within=Subtree(), application=:leaf)), every=Hour(1)),
            ModelSpec(NestedCallLeafModel(); name=:leaf, on=One(name=:leaf), every=Hour(1)),
        ),
        environment=(duration=Hour(1),),
    )

    simulation = run!(model; outputs=:all)
    statuses = Dict(object.id.value => object.status for object in model_objects(model))
    @test statuses[:leaf].calls == 2
    @test statuses[:leaf].value == 2.0
    @test statuses[:middle].calls == 2
    @test statuses[:middle].value == 2.0
    @test statuses[:scene].trial_value == 1.0
    @test statuses[:scene].accepted_value == 2.0

    @test length(outputs(simulation)[(:leaf, ObjectId(:leaf), :value)]) == 1
    @test length(outputs(simulation)[(:middle, ObjectId(:middle), :value)]) == 1
    @test only(outputs(simulation)[(:leaf, ObjectId(:leaf), :value)])[2] == 2.0
    @test only(outputs(simulation)[(:middle, ObjectId(:middle), :value)])[2] == 2.0

    schedule = Dict(row.application_id => row for row in explain_schedule(simulation.compiled))
    @test schedule[:middle].manual_call_only
    @test schedule[:leaf].manual_call_only
    @test !schedule[:root].manual_call_only
    @test schedule[:middle].schedule_kind == :manual_call_only
    @test isnothing(schedule[:middle].schedule_entry_index)
    @test schedule[:root].event_driven

    @test_nowarn run_call!(
        NESTED_ROOT_CONTEXT[],
        :middle;
        environment=(duration=Hour(2),),
        publish=true,
    )
    @test statuses[:leaf].calls == 3
    @test statuses[:middle].calls == 3
end

@testset "nested manual Many owners refresh transitively" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene, name=:scene),
        Object(:middle; scale=:Plant, name=:middle, parent=:scene),
        Object(:leaf_a; scale=:Leaf, parent=:middle);
        applications=(
            ModelSpec(
                NestedManyRootModel();
                name=:root,
                on=One(name=:scene),
                calls=(
                    :middle => One(
                        name=:middle,
                        within=Subtree(),
                        application=:middle,
                    ),
                ),
            ),
            ModelSpec(
                NestedManyMiddleModel();
                name=:middle,
                on=One(name=:middle),
                calls=(
                    :leaves => Many(
                        scale=:Leaf,
                        within=Subtree(),
                        application=:leaf,
                    ),
                ),
            ),
            ModelSpec(
                NestedCallLeafModel();
                name=:leaf,
                on=Many(scale=:Leaf),
            ),
        ),
        environment=(duration=Hour(1),),
    )

    simulation = run!(model; outputs=:none)
    root = only(model_objects(model; name=:scene)).status
    scenario_plan = simulation.compiled.scenario_plan
    @test root.ncalls == 1
    @test root.total == 1.0
    @test length(call_targets(NESTED_MANY_MIDDLE_CONTEXT[], :leaves)) == 1

    register_object!(
        model,
        Object(:leaf_b; scale=:Leaf, parent=:middle),
    )
    continue!(simulation)

    @test simulation.compiled.scenario_plan === scenario_plan
    @test root.ncalls == 2
    @test root.total == 3.0
    @test length(call_targets(NESTED_MANY_MIDDLE_CONTEXT[], :leaves)) == 2
end

@testset "hard-call ownership cycles fail before execution" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene, name=:scene),
        Object(:middle; scale=:Plant, name=:middle, parent=:scene);
        applications=(
            ModelSpec(
                NestedCallRootModel();
                name=:root,
                on=One(name=:scene),
                calls=(
                    :middle => One(
                        name=:middle,
                        application=:middle,
                    ),
                ),
            ),
            ModelSpec(
                NestedCallMiddleModel();
                name=:middle,
                on=One(name=:middle),
                calls=(
                    :leaf => One(
                        name=:scene,
                        application=:root,
                    ),
                ),
            ),
        ),
    )
    @test_throws "hard-call ownership cycle detected" Advanced.refresh_bindings!(
        model,
    )
end


@testset "hard-call return shape and errors" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene, name=:scene),
        Object(:leaf_b; scale=:Leaf, name=:leaf_b, parent=:scene),
        Object(:leaf_a; scale=:Leaf, name=:leaf_a, parent=:scene);
        applications=(
            ModelSpec(CallReturnShapeModel(); name=:controller, on=One(name=:scene), calls=(:one => One(name=:leaf_a, application=:leaf_calls),
                    :optional => OptionalOne(
                        name=:missing,
                        application=:leaf_calls,
                    ),
                    :many => Many(scale=:Leaf, application=:leaf_calls),)),
            ModelSpec(NestedCallLeafModel(); name=:leaf_calls, on=Many(scale=:Leaf)),
        ),
        environment=(duration=Hour(1),),
    )

    simulation = run!(model)
    scenario_plan = simulation.compiled.scenario_plan
    call_plans = scenario_plan.call_plans
    @test getproperty.(call_plans, :slot) == (1, 2, 3)
    @test getproperty.(call_plans, :application_slot) == (1, 1, 1)
    @test getproperty.(call_plans, :application_id) ==
          (:controller, :controller, :controller)
    @test getproperty.(call_plans, :call) == (:one, :optional, :many)
    @test getproperty.(call_plans, :potential_callee_application_ids) ==
          ((:leaf_calls,), (:leaf_calls,), (:leaf_calls,))
    @test scenario_plan.manual_application_ids == (:leaf_calls,)
    @test scenario_plan.call_owners.leaf_calls == (:controller,)
    @test all(
        plan -> plan ===
                only(
            candidate for candidate in
            scenario_plan.call_plans_by_application.controller
            if candidate.call == plan.call
        ),
        call_plans,
    )
    @test isempty(scenario_plan.call_plans_by_application.leaf_calls)
    one_binding = only(
        binding for binding in simulation.compiled.call_bindings
        if binding.call == :one
    )
    one_plan = only(plan for plan in call_plans if plan.call == :one)
    @test fieldnames(typeof(one_binding)) == (
        :plan,
        :consumer_id,
        :callee_object_ids,
        :callee_application_ids,
    )
    @test one_binding.plan === one_plan
    @test one_binding.application_id == :controller
    @test one_binding.multiplicity == :one
    one_call_row = only(
        row for row in explain_calls(simulation.compiled) if row.call == :one
    )
    @test one_call_row.call_plan_slot == 1
    @test one_call_row.application_slot == 1
    @test one_call_row.potential_callee_application_ids == (:leaf_calls,)
    controller = only(model_objects(model; scale=:Scene)).status
    @test controller.one_count == 1
    @test controller.optional_count == 0
    @test controller.many_count == 2
    @test controller.all_vector_like
    @test controller.cached_view
    context = CALL_RETURN_CONTEXT[]
    @test (@inferred literal_call_targets(context)) === call_targets(context, :one)
    @test (@inferred literal_call_model(context)) isa NestedCallLeafModel
    @test call_model(context, :one) === runtime_model(only(call_targets(context, :one)))
    @test call_model_lookup_allocations(context) == 0
    @test_throws "resolved 0" call_model(context, :optional)
    @test_throws "resolved 2" call_model(context, :many)
    @test_throws ArgumentError call_model(nothing, :one)
    @test_throws "mutually exclusive" run_call!(
        context,
        :one;
        environment=(T=20.0,),
        sampled_environment=(T=21.0,),
    )
    call_lookup_allocations(context)
    @test call_lookup_allocations(context) == 0
    one_call_view = call_targets(context, :one)
    @test length(one_call_view.execution_batches) == 1
    cached_execution_target =
        only(only(one_call_view.execution_batches).targets)
    continue!(simulation)
    @test simulation.compiled.scenario_plan === scenario_plan
    @test simulation.compiled.scenario_plan.call_plans === call_plans
    continued_call_view = call_targets(CALL_RETURN_CONTEXT[], :one)
    @test continued_call_view === one_call_view
    @test only(only(continued_call_view.execution_batches).targets) ===
          cached_execution_target
    register_object!(
        model,
        Object(:leaf_c; scale=:Leaf, name=:leaf_c, parent=:scene),
    )
    continue!(simulation)
    refreshed_call_view = call_targets(CALL_RETURN_CONTEXT[], :one)
    # Adding an unrelated Many callee must not rebuild this unchanged One target.
    @test only(only(refreshed_call_view.execution_batches).targets) ===
          cached_execution_target
    @test_throws ArgumentError run_call!(nothing, :one)

    undeclared = CompositeModel(
        Object(:scene; scale=:Scene);
        applications=(
            ModelSpec(CallReturnShapeModel(); name=:controller, on=One(scale=:Scene)),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "did not declare call `one`" run!(undeclared)

    zero_one = CompositeModel(
        Object(:scene; scale=:Scene);
        applications=(
            ModelSpec(CallReturnShapeModel(); name=:controller, on=One(scale=:Scene), calls=(:one => One(scale=:Leaf, application=:leaf_calls))),
        ),
    )
    @test_throws "Expected exactly one object" Advanced.refresh_bindings!(zero_one)

    multiple_one = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:leaf_a; scale=:Leaf, parent=:scene),
        Object(:leaf_b; scale=:Leaf, parent=:scene);
        applications=(
            ModelSpec(CallReturnShapeModel(); name=:controller, on=One(scale=:Scene), calls=(:one => One(scale=:Leaf, application=:leaf_calls))),
            ModelSpec(NestedCallLeafModel(); name=:leaf_calls, on=Many(scale=:Leaf)),
        ),
    )
    @test_throws "Expected exactly one object" Advanced.refresh_bindings!(multiple_one)

    @test_throws "`process=` in scenario" ModelSpec(
        CallReturnShapeModel();
        name=:controller,
        on=One(scale=:Scene),
        calls=(:one => One(scale=:Leaf, process=:nested_call_leaf),),
    )
    @test_throws "`process=` in scenario" ModelSpec(
        CallReturnShapeModel();
        name=:controller,
        on=One(scale=:Scene),
        calls=(
            :optional =>
                OptionalOne(scale=:Leaf, process=:nested_call_leaf),
        ),
    )
end

@testset "Many call targets preserve object identity" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene, name=:scene),
        Object(:leaf_b; scale=:Leaf, parent=:scene),
        Object(:leaf_a; scale=:Leaf, parent=:scene);
        applications=(
            ModelSpec(ManyCallControllerModel(); name=:controller, on=One(name=:scene), calls=(:children => Many(
                        scale=:Leaf,
                        within=SceneScope(),
                        application=:leaf_calls,
                    ),)),
            ModelSpec(NestedCallLeafModel(); name=:leaf_calls, on=Many(scale=:Leaf)),
        ),
        environment=(duration=Hour(1),),
    )

    compiled = Advanced.refresh_bindings!(model)
    call = only(explain_calls(compiled))
    @test call.callee_object_ids == [:leaf_a, :leaf_b]
    @test call.callee_application_ids == [:leaf_calls]

    simulation = run!(model; outputs=:all, performance=true)
    controller = only(model_objects(model; scale=:Scene)).status
    @test controller.ncalls == 2
    @test controller.total == 2.0
    rows = filter(
        row -> row.application_id == :leaf_calls && row.variable == :value,
        collect_outputs(simulation; sink=nothing),
    )
    @test getproperty.(rows, :object_id) == [:leaf_a, :leaf_b]
    @test getproperty.(rows, :value) == [1.0, 1.0]
    initial_call_view = call_targets(MANY_CALL_CONTEXT[], :children)
    initial_execution_targets = [
        target
        for batch in initial_call_view.execution_batches
        for target in batch.targets
    ]
    @test getproperty.(initial_execution_targets, :object_id) ==
          ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_b)]

    register_object!(
        model,
        Object(:leaf_c; scale=:Leaf, parent=:scene),
    )
    continue!(simulation; steps=1)
    performance = Advanced.runtime_performance(simulation)
    @test performance.counts[:execution_target_call_batches_extended] == 1
    refreshed_call_view = call_targets(MANY_CALL_CONTEXT[], :children)
    refreshed_execution_targets = [
        target
        for batch in refreshed_call_view.execution_batches
        for target in batch.targets
    ]
    @test refreshed_call_view === initial_call_view
    @test refreshed_execution_targets[1] === initial_execution_targets[1]
    @test refreshed_execution_targets[2] === initial_execution_targets[2]
    @test getproperty.(refreshed_execution_targets, :object_id) ==
          ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_b), ObjectId(:leaf_c)]
    @test controller.ncalls == 3
    @test controller.total == 5.0

    remove_object!(model, :leaf_b)
    continue!(simulation; steps=1)
    @test controller.ncalls == 2
    @test controller.total == 5.0
end

@testset "large monotonic Many call extension preserves existing targets" begin
    initial_count = 128
    initial_leaf_ids = Symbol[
        Symbol("leaf_", lpad(string(index), 3, '0'))
        for index in 1:initial_count
    ]
    model = CompositeModel(
        Object(:scene; scale=:Scene, name=:scene),
        (
            Object(leaf_id; scale=:Leaf, parent=:scene)
            for leaf_id in initial_leaf_ids
        )...;
        applications=(
            ModelSpec(
                ManyCallControllerModel();
                name=:controller,
                on=One(name=:scene),
                calls=(
                    :children => Many(
                        scale=:Leaf,
                        within=SceneScope(),
                        application=:leaf_calls,
                    ),
                ),
            ),
            ModelSpec(
                NestedCallLeafModel();
                name=:leaf_calls,
                on=Many(scale=:Leaf),
            ),
        ),
        environment=(duration=Hour(1),),
    )

    simulation = run!(model; outputs=:none, performance=true)
    controller = only(model_objects(model; scale=:Scene)).status
    initial_call_view = call_targets(MANY_CALL_CONTEXT[], :children)
    initial_execution_targets = [
        target
        for batch in initial_call_view.execution_batches
        for target in batch.targets
    ]
    @test length(initial_execution_targets) == initial_count
    @test getproperty.(initial_execution_targets, :object_id) ==
          ObjectId.(initial_leaf_ids)
    @test controller.ncalls == initial_count
    @test controller.total == initial_count

    added_leaf_id = :leaf_129
    register_object!(
        model,
        Object(added_leaf_id; scale=:Leaf, parent=:scene),
    )
    continue!(simulation)

    refreshed_call_view = call_targets(MANY_CALL_CONTEXT[], :children)
    refreshed_execution_targets = [
        target
        for batch in refreshed_call_view.execution_batches
        for target in batch.targets
    ]
    @test refreshed_call_view === initial_call_view
    @test length(refreshed_execution_targets) == initial_count + 1
    @test all(
        refreshed_execution_targets[index] === initial_execution_targets[index]
        for index in eachindex(initial_execution_targets)
    )
    @test refreshed_execution_targets[end].object_id == ObjectId(added_leaf_id)
    @test all(
        refreshed_execution_targets[end] !== initial_target
        for initial_target in initial_execution_targets
    )
    @test Advanced.runtime_performance(simulation).counts[
        :execution_target_call_batches_extended
    ] == 1
    @test Advanced.runtime_performance(simulation).counts[
        :execution_target_call_delta_extensions
    ] == 1
    @test Advanced.runtime_performance(simulation).counts[
        :execution_target_call_delta_targets_added
    ] == 1
    @test controller.ncalls == initial_count + 1
    @test controller.total == 2 * initial_count + 1
end

@testset "large selective Many call remains lazy until full inspection" begin
    initial_count = 128
    initial_leaf_ids = Symbol[
        Symbol("lazy_leaf_", lpad(string(index), 3, '0'))
        for index in 1:initial_count
    ]
    selected_leaf_ids = (
        initial_leaf_ids[1],
        initial_leaf_ids[div(initial_count, 2)],
        initial_leaf_ids[end],
    )
    model = CompositeModel(
        Object(:scene; scale=:Scene, name=:scene),
        (
            Object(leaf_id; scale=:Leaf, parent=:scene)
            for leaf_id in initial_leaf_ids
        )...;
        applications=(
            ModelSpec(
                SelectiveManyCallControllerModel(selected_leaf_ids);
                name=:selective_controller,
                on=One(name=:scene),
                calls=(
                    :children => Many(
                        scale=:Leaf,
                        within=SceneScope(),
                        application=:selective_leaf_calls,
                    ),
                ),
            ),
            ModelSpec(
                NestedCallLeafModel();
                name=:selective_leaf_calls,
                on=Many(scale=:Leaf),
            ),
        ),
        environment=(duration=Hour(1),),
    )

    simulation = run!(model; outputs=:none)
    controller = only(model_objects(model; scale=:Scene)).status
    context = LAZY_MANY_CALL_CONTEXT[]
    full_call_view = call_targets(context, :children)
    @test !PlantSimEngine._call_execution_batches_materialized(
        full_call_view,
    )
    @test controller.selected_count == length(selected_leaf_ids)
    @test controller.selected_total == length(selected_leaf_ids)
    @test all(
        model_status(model, leaf_id).calls == 1
        for leaf_id in selected_leaf_ids
    )
    @test all(
        model_status(model, leaf_id).calls == 0
        for leaf_id in setdiff(initial_leaf_ids, selected_leaf_ids)
    )

    @test call_targets(context, :children) === full_call_view
    @test !PlantSimEngine._call_execution_batches_materialized(
        full_call_view,
    )
    @test length(full_call_view) == initial_count
    @test PlantSimEngine._call_execution_batches_materialized(full_call_view)
    materialized_targets = collect(full_call_view)
    @test getproperty.(materialized_targets, :object_id) ==
          ObjectId.(initial_leaf_ids)
    @test all(
        model_status(model, leaf_id).calls ==
        (leaf_id in selected_leaf_ids ? 1 : 0)
        for leaf_id in initial_leaf_ids
    )

    executed_targets = run_call!(context, :children; publish=true)
    @test executed_targets === full_call_view
    @test PlantSimEngine._call_execution_batches_materialized(
        executed_targets,
    )
    @test sum(target.status.calls for target in executed_targets) ==
          initial_count + length(selected_leaf_ids)
    @test sum(target.status.value for target in executed_targets) ==
          initial_count + length(selected_leaf_ids)
end

@testset "non-monotonic Many call additions use the rebuild path" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene, name=:scene),
        Object(:leaf_b; scale=:Leaf, parent=:scene),
        Object(:leaf_c; scale=:Leaf, parent=:scene);
        applications=(
            ModelSpec(
                ManyCallControllerModel();
                name=:controller,
                on=One(name=:scene),
                calls=(
                    :children => Many(
                        scale=:Leaf,
                        within=SceneScope(),
                        application=:leaf_calls,
                    ),
                ),
            ),
            ModelSpec(
                NestedCallLeafModel();
                name=:leaf_calls,
                on=Many(scale=:Leaf),
            ),
        ),
        environment=(duration=Hour(1),),
    )

    simulation = run!(model; outputs=:none, performance=true)
    initial_call_view = call_targets(MANY_CALL_CONTEXT[], :children)
    register_object!(
        model,
        Object(:leaf_a; scale=:Leaf, parent=:scene),
    )
    continue!(simulation)

    refreshed_call_view = call_targets(MANY_CALL_CONTEXT[], :children)
    refreshed_object_ids = ObjectId[
        target.object_id
        for batch in refreshed_call_view.execution_batches
        for target in batch.targets
    ]
    @test refreshed_object_ids ==
          ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_b), ObjectId(:leaf_c)]
    @test refreshed_call_view !== initial_call_view
    @test get(
        Advanced.runtime_performance(simulation).counts,
        :execution_target_call_batches_extended,
        0,
    ) == 0
end

@testset "reparented Many call targets rebuild within a stable scope" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene, name=:scene),
        Object(:plant_a; scale=:Plant, parent=:scene),
        Object(:plant_b; scale=:Plant, parent=:scene),
        Object(:leaf; scale=:Leaf, parent=:plant_a);
        applications=(
            ModelSpec(
                ManyCallControllerModel();
                name=:controller,
                on=One(name=:scene),
                calls=(
                    :children => Many(
                        scale=:Leaf,
                        within=SceneScope(),
                        application=:leaf_calls,
                    ),
                ),
            ),
            ModelSpec(
                NestedCallLeafModel();
                name=:leaf_calls,
                on=Many(scale=:Leaf),
            ),
        ),
        environment=(duration=Hour(1),),
    )

    simulation = run!(model; outputs=:none, performance=true)
    reparent_object!(model, :leaf, :plant_b)
    continue!(simulation)

    refreshed_call_view = call_targets(MANY_CALL_CONTEXT[], :children)
    refreshed_execution_target =
        only(only(refreshed_call_view.execution_batches).targets)
    @test refreshed_execution_target.object_id == ObjectId(:leaf)
    @test get(
        Advanced.runtime_performance(simulation).counts,
        :execution_target_call_batches_extended,
        0,
    ) == 0
end

@testset "call targets refresh after reparenting" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant_a; scale=:Plant, name=:plant_a, parent=:scene),
        Object(:plant_b; scale=:Plant, name=:plant_b, parent=:scene),
        Object(:leaf; scale=:Leaf, parent=:plant_b);
        applications=(
            ModelSpec(ManyCallControllerModel(); name=:controller, on=One(name=:plant_a), calls=(:children => Many(
                        scale=:Leaf,
                        within=Subtree(),
                        application=:leaf_calls,
                    ),)),
            ModelSpec(NestedCallLeafModel(); name=:leaf_calls, on=Many(scale=:Leaf)),
        ),
        environment=(duration=Hour(1),),
    )

    simulation = run!(model; performance=true)
    scenario_plan = simulation.compiled.scenario_plan
    application_children = simulation.compiled.application_children
    application_order = simulation.compiled.application_order
    controller = only(model_objects(model; name=:plant_a)).status
    schedule = Dict(row.application_id => row for row in explain_schedule(simulation.compiled))
    @test schedule[:leaf_calls].manual_call_only
    @test !schedule[:leaf_calls].root_scheduled
    @test controller.ncalls == 0

    reparent_object!(model, :leaf, :plant_a)
    continue!(simulation; steps=1)
    @test simulation.compiled.scenario_plan === scenario_plan
    @test simulation.compiled.application_children === application_children
    @test simulation.compiled.application_order === application_order
    performance = Advanced.runtime_performance(simulation)
    @test performance.counts[:selector_application_candidates] == 1
    @test performance.counts[:selector_call_binding_candidates] == 1
    @test controller.ncalls == 1
    @test controller.total == 1.0

    reparent_object!(model, :leaf, :plant_b)
    continue!(simulation; steps=1)
    @test simulation.compiled.scenario_plan === scenario_plan
    @test simulation.compiled.application_children === application_children
    @test simulation.compiled.application_order === application_order
    performance = Advanced.runtime_performance(simulation)
    @test performance.counts[:selector_application_candidates] == 2
    # Leaving the anchored subtree is rebuilt from the old target membership;
    # it does not require another reverse-index candidate on the new ancestry.
    @test performance.counts[:selector_call_binding_candidates] == 1
    @test controller.ncalls == 0
    @test controller.total == 0.0
end

@testset "manual target cadence contract" begin
    incompatible = CompositeModel(
        Object(:scene; scale=:Scene, name=:scene),
        Object(:leaf; scale=:Leaf, name=:leaf, parent=:scene);
        applications=(
            ModelSpec(ManyCallControllerModel(); name=:controller, on=One(name=:scene), calls=(:children => One(name=:leaf, application=:leaf_calls)), every=Day(1)),
            ModelSpec(NestedCallLeafModel(); name=:leaf_calls, on=One(name=:leaf), every=Hour(1)),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "incompatible cadence" Advanced.refresh_bindings!(incompatible)

    incompatible_without_current_targets = CompositeModel(
        Object(:scene; scale=:Scene, name=:scene);
        applications=(
            ModelSpec(
                ManyCallControllerModel();
                name=:controller,
                on=One(name=:scene),
                calls=(
                    :children => Many(
                        scale=:Leaf,
                        application=:leaf_calls,
                    ),
                ),
                every=Day(1),
            ),
            ModelSpec(
                NestedCallLeafModel();
                name=:leaf_calls,
                on=Many(scale=:Leaf),
                every=Hour(1),
            ),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "incompatible cadence" Advanced.refresh_bindings!(
        incompatible_without_current_targets,
    )

    inherited = CompositeModel(
        Object(:scene; scale=:Scene, name=:scene),
        Object(:leaf; scale=:Leaf, name=:leaf, parent=:scene);
        applications=(
            ModelSpec(ManyCallControllerModel(); name=:controller, on=One(name=:scene), calls=(:children => One(name=:leaf, application=:leaf_calls)), every=Day(1)),
            ModelSpec(NestedCallLeafModel(); name=:leaf_calls, on=One(name=:leaf)),
        ),
        environment=(duration=Hour(1),),
    )
    @test_nowarn Advanced.refresh_bindings!(inherited)
end
