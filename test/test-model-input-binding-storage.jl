module ModelInputBindingStorageChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine

PSE.@process "input_binding_storage_reader" verbose=false
PSE.@process "input_binding_storage_capture" verbose=false

struct Reader <: AbstractInput_Binding_Storage_ReaderModel end
PSE.inputs_(::Reader) = (single=Required(Float32), values=Default(Float64[]))
PSE.outputs_(::Reader) = (total=0.0,)
function PSE.run!(::Reader, status, environment, constants, context)
    status.total = Float64(status.single) + sum(bound_input(context, :values); init=0.0)
    return nothing
end

struct Capture <: AbstractInput_Binding_Storage_CaptureModel
    context::Base.RefValue{Any}
end
PSE.inputs_(::Capture) = NamedTuple()
PSE.outputs_(::Capture) = (visits=0,)
function PSE.run!(model::Capture, status, environment, constants, context)
    model.context[] = context
    status.visits += 1
    return nothing
end

function fixture(; called=false)
    capture = Ref{Any}(nothing)
    reader = ModelSpec(Reader(); name=:reader, on=Many(scale=:Reader), inputs=(
        single=One(id=:anchor, within=SceneScope(), var=:x, from_status=true),
        values=Many(scale=:Leaf, within=SceneScope(), var=:x, from_status=true),
    ))
    applications = called ? (
        ModelSpec(Capture(capture); name=:capture, on=One(id=:scene), calls=(
            readers=Many(scale=:Reader, within=Subtree(), application=:reader),)),
        reader,
    ) : (reader,)
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:anchor; scale=:Anchor, parent=:scene, status=Status(x=3f0)),
        Object(:a; scale=:Reader, parent=:scene),
        Object(:b; scale=:Reader, parent=:scene);
        applications,
    )
    return (; model, capture, called)
end

prepare(model, prototype=nothing) = PSE._prepare_simulation!(model;
    steps=0, outputs=:none, constants=PSE.Constants(), input_binding_storage=prototype)

binding(simulation, object, input) = only(binding for binding in simulation.compiled.input_bindings
    if binding.consumer_id == ObjectId(object) && binding.input === input)

function observe_families!(families, simulation)
    for binding in simulation.compiled.input_bindings
        B = typeof(binding)
        B in families || push!(families, B)
    end
    return families
end

storage_prototype(families) = Vector{Union{families...}}()

function check_carriers(data, simulation)
    anchor = PSE.refvalue(model_status(data.model, :anchor), :x)
    first, second = binding(simulation, :a, :values), binding(simulation, :b, :values)
    @test binding(simulation, :a, :single).carrier === anchor
    @test binding(simulation, :b, :single).carrier === anchor
    @test first.carrier === second.carrier
    @test first.source_ids === second.source_ids
    @test all(reference === PSE.refvalue(model_status(data.model, id), :x)
        for (id, reference) in zip(first.source_ids, parent(first.carrier)))
    return first
end

function advance!(data, simulation)
    step!(simulation)
    data.called && run_call!(data.capture[], :readers; publish=true)
    return (model_status(data.model, :a).total, model_status(data.model, :b).total)
end

function birth!(model, id, value)
    status = Status(x=value)
    register_object!(model, Object(id; scale=:Leaf, parent=:scene, status))
    return PSE.refvalue(status, :x)
end

# Record all real raw bindings, including One, before and after actual births.
# This deliberately does not infer a family from a batch or a model default.
function ordinary_control(; called=false)
    data = fixture(; called)
    simulation = prepare(data.model)
    families = observe_families!(DataType[], simulation)
    initial_families = copy(families)
    @test eltype(simulation.compiled.input_bindings) === PSE.CompiledModelInputBinding
    @test isempty(check_carriers(data, simulation).carrier)
    totals = [advance!(data, simulation)]
    birth!(data.model, :leaf_1, 7.0)
    push!(totals, advance!(data, simulation))
    observe_families!(families, simulation)
    future = binding(simulation, :a, :values)
    @test !(typeof(future) in initial_families)
    first = check_carriers(data, simulation)
    carrier, source_ids = first.carrier, first.source_ids
    birth!(data.model, :leaf_2, 11.0)
    push!(totals, advance!(data, simulation))
    observe_families!(families, simulation)
    current = check_carriers(data, simulation)
    @test current.carrier === carrier
    @test current.source_ids === source_ids
    @test totals == [(3.0, 3.0), (10.0, 10.0), (21.0, 21.0)]
    return (; families, initial_families, future, totals)
