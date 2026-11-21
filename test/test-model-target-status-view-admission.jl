module TargetStatusViewAdmissionChecks49

using PlantSimEngine, Test
const PSE = PlantSimEngine

PSE.@process "target_view_source" verbose=false
PSE.@process "target_view_consumer" verbose=false
PSE.@process "target_view_creator" verbose=false
PSE.@process "target_view_initializer" verbose=false

struct Source <: AbstractTarget_View_SourceModel
    declarations::Base.RefValue{Int}
    runs::Base.RefValue{Int}
end
struct Scalar <: AbstractTarget_View_ConsumerModel
    runs::Base.RefValue{Int}
end
struct Multiple <: AbstractTarget_View_ConsumerModel
    runs::Base.RefValue{Int}
end
PSE.inputs_(::Source) = NamedTuple()
function PSE.outputs_(model::Source)
    model.declarations[] += 1
    return (signal=0.0f0,)
end
PSE.inputs_(::Scalar) = (signal=Required(Float32),)
PSE.inputs_(::Multiple) = (signals=Required(AbstractVector),)
PSE.outputs_(::Union{Scalar,Multiple}) = (value=0.0f0, visits=0)
function PSE.run!(model::Source, status, environment, constants, context)
    model.runs[] += 1
    status.signal += 1.0f0
    return nothing
end
function PSE.run!(model::Scalar, status, environment, constants, context)
    model.runs[] += 1
    status.value += status.signal
    status.visits += 1
    return nothing
end
function PSE.run!(model::Multiple, status, environment, constants, context)
    model.runs[] += 1
    status.value += sum(bound_input(context, :signals); init=0.0f0)
    status.visits += 1
    return nothing
end

function fixture(mode)
    declarations, source_runs, consumer_runs = Ref(0), Ref(0), Ref(0)
    consumer_status = mode === :many ? Status(signals=Float32[], value=0.0f0, visits=0) :
        Status(signal=3.0f0, value=0.0f0, visits=0)
    objects = (Object(:scene; scale=:Scene),
        Object(:a; scale=:Source, parent=:scene, status=Status(signal=3.0f0)),
        Object(:consumer; scale=:Leaf, parent=:scene, status=consumer_status))
    mode === :many && (objects = (objects...,
        Object(:b; scale=:Source, parent=:scene, status=Status(signal=5.0f0))))
    route = mode === :many ? Many(scale=:Source, within=SceneScope(), application=:source, var=:signal) :
        One(id=:a, within=SceneScope(), application=:source, var=:signal)
    inputs = mode === :many ? (signals=route,) :
        mode === :temporal ? (PreviousTimeStep(:signal) => route,) : (signal=route,)
    consumer = mode === :many ? Multiple(consumer_runs) : Scalar(consumer_runs)
    model = CompositeModel(objects...; applications=(
        ModelSpec(Source(declarations,source_runs); name=:source, on=Many(scale=:Source)),
        ModelSpec(consumer; name=:consumer, on=One(id=:consumer), inputs=inputs)))
    simulation = run!(model; steps=0, outputs=:all)
    target = only(target for batch in simulation.execution_plan.batches
        if batch.application.id === :consumer for target in batch.targets)
    return (;model,simulation,target,declarations,source_runs,consumer_runs)
end

history(simulation) = Dict(key => collect(stream) for (key,stream) in outputs(simulation))
function construct(data, schema)
    simulation = data.simulation
    return PSE._new_model_execution_target(simulation.compiled,
        simulation.environment_bindings, simulation.compiled.applications_by_id[:consumer],
        ObjectId(:consumer), simulation.temporal_streams, simulation.output_retention,
        simulation.constants; target_schema=schema)
end

