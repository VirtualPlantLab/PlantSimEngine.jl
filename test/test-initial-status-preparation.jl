using PlantSimEngine
using PlantSimEngine.Diagnostics
using Test

PlantSimEngine.@process "initial_status_preparation_probe" verbose = false
PlantSimEngine.@process "initial_status_preparation_reader" verbose = false

# These deliberately small schemas exercise compiler initialization, not a
# scientific model. Supplying schemas as parameters also keeps the same tests
# applicable to several orders and combinations of defaults.
struct InitialStatusPreparationProbe{I,O} <: AbstractInitial_Status_Preparation_ProbeModel
    input_schema::I
    output_defaults::O
end

PlantSimEngine.inputs_(model::InitialStatusPreparationProbe) = model.input_schema
PlantSimEngine.outputs_(model::InitialStatusPreparationProbe) = model.output_defaults
PlantSimEngine.run!(::InitialStatusPreparationProbe, status, environment, constants, context) =
    nothing

struct CountedOutputPreparationProbe{O} <: AbstractInitial_Status_Preparation_ProbeModel
    output_defaults::O
    evaluations::Base.RefValue{Int}
end
PlantSimEngine.inputs_(::CountedOutputPreparationProbe) = NamedTuple()
function PlantSimEngine.outputs_(model::CountedOutputPreparationProbe)
    model.evaluations[] += 1
    return model.output_defaults
end

struct InitialStatusPreparationReader <: AbstractInitial_Status_Preparation_ReaderModel end
PlantSimEngine.inputs_(::InitialStatusPreparationReader) = (
    bound=Default(-99.0),
    optional=Default(3.0),
    input_buffer=Default([2.0, 4.0]),
)
PlantSimEngine.outputs_(::InitialStatusPreparationReader) = (observed=0.0,)
function PlantSimEngine.run!(::InitialStatusPreparationReader, status, environment, constants, context)
    status.observed = status.bound + status.optional + sum(status.input_buffer)
    return nothing
end

initial_preparation_status(model, id) = only(
    object.status for object in model_objects(model) if object.id == ObjectId(id)
)

@testset "complete initial statuses retain identity and arbitrary Ref aliases" begin
    storage = [7.5, 2.25]
    supplied_reference = Ref(storage, 1)
    result_reference = Ref(storage, 2)
    original = Status((
        supplied=supplied_reference,
        alias=supplied_reference,
        result=result_reference,
        offset=Ref(3.0),
    ))
    model = CompositeModel(
        Object(:leaf; scale=:Leaf, status=original);
        applications=(
            ModelSpec(
                InitialStatusPreparationProbe(
                    (supplied=Required(Real), offset=Default(-1.0)),
                    (result=-2.0,),
                ); name=:first, on=One(scale=:Leaf),
            ),
            ModelSpec(
                InitialStatusPreparationProbe((offset=Default(-3.0),), NamedTuple());
                name=:second, on=One(scale=:Leaf),
            ),
        ),
    )
    compiled = Advanced.refresh_bindings!(model)
    @test initial_preparation_status(model, :leaf) === original
    @test propertynames(original) == (:supplied, :alias, :result, :offset)
    @test original.offset == 3.0
    @test PlantSimEngine.refvalue(original, :supplied) === supplied_reference
    @test PlantSimEngine.refvalue(original, :alias) === supplied_reference
    @test PlantSimEngine.refvalue(original, :result) === result_reference
    for application_id in (:first, :second)
        view = compiled.status_views_by_target[(application_id, ObjectId(:leaf))]
        @test view.status === original
        @test view.canonical_status === original
        @test isempty(view.temporal_inputs)
        @test isempty(view.private_outputs)
    end

    # Both directions must still reach the caller's storage after preparation.
    storage[1] = 9.25
    @test original.supplied == original.alias == 9.25
    original.result = 4.5
    @test storage[2] == 4.5
    simulation = run!(model; steps=1, outputs=:none)
    @test initial_preparation_status(model, :leaf) === original
    @test final_state(simulation).supplied == 9.25
    @test storage == [9.25, 4.5]
end

