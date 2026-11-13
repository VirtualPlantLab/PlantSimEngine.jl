module ResolvedInputMaterializationChecks

using Dates, PlantSimEngine, Test
const PSE = PlantSimEngine

PSE.@process "resolved_endpoint_source" verbose=false
PSE.@process "resolved_endpoint_reader" verbose=false
PSE.@process "resolved_endpoint_distributor" verbose=false

struct Source{T,P} <: AbstractResolved_Endpoint_SourceModel
    value::T
    policy::P
end
Source(value) = Source(value, nothing)
PSE.outputs_(model::Source{T}) where {T} = (x=zero(T),)
PSE.output_policy(model::Source) = isnothing(model.policy) ? NamedTuple() : (x=model.policy[],)
function PSE.run!(model::Source, status, environment, constants, context)
    status.x = model.value * oftype(model.value, context.time)
    return nothing
end

struct Reader{T} <: AbstractResolved_Endpoint_ReaderModel end
PSE.inputs_(::Reader{T}) where {T} = (x=Required(T),)
PSE.outputs_(::Reader{T}) where {T} = (seen=zero(T),)
PSE.run!(::Reader, status, environment, constants, context) = (status.seen=status.x; nothing)

struct Distributor{T} <: AbstractResolved_Endpoint_DistributorModel
    value::T
end
PSE.outputs_(model::Distributor{T}) where {T} = (x=Distributed(Default(zero(T))),)
function PSE.run!(model::Distributor, status, environment, constants, context)
    destinations = output_targets(context, (:x,))
    for index in eachindex(destinations.columns.x)
        destinations.columns.x[index] = model.value
    end
    return nothing
end

struct RequiredDistributor <: AbstractResolved_Endpoint_DistributorModel end
PSE.outputs_(::RequiredDistributor) = (x=Distributed(Required(Real)),)
PSE.run!(::RequiredDistributor, status, environment, constants, context) = nothing

struct ArraySource{A,C} <: AbstractResolved_Endpoint_SourceModel
    value::A
    declarations::C
end
function PSE.outputs_(model::ArraySource)
    model.declarations[] += 1
    return (x=model.value,)
end
PSE.run!(::ArraySource, status, environment, constants, context) = nothing

struct ArrayManyReader{T} <: AbstractResolved_Endpoint_ReaderModel
    initial::T
end
PSE.inputs_(::ArrayManyReader) = (x=Required(AbstractVector),)
PSE.outputs_(model::ArrayManyReader) = (seen=model.initial,)
function PSE.run!(model::ArrayManyReader, status, environment, constants, context)
    initial = zero(model.initial)
    status.seen = sum(array -> sum(array; init=initial), status.x; init=initial)
    return nothing
end

function point_scene(::Type{T}; policy=nothing, stream_only=false) where {T}
    return CompositeModel(Object(:source; scale=:Leaf), Object(:reader; scale=:Reader);
        applications=(
            ModelSpec(Source(T(2.5), policy); name=:source, on=One(id=:source),
                output_routing=stream_only ? (x=:stream_only,) : NamedTuple()),
            ModelSpec(Reader{T}(); name=:reader, on=One(id=:reader),
                inputs=(x=One(SceneScope(); id=:source, application=:source, var=:x),)),
        ), environment=(duration=Hour(1),))
end

@testset "resolved point endpoints keep live identity and fresh policy reads" begin
    for T in (Float32, Float64)
        policy = Ref{PSE.SchedulePolicy}(HoldLast())
        model = point_scene(T; policy)
        simulation = run!(model; steps=0, outputs=:none)
        compiled = simulation.compiled
        application = compiled.applications_by_id[:reader]
        plan = only(compiled.scenario_plan.input_plans_by_application.reader)
        sources = PSE._resolve_input_sources(model, ObjectId(:reader), plan,
            compiled.applications_by_object, compiled.applications_by_id,
            nothing, compiled.distributed_outputs)
        @test sources.source_ids == [ObjectId(:source)]
        @test sources.source_application_ids == [:source]
        first = PSE._materialize_input_route(model, :reader, application.process,
            ObjectId(:reader), plan, sources, compiled.applications_by_id)
        source_ref = PSE.refvalue(model_status(model, :source), :x)
        @test first.carrier === source_ref
        @test first.policy isa HoldLast
        policy[] = Aggregate()
        next = PSE._materialize_input_route(model, :reader, application.process,
            ObjectId(:reader), plan, sources, compiled.applications_by_id)
        @test next.carrier === source_ref
        @test next.policy isa Aggregate
        @test next.carrier_hint === :temporal_stream
        @test first.policy isa HoldLast
        source_ref[] = T(9)
        @test next.carrier[] === T(9)
    end
end

# Keep scalar outputs generic while testing vector-valued source carriers.
struct ManyReader{V,T} <: AbstractResolved_Endpoint_ReaderModel
    initial::T
end
PSE.inputs_(::ManyReader{V}) where {V} = (x=Required(V),)
PSE.outputs_(model::ManyReader) = (seen=model.initial,)
PSE.run!(model::ManyReader, status, environment, constants, context) =
    (status.seen=sum(status.x; init=zero(model.initial)); nothing)

