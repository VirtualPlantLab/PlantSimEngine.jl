module SharedInputRecipeChecks

using Dates, PlantSimEngine, Test
using PlantSimEngine.Diagnostics
const PSE = PlantSimEngine

PSE.@process "input_recipe_writer" verbose=false
PSE.@process "input_recipe_pair_reader" verbose=false
PSE.@process "input_recipe_aggregate" verbose=false
PSE.@process "input_recipe_empty" verbose=false

struct Writer{T,P} <: AbstractInput_Recipe_WriterModel
    value::T
    policy::P
end
Writer(value) = Writer(value, nothing)
PSE.inputs_(::Writer) = NamedTuple()
PSE.outputs_(::Writer{T}) where {T} = (x=zero(T), y=zero(T))
PSE.output_policy(model::Writer) = isnothing(model.policy) ? NamedTuple() :
    (x=model.policy[], y=model.policy[])
function PSE.run!(model::Writer, status, environment, constants, context)
    status.x = model.value
    status.y = 2 * model.value
    return nothing
end

struct PairReader{T} <: AbstractInput_Recipe_Pair_ReaderModel end
PSE.inputs_(::PairReader{T}) where {T} = (left=Required(T), right=Required(T))
PSE.outputs_(::PairReader{T}) where {T} = (total=zero(T),)
function PSE.run!(::PairReader, status, environment, constants, context)
    status.total = status.left + status.right
    return nothing
end

struct InferredReader <: AbstractInput_Recipe_Pair_ReaderModel end
PSE.inputs_(::InferredReader) = (x=Required(Float32), y=Required(Float32))
PSE.outputs_(::InferredReader) = (total=0f0,)
function PSE.run!(::InferredReader, status, environment, constants, context)
    status.total = status.x + status.y
    return nothing
end

struct AggregateReader <: AbstractInput_Recipe_AggregateModel end
PSE.inputs_(::AggregateReader) = (values=Default(Float64[]),)
PSE.outputs_(::AggregateReader) = (total=0.0,)
function PSE.run!(::AggregateReader, status, environment, constants, context)
    status.total = sum(bound_input(context, :values); init=0.0)
    return nothing
end

struct EmptyModel <: AbstractInput_Recipe_EmptyModel end
PSE.inputs_(::EmptyModel) = NamedTuple()
PSE.outputs_(::EmptyModel) = NamedTuple()
PSE.run!(::EmptyModel, status, environment, constants, context) = nothing

function pair_model(; policy=nothing)
    return CompositeModel(Object(0; scale=:Scene), Object(1; scale=:Leaf),
        Object(2; scale=:Reader), Object(3; scale=:Other);
        applications=(
            ModelSpec(EmptyModel(); name=:empty_a, on=One(id=0)),
            ModelSpec(Writer(2f0, policy); name=:source, on=One(id=1)),
            ModelSpec(EmptyModel(); name=:empty_b, on=One(id=0)),
            ModelSpec(PairReader{Float32}(); name=:reader, on=One(id=2),
                inputs=(left=One(SceneScope(); id=1, var=:x),
                    right=One(SceneScope(); id=1, var=:y))),
            ModelSpec(Writer(9f0); name=:other_source, on=One(id=3)),
        ), environment=(duration=Hour(1),))
end

function binding_signature(bindings)
    return [(binding.application_id, binding.input, binding.source_ids,
        binding.source_application_ids, typeof(binding.policy), binding.carrier_hint)
        for binding in bindings]
end

function reader_recipe(compiled)
    application = compiled.applications_by_id[:reader]
    recipe = PSE._application_plans(compiled.scenario_plan.input_recipes_by_application,
        application.slot)
    return application, recipe
end

@testset "canonical input recipes preserve named application slots and shared live refs" begin
    model = pair_model()
    simulation = run!(model; outputs=:all)
    compiled = simulation.compiled
    scenario = compiled.scenario_plan
    application, recipe = reader_recipe(compiled)
    @test keys(scenario.input_recipes_by_application) == keys(scenario.input_plans_by_application)
    @test keys(scenario.input_recipes_by_application) ==
          (:empty_a, :source, :empty_b, :reader, :other_source)
    @test application.slot == 4
    @test compiled.applications_by_id[:source].slot == 2
    @test compiled.applications_by_id[:other_source].slot == 5
    @test recipe.query_count == 1
    @test recipe.query_slots == (1, 1)
    @test isempty(recipe.inferred)
    @test Tuple(plan.input for plan in recipe.explicit) == (:left, :right)
    @test model_status(model, 2).total === 6f0
    bindings = compiled.input_bindings_by_target[(:reader, ObjectId(2))]
    for binding in bindings
        source = binding.input === :left ? :x : :y
        @test input_carrier(binding) === PSE.refvalue(model_status(model, 1), source)
        @test fieldtype(typeof(binding), :consumer_id) === ObjectId{Int}
    end
    # Exercise the canonical default preparation entry, without supplying the
    # prebuilt recipe table. It must derive the same routes and exact carriers.
    fresh = PSE._compile_model_input_bindings(model, compiled.applications)
    @test binding_signature(fresh) == binding_signature(compiled.input_bindings)
    @test all(input_carrier(binding) === PSE.refvalue(model_status(model, 1),
        binding.input === :left ? :x : :y) for binding in fresh)
end

