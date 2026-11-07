module ClosedGroupRefreshChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine
PSE.@process "closed_group_counter" verbose=false
struct Counter{T} <: AbstractClosed_Group_CounterModel
    increment::T
    trace::Vector{Symbol}
    declarations::Base.RefValue{Int}
end
PSE.inputs_(::Counter) = NamedTuple()
function PSE.outputs_(model::Counter)
    model.declarations[] += 1
    return (count=zero(model.increment),)
end
function PSE.run!(model::Counter, status, environment, constants, context)
    push!(model.trace, context.application.id)
    status.count += model.increment
    return nothing
end

function three_groups()
    trace, declarations = Symbol[], Ref(0)
    increments = (1f0, 1.0, 1f0)
    ids = (:a1, :b, :a2)
    specs = ntuple(index -> ModelSpec(Counter(increments[index], trace, declarations);
        name=ids[index], on=One(id=ids[index])), 3)
    objects = ntuple(index -> Object(ids[index];
        status=Status(count=zero(increments[index]))), 3)
    simulation = run!(CompositeModel(objects...; applications=specs);
        steps=0, outputs=:none)
    return (; simulation, trace, declarations)
end

function closed_plan(plan)
    return PSE.CompiledExecutionPlan(plan.cohorts, plan.topology,
        Tuple(plan.groups), plan.batches, Tuple(plan.groups_by_application_slot),
        plan.schedule, plan.model_revision, plan.environment_revision)
end

@testset "closed A/B/A groups retain current scheduler order and slot ownership" begin
    fixture = three_groups()
    simulation = fixture.simulation
    previous = closed_plan(simulation.execution_plan)
    @test typeof(previous.groups[1]) === typeof(previous.groups[3])
    @test typeof(previous.groups[1]) !== typeof(previous.groups[2])
    @test [group.application.id for group in previous.groups] == [:a1, :b, :a2]
    current = reverse(collect(previous.groups))
    admitted = @inferred PSE._execution_groups_in_schema(previous.groups, current)
    @test [group.application.id for group in admitted] == [:a2, :b, :a1]
    @test admitted[1] === previous.groups[3]
    @test admitted[3] === previous.groups[1]
    @test_throws "prepared tuple schema" PSE._execution_groups_in_schema(
        previous.groups, [previous.groups[2], previous.groups[1], previous.groups[3]])
    @test_throws "count differs" PSE._execution_groups_in_schema(
        previous.groups, current[1:2])
    @test_throws "prepared tuple schema" PSE._execution_groups_in_schema(
        (previous.groups[1], nothing, previous.groups[3]), previous.groups)
    repeated = PSE._execution_groups_in_schema(previous.groups,
        [previous.groups[1], previous.groups[2], previous.groups[1]])
    repeated_slots = PSE._execution_groups_by_application_slot(repeated, 3)
    @test_throws "prepared tuple schema" PSE._execution_groups_in_schema(
        previous.groups_by_application_slot, repeated_slots)

    # Build a CURRENT schedule definition with the canonical compiler, keeping
    # authored slots and all real application/group owners. A/B/A makes both
    # dependency-order representations inhabit the same actual tuple types.
    compiled = simulation.compiled
    old_scenario = compiled.scenario_plan
    order = reverse(old_scenario.application_order)
    definition = PSE._compiled_application_schedule(compiled.applications_by_id,
        order, old_scenario.manual_application_ids)
    current_plans = Tuple(compiled.applications_by_id[id].plan for id in order)
    fields = ntuple(fieldcount(typeof(old_scenario))) do index
        name = fieldname(typeof(old_scenario), index)
        name === :application_schedule && return definition
        name === :application_order && return order
        name === :ordered_application_plans && return current_plans
        return getfield(old_scenario, index)
    end
    compiled.scenario_plan = typeof(old_scenario)(fields...)
    compiled.application_order = order
    compiled.ordered_applications = Tuple(compiled.applications_by_id[id] for id in order)
    refreshed = PSE._refresh_model_execution_plan(previous, compiled,
        simulation.environment_bindings, simulation.temporal_streams,
        simulation.output_retention, simulation.constants, nothing, Set{Symbol}())
    @test typeof(refreshed.plan) === typeof(previous)
    @test [group.application.id for group in refreshed.plan.groups] == [:a2, :b, :a1]
    @test [group.application.id for group in refreshed.plan.groups_by_application_slot] == [:a1, :b, :a2]
    @test refreshed.targets_constructed == 0
    @test refreshed.batches_constructed == 0
    @test refreshed.groups_reused == 3
    @test isempty(fixture.trace)
    simulation = PSE._simulation_with_execution_plan(simulation, refreshed.plan)
    step!(simulation)
    @test fixture.trace == [:a2, :b, :a1]
    @test all(id -> model_status(simulation.model, id).count == 1, (:a1, :b, :a2))