@testset "absent declared producers have their Many family before first growth" begin
    for T in (Float32, Float64)
        model = CompositeModel(Object(:reader; scale=:Reader); applications=(
            ModelSpec(Source(T(2)); name=:source, on=Many(scale=:Leaf)),
            ModelSpec(ManyReader{AbstractVector,T}(zero(T)); name=:reader,
                on=One(id=:reader), inputs=(x=Many(SceneScope(); scale=:Leaf,
                    application=:source, var=:x),)),
        ), environment=(duration=Hour(1),))
        plan = only(model.scenario_plan_cache.program.input_records)
        @test plan.reference_types === Tuple{Base.RefValue{T}}
        @test fieldtype(typeof(plan), :reference_types) === Type{Tuple{Base.RefValue{T}}}
        simulation = run!(model; steps=0, outputs=:all)
        binding = only(simulation.compiled.input_bindings)
        carrier = binding.carrier
        status_type = typeof(model_status(model, :reader))
        binding_type = typeof(binding)
        @test carrier isa PSE.RefVector{T}
        @test isempty(carrier)
        register_object!(model, Object(:new_leaf; scale=:Leaf))
        continue!(simulation; steps=1)
        current = only(simulation.compiled.input_bindings)
        @test typeof(current) === binding_type
        @test current.carrier === carrier
        @test typeof(model_status(model, :reader)) === status_type
        @test model_status(model, :reader).seen === T(2)
        @test only(parent(carrier)) === PSE.refvalue(model_status(model, :new_leaf), :x)
        @test current.source_ids == [ObjectId(:new_leaf)]
    end
end

function array_scene(values, policy; existing)
    source = ArraySource(values, Ref(0))
    objects = existing ? (Object(:leaf; scale=:Leaf), Object(:reader; scale=:Reader)) :
        (Object(:reader; scale=:Reader),)
    model = CompositeModel(objects...; applications=(
        ModelSpec(source; name=:source, on=Many(scale=:Leaf)),
        ModelSpec(ArrayManyReader(0f0); name=:reader, on=One(id=:reader),
            inputs=(x=Many(SceneScope(); scale=:Leaf, application=:source, var=:x),)),
    ), environment=(duration=Hour(1),), type_promotion=policy)
    return model, source
end

@testset "array-default type witnesses agree with real source materialization" begin
    cases = (
        (Real[1.0, 2.0], Dict(Float64 => Float32), Vector{Float32}),
        (Real[1, 2.0], Dict(Float64 => Float32), Vector{Real}),
        (Real[1.0 2.0; 3.0 4.0], Dict(Float64 => Float32), Matrix{Float32}),
        (Real[], Dict(Real => Float32), Vector{Float32}),
        (Real[], Dict(Float64 => Float32), Vector{Real}),
        (Real[1.0, 2.0], nothing, Vector{Real}),
    )
    for (values, policy, Value) in cases
        model, source = array_scene(copy(values), policy; existing=false)
        @test source.declarations[] == 1
        plan = only(model.scenario_plan_cache.program.input_records)
        @test plan.reference_types === Tuple{Base.RefValue{Value}}
        simulation = run!(model; steps=0, outputs=:all)
        carrier = only(simulation.compiled.input_bindings).carrier
        @test carrier isa PSE.RefVector{Value}
        @test isempty(carrier)
        register_object!(model, Object(:leaf; scale=:Leaf))
        continue!(simulation; steps=1)

        # Compare to the existing ordinary initialization/conversion path,
        # rather than reproducing its join or conversion logic in this test.
        baseline_model, baseline_source = array_scene(copy(values), policy; existing=true)
        @test baseline_source.declarations[] == 1
        baseline = run!(baseline_model; steps=1, outputs=:all)
        actual = model_status(model, :leaf).x
        expected = model_status(baseline_model, :leaf).x
        @test typeof(actual) === Value
        @test typeof(expected) === Value
        @test isequal(actual, expected)
        @test actual !== source.value
        @test only(parent(only(simulation.compiled.input_bindings).carrier)) ===
            PSE.refvalue(model_status(model, :leaf), :x)
        @test only(simulation.compiled.input_bindings).carrier === carrier
        @test model_status(model, :reader).seen === model_status(baseline_model, :reader).seen
        for key in ((:source, ObjectId(:leaf), :x), (:reader, ObjectId(:reader), :seen))
            @test outputs(simulation)[key] == outputs(baseline)[key]
        end
    end

    # Equal interface values may still contain different actual element types.
    # Preserve separate constructor witnesses for the configured replacement.
    base_source = ArraySource(Real[1.0, 2.0], Ref(0))
    replacement = ArraySource(Real[1f0, 2f0], Ref(0))
    template = CompositeModelTemplate((
        ModelSpec(base_source; name=:source, on=Many(scale=:Leaf)),
    ))
    instance = ObjectInstance(:stand, template; root=Object(:plant; scale=:Plant),
        objects=(Object(:base_leaf; scale=:Leaf, parent=:plant),
            Object(:override_leaf; scale=:Leaf, parent=:plant)),
        object_overrides=(Override(object=:override_leaf, application=:source, model=replacement),))
    overridden = CompositeModel(instance, Object(:reader; scale=:Reader); applications=(
        ModelSpec(ArrayManyReader(0f0); name=:reader, on=One(id=:reader),
            inputs=(x=Many(SceneScope(); scale=:Leaf, application=:stand__source, var=:x),)),
        ), environment=(duration=Hour(1),), type_promotion=Dict(Float64 => Float32))
    override_simulation = run!(overridden; steps=1, outputs=:all)
    override_binding = only(override_simulation.compiled.input_bindings)
    @test eltype(parent(override_binding.carrier)) ===
        Union{Base.RefValue{Vector{Float32}},Base.RefValue{Vector{Real}}}
    @test model_status(overridden, :base_leaf).x isa Vector{Float32}
    @test model_status(overridden, :override_leaf).x isa Vector{Real}
    @test model_status(overridden, :reader).seen === 6f0
    @test override_binding.source_ids == [ObjectId(:base_leaf), ObjectId(:override_leaf)]
    @test parent(override_binding.carrier)[1] === PSE.refvalue(model_status(overridden, :base_leaf), :x)
    @test parent(override_binding.carrier)[2] === PSE.refvalue(model_status(overridden, :override_leaf), :x)

    # Length/value changes within the configured numeric representation remain
    # runtime data, not additional reference-layout families.
    model, source = array_scene(Real[1.0, 2.0], Dict(Float64 => Float32); existing=false)
    @test source.declarations[] == 1
    push!(source.value, 4.0)
    simulation = run!(model; steps=0, outputs=:none)
    register_object!(model, Object(:leaf; scale=:Leaf))
    continue!(simulation; steps=1)
    @test model_status(model, :leaf).x == Float32[1, 2, 4]
    @test model_status(model, :leaf).x isa Vector{Float32}
    @test model_status(model, :reader).seen === 7f0
