module SharedInputRecipeChecks

using Dates, PlantSimEngine, Test
using PlantSimEngine.Diagnostics
const PSE = PlantSimEngine

PSE.@process "input_recipe_writer" verbose=false
PSE.@process "input_recipe_pair_reader" verbose=false
include("fixtures/raw_status_readers.jl")

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
        application.id)
    return application, recipe
end

@testset "canonical input recipes preserve named application slots and shared live refs" begin
    model = pair_model()
    simulation = run!(model; outputs=:all)
    compiled = simulation.compiled
    scenario = compiled.scenario_plan
    application, recipe = reader_recipe(compiled)
    selector = One(id=1, within=SceneScope(), application=:source, var=:x)
    @test (@inferred PSE._model_selector_policy(selector,
        compiled.applications_by_id, [:source], :x)) isa HoldLast
    @test_throws "No compiled model application with id `missing`" PSE._model_policy_from_source_application(
        compiled.applications_by_id, :missing, :x)
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
    # Binding consumes the one prepared recipe table. It never reconstructs
    # logical routes while obtaining the same canonical reference carriers.
    fresh = PSE._compile_model_input_bindings(model, compiled.applications,
        scenario.manual_application_ids, scenario.input_recipes_by_application)
    @test binding_signature(fresh) == binding_signature(compiled.input_bindings)
    @test all(input_carrier(binding) === PSE.refvalue(model_status(model, 1),
        binding.input === :left ? :x : :y) for binding in fresh)
end

@testset "restaging admitted scalar and Many inputs retains official cells" begin
    many_model = CompositeModel(Object(:reader; scale=:Reader),
        Object(:source; scale=:Leaf);
        applications=(
            ModelSpec(Writer(3f0); name=:source, on=One(id=:source)),
            ModelSpec(AggregateReader(); name=:aggregate, on=One(id=:reader),
                inputs=(values=Many(SceneScope(); scale=:Leaf,
                    application=:source, var=:x),)),
        ), environment=(duration=Hour(1),))
    for model in (pair_model(), many_model)
        simulation = run!(model; steps=0, outputs=:all)
        compiled = simulation.compiled
        # The finite owner contains only the real bindings just compiled here.
        B = Union{map(typeof, compiled.input_bindings)...}
        bindings = Vector{B}(compiled.input_bindings)
        statuses = Dict(id => model_status(model,id) for id in keys(model.registry.objects))
        references = Dict((binding.application_id,binding.consumer_id,binding.input) =>
            PSE.refvalue(statuses[binding.consumer_id],binding.input) for binding in bindings)
        before = copy(model.status_conversion_records)
        PSE._prepare_model_input_statuses_batched!(model,compiled.applications,
            compiled.applications_by_id,bindings; final_references=references)
        @test all(model_status(model,id) === status for (id,status) in statuses)
        @test all(PSE.refvalue(model_status(model,binding.consumer_id),binding.input) ===
            references[(binding.application_id,binding.consumer_id,binding.input)] for binding in bindings)
        @test model.status_conversion_records == before
        continue!(simulation)
        if model === many_model
            @test input_carrier(only(bindings)) isa PSE.RefVector{Float32}
            @test model_status(model,:reader).total === 3.0
            @test outputs(simulation)[(:aggregate,ObjectId(:reader),:total)] == [(1.0,3.0)]
        else
            @test model_status(model,2).total === 6f0
            @test outputs(simulation)[(:reader,ObjectId(2),:total)] == [(1.0,6f0)]
        end
    end
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
    @test carrier === old_carrier
    @test Set(binding.source_ids) == Set((ObjectId(1), ObjectId(:new_leaf)))
    @test isempty(binding.source_application_ids)
    for (id, reference) in zip(binding.source_ids, parent(carrier))
        @test reference === PSE.refvalue(model_status(model, id), :x)
    end
    @test first_ref[] isa Float32
    @test PSE.refvalue(second, :x)[] isa Float64
    first_ref[] = 7f0
    @test first.x === 7f0
    @test old_carrier[findfirst(isequal(ObjectId(1)), binding.source_ids)] === 7f0
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