end

@testset "closed lookup requires an existing id, application type and authored slot" begin
    fixture = three_groups()
    simulation = fixture.simulation
    slots = Tuple(simulation.execution_plan.groups_by_application_slot)
    application = slots[1].application
    invoked = Ref(false)
    counts = PSE._with_previous_execution_group(slots, application, falses(3)) do group
        invoked[] = true
        @test group === slots[1]
        return (0, 0, 1)
    end
    @test invoked[] && counts === (0, 0, 1)
    # A real same-typed application is absent, rather than a fabricated group
    # or a placeholder Status supplied only to satisfy inference.
    other = run!(CompositeModel(Object(:other; status=Status(count=0f0));
        applications=(ModelSpec(Counter(1f0, Symbol[], Ref(0));
            name=:other, on=One(id=:other)),)); steps=0, outputs=:none)
    missing = only(other.compiled.applications)
    @test typeof(missing) === typeof(application)
    invoked[] = false
    @test_throws "prepared execution-group schema" PSE._with_previous_execution_group(
        group -> (invoked[] = true; (0, 0, 0)), slots, missing, falses(3))
    @test !invoked[]

    # Public force can legitimately reorder ordinary authored application slots.
    reverse!(simulation.model.applications)
    PSE.Advanced.refresh_bindings!(simulation.model; force=true)
    moved = PSE.Advanced.compiled_bindings(simulation.model).applications_by_id[:a1]
    @test moved.slot == 3
    @test typeof(moved) === typeof(application)
    @test_throws "prepared execution-group schema" PSE._with_previous_execution_group(
        group -> (invoked[] = true; (0, 0, 0)), slots, moved, falses(3))
    @test !invoked[]
    open_counts = PSE._with_previous_execution_group(collect(slots), moved, falses(3)) do group
        @test group === slots[1]
        return (0, 0, 1)
    end
    @test open_counts === (0, 0, 1)
    # Reordering authored ids also changes the metadata table's tuple type;
    # the existing outer C witness requires a new timeline for that edit.
    current_simulation = run!(simulation.model; steps=0, outputs=:none)
    step!(current_simulation)
    @test fixture.trace == [:a2, :b, :a1]
end