end

@testset "configured Float32 refs take precedence over Float64 producer defaults" begin
    source = Status(x=1f0)
    model = CompositeModel(Object(:source; scale=:Leaf, status=source),
        Object(:reader; scale=:Reader); applications=(
            ModelSpec(Source(2.0); name=:source, on=Many(scale=:Leaf)),
            ModelSpec(ManyReader{AbstractVector,Float32}(0f0); name=:reader,
                on=One(id=:reader), inputs=(x=Many(SceneScope(); scale=:Leaf,
                    application=:source, var=:x),)),
        ), environment=(duration=Hour(1),))
    @test only(model.scenario_plan_cache.program.input_records).reference_types ===
        Tuple{Base.RefValue{Float32}}
    simulation = run!(model; steps=1, outputs=:all)
    carrier = only(simulation.compiled.input_bindings).carrier
    @test carrier isa PSE.RefVector{Float32}
    @test model_status(model, :reader).seen === 2f0
    @test only(parent(carrier)) === PSE.refvalue(source, :x)
    register_object!(model, Object(:z_leaf; scale=:Leaf, status=Status(x=3f0)))
    continue!(simulation; steps=1)
    @test only(simulation.compiled.input_bindings).carrier === carrier
    @test carrier isa PSE.RefVector{Float32}
    @test model_status(model, :reader).seen === 8f0
    @test parent(carrier)[1] === PSE.refvalue(model_status(model, :source), :x)
    @test parent(carrier)[2] === PSE.refvalue(model_status(model, :z_leaf), :x)
end

@testset "partial current source state also admits the missing default family" begin
    supplied = Status(x=1f0)
    model = CompositeModel(Object(:a_leaf; scale=:Leaf, status=supplied),
        Object(:b_leaf; scale=:Leaf), Object(:reader; scale=:Reader);
        applications=(
            ModelSpec(Source(2.0); name=:source, on=Many(scale=:Leaf)),
            ModelSpec(ManyReader{AbstractVector,Float64}(0.0); name=:reader,
                on=One(id=:reader), inputs=(x=Many(SceneScope(); scale=:Leaf,
                    application=:source, var=:x),)),
        ), environment=(duration=Hour(1),))
    plan = only(model.scenario_plan_cache.program.input_records)
    @test Set(fieldtypes(plan.reference_types)) ==
        Set((Base.RefValue{Float32}, Base.RefValue{Float64}))
    simulation = run!(model; steps=0, outputs=:all)
    carrier = only(simulation.compiled.input_bindings).carrier
    @test carrier isa PSE.ObjectRefVector
    @test model_status(model, :a_leaf).x === 1f0
    @test model_status(model, :b_leaf).x === 0.0
    @test parent(carrier)[1] === PSE.refvalue(supplied, :x)
    @test parent(carrier)[2] === PSE.refvalue(model_status(model, :b_leaf), :x)
    continue!(simulation; steps=1)
    @test model_status(model, :reader).seen === 4.0
    @test model_status(model, :a_leaf).x === 2f0
    @test model_status(model, :b_leaf).x === 2.0
    @test only(simulation.compiled.input_bindings).carrier === carrier
end

@testset "declared heterogeneous Many stays finite from empty to two producers" begin
    model = CompositeModel(Object(:reader; scale=:Reader); applications=(
        ModelSpec(Source(2f0); name=:first, on=Many(kind=:first, scale=:Leaf)),
        ModelSpec(Source(3.0); name=:second, on=Many(kind=:second, scale=:Leaf)),
        ModelSpec(ManyReader{AbstractVector,Float64}(0.0); name=:reader,
            on=One(id=:reader), inputs=(x=Many(SceneScope(); scale=:Leaf, var=:x),)),
    ), environment=(duration=Hour(1),))
    simulation = run!(model; steps=0, outputs=:all)
    binding = only(simulation.compiled.input_bindings)
    carrier = binding.carrier
    B = typeof(binding)
    @test carrier isa PSE.ObjectRefVector
    @test eltype(parent(carrier)) === Union{Base.RefValue{Float32},Base.RefValue{Float64}}
    @test isempty(carrier)
    register_object!(model, Object(:first_leaf; scale=:Leaf, kind=:first))
    continue!(simulation; steps=1)
    @test only(simulation.compiled.input_bindings).carrier === carrier
    @test typeof(only(simulation.compiled.input_bindings)) === B
    @test model_status(model, :reader).seen === 2.0
    register_object!(model, Object(:second_leaf; scale=:Leaf, kind=:second))
    continue!(simulation; steps=1)
    @test only(simulation.compiled.input_bindings).carrier === carrier
    @test typeof(only(simulation.compiled.input_bindings)) === B
    @test model_status(model, :reader).seen === 10.0
    @test map(typeof, collect(carrier)) == [Float32, Float64]
    @test parent(carrier)[1] === PSE.refvalue(model_status(model, :first_leaf), :x)
    @test parent(carrier)[2] === PSE.refvalue(model_status(model, :second_leaf), :x)
end