@testset "inferred input groups drive initial and newborn execution in dependency order" begin
    model = CompositeModel(Object(1; scale=:Leaf);
        applications=(
            ModelSpec(InferredReader(); name=:inferred, on=Many(scale=:Leaf)),
            ModelSpec(Writer(3f0); name=:source, on=Many(scale=:Leaf)),
        ), environment=(duration=Hour(1),))
    simulation = run!(model; outputs=:all)
    recipe = simulation.compiled.scenario_plan.input_recipes_by_application[:inferred]
    @test isempty(recipe.explicit)
    @test Tuple(first(group).input for group in recipe.inferred) == (:x, :y)
    @test model_status(model, 1).total === 9f0
    initial = Status(x=1f0, y=2f0)
    x_reference = PSE.refvalue(initial, :x)
    y_reference = PSE.refvalue(initial, :y)
    register_object!(model, Object(2; scale=:Leaf, status=initial))
    continue!(simulation)
    @test model_status(model, 2).total === 9f0
    @test PSE.refvalue(model_status(model, 2), :x) === x_reference
    @test PSE.refvalue(model_status(model, 2), :y) === y_reference
    bindings = simulation.compiled.input_bindings_by_target[(:inferred, ObjectId(2))]
    @test Tuple(binding.input for binding in bindings) == (:x, :y)
    @test all(input_carrier(binding) === PSE.refvalue(model_status(model, 2), binding.input)
        for binding in bindings)
    @test outputs(simulation)[(:inferred, ObjectId(2), :total)] == [(2.0, 9f0)]
end

@testset "one recipe resolves new source families without copying values or refs" begin
    first = Status(x=2f0)
    model = CompositeModel(Object(:plant; scale=:Plant),
        Object(1; scale=:Leaf, parent=:plant, status=first);
        applications=(ModelSpec(AggregateReader(); name=:aggregate, on=One(id=:plant),
            inputs=(values=Many(scale=:Leaf, within=Subtree(), var=:x, from_status=true),)),),
        environment=(duration=Hour(1),))
    simulation = run!(model; outputs=:all)
    recipe = only(values(simulation.compiled.scenario_plan.input_recipes_by_application))
    @test model_status(model, :plant).total === 2.0
    old_binding = only(simulation.compiled.input_bindings)
    old_carrier = input_carrier(old_binding)
    first_ref = PSE.refvalue(first, :x)
    @test only(parent(old_carrier)) === first_ref

    second = Status(x=9.0)
    register_object!(model, Object(:new_leaf; scale=:Leaf, parent=:plant, status=second))
    continue!(simulation)
    @test only(values(simulation.compiled.scenario_plan.input_recipes_by_application)) === recipe
    @test model_status(model, :plant).total === 11.0
    binding = only(simulation.compiled.input_bindings)
    carrier = input_carrier(binding)
    @test carrier isa PSE.ObjectRefVector
    @test Set(binding.source_ids) == Set((ObjectId(1), ObjectId(:new_leaf)))
    @test isempty(binding.source_application_ids)
    for (id, reference) in zip(binding.source_ids, parent(carrier))
        @test reference === PSE.refvalue(model_status(model, id), :x)
    end
    @test first_ref[] isa Float32
    @test PSE.refvalue(second, :x)[] isa Float64
    first_ref[] = 7f0
    @test first.x === 7f0
    @test only(old_carrier) === 7f0
    continue!(simulation)
    @test model_status(model, :plant).total === 16.0
    @test outputs(simulation)[(:aggregate, ObjectId(:plant), :total)] ==
          [(1.0, 2.0), (2.0, 11.0), (3.0, 16.0)]
end

function materialize_reader(model, compiled, application, recipe)
    bindings = PSE.CompiledModelInputBinding[]
    PSE._compile_consumer_input_recipe!(bindings, model, application.id, application.process, ObjectId(2),
        recipe, compiled.scenario_plan.manual_application_ids,
        compiled.applications_by_object, compiled.applications_by_id,
        compiled.distributed_outputs)
    return bindings
end

function closed_registry_model(model)
    previous = model.registry
    registry = PSE.ObjectRegistry(PSE._closed_object_family_store(previous.objects),
        previous.by_scale, previous.by_kind, previous.by_species,
        previous.ancestor_ids_by_object)
    return PSE.CompositeModel(registry, model.applications, model.environment,
        model.instances, model.source_adapter, model.status_conversion,
        model.status_conversion_records, model.status_source_owners,
        model.status_source_identities, model.scenario_plan_cache,
        model.binding_cache, model.environment_binding_cache, model.bindings_dirty,
        model.environment_bindings_dirty, model.lifecycle_delta,
        model.input_default_status_variables, model.runtime_revision,
        model.revision, model.environment_revision)
end

@testset "prepared routes retain fresh producer policies and closed identity types" begin
    policy = Ref{PSE.SchedulePolicy}(HoldLast())
    model = pair_model(; policy)
    simulation = run!(model; outputs=:none)
    compiled = simulation.compiled
    application, recipe = reader_recipe(compiled)
    first = materialize_reader(model, compiled, application, recipe)
    @test all(binding.policy isa HoldLast for binding in first)
    policy[] = Aggregate()
    next = materialize_reader(model, compiled, application, recipe)
    @test all(binding.policy isa Aggregate for binding in next)
    @test all(binding.carrier_hint === :temporal_stream for binding in next)
    @test all(binding.policy isa HoldLast for binding in first)
    @test all(input_carrier(old) === input_carrier(new) for (old, new) in zip(first, next))

    closed = closed_registry_model(model)
    bindings = materialize_reader(closed, compiled, application, recipe)
    @test all(binding.source_ids isa Vector{ObjectId{Int}} for binding in bindings)
    @test all(binding.consumer_id isa ObjectId{Int} for binding in bindings)
    @test all(binding.source_ids == [ObjectId(1)] for binding in bindings)
    for binding in bindings
        source = binding.input === :left ? :x : :y
        @test input_carrier(binding) === PSE.refvalue(model_status(closed, 1), source)
    end
    @test_throws ArgumentError PSE._input_binding_source_ids(closed.registry.objects,
        [ObjectId(:unadmitted_identity_type)])
end

end