@testset "empty model ports still create and validate object statuses" begin
    probe = InitialStatusPreparationProbe(NamedTuple(), NamedTuple())
    supplied = Status()
    model = CompositeModel(
        Object(:supplied; scale=:Leaf, status=supplied),
        Object(:missing_a; scale=:Leaf),
        Object(:missing_b; scale=:Leaf);
        applications=(ModelSpec(probe; name=:empty, on=Many(scale=:Leaf)),),
    )
    compiled = Advanced.refresh_bindings!(model)
    @test initial_preparation_status(model, :supplied) === supplied
    for object in model_objects(model)
        @test object.status isa Status
        @test isempty(propertynames(object.status))
        @test object_id(model, object.status) == object.id
        view = compiled.status_views_by_target[(:empty, object.id)]
        @test view.status === object.status
        @test view.canonical_status === object.status
    end
    @test initial_preparation_status(model, :missing_a) !==
          initial_preparation_status(model, :missing_b)

    invalid_status = (sentinel=7.0,)
    invalid = CompositeModel(
        Object(:invalid; scale=:Leaf, status=invalid_status);
        applications=(ModelSpec(probe; name=:empty, on=One(scale=:Leaf)),),
    )
    @test_throws "Model object `invalid` uses model applications but its status has type" Advanced.refresh_bindings!(invalid)
    @test initial_preparation_status(invalid, :invalid) === invalid_status
end

@testset "initial preparation preserves existing references and first defaults" begin
    original = Status(signal=7.0, untouched=[8.0])
    signal_reference = PlantSimEngine.refvalue(original, :signal)
    untouched_reference = PlantSimEngine.refvalue(original, :untouched)
    output_buffer = [1.0, 2.0]
    input_buffer = [3.0, 4.0]
    first = InitialStatusPreparationProbe(
        (offset=Default(2.0), input_buffer=Default(input_buffer)),
        (signal=1.0, output_buffer=output_buffer, extra=4.0),
    )
    second = InitialStatusPreparationProbe(
        (offset=Default(99.0),),
        (signal=99.0,),
    )
    model = CompositeModel(
        Object(:existing; scale=:Leaf, status=original),
        Object(:missing; scale=:Leaf);
        applications=(
            ModelSpec(first; name=:first, on=Many(scale=:Leaf)),
            ModelSpec(second; name=:second, on=Many(scale=:Leaf),
                updates=Updates(:signal; after=:first)),
        ),
    )
    Advanced.refresh_bindings!(model)
    existing = initial_preparation_status(model, :existing)
    missing = initial_preparation_status(model, :missing)

    @test PlantSimEngine.refvalue(existing, :signal) === signal_reference
    @test PlantSimEngine.refvalue(existing, :untouched) === untouched_reference
    @test existing.signal == 7.0
    @test missing.signal == 1.0
    @test existing.offset == missing.offset == 2.0
    @test existing.extra == missing.extra == 4.0
    @test propertynames(existing) ==
          (:signal, :untouched, :output_buffer, :extra, :offset, :input_buffer)
    @test propertynames(missing) ==
          (:signal, :output_buffer, :extra, :offset, :input_buffer)

    for name in (:output_buffer, :input_buffer)
        @test getproperty(existing, name) !== getproperty(missing, name)
        getproperty(existing, name)[1] = -1.0
        @test getproperty(missing, name)[1] > 0.0
    end
    @test output_buffer == [1.0, 2.0]
    @test input_buffer == [3.0, 4.0]
    existing.untouched[1] = 10.0
    @test original.untouched == [10.0]
end

