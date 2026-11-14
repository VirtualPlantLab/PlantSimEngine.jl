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
    initial_many = check_carriers(data, simulation)
    @test isempty(initial_many.carrier)
    totals = [advance!(data, simulation)]
    birth!(data.model, :leaf_1, 7.0)
    push!(totals, advance!(data, simulation))
    observe_families!(families, simulation)
    future = binding(simulation, :a, :values)
    @test typeof(future) in initial_families
    @test future.carrier === initial_many.carrier
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
    input_cache = simulation.compiled.input_bindings_by_target
    @test valtype(input_cache) === Vector{eltype(prototype)}
    @test isconcretetype(valtype(input_cache))
    @test simulation.compiled.input_bindings !== prototype
    @test eltype(simulation.compiled.input_bindings) === eltype(prototype)
    @test isempty(check_carriers(data, simulation).carrier)
    totals = [advance!(data, simulation)]
    first_reference = birth!(data.model, :leaf_1, 7.0)
    push!(totals, advance!(data, simulation))
    first = check_carriers(data, simulation)
    @test simulation.compiled.input_bindings_by_target === input_cache
    @test any(cached -> cached === first, input_cache[(:reader, ObjectId(:a))])
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

    incomplete = storage_prototype(filter(B -> B !== typeof(control.future), control.families))
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

@testset "observed manual call owners keep the real closed identity domain" begin
    ordinary = fixture(; called=true)
    baseline = prepare(ordinary.model)
    @test advance!(ordinary, baseline) == (3.0, 3.0)
    expected_index = baseline.compiled.observed_manual_call_binding_indices_by_callee_target

    data = fixture(; called=true)
    prepare(data.model) # Close only the actual complete statuses on these objects.
    previous = data.model.registry
    registry = PSE.ObjectRegistry(PSE._closed_object_family_store(previous.objects),
        previous.by_scale, previous.by_kind, previous.by_species,
        previous.ancestor_ids_by_object)
    original = data.model
    model = PSE.CompositeModel(registry, original.applications, original.environment,
        original.instances, original.source_adapter, original.status_conversion,
        original.status_conversion_records, original.status_source_owners,
        original.status_source_identities, nothing, nothing, nothing, true,
        true, original.lifecycle_delta,
        original.input_default_status_variables, original.runtime_revision,
        original.revision, original.environment_revision)
    @test all(model_object(model, id) === model_object(original, id)
        for id in (:scene, :anchor, :a, :b))
    closed = merge(data, (; model))
    simulation = prepare(model)
    @test advance!(closed, simulation) == (3.0, 3.0)
    index = simulation.compiled.observed_manual_call_binding_indices_by_callee_target
    @test keytype(index) === Tuple{Symbol,ObjectId{Symbol}}
    @test Set(keys(index)) == Set(keys(expected_index))
    @test all(index[key] == values for (key, values) in expected_index)
    @test Set(keys(index)) == Set(((:reader, ObjectId(:a)), (:reader, ObjectId(:b))))
    check_carriers(closed, simulation)

    before = (model_status(model, :a).total, model_status(model, :b).total,
        model_status(model, :scene).visits, model_status(model, :anchor).x)
    changed = Set{Tuple{Symbol,ObjectId{Symbol}}}()
    callees = Set(((:reader, ObjectId(:a)),))
    @test PSE._propagate_changed_manual_call_owners!(model.registry.objects,
        changed, callees, simulation.compiled.call_bindings, index) === changed
    @test changed == Set(((:capture, ObjectId(:scene)),))
    @test (model_status(model, :a).total, model_status(model, :b).total,
        model_status(model, :scene).visits, model_status(model, :anchor).x) === before
    check_carriers(closed, simulation)
end

@testset "new consumers compile only their original partial target selection" begin
    data = fixture()
    simulation = prepare(data.model)
    old_bindings = copy(simulation.compiled.input_bindings)
    shared = check_carriers(data, simulation)
    register_object!(data.model, Object(:c; scale=:Reader, parent=:scene,
        status=Status(total=0.0)))
    continue!(simulation; steps=0)

    @test length(simulation.compiled.input_bindings) == length(old_bindings) + 2
    @test all(actual === previous for (actual, previous) in
        zip(simulation.compiled.input_bindings, old_bindings))
    @test binding(simulation, :c, :single).carrier ===
        PSE.refvalue(model_status(data.model, :anchor), :x)
    @test binding(simulation, :c, :values).carrier === shared.carrier
    @test binding(simulation, :c, :values).source_ids === shared.source_ids
    step!(simulation)
    @test model_status(data.model, :c).total == 3.0
    check_carriers(data, simulation)
