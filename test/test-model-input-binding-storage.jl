module ModelInputBindingStorageChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine

PSE.@process "input_binding_storage_reader" verbose=false
PSE.@process "input_binding_storage_capture" verbose=false

struct Reader{T} <: AbstractInput_Binding_Storage_ReaderModel end
Reader() = Reader{Float64}()
PSE.inputs_(::Reader{T}) where {T} = (single=Required(Float32), values=Default(T[]))
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

@testset "direct Many extension stages every admitted reference before committing" begin
    data = fixture()
    simulation = prepare(data.model)
    current = binding(simulation, :a, :values)
    references, source_ids = parent(current.carrier), current.source_ids
    first = Status(x=7.0)
    second = Status(x=9f0)
    register_object!(data.model, Object(:first; scale=:Leaf, parent=:scene, status=first))
    # The unprepared numerical class is rejected before it can become active.
    @test_throws ArgumentError register_object!(data.model,
        Object(:second; scale=:Leaf, parent=:scene, status=second))
    @test !haskey(data.model.registry.objects,ObjectId(:second))
    register_object!(data.model,Object(:second;scale=:Leaf,parent=:scene))
    @test model_status(data.model,:second) === nothing
    # A valid first reference followed by genuine absence must not append either.
    @test !PSE._append_stable_many_source_references!(data.model, current,
        ObjectId[ObjectId(:first), ObjectId(:second)], nothing)
    @test parent(current.carrier) === references
    @test current.source_ids === source_ids
    @test isempty(references) && isempty(source_ids)
    @test PSE.refvalue(first, :x)[] === 7.0
    @test PSE.refvalue(second, :x)[] === 9f0
    @test check_carriers(data, simulation).carrier === current.carrier
end

@testset "from-status permissions retain source route and numerical configuration" begin
    model = CompositeModel(Object(:scene;scale=:Scene),
        Object(:root_a;parent=:scene),Object(:root_b;parent=:scene),
        Object(:anchor;scale=:Anchor,parent=:scene,status=Status(x=3f0)),
        Object(:reader_a;scale=:Reader,parent=:root_a),
        Object(:reader_b;scale=:Reader,parent=:root_b),
        Object(:leaf_a;scale=:Leaf,parent=:root_a,status=Status(x=5f0));
        applications=Tuple(ModelSpec(Reader{T}();name=name,on=One(id=id),inputs=(
            single=One(id=:anchor,within=SceneScope(),var=:x,from_status=true),
            values=Many(scale=:Leaf,within=Scope(ObjectId(root)),var=:x,from_status=true),
        )) for (T,name,id,root) in ((Float32,:reader_a,:reader_a,:root_a),
            (Float64,:reader_b,:reader_b,:root_b))))
    simulation = run!(model;steps=0,outputs=:all)
    first = model_status(model,:leaf_a)
    old_reference = PSE.refvalue(first,:x)
    # B's RT also keeps A's real Ref32 for reparenting. It is not a new RAW right.
    rt_b = binding(simulation,:reader_b,:values).plan.reference_types
    @test Base.RefValue{Float32} in fieldtypes(rt_b)
    bad = Status(x=7f0)
    identity_before = copy(model.status_source_identities)
    revision = model.revision
    @test_throws ArgumentError register_object!(model,
        Object(:bad;scale=:Leaf,parent=:root_b,status=bad))
    @test !haskey(model.registry.objects,ObjectId(:bad))
    @test model.status_source_identities == identity_before
    @test model.revision == revision
    good = Status(x=7.0)
    good_reference = PSE.refvalue(good,:x)
    register_object!(model,Object(:good;scale=:Leaf,parent=:root_b,status=good))
    step!(simulation)
    @test model_status(model,:leaf_a) === first
    @test PSE.refvalue(first,:x) === old_reference
    @test PSE.refvalue(model_status(model,:good),:x) === good_reference
    @test model_status(model,:reader_a).total == 8.0
    @test model_status(model,:reader_b).total == 10.0
    @test outputs(simulation)[(:reader_a,ObjectId(:reader_a),:total)] == [(1.0,8.0)]
    @test outputs(simulation)[(:reader_b,ObjectId(:reader_b),:total)] == [(1.0,10.0)]
    reparent_object!(model,:leaf_a,:root_b)
    step!(simulation)
    @test model_status(model,:leaf_a) === first
    @test PSE.refvalue(first,:x) === old_reference
    @test model_status(model,:reader_a).total == 3.0
    @test model_status(model,:reader_b).total == 15.0
    @test_throws ArgumentError register_object!(model,
        Object(:still_bad;scale=:Leaf,parent=:root_b,status=Status(x=9f0)))
    @test !haskey(model.registry.objects,ObjectId(:still_bad))