@testset "empty scoped producer keeps its default and other reparentable families" begin
    outside = Status(x=1f0)
    model = CompositeModel(Object(:a_root; scale=:Plant), Object(:b_root; scale=:Plant),
        Object(:b_leaf; scale=:Leaf, parent=:b_root, status=outside),
        Object(:reader; scale=:Reader, parent=:a_root); applications=(
            ModelSpec(Source(2.0); name=:source,
                on=Many(Scope(ObjectId(:a_root)); scale=:Leaf)),
            ModelSpec(ManyReader{AbstractVector,Float64}(0.0); name=:reader,
                on=One(id=:reader), inputs=(x=Many(SceneScope(); scale=:Leaf,
                    application=:source, var=:x),)),
        ), environment=(duration=Hour(1),))
    simulation = run!(model; steps=0, outputs=:all)
    binding = only(simulation.compiled.input_bindings)
    B = typeof(binding)
    C = typeof(binding.carrier)
    @test eltype(parent(binding.carrier)) === Union{Base.RefValue{Float32},Base.RefValue{Float64}}
    @test isempty(binding.carrier)
    register_object!(model, Object(:a_leaf; scale=:Leaf, parent=:a_root))
    continue!(simulation; steps=1)
    current = only(simulation.compiled.input_bindings)
    @test typeof(current) === B
    @test typeof(current.carrier) === C
    @test model_status(model, :reader).seen === 2.0
    @test current.source_ids == [ObjectId(:a_leaf)]
    reparent_object!(model, :b_leaf, :a_root)
    continue!(simulation; steps=1)
    current = only(simulation.compiled.input_bindings)
    @test typeof(current) === B
    @test typeof(current.carrier) === C
    @test current.source_ids == [ObjectId(:a_leaf), ObjectId(:b_leaf)]
    @test parent(current.carrier)[2] === PSE.refvalue(outside, :x)
    @test model_status(model, :reader).seen === 8.0
end

@testset "numeric override witnesses do not erase an unobserved base family" begin
    for base_configured in (false, true)
        original = Status(x=1f0)
        objects = base_configured ?
            (Object(:base_leaf; scale=:Leaf, parent=:plant, status=original),
             Object(:override_leaf; scale=:Leaf, parent=:plant)) :
            (Object(:override_leaf; scale=:Leaf, parent=:plant, status=original),)
        template = CompositeModelTemplate((
            ModelSpec(Source(2.0); name=:source, on=Many(scale=:Leaf)),
        ))
        instance = ObjectInstance(:stand, template; root=Object(:plant; scale=:Plant),
            objects, object_overrides=(Override(object=:override_leaf,
                application=:source, model=Source(3f0)),))
        model = CompositeModel(instance, Object(:reader; scale=:Reader); applications=(
            ModelSpec(ManyReader{AbstractVector,Float64}(0.0); name=:reader,
                on=One(id=:reader), inputs=(x=Many(SceneScope(); scale=:Leaf,
                    application=:stand__source, var=:x),)),
        ), environment=(duration=Hour(1),))
        simulation = run!(model; steps=0, outputs=:all)
        binding = only(simulation.compiled.input_bindings)
        B = typeof(binding)
        if base_configured
            @test binding.carrier isa PSE.RefVector{Float32}
            continue!(simulation; steps=1)
            @test model_status(model, :reader).seen === 5.0
        else
            @test eltype(parent(binding.carrier)) ===
                Union{Base.RefValue{Float32},Base.RefValue{Float64}}
            register_object!(model, Object(:z_base_leaf; scale=:Leaf, parent=:plant))
            continue!(simulation; steps=1)
            current = only(simulation.compiled.input_bindings)
            @test typeof(current) === B
            @test typeof(current.carrier) === typeof(binding.carrier)
            @test model_status(model, :reader).seen === 5.0
            @test parent(current.carrier)[1] === PSE.refvalue(original, :x)
            @test parent(current.carrier)[2] ===
                PSE.refvalue(model_status(model, :z_base_leaf), :x)
        end
    end
end

@testset "distributed Many observes destination refs rather than execution objects" begin
    status = Status(x=1f0)
    model = CompositeModel(Object(:scene; scale=:Scene),
        Object(:leaf; scale=:Leaf, status), Object(:reader; scale=:Reader); applications=(
            ModelSpec(Distributor(4.0); name=:writer, on=Many(scale=:Scene),
                outputs_to=(OutputTo(Many(SceneScope(); scale=:Leaf)),)),
            ModelSpec(ManyReader{AbstractVector,Float32}(0f0); name=:reader,
                on=One(id=:reader), inputs=(x=Many(SceneScope(); scale=:Leaf,
                    application=:writer, var=:x),)),
        ), environment=(duration=Hour(1),))
    @test only(model.scenario_plan_cache.program.input_records).reference_types ===
        Tuple{Base.RefValue{Float32}}
    simulation = run!(model; steps=1, outputs=:all)
    carrier = only(simulation.compiled.input_bindings).carrier
    @test carrier isa PSE.RefVector{Float32}
    @test model_status(model, :reader).seen === 4f0
    @test only(parent(carrier)) === PSE.refvalue(status, :x)
end

@testset "a future One destination does not freeze a false Many preparation failure" begin
    model = CompositeModel(Object(:scene; scale=:Scene), Object(:reader; scale=:Reader);
        applications=(
            ModelSpec(Distributor(4f0); name=:writer, on=Many(scale=:Scene),
                outputs_to=(OutputTo(One(SceneScope(); id=:future_leaf, scale=:Leaf)),)),
            ModelSpec(ManyReader{AbstractVector,Float32}(0f0); name=:reader,
                on=One(id=:reader), inputs=(x=Many(SceneScope(); scale=:Leaf,
                    application=:writer, var=:x),)),
        ), environment=(duration=Hour(1),))
    @test only(model.scenario_plan_cache.program.input_records) isa PSE.CompiledModelInputPlan
    @test only(model.scenario_plan_cache.program.input_records).reference_types ===
        Tuple{Base.RefValue{Float32}}
    register_object!(model, Object(:future_leaf; scale=:Leaf))
    simulation = run!(model; steps=1, outputs=:all)
    @test only(simulation.compiled.input_bindings).carrier isa PSE.RefVector{Float32}
    @test model_status(model, :reader).seen === 4f0
    @test only(parent(only(simulation.compiled.input_bindings).carrier)) ===
        PSE.refvalue(model_status(model, :future_leaf), :x)
end

