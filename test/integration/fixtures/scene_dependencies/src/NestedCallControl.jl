module NestedCallControl

import PlantSimEngine as PSE
include("native_preparation.jl")

PSE.@process "nested_prepared" verbose=false
struct Stage{I} <: AbstractNested_PreparedModel end
PSE.inputs_(::Stage) = NamedTuple()
PSE.outputs_(::Stage) = (hits=0,)
function PSE.run!(::Stage, status, environment, constants, context)
    status.hits += 1
    return nothing
end

const STAGES = (:controller, :energy_balance, :photosynthesis, :response)

function mount(i)
    name = STAGES[i]
    calls = if i == length(STAGES)
        NamedTuple()
    else
        child = STAGES[i+1]
        multiplicity = i == 1 ? PSE.Many : PSE.One
        binding = multiplicity(PSE.SceneScope(); id=child, application=child)
        NamedTuple{(child,)}((binding,))
    end
    return PSE.ModelSpec(Stage{i}(); name, on=PSE.One(id=name), calls)
end

function prepare(views, environment)
    objects = map(name -> PSE.Object(name; scale=name, status=PSE.Status(hits=0)), STAGES)
    model = PSE.CompositeModel(objects...; applications=Tuple(mount(i) for i in eachindex(STAGES)))
    scene = NativePreparation.close_registry(model, PSE.ObjectId{Symbol})
    return PSE._prepare_simulation!(scene; steps=0, outputs=:none, constants=PSE.Constants(),
        status_view_schema=views, environment_schema=environment,
        input_binding_storage=PSE.CompiledModelInputBinding[])
end

root(simulation) = only(only(simulation.execution_plan.groups).batches)

function record_batches!(schemas, batch)
    calls = first(batch.targets).context.calls
    children = map(calls) do call
        child = only(PSE._materialize_call_execution_batches!(call))
        return record_batches!(schemas, child)
    end
    names = Tuple(call.binding.plan.call for call in calls)
    B = PSE._execution_batch_type_with_call_schemas(typeof(batch), NamedTuple{names}(children))
    return schemas[batch.application.id] = NativePreparation.batch_schema((B,))
end

function prepare_calls()
    observed = NativePreparation.RuntimeTypes()
    environment = PSE._collecting_environment_binding_schema()
    initial = prepare(observed, environment)
    record_batches!(Dict{Symbol,Any}(), root(initial))
    tables = map(name -> Vector{Union{observed.views[name]...}}(), STAGES)
    metadata = PSE.CompiledMetadataTable(NamedTuple{STAGES}(tables))
    simulation = prepare(metadata, PSE._freeze_environment_binding_schema(environment))
    schemas = Dict{Symbol,Any}()
    record_batches!(schemas, root(simulation))
    closed = PSE._prepare_execution_batch_schemas(simulation,
        NamedTuple{STAGES}(map(name -> schemas[name], STAGES)))
    return only(first(root(closed).targets).context.calls)
end

const TARGETS = prepare_calls()

Base.@noinline function check(targets)
    schema = targets.batch_schema
    batches = PSE._compiled_call_execution_batches(targets.compiled, targets.environment_bindings,
        targets.binding, targets.temporal_streams, targets.output_retention, targets.constants;
        cohort_schema=PSE._execution_cohort_schema(schema), batch_schema=schema)
    length(batches) == 1 || return false
    rows = first(batches).targets
    length(rows) == 1 || return false
    return first(rows).object_id === PSE.ObjectId(:energy_balance)
end

end
