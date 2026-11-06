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
    recipe = compiled.scenario_plan.input_recipes_by_application.reader
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
    @test PSE._input_reference_carrier(One(), ids[1:1], reference_for) === cells[1]
    @test visited == [1]
    empty!(visited)
    @test isnothing(PSE._input_reference_carrier(OptionalOne(), ObjectId{Int}[], reference_for))
    @test isempty(visited)
    homogeneous = PSE._input_reference_carrier(Many(), ids, reference_for)
    @test homogeneous isa PSE.RefVector{Float64}
    @test visited == [1, 2, 3]
    @test all(parent(homogeneous)[index] === cells[index] for index in eachindex(cells))
    cells[2][] = 8.0
    @test homogeneous[2] === 8.0

    mixed = Base.RefValue[Ref(1f0), Ref(2.0), Ref(3)]
    empty!(visited)
    mixed_for(id) = (push!(visited, id.value); mixed[id.value])
    heterogeneous = PSE._input_reference_carrier(Many(), ids, mixed_for)
    @test heterogeneous isa PSE.ObjectRefVector
    @test visited == [1, 2, 3]
    @test all(parent(heterogeneous)[index] === mixed[index] for index in eachindex(mixed))
    @test typeof.(collect(heterogeneous)) == [Float32, Float64, Int]
    mixed[1][] = 7f0
    @test heterogeneous[1] === 7f0

    abstract = Ref{Real}(1.0)
    @test PSE._input_reference_carrier(Many(), ids[1:1], _ -> abstract) isa PSE.ObjectRefVector
    @test PSE._input_reference_carrier(Many(), ObjectId{Int}[], reference_for) isa PSE.RefVector{Any}
    @test isnothing(PSE._input_reference_carrier(One(), ids[1:1], _ -> nothing))
    empty!(visited)
    missing_for(id) = (push!(visited, id.value); id.value == 2 ? nothing : cells[id.value])
    @test isnothing(PSE._input_reference_carrier(Many(), ids, missing_for))
    @test visited == [1, 2]
    external = Ref([4.0], 1)
    @test_throws ArgumentError PSE._input_reference_carrier(One(), ids[1:1], _ -> external)
    @test_throws ArgumentError PSE._input_reference_carrier(Many(), ids[1:1], _ -> external)
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
        carrier = PSE._input_reference_carrier(Many(), ids, getter)
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
    @test PSE._input_reference_carrier(Many(), empty_ids, _ -> error("empty source visited")) isa PSE.RefVector{Any}
    @test isempty(empty_ids.reads)
    for selector in (One(), OptionalOne())
        ids = OffsetSourceIds([ObjectId(1)], 7)
        cell = Ref(5.0)
        @test PSE._input_reference_carrier(selector, ids, _ -> cell) === cell
        @test ids.reads == [7]
    end
end

@noinline function repeat_point_carrier(model, selector, ids, expected, repetitions)
    same = true
    for _ in 1:repetitions
        same &= PSE._input_carrier(model, selector, ids, Val(:x)) === expected
    end
    return same
end
@noinline point_allocations(model, selector, ids, expected, repetitions) =
    @allocated repeat_point_carrier(model, selector, ids, expected, repetitions)
@noinline many_allocations(ids, getter) =
    @allocated PSE._input_reference_carrier(Many(), ids, getter)

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