end

@testset "real One and shared Many families close before compilation" begin
    control = ordinary_control()
    prototype = storage_prototype(control.families)
    data = fixture()
    simulation = prepare(data.model, prototype)
    @test simulation.compiled.input_bindings !== prototype
    @test eltype(simulation.compiled.input_bindings) === eltype(prototype)
    @test isempty(check_carriers(data, simulation).carrier)
    totals = [advance!(data, simulation)]
    first_reference = birth!(data.model, :leaf_1, 7.0)
    push!(totals, advance!(data, simulation))
    first = check_carriers(data, simulation)
    @test only(parent(first.carrier)) === first_reference
    carrier, source_ids = first.carrier, first.source_ids
    second_reference = birth!(data.model, :leaf_2, 11.0)
    push!(totals, advance!(data, simulation))
    current = check_carriers(data, simulation)
    @test current.carrier === carrier
    @test current.source_ids === source_ids
    @test all(actual === expected for (actual, expected) in
        zip(parent(current.carrier), (first_reference, second_reference)))
    @test totals == control.totals
    @test all(binding -> typeof(binding) in control.families,
        simulation.compiled.input_bindings)
    @test isempty(prototype)

    incomplete = storage_prototype(control.initial_families)
    @test_throws "outside its prepared storage family" PSE._with_model_input_binding(
        identity, incomplete, control.future)
end

@testset "explicit storage is admitted even after a clean zero-step preparation" begin
    control = ordinary_control()
    data = fixture()
    previous = prepare(data.model)
    anchor = PSE.refvalue(model_status(data.model, :anchor), :x)
    prototype = storage_prototype(control.families)
    current = prepare(data.model, prototype)
    @test current.compiled !== previous.compiled
    @test current.compiled.input_bindings !== previous.compiled.input_bindings
    @test eltype(current.compiled.input_bindings) === eltype(prototype)
    @test current_step(current) == 0
    @test PSE.refvalue(model_status(data.model, :anchor), :x) === anchor
    check_carriers(data, current)
    @test isempty(prototype)

    nonempty = [control.future]
    @test_throws "Input binding storage must be an empty prototype" prepare(fixture().model, nonempty)
end

@testset "zero input plans use the real empty binding family" begin
    model = CompositeModel(Object(:only; status=Status(value=1f0)))
    prototype = Vector{Union{}}()
    simulation = prepare(model, prototype)
    @test simulation.compiled.input_bindings isa Vector{Union{}}
    @test simulation.compiled.input_bindings !== prototype
    @test isempty(simulation.compiled.input_bindings)
    step!(simulation)
    @test current_step(simulation) == 1
    @test model_status(model, :only).value === 1f0
    @test isempty(prototype)
end

@testset "targeted calls keep the admitted input storage and live references" begin
    control = ordinary_control(; called=true)
    data = fixture(; called=true)
    prototype = storage_prototype(control.families)
    simulation = prepare(data.model, prototype)
    step!(simulation)
    reference = birth!(data.model, :leaf_1, 7.0)
    step!(simulation)
    selected = call_targets(data.capture[], :readers; objects=(:a,))
    target = only(selected)
    @test target.object_id === ObjectId(:a)
    @test PSE.refvalue(target.status, :single) === PSE.refvalue(model_status(data.model, :anchor), :x)
    @test only(parent(target.status.values)) === reference
    run_call!(target; publish=true)
    @test model_status(data.model, :a).total == 10.0
    @test model_status(data.model, :b).total == 0.0
    @test eltype(simulation.compiled.input_bindings) === eltype(prototype)
    check_carriers(data, simulation)
    @test isempty(prototype)
end

end # module ModelInputBindingStorageChecks