@testset "initial input defaults retain resolved carriers and unresolved optionals" begin
    model = CompositeModel(
        Object(:source; scale=:Source),
        Object(:leaf_a; scale=:Leaf),
        Object(:leaf_b; scale=:Leaf);
        applications=(
            ModelSpec(
                InitialStatusPreparationProbe(NamedTuple(), (signal=5.0,));
                name=:source, on=One(scale=:Source),
            ),
            ModelSpec(
                InitialStatusPreparationReader(); name=:reader, on=Many(scale=:Leaf),
                inputs=(
                    bound=One(scale=:Source, within=SceneScope(), application=:source, var=:signal),
                    optional=OptionalOne(scale=:Soil, within=SceneScope(), var=:absent),
                ),
            ),
        ),
    )
    Advanced.refresh_bindings!(model)
    source = initial_preparation_status(model, :source)
    first = initial_preparation_status(model, :leaf_a)
    second = initial_preparation_status(model, :leaf_b)
    for status in (first, second)
        @test PlantSimEngine.refvalue(status, :bound) ===
              PlantSimEngine.refvalue(source, :signal)
        @test status.bound == 5.0
        @test status.optional == 3.0
    end
    @test first.input_buffer !== second.input_buffer
    rows = explain_initialization(model)
    optional_rows = filter(row -> row.role == :input && row.variable == :optional, rows)
    @test length(optional_rows) == 2
    @test all(row -> row.disposition == :defaulted && row.origin == :model_default,
        optional_rows)

    simulation = run!(model; steps=1, outputs=:none)
    @test final_state(simulation, :leaf_a).observed == 14.0
    @test final_state(simulation, :leaf_b).observed == 14.0
end

@testset "initial bound defaults retain conversion evidence and source identity" begin
    transformed = Symbol[]
    transform = (variable, value) -> begin
        push!(transformed, variable)
        variable == :bound ? 2 * value : value
    end
    model = CompositeModel(
        Object(:source; scale=:Source),
        Object(:leaf; scale=:Leaf);
        applications=(
            ModelSpec(
                InitialStatusPreparationProbe(NamedTuple(), (signal=5.0,));
                name=:source, on=One(scale=:Source),
            ),
            ModelSpec(
                InitialStatusPreparationProbe((bound=Default(-99.0),), NamedTuple());
                name=:reader, on=One(scale=:Leaf),
                inputs=(bound=One(scale=:Source, within=SceneScope(),
                    application=:source, var=:signal),),
            ),
        ),
        type_promotion=Dict(Float64 => Float32),
        status_transform=transform,
    )
    compiled = Advanced.refresh_bindings!(model)
    source = initial_preparation_status(model, :source)
    reader = initial_preparation_status(model, :leaf)
    @test reader.bound === source.signal === 5.0f0
    @test PlantSimEngine.refvalue(reader, :bound) ===
          PlantSimEngine.refvalue(source, :signal)
    @test count(==(:bound), transformed) == 1
    row = only(row for row in explain_initialization(model)
        if row.application_id == :reader && row.role == :input && row.variable == :bound)
    @test row.disposition == :producer_bound
    @test row.original_type === Float64
    @test row.effective_type === Float32
    @test row.type_mapping_applied
    @test row.status_transform_applied
    @test row.status_transform_changed
    view = compiled.status_views_by_target[(:reader, ObjectId(:leaf))]
    @test view.status === reader
    @test view.canonical_status === reader
end

@testset "initial defaults preserve numeric conversion diagnostics" begin
    transform = (variable, value) -> variable == :offset ? 2 * value : value
    probe = InitialStatusPreparationProbe(
        (supplied=Required(Real), offset=Default(0.5), input_buffer=Default([1.0, 2.0])),
        (result=0.0, output_buffer=[3.0, 4.0], count=2),
    )
    model = CompositeModel(
        probe;
        status=(supplied=1.25,),
        type_promotion=Dict(Float64 => Float32),
        status_transform=transform,
    )
    Advanced.refresh_bindings!(model)
    status = only(model_objects(model)).status
    @test status.supplied === 1.25f0
    @test status.offset === 1.0f0
    @test status.result === 0.0f0
    @test status.input_buffer == Float32[1, 2]
    @test status.output_buffer == Float32[3, 4]
    @test eltype(status.input_buffer) === Float32
    @test eltype(status.output_buffer) === Float32
    @test status.count === 2
    @test probe.input_schema.offset.value === 0.5
    @test eltype(probe.output_defaults.output_buffer) === Float64

    rows = explain_initialization(model)
    for (role, name) in ((:input, :supplied), (:input, :offset), (:output, :result))
        row = only(row for row in rows if row.role == role && row.variable == name)
        @test row.original_type === Float64
        @test row.effective_type === Float32
        @test row.type_mapping_applied
        @test row.type_mapping_rule == (Float64 => Float32)
        @test row.status_transform_applied
        @test row.status_transform_changed == (name == :offset)
    end