@testset "stream-only Many uses its private type instead of canonical refs" begin
    status = Status(x=1f0)
    model = CompositeModel(Object(:leaf; scale=:Leaf, status),
        Object(:reader; scale=:Reader); applications=(
            ModelSpec(Source(2.0); name=:source, on=Many(scale=:Leaf),
                output_routing=(x=:stream_only,)),
            ModelSpec(ManyReader{AbstractVector,Float64}(0.0); name=:reader,
                on=One(id=:reader), inputs=(x=Many(SceneScope(); scale=:Leaf,
                    application=:source, var=:x),)),
        ), environment=(duration=Hour(1),))
    @test only(model.scenario_plan_cache.program.input_records).reference_types ===
        Tuple{Base.RefValue{Float64}}
    simulation = run!(model; steps=0, outputs=:all)
    carrier = only(simulation.compiled.input_bindings).carrier
    @test carrier isa PSE.RefVector{Float64}
    @test only(parent(carrier)) !== PSE.refvalue(status, :x)
    continue!(simulation; steps=1)
    @test model_status(model, :reader).seen === 2.0
    @test status.x === 1f0
    @test outputs(simulation)[(:source, ObjectId(:leaf), :x)] == [(1.0, 2.0)]
end

@testset "an absent Required(Real) producer needs a configured element type" begin
    function required_scene(::Type{V}) where {V}
        CompositeModel(Object(:scene; scale=:Scene), Object(:reader; scale=:Reader);
            applications=(
                ModelSpec(RequiredDistributor(); name=:writer, on=Many(scale=:Scene),
                    outputs_to=(OutputTo(Many(SceneScope(); scale=:Leaf)),)),
                ModelSpec(ManyReader{V,Float32}(0f0); name=:reader, on=One(id=:reader),
                    inputs=(x=Many(SceneScope(); scale=:Leaf, application=:writer, var=:x),)),
            ), environment=(duration=Hour(1),))
    end
    typed = required_scene(Vector{Float32})
    @test only(typed.scenario_plan_cache.program.input_records).reference_types ===
        Tuple{Base.RefValue{Float32}}
    @test only(run!(typed; steps=0, outputs=:none).compiled.input_bindings).carrier isa
        PSE.RefVector{Float32}
    ambiguous = required_scene(AbstractVector)
    @test only(ambiguous.scenario_plan_cache.program.input_records) isa PSE.ScenarioPreparationFailure
    @test_throws "no concrete configured source type" run!(ambiguous; steps=0, outputs=:none)

    # A known Ref in another scope is eligible after reparenting, but cannot
    # determine a new producer configuration whose Required(Real) is unresolved.
    scoped = CompositeModel(Object(:scene; scale=:Scene), Object(:a_root; scale=:Plant),
        Object(:b_root; scale=:Plant), Object(:b_leaf; scale=:Leaf, parent=:b_root,
            status=Status(x=1f0)), Object(:reader; scale=:Reader); applications=(
                ModelSpec(RequiredDistributor(); name=:writer, on=Many(scale=:Scene),
                    outputs_to=(OutputTo(Many(Scope(ObjectId(:a_root)); scale=:Leaf)),)),
                ModelSpec(ManyReader{AbstractVector,Float32}(0f0); name=:reader,
                    on=One(id=:reader), inputs=(x=Many(SceneScope(); scale=:Leaf,
                        application=:writer, var=:x),)),
            ), environment=(duration=Hour(1),))
    @test only(scoped.scenario_plan_cache.program.input_records) isa PSE.ScenarioPreparationFailure
    @test_throws "no concrete configured source type" run!(scoped; steps=0, outputs=:none)
end

@testset "status-only empty Many requires a concrete configured element type" begin
    function status_only(::Type{V}) where {V}
        CompositeModel(Object(:reader; scale=:Reader); applications=(
            ModelSpec(ManyReader{V,Float32}(0f0); name=:reader, on=One(id=:reader),
                inputs=(x=Many(SceneScope(); scale=:Leaf, var=:x, from_status=true),)),
        ), environment=(duration=Hour(1),))
    end
    typed = status_only(Vector{Float32})
    @test only(typed.scenario_plan_cache.program.input_records).reference_types ===
        Tuple{Base.RefValue{Float32}}
    simulation = run!(typed; steps=0, outputs=:none)
    @test only(simulation.compiled.input_bindings).carrier isa PSE.RefVector{Float32}
    ambiguous = status_only(AbstractVector)
    @test only(ambiguous.scenario_plan_cache.program.input_records) isa PSE.ScenarioPreparationFailure
    @test_throws "no concrete configured source type" run!(ambiguous; steps=0, outputs=:none)
end

struct VariantInputDefaults{T} <: AbstractResolved_Endpoint_ReaderModel
    seed::Base.RefValue{Float64}
    input_reads::Base.RefValue{Int}
    output_reads::Base.RefValue{Int}
end
function PSE.inputs_(model::VariantInputDefaults)
    model.input_reads[] += 1
    return (offset=Default(model.seed[]),)
end
function PSE.outputs_(model::VariantInputDefaults{T}) where {T}
    model.output_reads[] += 1
    return (seen=zero(T),)
end
PSE.run!(::VariantInputDefaults{T}, status, environment, constants, context) where {T} =
    (status.seen = T(status.offset + context.time); nothing)

struct VariantPrivateDefaults{T} <: AbstractResolved_Endpoint_SourceModel
    output_reads::Base.RefValue{Int}
end
PSE.inputs_(::VariantPrivateDefaults) = NamedTuple()
function PSE.outputs_(model::VariantPrivateDefaults{T}) where {T}
    model.output_reads[] += 1
    return (live=zero(T), private=zero(T))
end
function PSE.run!(::VariantPrivateDefaults{T}, status, environment, constants, context) where {T}
    status.private = T(context.time)
    status.live = 2 * status.private
    return nothing
end