end

function scope_cache_fixture(selector)
    return CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant_a; scale=:Plant, parent=:scene),
        Object(:plant_b; scale=:Plant, parent=:scene),
        Object(:anchor; scale=:Anchor, parent=:scene, status=Status(x=3f0)),
        Object(:a; scale=:Reader, parent=:plant_a),
        Object(:b; scale=:Reader, parent=:plant_b),
        Object(:first; scale=:Leaf, parent=:plant_a, status=Status(x=7.0)),
        Object(:second; scale=:Leaf, parent=:plant_b, status=Status(x=11.0));
        applications=(ModelSpec(Reader(); name=:reader, on=Many(scale=:Reader),
            inputs=(single=One(id=:anchor, within=SceneScope(), var=:x, from_status=true),
                values=selector)),))
end

@testset "Many scope anchors preserve shared columns and consumer-specific ancestors" begin
    for (selector, shared, expected_b) in (
        (Many(Scope(ObjectId(:plant_a)); scale=:Leaf, var=:x, from_status=true),
            true, (10.0, 15.0, 8.0)),
        (Many(Ancestor(scale=:Plant); scale=:Leaf, var=:x, from_status=true),
            false, (14.0, 14.0, 14.0)),
    )
        model = scope_cache_fixture(selector)
        simulation = run!(model; steps=1, outputs=:all)
        for phase in 1:3
            if phase == 2
                register_object!(model, Object(:new; scale=:Leaf, parent=:plant_a,
                    status=Status(x=5.0)))
                continue!(simulation; steps=1)
            elseif phase == 3
                remove_object!(model, :first)
                continue!(simulation; steps=1)
            end
            first = binding(simulation, :a, :values)
            second = binding(simulation, :b, :values)
            @test (first.carrier === second.carrier) === shared
            @test (first.source_ids === second.source_ids) === shared
            @test model_status(model, :a).total == (10.0, 15.0, 8.0)[phase]
            @test model_status(model, :b).total == expected_b[phase]
            for current in (first, second)
                expected_count = current.consumer_id == ObjectId(:a) || shared ?
                    (1, 2, 1)[phase] : 1
                @test length(current.source_ids) == length(parent(current.carrier)) == expected_count
                @test all(reference === PSE.refvalue(model_status(model, id), :x)
                    for (id, reference) in zip(current.source_ids, parent(current.carrier)))
            end
        end
        @test outputs(simulation)[(:reader, ObjectId(:a), :total)] ==
            [(1.0, 10.0), (2.0, 15.0), (3.0, 8.0)]
        @test outputs(simulation)[(:reader, ObjectId(:b), :total)] ==
            [(Float64(step), expected_b[step]) for step in 1:3]
    end
end

@testset "partial applications retain their exact target selection and metadata owner" begin
    data = fixture()
    simulation = prepare(data.model)
    owner = simulation.compiled.applications_by_id
    current = owner[:reader]
    partial = PSE._partial_model_application(current, [ObjectId(:a)])
    targets = partial.target_ids
    @test typeof(partial) === typeof(current)
    @test PSE._with_model_application(identity, owner, partial) === partial
    @test partial.target_ids === targets
    @test partial.target_ids == [ObjectId(:a)]
    @test current.target_ids == [ObjectId(:a), ObjectId(:b)]

    # Keep exactly the same application type and ID while changing the plan.
    plan = current.plan
    fields = ntuple(index -> index == 1 ? plan.slot + 1 : getfield(plan, index),
        fieldcount(typeof(plan)))
    foreign_plan = typeof(plan)(fields...)
    foreign = typeof(current)(foreign_plan, targets)
    @test typeof(foreign) === typeof(current)
    @test foreign.id === current.id
    @test foreign.plan !== current.plan
    visits = Ref(0)
    @test_throws "outside its compiled metadata owner" PSE._with_model_application(
        owner, foreign) do application
        visits[] += 1
    end
    @test visits[] == 0
    @test partial.target_ids === targets
    check_carriers(data, simulation)
end

end # module ModelInputBindingStorageChecks
