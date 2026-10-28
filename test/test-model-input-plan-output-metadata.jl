module InputPlanOutputMetadataChecks

using Dates, PlantSimEngine, Test

const PSE = PlantSimEngine
const D = PSE.Diagnostics

PSE.@process "input_plan_metadata_source" verbose=false
PSE.@process "input_plan_metadata_reader" verbose=false
PSE.@process "input_plan_metadata_distributed" verbose=false
PSE.@process "input_plan_metadata_sum" verbose=false

# Both the scalar port and the freshly allocated array declaration depend on
# instance parameters. A cache keyed by model type would conflate these models.
struct Source{T} <: AbstractInput_Plan_Metadata_SourceModel
    value::T
    port::Symbol
    payload::Symbol
    width::Int
    queries::Base.RefValue{Int}
    unit::Symbol
end
Source(value; port=:signal, payload=:source_payload, width=8,
    queries=Ref(0), unit=:metadata_signal) =
    Source(value, port, payload, width, queries, unit)
function PSE.outputs_(model::Source{T}) where {T}
    model.queries[] += 1
    return NamedTuple{(model.port, model.payload)}((zero(T), zeros(T, model.width)))
end
PSE.variable_contracts_(model::Source) =
    NamedTuple{(model.port,)}((VariableContract(unit=model.unit),))
function PSE.run!(model::Source, status, environment, constants, context)
    setproperty!(status, model.port, model.value * oftype(model.value, context.time))
    fill!(getproperty(status, model.payload), model.value)
    return nothing
end

struct Reader{T} <: AbstractInput_Plan_Metadata_ReaderModel
    initial::T
    port::Symbol
    observed::Symbol
    queries::Base.RefValue{Int}
    unit::Symbol
end
Reader(::Type{T}; port=:signal, observed=:observed, queries=Ref(0),
    unit=:metadata_signal) where {T} = Reader(zero(T), port, observed, queries, unit)
PSE.inputs_(model::Reader{T}) where {T} = NamedTuple{(model.port,)}((Required(T),))
function PSE.outputs_(model::Reader{T}) where {T}
    model.queries[] += 1
    return NamedTuple{(model.observed, Symbol(model.observed, :_payload))}((zero(T), zeros(T, 3)))
end
PSE.variable_contracts_(model::Reader) =
    NamedTuple{(model.port,)}((VariableContract(unit=model.unit),))
function PSE.run!(model::Reader, status, environment, constants, context)
    value = getproperty(status, model.port)
    setproperty!(status, model.observed, value)
    getproperty(status, Symbol(model.observed, :_payload))[1] = value
    return nothing
end

function query_scene(::Type{T}, count; explicit=false) where {T}
    source = Source(T(4))
    readers = [Reader(T) for _ in 1:count]
    applications = (
        ModelSpec(source; name=:source, on=Many(scale=:Cell)),
        (ModelSpec(readers[index]; name=Symbol(:reader_, index),
            on=One(id=Symbol(:cell_, index)),
            inputs=explicit ? (signal=One(within=Self(), application=:source),) : NamedTuple())
            for index in 1:count)...,
    )
    model = CompositeModel(
        (Object(Symbol(:cell_, index); scale=:Cell) for index in 1:count)...;
        applications, environment=(duration=Hour(1),))
    return (; model, source, readers)
end

function planner_pass(data, applications, destinations)
    data.source.queries[] = 0
    foreach(reader -> reader.queries[] = 0, data.readers)
    plans = PSE._compile_model_input_plans(data.model, applications, destinations)
    queries = (source=data.source.queries[], readers=[reader.queries[] for reader in data.readers])
    return plans, queries
end

plan_signature(plans) = [(plan.application_id, plan.input, plan.origin,
    plan.potential_source_application_ids) for plan in plans]