@testset "one target constructor admits real scalar, Many and temporal views" begin
    for mode in (:one,:many,:temporal)
        data = fixture(mode)
        simulation = data.simulation
        application = simulation.compiled.applications_by_id[:consumer]
        key = (:consumer,ObjectId(:consumer))
        view = PSE._model_status_view_for_application(simulation.compiled, application, key[2])
        @test valtype(typeof(simulation.compiled.status_views_by_target)) === Any
        @test view === simulation.compiled.status_views_by_target[key]
        references = Dict(name => PSE.refvalue(model_status(data.model,:consumer),name)
            for name in keys(model_status(data.model,:consumer)))
        before_history = history(simulation)
        declarations = data.declarations[]
        schema = PSE._closed_execution_cohort_schema(Tuple{typeof(data.target)})
        for admission in (PSE.OpenExecutionCohortSchema(),schema)
            target = construct(data,admission)
            @test typeof(target) === typeof(data.target)
            @test target !== data.target
            @test target.status_view === view
            @test target.bound_inputs === view.bound_inputs
            @test target.context.bound_inputs === view.bound_inputs
            @test target.call_context_cache.execution_stamp === view.execution_stamp
            @test all(PSE.refvalue(target.status_view.canonical_status,name) === reference
                for (name,reference) in references)
            @test data.declarations[] == declarations
            @test data.source_runs[] == data.consumer_runs[] == 0
            @test history(simulation) == before_history
        end

        # Missing lookup retains its original diagnostic before construction.
        delete!(simulation.compiled.status_views_by_target,key)
        message = "No compiled status view for application `consumer` on object `consumer`."
        @test_throws message PSE._model_status_view_for_application(
            simulation.compiled,application,key[2])
        @test_throws message construct(data,schema)
        simulation.compiled.status_views_by_target[key] = view
        @test data.declarations[] == declarations
        @test data.source_runs[] == data.consumer_runs[] == 0
        step!(simulation)
        @test model_status(data.model,:consumer).value ===
            (mode === :many ? 10.0f0 : mode === :temporal ? 3.0f0 : 4.0f0)
        @test model_status(data.model,:consumer).visits == 1
        @test data.consumer_runs[] == 1
        @test data.source_runs[] == (mode === :many ? 2 : 1)
        @test all(PSE.refvalue(model_status(data.model,:consumer),name) === reference
            for (name,reference) in references)
    end
end

struct LeafInitModel <: AbstractTarget_View_InitializerModel end
struct Creator{C} <: AbstractTarget_View_CreatorModel
    initialized::C
end
PSE.inputs_(::LeafInitModel) = NamedTuple()
PSE.outputs_(::LeafInitModel) = (value=0.0f0, visits=0)
PSE.inputs_(::Creator) = NamedTuple()
PSE.outputs_(::Creator) = (born=false, seen=0.0f0)
function PSE.run!(::LeafInitModel,status,environment,constants,context)
    status.value += 2.0f0
    status.visits += 1
    return nothing
end
function PSE.run!(model::Creator,status,environment,constants,context)
    if !status.born
        object = register_object!(runtime_model(context),Object(:new;
            scale=:Leaf,parent=:root,status=Status(value=0.0f0,visits=0)))
        model.initialized[] = run_initializer!(context,:initialize,object)
        status.born = true
    end
    status.seen = model_status(runtime_model(context),:new).value
    return nothing
end

@testset "newborn initializer uses the same status-view admission factory" begin
    initialized = Ref{Any}(nothing)
    model = CompositeModel(Object(:root;scale=:Scene); applications=(
        ModelSpec(Creator(initialized);name=:creator,on=One(id=:root),calls=(
            initialize=PSE.Initializer(One(within=Subtree(),scale=:Leaf,application=:leaf)),)),
        ModelSpec(LeafInitModel();name=:leaf,on=Many(scale=:Leaf))))
    simulation = run!(model;steps=1,outputs=:all)
    newborn = model_status(model,:new)
    value_ref = PSE.refvalue(newborn,:value)
    @test initialized[] === newborn
    @test newborn.value === 2.0f0
    @test newborn.visits == 1
    @test model_status(model,:root).seen === 2.0f0
    @test isempty(outputs(simulation)[(:leaf,ObjectId(:new),:value)])
    continue!(simulation;steps=1)
    @test PSE.refvalue(model_status(model,:new),:value) === value_ref
    @test newborn.value === 4.0f0
    @test newborn.visits == 2
    @test model_status(model,:root).seen === 4.0f0
    @test outputs(simulation)[(:leaf,ObjectId(:new),:value)] == [(2.0,4.0f0)]
end

end