function variant_defaults_scene(base, replacement; private=false)
    template = CompositeModelTemplate((ModelSpec(base; name=:variant, on=Many(scale=:Leaf),
        output_routing=private ? (private=:stream_only,) : NamedTuple()),))
    leaves = Tuple(Object(id; scale=:Leaf, parent=:plant,
        status=private ? Status(private=99.0) : nothing)
        for id in (:a_base, :b_override, :c_base, :d_override))
    instance = ObjectInstance(:stand, template; root=Object(:plant; scale=:Plant),
        objects=leaves, object_overrides=(
            Override(object=:b_override, application=:variant, model=replacement),
            Override(object=:d_override, application=:variant, model=replacement)))
    applications = private ? (ModelSpec(ManyReader{AbstractVector,Float64}(0.0);
        name=:reader, on=One(id=:reader), inputs=(x=Many(SceneScope(); scale=:Leaf,
            application=:stand__variant, var=:private),)),) : ()
    return CompositeModel(instance, Object(:reader; scale=:Reader);
        applications, environment=(duration=Hour(1),))
end

@testset "effective input defaults stay fresh and are read once per used variant" begin
    base = VariantInputDefaults{Float64}(Ref(1.0), Ref(0), Ref(0))
    replacement = VariantInputDefaults{Float32}(Ref(1.0), Ref(0), Ref(0))
    model = variant_defaults_scene(base, replacement)
    # Both input declarations are compatible at preparation. Their values may
    # subsequently change without changing the prepared variable or numeric type.
    base.seed[], replacement.seed[] = 3.0, 7.0
    simulation = run!(model; steps=0, outputs=:all)
    compiled = simulation.compiled
    application = compiled.applications_by_id[:stand__variant]
    @test PSE._application_model(application, ObjectId(:b_override)) === replacement
    references = Dict(id => PSE.refvalue(model_status(model, id), :offset)
        for id in (:a_base, :b_override, :c_base, :d_override))
    @test model_status(model, :a_base).offset === model_status(model, :c_base).offset === 3.0
    @test model_status(model, :b_override).offset === model_status(model, :d_override).offset === 7.0
    @test model_status(model, :a_base).seen === 0.0
    @test model_status(model, :b_override).seen === 0f0
    for batched in (false, true)
        base.input_reads[] = replacement.input_reads[] = 0
        if batched
            PSE._prepare_model_input_statuses_batched!(model, (application,),
                compiled.applications_by_id, compiled.input_bindings)
        else
            PSE._prepare_model_input_defaults!(model, (application,), compiled.applications_by_id)
        end
        @test (base.input_reads[], replacement.input_reads[]) == (1, 1)
        @test all(PSE.refvalue(model_status(model, id), :offset) === reference
            for (id, reference) in references)
    end
    step!(simulation)
    @test model_status(model, :a_base).seen === 4.0
    @test model_status(model, :b_override).seen === 8f0
    @test outputs(simulation)[(:stand__variant, ObjectId(:a_base), :seen)] == [(1.0, 4.0)]
    @test outputs(simulation)[(:stand__variant, ObjectId(:b_override), :seen)] == [(1.0, 8f0)]
    base.seed[] = 11.0
    register_object!(model, Object(:e_base; scale=:Leaf, parent=:plant))
    step!(simulation)
    @test model_status(model, :e_base).offset === 11.0
    @test model_status(model, :e_base).seen === 13.0
    @test all(PSE.refvalue(model_status(model, id), :offset) === reference
        for (id, reference) in references)
end

@testset "effective stream-only defaults retain private numeric refs and histories" begin
    base = VariantPrivateDefaults{Float64}(Ref(0))
    replacement = VariantPrivateDefaults{Float32}(Ref(0))
    model = variant_defaults_scene(base, replacement; private=true)
    simulation = run!(model; steps=0, outputs=:all)
    compiled = simulation.compiled
    application = compiled.applications_by_id[:stand__variant]
    base_view = compiled.status_views_by_target[(:stand__variant, ObjectId(:a_base))]
    override_view = compiled.status_views_by_target[(:stand__variant, ObjectId(:b_override))]
    @test base_view.private_outputs.private isa Base.RefValue{Float64}
    @test override_view.private_outputs.private isa Base.RefValue{Float32}
    @test PSE.refvalue(base_view.status, :private) === base_view.private_outputs.private
    @test PSE.refvalue(override_view.status, :private) === override_view.private_outputs.private
    @test override_view.private_outputs.private !== PSE.refvalue(model_status(model, :b_override), :private)
    base.output_reads[] = replacement.output_reads[] = 0
    PSE._prepare_model_output_statuses!(model, (application,), compiled.applications_by_id)
    @test (base.output_reads[], replacement.output_reads[]) == (1, 1)

    # Isolate each cold reader from declaration/diagnostic reads elsewhere.
    base.output_reads[] = replacement.output_reads[] = 0
    initial = PSE._stream_only_initial_reference(model, ObjectId(:b_override),
        [:stand__variant], :private, compiled.applications_by_id)
    @test initial isa Base.RefValue{Float32}
    @test initial[] === 0f0
    @test (base.output_reads[], replacement.output_reads[]) == (0, 1)
    base.output_reads[] = replacement.output_reads[] = 0
    positions = Dict(id => index for (index, id) in pairs(compiled.application_order))
    ephemeral = PSE._compile_model_status_view(model, application, ObjectId(:b_override), (),
        compiled.applications_by_id, positions, compiled.distributed_outputs;
        execution_stamp=override_view.execution_stamp, status_view_schema=compiled.status_view_schema,
        input_binding_storage=compiled.input_bindings)
    @test (base.output_reads[], replacement.output_reads[]) == (0, 1)
    @test ephemeral.private_outputs.private isa Base.RefValue{Float32}
    @test ephemeral.canonical_status === override_view.canonical_status
    @test compiled.status_views_by_target[(:stand__variant, ObjectId(:b_override))] === override_view
    continue!(simulation; steps=2)
    @test model_status(model, :reader).seen === 8.0
    @test model_status(model, :a_base).private === model_status(model, :b_override).private === 99.0
    @test model_status(model, :a_base).live === 4.0
    @test model_status(model, :b_override).live === 4f0
    @test outputs(simulation)[(:stand__variant, ObjectId(:a_base), :private)] == [(1.0, 1.0), (2.0, 2.0)]
    @test outputs(simulation)[(:stand__variant, ObjectId(:b_override), :private)] == [(1.0, 1f0), (2.0, 2f0)]
    @test override_view.private_outputs.private ===
        compiled.status_views_by_target[(:stand__variant, ObjectId(:b_override))].private_outputs.private