@testset "one input-plan pass bounds output declaration queries as consumers grow" begin
    for T in (Float32, Float64), explicit in (false, true), count in (1, 8, 32)
        data = query_scene(T, count; explicit)
        applications = PSE._compile_model_applications(data.model, data.model.applications,
            PSE._model_timeline(data.model))
        destinations = PSE._compile_model_output_destination_plans(data.model, applications)
        plans, queries = planner_pass(data, applications, destinations)
        @test length(plans) == count
        @test all(plan -> plan.potential_source_application_ids == (:source,), plans)
        @test all(plan -> plan.origin == (explicit ? :model_spec : :inferred_same_object), plans)
        # Contract validation still reads declarations for each real binding.
        # The producer scan itself must not add consumer × application queries.
        @test 1 <= queries.source <= count + 2
        @test all(query -> 1 <= query <= 3, queries.readers)
        @test queries.source + sum(queries.readers) <= 4 * count + 2
        repeated, fresh_queries = planner_pass(data, applications, destinations)
        @test plan_signature(repeated) == plan_signature(plans)
        @test 1 <= fresh_queries.source <= count + 2
        @test all(query -> 1 <= query <= 3, fresh_queries.readers)

        simulation = run!(data.model; steps=1, outputs=:all)
        for index in 1:count
            state = model_status(data.model, Symbol(:cell_, index))
            @test state.observed === T(4)
            @test state.observed_payload[1] === T(4)
            @test state.source_payload == fill(T(4), 8)
        end
        @test current_step(simulation) == 1
    end
end

@testset "planner metadata supports filtered applications with non-dense slots" begin
    data = query_scene(Float64, 8)
    applications = PSE._compile_model_applications(data.model, data.model.applications,
        PSE._model_timeline(data.model))
    selected = applications[[1, length(applications)]]
    @test getproperty.(selected, :slot) == [1, 9]
    plans, queries = planner_pass(data, selected, PSE.NoCompiledDistributedOutputPlans())
    @test plan_signature(plans) == [(:reader_8, :signal, :inferred_same_object, (:source,))]
    @test queries.source <= 3
    @test queries.readers[end] <= 3
    @test all(iszero, queries.readers[1:end-1])
end

@testset "per-application metadata and fresh recompiles preserve parameter-dependent schemas" begin
    for T in (Float32, Float64)
        first = Source(T(3); port=:alpha, width=2)
        second = Source(T(7); port=:beta, width=5)
        @test typeof(first) === typeof(second)
        a, b = Reader(T; port=:alpha, observed=:seen_a), Reader(T; port=:beta, observed=:seen_b)
        @test typeof(a) === typeof(b)
        model = CompositeModel(Object(:a; scale=:Cell), Object(:b; scale=:Cell);
            applications=(
                ModelSpec(first; name=:first, on=One(id=:a)),
                ModelSpec(second; name=:second, on=One(id=:b)),
                ModelSpec(a; name=:reader_a, on=One(id=:a)),
                ModelSpec(b; name=:reader_b, on=One(id=:b)),
            ), environment=(duration=Hour(1),))
        compiled = Advanced.refresh_bindings!(model)
        @test [(plan.input, plan.potential_source_application_ids)
            for plan in compiled.scenario_plan.input_plans] == [(:alpha, (:first,)), (:beta, (:second,))]
        simulation = run!(model; steps=1, outputs=:all)
        @test final_state(simulation, :a).seen_a === T(3)
        @test final_state(simulation, :b).seen_b === T(7)
        @test length(model_status(model, :a).source_payload) == 2
        @test length(model_status(model, :b).source_payload) == 5
        @test model_status(model, :a).source_payload !== model_status(model, :b).source_payload
        before = (first.queries[], second.queries[])
        refreshed = Advanced.refresh_bindings!(model; force=true)
        @test first.queries[] > before[1] && second.queries[] > before[2]
        @test plan_signature(refreshed.scenario_plan.input_plans) ==
            plan_signature(compiled.scenario_plan.input_plans)

        # A new scenario uses the same concrete model types with another schema;
        # no pass-local metadata may survive as a type- or process-level cache.
        third = Source(T(11); port=:gamma, width=11)
        @test typeof(third) === typeof(first)
        rebuilt = CompositeModel(Object(:c; scale=:Cell); applications=(
            ModelSpec(third; name=:first, on=One(id=:c)),
            ModelSpec(Reader(T; port=:gamma); name=:reader_a, on=One(id=:c)),
        ), environment=(duration=Hour(1),))
        fresh = run!(rebuilt; steps=1, outputs=:all)
        @test only(fresh.compiled.scenario_plan.input_plans).input == :gamma
        @test only(fresh.compiled.scenario_plan.input_plans).potential_source_application_ids == (:first,)
        @test final_state(fresh).observed === T(11)
        @test !hasproperty(model_status(rebuilt, :c), :alpha)
        @test !hasproperty(model_status(rebuilt, :c), :beta)
        @test length(model_status(rebuilt, :c).source_payload) == 11
    end