end

@testset "from-status routes preserve real array references in One and Many" begin
    anchor_storage, known_storage, born_storage = Float32[3], [5.0], [7.0]
    anchor_reference = Ref(anchor_storage,1)
    known_reference = Ref(known_storage,1)
    born_reference = Ref(born_storage,1)
    model = CompositeModel(Object(:scene;scale=:Scene),
        Object(:outside;parent=:scene),Object(:inside;parent=:scene),
        Object(:anchor;scale=:Anchor,parent=:scene,status=Status((x=anchor_reference,))),
        Object(:known;scale=:Leaf,parent=:outside,status=Status((x=known_reference,))),
        Object(:reader;scale=:Reader,parent=:inside);
        applications=(ModelSpec(Reader();name=:reader,on=One(id=:reader),inputs=(
            single=One(id=:anchor,within=SceneScope(),var=:x,from_status=true),
            values=Many(scale=:Leaf,within=Scope(ObjectId(:inside)),var=:x,from_status=true),
        )),))
    simulation = run!(model;steps=0,outputs=:all)
    single = binding(simulation,:reader,:single)
    many = binding(simulation,:reader,:values)
    @test typeof(anchor_reference) in fieldtypes(single.plan.reference_types)
    @test typeof(known_reference) in fieldtypes(many.plan.reference_types)
    @test single.carrier === anchor_reference
    @test PSE.refvalue(model_status(model,:reader),:single) === anchor_reference
    @test PSE.input_value(single) === 3f0
    carrier, source_ids = many.carrier, many.source_ids
    @test carrier isa PSE.ObjectRefVector && isempty(carrier)
    @test eltype(typeof(born_reference)) === Float64
    register_object!(model,Object(:born;scale=:Leaf,parent=:inside,
        status=Status((x=born_reference,))))
    @test PSE.refvalue(model_status(model,:born),:x) === born_reference
    step!(simulation)
    many = binding(simulation,:reader,:values)
    @test many.carrier === carrier && many.source_ids === source_ids
    @test only(parent(carrier)) === born_reference
    @test model_status(model,:reader).total === 10.0
    anchor_storage[1] = 4f0
    born_storage[1] = 9.0
    step!(simulation)
    @test PSE.refvalue(model_status(model,:anchor),:x) === anchor_reference
    @test PSE.refvalue(model_status(model,:reader),:single) === anchor_reference
    @test PSE.refvalue(model_status(model,:born),:x) === born_reference
    @test only(parent(binding(simulation,:reader,:values).carrier)) === born_reference
    @test PSE.input_value(binding(simulation,:reader,:single)) === 4f0
    @test model_status(model,:reader).total === 13.0
    @test outputs(simulation)[(:reader,ObjectId(:reader),:total)] == [(1.0,10.0),(2.0,13.0)]
end