@testset "input refresh references use the closed mixed identity domain" begin
    organ = (:tree, :leaf, 1)
    model = PSE._with_object_id_domain(CompositeModel(
        Object(:source; scale=:Leaf), Object(:reader; scale=:Reader),
        Object(organ; scale=:Reader);
        applications=(
            ModelSpec(Writer(2f0); name=:source, on=One(id=:source)),
            ModelSpec(PairReader{Float32}(); name=:reader, on=Many(scale=:Reader),
                inputs=(left=One(SceneScope(); id=:source, var=:x),
                    right=One(SceneScope(); id=:source, var=:y))),
        ), environment=(duration=Hour(1),)))
    simulation = run!(model; steps=0, outputs=:all)
    bindings = simulation.compiled.input_bindings
    references = PSE._model_input_status_references(model.registry.objects, bindings)
    I = keytype(model.registry.objects)
    @test I === Union{ObjectId{Symbol},ObjectId{Tuple{Symbol,Symbol,Int}}}
    @test keytype(references) === Tuple{Symbol,I,Symbol}
    @test length(references) == 4
    for binding in bindings
        key = (binding.application_id, binding.consumer_id, binding.input)
        @test references[key] === input_carrier(binding)
    end
    continue!(simulation)
    @test model_status(model,:reader).total === 6f0
    @test model_status(model,organ).total === 6f0
    newborn = (:tree, :leaf, 2)
    register_object!(model, Object(newborn; scale=:Reader))
    step!(simulation)
    @test model_status(model,newborn).total === 6f0
    @test outputs(simulation)[(:reader,ObjectId(newborn),:total)] == [(2.0,6f0)]
    for (key, reference) in references
        @test reference === PSE.refvalue(model_status(model,key[2]),key[3])
    end
    refreshed = PSE._model_input_status_references(model.registry.objects,
        simulation.compiled.input_bindings)
    @test length(refreshed) == 6
    for variable in (:left, :right)
        @test refreshed[(:reader,ObjectId(newborn),variable)] ===
            PSE.refvalue(model_status(model,newborn),variable)
    end
end

@testset "prepared routes retain fresh producer policies and closed identity types" begin
    policy = Ref{PSE.SchedulePolicy}(HoldLast())
    model = pair_model(; policy)
    closed = PSE._with_object_id_domain(model)
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

@testset "Retry a pending leaf after its required writer appears" begin
    model = CompositeModel(Object(1; scale=:Scene); applications=(
        ModelSpec(Writer(2f0); name=:source, on=One(id=1)),
        ModelSpec(Writer(4f0); name=:later, on=Many(scale=:Extra)),
        ModelSpec(PairReader{Float32}(); name=:reader, on=Many(scale=:Leaf),
            inputs=(left=One(SceneScope(); id=1, var=:x, application=:source),
                right=One(SceneScope(); scale=:Extra, var=:y, application=:later))),
    ))
    simulation = run!(model; steps=0, outputs=:all)
    compiled = simulation.compiled
    reader = compiled.applications_by_id[:reader]
    root = model_status(model, 1)
    source = PSE.refvalue(root, :x)
    leaf = ObjectId(2)
    register_object!(model, Object(leaf; scale=:Leaf, parent=1))
    initial_leaf = model_status(model, leaf)
    for attempt in 1:2
        @test_throws "Expected exactly one object" PSE.continue!(simulation; steps=1)
        @test current_step(simulation) == 0
        @test simulation.compiled === compiled
        @test isempty(reader.target_ids)
        @test isempty(get(compiled.applications_by_object, leaf, ()))
        @test isempty(compiled.input_bindings)
        @test !haskey(compiled.input_bindings_by_target, (:reader, leaf))
        @test !haskey(compiled.status_views_by_target, (:reader, leaf))
        @test model_status(model, leaf) === initial_leaf
        @test PSE.refvalue(model_status(model, 1), :x) === source
    end
    register_object!(model, Object(3; scale=:Extra, parent=1))
    step!(simulation)
    @test current_step(simulation) == 1
    @test reader.target_ids == [leaf]
    @test only(simulation.compiled.applications_by_object[leaf]).id === :reader
    current = simulation.compiled
    bindings = current.input_bindings_by_target[(:reader, leaf)]
    @test getproperty.(bindings, :input) == [:left, :right]
    @test all(i -> current.input_bindings[i] === bindings[i], eachindex(bindings))
    @test bindings[1].carrier === source
    @test bindings[2].carrier === PSE.refvalue(model_status(model, 3), :y)
    @test PSE.refvalue(current.status_views_by_target[(:reader, leaf)].status, :left) === source
    @test model_status(model, leaf).total === 10f0
end