end

@testset "canonical inference excludes stream-only outputs while explicit binding retains them" begin
    for T in (Float32, Float64)
        canonical = Source(T(3); payload=:canonical_payload)
        stream = Source(T(9); payload=:stream_payload)
        model = CompositeModel(Object(:cell; scale=:Cell); applications=(
            ModelSpec(canonical; name=:canonical, on=One(id=:cell)),
            ModelSpec(stream; name=:stream, on=One(id=:cell), output_routing=(signal=:stream_only,)),
            ModelSpec(Reader(T; observed=:inferred_seen); name=:inferred, on=One(id=:cell)),
            ModelSpec(Reader(T; observed=:explicit_seen); name=:explicit, on=One(id=:cell),
                inputs=(signal=One(within=Self(), application=:stream),)),
        ), environment=(duration=Hour(1),))
        compiled = Advanced.refresh_bindings!(model)
        plans = compiled.scenario_plan.input_plans
        inferred = only(plan for plan in plans if plan.application_id == :inferred)
        explicit = only(plan for plan in plans if plan.application_id == :explicit)
        @test inferred.potential_source_application_ids == (:canonical,)
        @test explicit.potential_source_application_ids == (:stream,)
        simulation = run!(model; steps=1, outputs=:all)
        state = final_state(simulation)
        @test state.signal === T(3)
        @test state.inferred_seen === T(3)
        @test state.explicit_seen === T(9)
        @test outputs(simulation)[(:stream, ObjectId(:cell), :signal)] == [(1.0, T(9))]
        bindings = D.explain_bindings(compiled)
        @test only(row for row in bindings if row.application_id == :inferred).source_application_ids == [:canonical]
        @test only(row for row in bindings if row.application_id == :explicit).carrier_kind == :temporal_stream
    end
end

struct DistributedWriter{T} <: AbstractInput_Plan_Metadata_DistributedModel
    value::T
end
PSE.outputs_(::DistributedWriter{T}) where {T} =
    (local_marker=zero(T), sent=Distributed(Default(zero(T))))
PSE.variable_contracts_(::DistributedWriter) = (sent=VariableContract(unit=:metadata_signal),)
function PSE.run!(model::DistributedWriter, status, environment, constants, context)
    status.local_marker = model.value
    targets = output_targets(context, (:sent,))
    for index in eachindex(object_ids(targets))
        targets.columns.sent[index] = model.value + oftype(model.value, index)
    end
    return nothing
end
struct SumReader{T} <: AbstractInput_Plan_Metadata_SumModel end
PSE.inputs_(::SumReader{T}) where {T} = (values=Required(Vector{T}),)
PSE.outputs_(::SumReader{T}) where {T} = (total=zero(T),)
PSE.variable_contracts_(::SumReader) = (values=VariableContract(unit=:metadata_signal),)
function PSE.run!(::SumReader, status, environment, constants, context)
    status.total = sum(status.values)
    return nothing
end