end

@testset "stream-only output defaults never acquire canonical ownership" begin
    model = CompositeModel(
        Object(:leaf; scale=:Leaf, status=Status(kept=7.0));
        applications=(
            ModelSpec(
                InitialStatusPreparationProbe(NamedTuple(), (kept=1.0, scratch=[2.0]));
                name=:private_output, on=One(scale=:Leaf),
                output_routing=(kept=:stream_only, scratch=:stream_only),
            ),
        ),
    )
    original = only(model_objects(model)).status
    kept_reference = PlantSimEngine.refvalue(original, :kept)
    compiled = Advanced.refresh_bindings!(model)
    status = only(model_objects(model)).status
    @test propertynames(status) == (:kept,)
    @test status.kept == 7.0
    @test PlantSimEngine.refvalue(status, :kept) === kept_reference
    @test !hasproperty(status, :scratch)

    view = compiled.status_views_by_target[(:private_output, ObjectId(:leaf))]
    @test view.status !== status
    @test view.canonical_status === status
    @test PlantSimEngine.refvalue(view.status, :kept) !== kept_reference
    @test view.status.kept == 1.0
    @test view.status.scratch == [2.0]

    simulation = run!(model; steps=1, outputs=:all)
    @test !hasproperty(only(model_objects(model)).status, :scratch)
    @test last(outputs(simulation)[(:private_output, ObjectId(:leaf), :scratch)])[2] == [2.0]
    @test only(model_objects(model)).status.kept == 7.0
end

@testset "distributed destination validation precedes initial default preparation" begin
    function destination_model(leaf_status)
        return CompositeModel(
            Object(:scene; scale=:Scene),
            Object(:leaf; scale=:Leaf, parent=:scene, status=leaf_status);
            applications=(
                ModelSpec(
                    InitialStatusPreparationProbe(NamedTuple(), (local_default=1.0,));
                    name=:distributor, on=One(scale=:Scene),
                    outputs_to=(
                        leaves=OutputTo(Many(scale=:Leaf, within=SceneScope());
                            vars=(distributed_buffer=Default([1.0]), required_value=Required(Real))),
                    ),
                ),
            ),
        )
    end
    original = Status(sentinel=7.0)
    sentinel_reference = PlantSimEngine.refvalue(original, :sentinel)
    missing = destination_model(original)
    @test_throws "Missing required distributed-output destination" Advanced.refresh_bindings!(missing)
    @test isnothing(initial_preparation_status(missing, :scene))
    @test initial_preparation_status(missing, :leaf) === original
    @test propertynames(original) == (:sentinel,)
    @test PlantSimEngine.refvalue(original, :sentinel) === sentinel_reference

    supplied = Status(required_value=4.0)
    required_reference = PlantSimEngine.refvalue(supplied, :required_value)
    valid = destination_model(supplied)
    Advanced.refresh_bindings!(valid)
    leaf_status = initial_preparation_status(valid, :leaf)
    @test PlantSimEngine.refvalue(leaf_status, :required_value) === required_reference
    @test leaf_status.required_value == 4.0
    @test leaf_status.distributed_buffer == [1.0]
    @test initial_preparation_status(valid, :scene).local_default == 1.0
end