@testset "open lookup admits a same-id application-type replacement" begin
    trace, declarations = Symbol[], Ref(0)
    status = Status(count=0f0)
    model = CompositeModel(Object(:leaf; status);
        applications=(ModelSpec(Counter(1f0, trace, declarations);
            name=:counter, on=One(id=:leaf)),))
    simulation = run!(model; steps=0, outputs=:none)
    previous = only(simulation.execution_plan.groups)
    model.applications[1] = ModelSpec(Counter(2.0, trace, declarations);
        name=:counter, on=One(id=:leaf))
    PSE.Advanced.refresh_bindings!(model; force=true)
    current = PSE.Advanced.compiled_bindings(model).applications_by_id[:counter]
    @test typeof(current) !== typeof(previous.application)
    invoked = Ref(false)
    @test_throws "prepared execution-group schema" PSE._with_previous_execution_group(
        group -> (invoked[] = true; (0, 0, 0)), (previous,), current, falses(1))
    @test !invoked[]
    counts = PSE._with_previous_execution_group([previous], current, falses(1)) do group
        @test group === previous
        return (0, 0, 1)
    end
    @test counts === (0, 0, 1)
    # A different authored CS needs a new Simulation under the existing outer
    # runtime contract. This tests the OPEN group container, not a new API for
    # changing a running Simulation's parametric compiled field.
    current_simulation = run!(model; steps=0, outputs=:none)
    current_groups = current_simulation.execution_plan.groups
    @test PSE._execution_groups_in_schema([previous], current_groups) === current_groups
    step!(current_simulation)
    @test status.count === 2f0
    @test model_status(model, :leaf) === status
    @test trace == [:counter]
end

@testset "ordinary heterogeneous overrides and public force retain full execution" begin
    trace, declarations = Symbol[], Ref(0)
    plain = Status(count=0f0)
    alternate = Status(count=0.0)
    template = CompositeModelTemplate((ModelSpec(Counter(1f0, trace, declarations);
        name=:counter, on=Many(scale=:Leaf)),))
    instance = ObjectInstance(:plant, template;
        root=Object(:plant; scale=:Plant),
        objects=(Object(:plain; scale=:Leaf, parent=:plant, status=plain),
            Object(:alternate; scale=:Leaf, parent=:plant, status=alternate)),
        object_overrides=(Override(object=:alternate, application=:counter,
            model=Counter(2.0, trace, declarations)),))
    model = CompositeModel(instance)
    simulation = run!(model; steps=1, outputs=:none)
    @test simulation.execution_plan.groups isa AbstractVector
    @test plain.count === 1f0 && alternate.count === 2.0
    PSE.Advanced.refresh_bindings!(model; force=true)
    step!(simulation)
    @test plain.count === 2f0 && alternate.count === 4.0
    @test model_status(model, :plain) === plain
    @test model_status(model, :alternate) === alternate
    group = only(simulation.execution_plan.groups)
    @test length(group.batches) == 2
    @test trace == fill(:plant__counter, 4)
end

@testset "a real learned batch schema admits an empty future group without probing defaults" begin
    trace, declarations = Symbol[], Ref(0)
    model = CompositeModel(Object(:scene; scale=:Scene),
        Object(:first; scale=:Leaf, status=Status(count=0));
        applications=(ModelSpec(Counter(1, trace, declarations);
            name=:counter, on=Many(scale=:Leaf)),))
    simulation = run!(model; steps=0, outputs=:none)
    Batch = typeof(only(only(simulation.execution_plan.groups).batches))
    removed_status = model_status(model, :first)
    remove_object!(model, :first)
    step!(simulation)
    application = simulation.compiled.applications_by_id[:counter]
    before = declarations[]
    future = PSE._empty_model_execution_group(application, Batch,
        simulation.execution_plan.cohorts)
    @test declarations[] == before
    @test isempty(future.batches) && isempty(future.membership.object_ids)
    @test length(model.registry.objects) == 1
    @test isempty(trace)
    old = simulation.execution_plan
    plan = PSE.CompiledExecutionPlan(old.cohorts, old.topology,
        (future,), old.batches, (future,), old.schedule,
        old.model_revision, old.environment_revision)
    simulation = PSE._simulation_with_execution_plan(simulation, plan)
    newborn = register_object!(model, Object(:next; scale=:Leaf, status=Status(count=7)))
    step!(simulation)
    @test newborn.status.count == 8
    @test removed_status.count == 0
    @test only(simulation.execution_plan.groups) === future
    @test only(simulation.execution_plan.groups_by_application_slot) === future
    @test typeof(simulation.execution_plan) === typeof(plan)
    @test only(only(future.batches).targets).status_view.status === newborn.status
    @test trace == [:counter]
end

end