@testset "distributed destinations remain potential producers independently of local names" begin
    for T in (Float32, Float64)
        model = CompositeModel(Object(:scene; scale=:Scene),
            Object(:a; scale=:Cell, parent=:scene), Object(:b; scale=:Cell, parent=:scene);
            applications=(
                ModelSpec(DistributedWriter(T(10)); name=:writer, on=One(id=:scene),
                    outputs_to=(OutputTo(Many(scale=:Cell, within=SceneScope())),)),
                ModelSpec(Reader(T; port=:sent); name=:reader, on=Many(scale=:Cell)),
                ModelSpec(SumReader{T}(); name=:sum, on=One(id=:scene),
                    inputs=(values=Many(scale=:Cell, within=Subtree(), application=:writer, var=:sent),)),
            ), environment=(duration=Hour(1),))
        simulation = run!(model; steps=1, outputs=:all)
        @test final_state(simulation, :a).observed === T(11)
        @test final_state(simulation, :b).observed === T(12)
        @test final_state(simulation, :scene).total === T(23)
        @test !hasproperty(model_status(model, :scene), :sent)
        @test !hasproperty(model_status(model, :a), :local_marker)
        @test all(plan -> plan.potential_source_application_ids == (:writer,),
            simulation.compiled.scenario_plan.input_plans)
    end
end

@testset "empty-selector plans retain contracts and acquire live carriers after growth" begin
    for T in (Float32, Float64)
        source, reader = Source(T(4)), Reader(T)
        model = CompositeModel(Object(:scene; scale=:Scene); applications=(
            ModelSpec(source; name=:source, on=Many(scale=:Cell)),
            ModelSpec(reader; name=:reader, on=Many(scale=:Cell)),
        ), environment=(duration=Hour(1),))
        simulation = run!(model; steps=1, outputs=:none)
        @test only(simulation.compiled.scenario_plan.input_plans).potential_source_application_ids == (:source,)
        @test isempty(model_objects(model; scale=:Cell))
        register_object!(model, Object(:a; scale=:Cell, parent=:scene))
        step!(simulation)
        @test model_status(model, :a).observed === T(8)
        @test PSE.refvalue(model_status(model, :a), :signal) ===
            only(binding.carrier for binding in simulation.compiled.input_bindings
                if binding.application_id == :reader && binding.consumer_id == ObjectId(:a))
        register_object!(model, Object(:b; scale=:Cell, parent=:scene))
        step!(simulation)
        @test model_status(model, :a).observed === model_status(model, :b).observed === T(12)
        @test model_status(model, :a).source_payload !== model_status(model, :b).source_payload
        model_status(model, :a).source_payload[1] = T(-1)
        @test model_status(model, :b).source_payload[1] === T(4)
        old_queries = source.queries[]
        Advanced.refresh_bindings!(model; force=true)
        @test source.queries[] > old_queries

        incompatible = CompositeModel(Object(:scene; scale=:Scene); applications=(
            ModelSpec(Source(T(4)); name=:source, on=Many(scale=:Cell)),
            ModelSpec(Reader(T; unit=:incompatible_signal); name=:reader, on=Many(scale=:Cell)),
        ), environment=(duration=Hour(1),))
        @test_throws "Incompatible variable contracts" Advanced.refresh_bindings!(incompatible)
    end
end

@testset "object overrides keep application metadata and numerical ownership distinct" begin
    for T in (Float32, Float64)
        base, alternate = Source(T(2)), Source(T(7))
        template = CompositeModelTemplate((
            ModelSpec(base; name=:source, on=Many(scale=:Cell)),
            ModelSpec(Reader(T); name=:reader, on=Many(scale=:Cell)),
        ))
        instance = ObjectInstance(:plant, template;
            root=Object(:plant; scale=:Plant),
            objects=(Object(:a; scale=:Cell, parent=:plant), Object(:b; scale=:Cell, parent=:plant)),
            object_overrides=(Override(object=:b, application=:source, model=alternate),))
        model = CompositeModel(instance; environment=(duration=Hour(1),))
        simulation = run!(model; steps=1, outputs=:all)
        @test final_state(simulation, :a).observed === T(2)
        @test final_state(simulation, :b).observed === T(7)
        @test model_status(model, :a).source_payload == fill(T(2), 8)
        @test model_status(model, :b).source_payload == fill(T(7), 8)
        @test model_status(model, :a).source_payload !== model_status(model, :b).source_payload
        @test base.queries[] > 0 && alternate.queries[] > 0
    end
end

end # module
