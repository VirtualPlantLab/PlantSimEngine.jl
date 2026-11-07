module PersistentEmptyExecutionGroupChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine
PSE.@process "persistent_empty_counter" verbose=false
struct Counter{C} <: AbstractPersistent_Empty_CounterModel
    declarations::C
end
PSE.inputs_(::Counter) = NamedTuple()
function PSE.outputs_(model::Counter)
    model.declarations[] += 1
    return (count=0,)
end
PSE.run!(::Counter, status, environment, constants, context) = (status.count += 1; nothing)

@testset "an ordinary learned group survives removal and same-schema return" begin
    declarations = Ref(0)
    original = Status(count=0)
    model = CompositeModel(Object(:first;scale=:Leaf,status=original);
        applications=(ModelSpec(Counter(declarations);name=:counter,on=Many(scale=:Leaf)),))
    simulation = run!(model;steps=1,outputs=:all)
    group = only(simulation.execution_plan.groups)
    @test original.count == 1
    remove_object!(model,:first)
    step!(simulation)
    @test only(simulation.execution_plan.groups) === group
    @test isempty(group.batches)
    @test isempty(group.membership.object_ids)
    @test original.count == 1
    @test outputs(simulation)[(:counter,ObjectId(:first),:count)] == [(1.0,1)]
    born = register_object!(model,Object(:next;scale=:Leaf,status=Status(count=10)))
    step!(simulation)
    @test only(simulation.execution_plan.groups) === group
    @test born.status.count == 11
    @test original.count == 1
    @test only(only(group.batches).targets).object_id === ObjectId(:next)
    @test outputs(simulation)[(:counter,ObjectId(:next),:count)] == [(3.0,11)]
    @test outputs(simulation)[(:counter,ObjectId(:first),:count)] == [(1.0,1)]
end

@testset "an admitted empty group fills its closed slot without dummy values" begin
    declarations = Ref(0)
    model = CompositeModel(Object(:scene;scale=:Scene);
        applications=(ModelSpec(Counter(declarations);name=:counter,on=Many(scale=:Leaf)),))
    simulation = run!(model;steps=0,outputs=:none)
    compiled = simulation.compiled
    application = compiled.applications_by_id[:counter]
    environment_plan = simulation.environment_bindings.application_plans_by_id[:counter]
    Empty = NamedTuple{(),Tuple{}}
    I = ObjectId{Symbol}
    # This is a supplied future reference descriptor, not inferred from an
    # output default and not instantiated as a placeholder Status.
    Full = Status{(:count,),Tuple{Base.RefValue{Int}}}
    View = PSE.CompiledModelStatusView{Full,Full,Tuple{},Empty,Empty}
    Context = PSE.RunContext{typeof(compiled),typeof(application),Tuple{},Empty,Empty,
        typeof(simulation.temporal_streams),typeof(simulation.output_retention),
        typeof(simulation.constants),PSE.NoEnvironmentOverride,I}
    Binding = PSE.CompiledEnvironmentBinding{typeof(environment_plan),Nothing,PSE.EnvironmentContext{I}}
    Target = PSE.CompiledExecutionTarget{typeof(PSE.model_(application.spec)),View,
        Tuple{},Empty,Empty,Tuple{},Tuple{},Binding,Context,I}
    Store = typeof(simulation.temporal_streams.cohorts)
    Owner = PSE._execution_store_owner_type(Store)
    Rows = PSE.ExecutionCohortRows{Target,PSE.ExecutionCohort{Target,I,Owner},Store}
    Batch = PSE.CompiledExecutionBatch{typeof(application),Rows,
        PSE.RawGlobalModelEnvironment{Nothing},PSE.CompiledOutputPublication{Tuple{}}}
    before_callbacks = declarations[]
    future = PSE._empty_model_execution_group(application,Batch,simulation.execution_plan.cohorts)
    @test declarations[] == before_callbacks
    @test length(model.registry.objects) == 1
    @test isnothing(model_status(model,:scene))
    @test isempty(future.batches)
    @test isempty(future.membership.object_ids)

    previous = simulation.execution_plan
    closed = PSE.CompiledExecutionPlan(previous.cohorts,previous.topology,
        (future,),previous.batches,(future,),previous.schedule,
        previous.model_revision,previous.environment_revision)
    simulation = PSE._simulation_with_execution_plan(simulation,closed)
    Plan = typeof(simulation.execution_plan)
    @test simulation.execution_plan.groups_by_application_slot isa Tuple
    @test simulation.execution_plan.batches isa AbstractVector
    @test simulation.execution_plan.topology isa PSE.DynamicExecution

    born = register_object!(model,Object(:born;scale=:Leaf,status=Status(count=7)))
    step!(simulation)
    @test born.status.count == 8
    @test typeof(simulation.execution_plan) === Plan
    @test only(simulation.execution_plan.groups) === future
    @test only(simulation.execution_plan.groups_by_application_slot) === future
    @test eltype(future.batches) === Batch
    @test only(only(future.batches).targets).status_view.status === born.status
    remove_object!(model,:born)
    step!(simulation)
    @test typeof(simulation.execution_plan) === Plan
    @test only(simulation.execution_plan.groups) === future
    @test isempty(future.batches)
    @test born.status.count == 8
end

end