end

struct CountWriterChecks
    count::Base.RefValue{Int}
end
function PSE._application_writes_object_variable(counter::CountWriterChecks, application, id, variable)
    counter.count[] += 1
    return PSE._application_writes_object_variable(PSE.NoCompiledDistributedOutputs(), application, id, variable)
end
PSE._final_inferred_output_plans(::CountWriterChecks, id, variable, matches) = matches

@testset "inferred endpoints reuse the writer already validated for that object" begin
    model = CompositeModel(Object(:leaf; scale=:Leaf);
        applications=(
            ModelSpec(Reader{Float32}(); name=:reader, on=Many(scale=:Leaf)),
            ModelSpec(Source(3f0); name=:source, on=Many(scale=:Leaf)),
        ), environment=(duration=Hour(1),))
    simulation = run!(model; outputs=:all)
    compiled = simulation.compiled
    application = compiled.applications_by_id[:reader]
    recipe = compiled.scenario_plan.input_recipes_by_application[:reader]
    counter = CountWriterChecks(Ref(0))
    bindings = PSE.CompiledModelInputBinding[]
    PSE._compile_consumer_input_recipe!(bindings, model, application.id, application.process, ObjectId(:leaf),
        recipe, compiled.scenario_plan.manual_application_ids,
        compiled.applications_by_object, compiled.applications_by_id, counter)
    @test counter.count[] == 1
    @test only(bindings).source_application_ids == [:source]
    @test only(bindings).carrier === PSE.refvalue(model_status(model, :leaf), :x)
    @test model_status(model, :leaf).seen === 3f0
end

@testset "point, homogeneous and heterogeneous carriers visit sources once" begin
    ids = [ObjectId(1), ObjectId(2), ObjectId(3)]
    cells = [Ref(1.0), Ref(2.0), Ref(3.0)]
    visited = Int[]
    reference_for(id) = (push!(visited, id.value); cells[id.value])
    @test PSE._input_reference_carrier(One(), ids[1:1], reference_for, Tuple{}) === cells[1]
    @test visited == [1]
    empty!(visited)
    @test isnothing(PSE._input_reference_carrier(OptionalOne(), ObjectId{Int}[], reference_for, Tuple{}))
    @test isempty(visited)
    homogeneous = PSE._input_reference_carrier(Many(), ids, reference_for, Tuple{Base.RefValue{Float64}})
    @test homogeneous isa PSE.RefVector{Float64}
    @test visited == [1, 2, 3]
    @test all(parent(homogeneous)[index] === cells[index] for index in eachindex(cells))
    cells[2][] = 8.0
    @test homogeneous[2] === 8.0

    mixed = Base.RefValue[Ref(1f0), Ref(2.0), Ref(3)]
    empty!(visited)
    mixed_for(id) = (push!(visited, id.value); mixed[id.value])
    heterogeneous = PSE._input_reference_carrier(Many(), ids, mixed_for, Tuple{Base.RefValue{Float32},Base.RefValue{Float64},Base.RefValue{Int}})
    @test heterogeneous isa PSE.ObjectRefVector
    @test visited == [1, 2, 3]
    @test all(parent(heterogeneous)[index] === mixed[index] for index in eachindex(mixed))
    @test typeof.(collect(heterogeneous)) == [Float32, Float64, Int]
    mixed[1][] = 7f0
    @test heterogeneous[1] === 7f0

    abstract = Ref{Real}(1.0)
    @test PSE._input_reference_carrier(Many(), ids[1:1], _ -> abstract, Tuple{Base.RefValue{Real}}) isa PSE.ObjectRefVector
    @test PSE._input_reference_carrier(Many(), ObjectId{Int}[], reference_for, Tuple{Base.RefValue{Float64}}) isa PSE.RefVector{Float64}
    @test isnothing(PSE._input_reference_carrier(One(), ids[1:1], _ -> nothing, Tuple{}))
    empty!(visited)
    missing_for(id) = (push!(visited, id.value); id.value == 2 ? nothing : cells[id.value])
    @test isnothing(PSE._input_reference_carrier(Many(), ids, missing_for, Tuple{Base.RefValue{Float64}}))
    @test visited == [1, 2]
    external = Ref([4.0], 1)
    @test_throws ArgumentError PSE._input_reference_carrier(One(), ids[1:1], _ -> external, Tuple{})
    @test_throws ArgumentError PSE._input_reference_carrier(Many(), ids[1:1], _ -> external, Tuple{Base.RefValue{Float64}})
end

struct OffsetSourceIds{T} <: AbstractVector{T}
    values::Vector{T}
    offset::Int
    reads::Vector{Int}
end
OffsetSourceIds(values::Vector{T}, offset::Int) where {T} =
    OffsetSourceIds{T}(values, offset, Int[])
Base.size(ids::OffsetSourceIds) = size(ids.values)
Base.axes(ids::OffsetSourceIds) =
    (Base.IdentityUnitRange(ids.offset:(ids.offset + length(ids.values) - 1)),)
Base.firstindex(ids::OffsetSourceIds) = ids.offset
Base.lastindex(ids::OffsetSourceIds) = ids.offset + length(ids.values) - 1
function Base.getindex(ids::OffsetSourceIds, index::Int)
    checkbounds(ids, index)
    push!(ids.reads, index)
    return ids.values[index - ids.offset + 1]