@testset "abstract from-status value bounds preserve their finite real Ref classes" begin
    for T in (Real,Any)
        model = CompositeModel(Object(:scene;scale=:Scene),
            Object(:outside;parent=:scene),Object(:inside;parent=:scene),
            Object(:anchor;scale=:Anchor,parent=:scene,status=Status(x=3f0)),
            Object(:reader;scale=:Reader,parent=:inside),
            Object(:known32;scale=:Leaf,parent=:outside,status=Status(x=1f0)),
            Object(:known64;scale=:Leaf,parent=:outside,status=Status(x=2.0)),
            Object(:known_real;scale=:Leaf,parent=:outside,status=Status((x=Ref{Real}(3f0),))),
            Object(:known_any;scale=:Leaf,parent=:outside,status=Status((x=Ref{Any}(4f0),)));
            applications=(ModelSpec(Reader{T}();name=:reader,on=One(id=:reader),inputs=(
                single=One(id=:anchor,within=SceneScope(),var=:x,from_status=true),
                values=Many(scale=:Leaf,within=Scope(ObjectId(:inside)),var=:x,from_status=true),
            )),))
        simulation = run!(model;steps=0,outputs=:all)
        current = binding(simulation,:reader,:values)
        carrier, ids = current.carrier, current.source_ids
        @test isempty(carrier)
        statuses = [Status(x=5f0),Status(x=7.0),Status((x=Ref{Real}(9f0),))]
        T === Any && push!(statuses,Status((x=Ref{Any}(11f0),)))
        cells = [PSE.refvalue(status,:x) for status in statuses]
        for (index,status) in enumerate(statuses)
            id = Symbol(:born_,index)
            register_object!(model,Object(id;scale=:Leaf,parent=:inside,status))
            @test PSE.refvalue(model_status(model,id),:x) === cells[index]
        end
        # Any remains a finite prepared family, not permission to invent Ref{BigFloat}.
        @test_throws ArgumentError register_object!(model,
            Object(:unknown;scale=:Leaf,parent=:inside,status=Status(x=BigFloat(1))))
        @test !haskey(model.registry.objects,ObjectId(:unknown))
        step!(simulation)
        current = binding(simulation,:reader,:values)
        @test current.carrier === carrier && current.source_ids === ids
        @test all(actual === expected for (actual,expected) in zip(parent(carrier),cells))
        @test cells[1][] === 5f0 && cells[2][] === 7.0 && cells[3][] === 9f0
        T === Any && @test cells[4][] === 11f0
        @test model_status(model,:reader).total == (T === Any ? 35.0 : 24.0)
    end
end

@testset "all applicable from-status route reference bounds precede RAW fallback" begin
    model = CompositeModel(Object(:scene;scale=:Scene),
        Object(:anchor;scale=:Anchor,parent=:scene,status=Status(x=3f0)),
        Object(:reader_a;scale=:Reader,parent=:scene),Object(:reader_b;scale=:Reader,parent=:scene),
        Object(:leaf_a;scale=:Leaf,parent=:scene,status=Status(x=5f0));
        applications=(
            ModelSpec(Reader{Float32}();name=:reader_a,on=One(id=:reader_a),inputs=(
                single=One(id=:anchor,within=SceneScope(),var=:x,from_status=true),
                values=Many(scale=:Leaf,within=SceneScope(),var=:x,from_status=true))),
            ModelSpec(Reader{Float64}();name=:reader_b,on=One(id=:reader_b),inputs=(
                single=One(id=:anchor,within=SceneScope(),var=:x,from_status=true),
                values=Many(id=:future,within=SceneScope(),var=:x,from_status=true)))))
    simulation = prepare(model)
    @test fieldtypes(binding(simulation,:reader_b,:values).plan.reference_types) == (Base.RefValue{Float64},)
    reference = Status(x=9f0)
    @test_throws ArgumentError register_object!(model,
        Object(:future;scale=:Leaf,parent=:scene,status=reference))
    @test !haskey(model.registry.objects,ObjectId(:future))
    @test PSE.refvalue(reference,:x)[] === 9f0
    @test isempty(binding(simulation,:reader_b,:values).source_ids)
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