@testset "A refused carrier leaves no writer or binding to the new leaf" begin
    function make_scene(populated)
        objects = Object[Object(1; scale=:Scene)]
        populated && push!(objects, Object(2; scale=:Leaf, parent=1))
        return CompositeModel(objects...; applications=(
            ModelSpec(Writer(2f0); name=:source, on=One(id=1)),
            ModelSpec(PairReader{Float32}(); name=:reader, on=Many(scale=:Leaf),
                inputs=(left=One(SceneScope(); id=1, var=:x),
                    right=One(SceneScope(); id=1, var=:y))),
        ))
    end
    reference = run!(make_scene(true); steps=0, outputs=:none)
    left = only(b for b in reference.compiled.input_bindings if b.input === :left)
    model = make_scene(false)
    sim = PSE._prepare_simulation!(model; steps=0, outputs=:none, constants=PSE.Constants(),
        input_binding_storage=Vector{typeof(left)}())
    register_object!(model, Object(2; scale=:Leaf, parent=1))
    for attempt in 1:2
        @test_throws MethodError PSE.continue!(sim; steps=0)
        @test current_step(sim) == 0
        @test isempty(sim.compiled.input_bindings)
        @test isempty(sim.compiled.applications_by_id[:reader].target_ids)
        @test !haskey(sim.compiled.applications_by_object, ObjectId(2))
        @test !haskey(sim.compiled.status_views_by_target, (:reader, ObjectId(2)))
        @test isnothing(model_status(model, 2))
    end
end

@testset "Healing a valid selection with a missing writer" begin
    model = CompositeModel(Object(1; scale=:Scene), Object(3; scale=:Extra, kind=:wrong, parent=1);
        applications=(
            ModelSpec(Writer(2f0); name=:source, on=One(id=1)),
            ModelSpec(Writer(4f0); name=:later, on=Many(scale=:Extra, kind=:green)),
            ModelSpec(PairReader{Float32}(); name=:reader, on=Many(scale=:Leaf),
                inputs=(left=One(SceneScope(); id=1, var=:x, application=:source),
                    right=One(SceneScope(); scale=:Extra, var=:y, application=:later))),
        ))
    sim = run!(model; steps=0, outputs=:none)
    register_object!(model, Object(2; scale=:Leaf, parent=1))
    previous = nothing
    for attempt in 1:2
        caught = try
            PSE.continue!(sim; steps=1)
            nothing
        catch err
            sprint(showerror, err)
        end
        @test caught isa String
        @test !occursin("Ambiguous canonical writers", something(caught, ""))
        isnothing(previous) || @test caught == previous
        previous = caught
        @test isempty(sim.compiled.input_bindings)
        @test isempty(sim.compiled.applications_by_id[:reader].target_ids)
        @test !haskey(sim.compiled.applications_by_object, ObjectId(2))
        @test isnothing(model_status(model, 2))
        @test current_step(sim) == 0
    end
    remove_object!(model, 3)
    register_object!(model, Object(4; scale=:Extra, kind=:green, parent=1))
    step!(sim)
    @test current_step(sim) == 1
    @test model_status(model, 2).total === 10f0
    @test length(sim.compiled.input_bindings) == 2
    @test only(sim.compiled.applications_by_object[ObjectId(2)]).id === :reader
end

@testset "A refused leaf preserves the existing Many carrier and publication history" begin
    model = CompositeModel(Object(1; scale=:Scene); applications=(
        ModelSpec(Writer(2.0); name=:source, on=One(id=1)),
        ModelSpec(Writer(4.0); name=:later, on=Many(scale=:Extra)),
        ModelSpec(PairReader{Float64}(); name=:reader, on=Many(scale=:Leaf),
            inputs=(left=One(SceneScope(); id=1, var=:x, application=:source),
                right=One(SceneScope(); scale=:Extra, var=:y, application=:later))),
        ModelSpec(AggregateReader(); name=:sum, on=One(id=1),
            inputs=(values=Many(scale=:Leaf, within=SceneScope(), application=:reader, var=:total),)),
    ))
    sim = run!(model; steps=1, outputs=:all)
    original = only(sim.compiled.input_bindings)
    carrier = original.carrier
    samples = copy(outputs(sim)[(:sum, ObjectId(1), :total)])
    register_object!(model, Object(2; scale=:Leaf, parent=1))
    for attempt in 1:2
        @test_throws "Expected exactly one object" PSE.continue!(sim; steps=1)
        @test current_step(sim) == 1
        @test only(sim.compiled.input_bindings) === original
        @test isempty(original.source_ids)
        @test isempty(carrier)
        @test outputs(sim)[(:sum, ObjectId(1), :total)] == samples
        @test isempty(sim.compiled.applications_by_id[:reader].target_ids)
        @test isnothing(model_status(model, 2))
    end
    register_object!(model, Object(3; scale=:Extra, parent=1))
    step!(sim)
    @test current_step(sim) == 2
    @test original.carrier === carrier
    @test only(parent(carrier)) === PSE.refvalue(model_status(model, 2), :total)
    @test original.source_ids == [ObjectId(2)]
    @test model_status(model, 2).total === 10.0
    @test model_status(model, 1).total === 10.0
    @test outputs(sim)[(:sum, ObjectId(1), :total)] == [samples; [(2.0,10.0)]]