end
function Base.iterate(ids::OffsetSourceIds, state::Int=firstindex(ids))
    state > lastindex(ids) && return nothing
    return ids[state], state + 1
end

@testset "source collection preserves arbitrary vector axes and iteration state" begin
    for cells in (
        Base.RefValue[Ref(1f0), Ref(2f0), Ref(3f0), Ref(4f0)],
        Base.RefValue[Ref(1f0), Ref(2f0), Ref(3.0), Ref(4f0)],
        Base.RefValue[Ref{Real}(1.0), Ref(2.0), Ref(3.0), Ref(4.0)],
    )
        ids = OffsetSourceIds(ObjectId.(1:4), -3)
        visited = Int[]
        getter(id) = (push!(visited, id.value); cells[id.value])
        carrier = PSE._input_reference_carrier(Many(), ids, getter, Tuple{unique(typeof.(cells))...})
        @test ids.reads == [-3, -2, -1, 0]
        @test visited == [1, 2, 3, 4]
        @test all(parent(carrier)[index] === cells[index] for index in eachindex(cells))
        @test typeof.(collect(carrier)) == typeof.([cell[] for cell in cells])
        if all(cell -> cell isa Base.RefValue{Float32}, cells)
            @test carrier isa PSE.RefVector{Float32}
        else
            @test carrier isa PSE.ObjectRefVector
        end
    end
    empty_ids = OffsetSourceIds(ObjectId{Int}[], 9)
    @test PSE._input_reference_carrier(Many(), empty_ids, _ -> error("empty source visited"), Tuple{Base.RefValue{Float32}}) isa PSE.RefVector{Float32}
    @test isempty(empty_ids.reads)
    for selector in (One(), OptionalOne())
        ids = OffsetSourceIds([ObjectId(1)], 7)
        cell = Ref(5.0)
        @test PSE._input_reference_carrier(selector, ids, _ -> cell, Tuple{}) === cell
        @test ids.reads == [7]
    end
end

@noinline function repeat_point_carrier(model, selector, ids, expected, repetitions)
    same = true
    for _ in 1:repetitions
        same &= PSE._input_carrier(model, selector, ids, Val(:x), Tuple{}) === expected
    end
    return same
end
@noinline point_allocations(model, selector, ids, expected, repetitions) =
    @allocated repeat_point_carrier(model, selector, ids, expected, repetitions)
@noinline many_allocations(ids, getter) =
    @allocated PSE._input_reference_carrier(Many(), ids, getter, Tuple{Base.RefValue{Float64}})

@testset "point materialization has no allocation per source and Many builds one vector" begin
    status = Status(x=1.0)
    model = CompositeModel(Object(1; status))
    ids = [ObjectId(1)]
    expected = PSE.refvalue(status, :x)
    for selector in (One(), OptionalOne())
        @test repeat_point_carrier(model, selector, ids, expected, 2)
        point_allocations(model, selector, ids, expected, 1000)
        allocated = minimum(point_allocations(model, selector, ids, expected, 1000) for _ in 1:3)
        # A small fixed allowance accommodates instrumentation on the Kaimon
        # task; the former temporary vector per call exceeds this by far.
        @test allocated <= 4096
    end
    count = 1024
    many_ids = ObjectId.(1:count)
    cells = [Ref(Float64(index)) for index in 1:count]
    getter = id -> cells[id.value]
    many_allocations(many_ids, getter)
    allocated = minimum(many_allocations(many_ids, getter) for _ in 1:3)
    @test allocated <= sizeof(Int) * count + 4096
end

@testset "shared materialization preserves Updates, distributed ownership and stream-only values" begin
    ordered = CompositeModel(Object(:leaf; scale=:Leaf);
        applications=(
            ModelSpec(Source(2.0); name=:first, on=Many(scale=:Leaf)),
            ModelSpec(Source(5.0); name=:second, on=Many(scale=:Leaf), updates=Updates(:x; after=:first)),
            ModelSpec(Reader{Float64}(); name=:reader, on=Many(scale=:Leaf),
                inputs=(x=One(within=Self(), var=:x),)),
        ), environment=(duration=Hour(1),))
    simulation = run!(ordered; outputs=:all)
    @test model_status(ordered, :leaf).seen === 5.0
    @test only(filter(binding -> binding.application_id === :reader,
        simulation.compiled.input_bindings)).source_application_ids == [:second]

    distributed = CompositeModel(Object(:plant; scale=:Plant),
        Object(:leaf; scale=:Leaf, parent=:plant);
        applications=(
            ModelSpec(Distributor(4f0); name=:distributor, on=Many(scale=:Plant),
                outputs_to=(OutputTo(Many(scale=:Leaf, within=Subtree())),)),
            ModelSpec(Reader{Float32}(); name=:reader, on=Many(scale=:Leaf)),
        ), environment=(duration=Hour(1),))
    simulation = run!(distributed; outputs=:all)
    @test model_status(distributed, :leaf).seen === 4f0
    register_object!(distributed, Object(:new_leaf; scale=:Leaf, parent=:plant))
    continue!(simulation)
    @test model_status(distributed, :new_leaf).seen === 4f0
    newborn = only(binding for binding in simulation.compiled.input_bindings
        if binding.application_id === :reader && binding.consumer_id == ObjectId(:new_leaf))
    @test newborn.source_application_ids == [:distributor]
    @test newborn.carrier === PSE.refvalue(model_status(distributed, :new_leaf), :x)

    streamed = point_scene(Float64; stream_only=true)
    simulation = run!(streamed; steps=2, outputs=:all)
    @test !(:x in propertynames(model_status(streamed, :source)))
    @test model_status(streamed, :reader).seen === 5.0
    @test outputs(simulation)[(:source, ObjectId(:source), :x)] == [(1.0, 2.5), (2.0, 5.0)]
end

end