@testset "runtime output assembly preserves ordered stream and status references" begin
    object_id = ObjectId(:target)
    status = Status(first=7.0, second=Float32[2, 3])
    application = (
        id=:probe,
        spec=ModelSpec(InitialStatusPreparationProbe(NamedTuple(), (first=0.0, second=Float32[]))),
    )
    retention = PlantSimEngine.OutputRetentionPlan(
        false,
        Set([(:probe, :second)]),
        Set([(:probe, :first)]),
        Dict((:probe, :second) => 3.0),
        Dict(:probe => [:second, :undeclared, :first]),
    )
    first_key = (:probe, object_id, :first)
    second_key = (:probe, object_id, :second)
    first_stream = Tuple{Float64,Float64}[(0.0, 1.0)]
    second_stream = PlantSimEngine.TemporalDependencyBuffer{Vector{Float32}}(3)
    streams = Dict{Tuple{Symbol,ObjectId,Symbol},Any}(
        first_key => first_stream, second_key => second_stream,
    )
    first_reference = PlantSimEngine.refvalue(status, :first)
    second_reference = PlantSimEngine.refvalue(status, :second)

    assembled = PlantSimEngine._runtime_model_output_streams(
        status, application, object_id, streams, retention,
    )
    @test map(PlantSimEngine._runtime_output_variable, assembled) == (:second, :first)
    @test typeof(assembled) === Tuple{
        PlantSimEngine.RuntimeOutputStream{:second,typeof(second_stream),typeof(second_reference)},
        PlantSimEngine.RuntimeOutputStream{:first,typeof(first_stream),typeof(first_reference)},
    }
    @test assembled[1].stream === second_stream
    @test assembled[2].stream === first_stream
    @test assembled[1].reference === second_reference
    @test assembled[2].reference === first_reference
    @test assembled[1].dependency_horizon == 3.0
    @test assembled[2].dependency_horizon == 0.0
    @test Set(keys(streams)) == Set([first_key, second_key])

    # These are live references, but assembly itself publishes no samples.
    status.first = 9.0
    status.second[1] = 4.0f0
    @test assembled[2].reference[] == 9.0
    @test assembled[1].reference[] === status.second
    @test assembled[1].reference[][1] == 4.0f0
    @test first_stream == [(0.0, 1.0)]
    @test isempty(second_stream)

    missing = Dict{Tuple{Symbol,ObjectId,Symbol},Any}(first_key => first_stream)
    @test_throws "No initialized retained output stream for application `probe` on object `target` and variable `second`." PlantSimEngine._runtime_model_output_streams(
        status, application, object_id, missing, retention,
    )
    @test Set(keys(missing)) == Set([first_key])
    initialized = PlantSimEngine._runtime_model_output_streams(
        status, application, object_id, missing, retention, true,
    )
    @test map(PlantSimEngine._runtime_output_variable, initialized) == (:second, :first)
    @test initialized[1].stream === missing[second_key]
    @test initialized[1].stream isa PlantSimEngine.TemporalDependencyBuffer{Vector{Float32}}
    @test initialized[2].stream === first_stream
    @test initialized[1].reference === second_reference
    @test initialized[2].reference === first_reference
    @test isempty(initialized[1].stream)
    @test first_stream == [(0.0, 1.0)]
    @test !haskey(missing, (:probe, object_id, :undeclared))

    fresh = empty(streams)
    fresh_outputs = PlantSimEngine._runtime_model_output_streams(
        status, application, object_id, fresh, retention, true,
    )
    @test fresh_outputs[2].stream === fresh[first_key]
    @test fresh_outputs[2].stream isa Vector{Tuple{Float64,Float64}}
    @test all(output -> isempty(output.stream), fresh_outputs)
end

@testset "empty retention never evaluates output defaults" begin
    evaluations = Ref(0)
    application = (
        id=:probe,
        spec=ModelSpec(CountedOutputPreparationProbe((output=zeros(3),), evaluations)),
    )
    for retained in (Dict{Symbol,Vector{Symbol}}(), Dict(:probe => Symbol[]))
        retention = PlantSimEngine.OutputRetentionPlan(
            false, Set{Tuple{Symbol,Symbol}}(), Set{Tuple{Symbol,Symbol}}(),
            Dict{Tuple{Symbol,Symbol},Float64}(), retained,
        )
        for initialize_missing in (false, true)
            evaluations[] = 0
            streams = Dict{Tuple{Symbol,ObjectId,Symbol},Any}()
            @test PlantSimEngine._runtime_model_output_streams(
                Status(), application, ObjectId(:target), streams, retention,
                initialize_missing,
            ) === ()
            @test evaluations[] == 0
            @test isempty(streams)
        end
    end
end