end


@testset "Existing raw-status input rejects a new leaf without publishing its membership" begin
    model = CompositeModel(Object(1; scale=:Scene),
        Object(2; scale=:Leaf, parent=1, status=Status(x=2.0)); applications=(
            ModelSpec(EmptyModel(); name=:tag, on=Many(scale=:Leaf)),
            ModelSpec(AggregateReader(); name=:sum, on=One(id=1),
                inputs=(values=Many(scale=:Leaf, within=SceneScope(), from_status=true, var=:x),)),
        ))
    sim = run!(model; steps=1, outputs=:all)
    original = only(sim.compiled.input_bindings)
    old_cell = only(parent(original.carrier))
    samples = copy(outputs(sim)[(:sum, ObjectId(1), :total)])
    register_object!(model, Object(3; scale=:Leaf, parent=1, status=Status()))
    for attempt in 1:2
        @test_throws "no source `Status` reference is available" PSE.continue!(sim; steps=1)
        @test current_step(sim) == 1
        @test sim.compiled.applications_by_id[:tag].target_ids == [ObjectId(2)]
        @test !haskey(sim.compiled.applications_by_object, ObjectId(3))
        @test only(sim.compiled.input_bindings) === original
        @test only(parent(original.carrier)) === old_cell
        @test original.source_ids == [ObjectId(2)]
        @test outputs(sim)[(:sum, ObjectId(1), :total)] == samples
    end
    remove_object!(model, 3)
    register_object!(model, Object(4; scale=:Leaf, parent=1, status=Status(x=4.0)))
    step!(sim)
    @test current_step(sim) == 2
    @test model_status(model, 1).total === 6.0
    @test outputs(sim)[(:sum, ObjectId(1), :total)] == [samples; [(2.0, 6.0)]]
    new = only(sim.compiled.input_bindings)
    @test new.source_ids == ObjectId.([2, 4])
    @test parent(new.carrier)[1] === old_cell
    @test parent(new.carrier)[2] === PSE.refvalue(model_status(model, 4), :x)
end


@testset "A refused reader keeps conversions pending until its inputs are admitted" begin
    model = CompositeModel(Object(1; scale=:Scene);
        type_promotion=Dict(Float64 => Float32), applications=(
            ModelSpec(Writer(2.0); name=:source, on=One(id=1), output_routing=(x=:stream_only,)),
            ModelSpec(Writer(4.0); name=:later, on=Many(scale=:Extra)),
            ModelSpec(PairReader{Float64}(); name=:reader, on=Many(scale=:Leaf),
                inputs=(left=One(SceneScope(); id=1, var=:x, application=:source),
                    right=One(SceneScope(); scale=:Extra, var=:y, application=:later))),
        ))
    sim = run!(model; steps=0, outputs=:all)
    register_object!(model, Object(2; scale=:Leaf, parent=1))
    before = copy(model.status_conversion_records)
    key = (:stream_only_source_default, :source, ObjectId(1), :x)
    @test !haskey(before, key)
    for attempt in 1:2
        @test_throws "Expected exactly one object" PSE.continue!(sim; steps=1)
        @test model.status_conversion_records == before
        @test isempty(sim.compiled.input_bindings)
        @test isnothing(model_status(model, 2))
        @test current_step(sim) == 0
    end
    register_object!(model, Object(3; scale=:Extra, parent=1))
    step!(sim)
    @test current_step(sim) == 1
    @test model.status_conversion_records[key].effective_type === Float32
    @test haskey(model.status_conversion_records, (:model_output_default, :reader, ObjectId(2), :total))
    @test model_status(model, 2).total === 10f0
end

end
