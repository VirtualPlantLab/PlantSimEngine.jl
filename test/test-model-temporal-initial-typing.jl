module TemporalInitialTypingChecks
using Dates, Test, PlantSimEngine
const PSE = PlantSimEngine
PSE.@process "typed_initial_source" verbose=false
PSE.@process "typed_initial_consumer" verbose=false
struct Source{T} <: AbstractTyped_Initial_SourceModel
    initial::T
end
PSE.outputs_(model::Source) = (signal=model.initial,)
function PSE.run!(::Source, status, environment, constants, context)
    status.signal += one(status.signal)
    return nothing
end
struct Consumer{T} <: AbstractTyped_Initial_ConsumerModel end
PSE.inputs_(::Consumer) = (signals=Required(AbstractVector),)
PSE.outputs_(::Consumer{T}) where {T} = (total=zero(T),)
function PSE.run!(::Consumer, status, environment, constants, context)
    status.total = sum(status.signals; init=zero(status.total))
    return nothing
end
function fixture(::Type{T}; empty=false) where {T}
    objects = Object[Object(:scene; scale=:Scene, status=Status(signals=T[]))]
    empty || push!(objects, Object(:a; scale=:Leaf, parent=:scene, status=Status(signal=T(2))))
    return CompositeModel(objects...; applications=(
        ModelSpec(Source(zero(T)); name=:source, on=Many(scale=:Leaf)),
        ModelSpec(Consumer{T}(); name=:consumer, on=One(scale=:Scene),
            inputs=(PreviousTimeStep(:signals) => Many(scale=:Leaf, within=SceneScope(),
                application=:source, var=:signal),)),
    ), environment=(duration=Hour(1),))
end
input(sim) = only(sim.compiled.status_views_by_target[(:consumer, ObjectId(:scene))].temporal_inputs)

@testset "homogeneous initial values retain their numerical schema across growth" begin
    for T in (Float32, Float64), retention in (:none, :all)
        model = fixture(T)
        sim = run!(model; steps=1, outputs=retention)
        initial = input(sim).initial
        @test initial isa Vector{T}
        @test initial == T[2]
        @test all(group -> isconcretetype(eltype(group.batches)), sim.execution_plan.groups)
        @test final_state(sim, :scene).total === T(2)
        register_object!(model, Object(:b; scale=:Leaf, status=Status(signal=T(10))); parent=:scene)
        continue!(sim; steps=1)
        @test input(sim).initial isa Vector{T}
        @test input(sim).initial == T[2, 10]
        @test final_state(sim, :scene).total === T(13)
        remove_object!(model, :a)
        continue!(sim; steps=1)
        @test input(sim).initial isa Vector{T}
        @test input(sim).initial == T[10]
        @test final_state(sim, :scene).total === T(11)
        if retention === :all
            @test outputs(sim)[(:consumer, ObjectId(:scene), :total)] ==
                [(1.0, T(2)), (2.0, T(13)), (3.0, T(11))]
            @test haskey(outputs(sim), (:source, ObjectId(:a), :signal))
        end
        remove_object!(model, :b)
        step!(sim)
        @test final_state(sim, :scene).total === zero(T)
        @test all(group -> all(batch -> !isempty(batch.targets), group.batches), sim.execution_plan.groups)
        register_object!(model, Object(:c; scale=:Leaf, status=Status(signal=T(20))); parent=:scene)
        step!(sim)
        @test final_state(sim, :scene).total === T(20)
        @test all(group -> isconcretetype(eltype(group.batches)), sim.execution_plan.groups)
    end
end
@testset "empty memberships can acquire a concrete schema" begin
    for T in (Float32, Float64)
        model = fixture(T; empty=true)
        sim = run!(model; steps=1, outputs=:all)
        @test isempty(input(sim).initial)
        @test final_state(sim, :scene).total === zero(T)
        register_object!(model, Object(:a; scale=:Leaf, status=Status(signal=T(7))); parent=:scene)
        step!(sim)
        @test input(sim).initial isa Vector{T}
        @test input(sim).initial == T[7]
        @test final_state(sim, :scene).total === T(7)
    end
end
@testset "heterogeneous snapshots never convert values into the first schema" begin
    mixed = Any[Float32(1.25), Float64(2.5)]
    result = PSE._construct_status_view_initial(Vector{Any}, mixed, true)
    @test result === mixed
    @test typeof.(result) == [Float32, Float64]
    private = Any[Float32[1, 2], Float32[3, 4]]
    typed = PSE._construct_status_view_initial(Vector{Vector{Float32}}, private, true)
    @test typed isa Vector{Vector{Float32}}
    @test typed[1] === private[1]
    @test typed[2] === private[2]
    # This helper narrows an already private snapshot, never copies its payload.
    typed[1][1] = 9
    @test private[1][1] === 9f0
end

function rebuild_input(ids, initial)
    binding = (selector=Many(), source_ids=ObjectId.(ids))
    storage = PSE.RefVector(Base.RefValue{Any}[
        Ref{Any}(deepcopy(value)) for value in initial
    ])
    return PSE.CompiledTemporalInput(binding, fill(nothing, length(ids)), initial, Ref(storage))
end

@testset "rebuilding temporal membership preserves the saved initial schema" begin
    for saved in (1.25f0, 1 // 3, Float32[1, 2])
        fresh = saved isa AbstractVector ? [Float64[9, 10], Float64[11, 12]] : [9.0, 11.0]
        previous = rebuild_input((:retained, :removed), [saved, deepcopy(saved)])
        current = rebuild_input((:newborn, :retained), fresh)
        carrier = current.reference[]
        restored = PSE._preserve_temporal_input_state!(
            current, previous, previous.binding.source_ids,
        )
        @test restored.initial isa Vector{Any}
        @test restored.initial !== current.initial
        @test restored.initial[1] === current.initial[1]
        @test typeof(restored.initial[2]) === typeof(saved)
        @test isequal(restored.initial[2], saved)
        @test restored.reference === current.reference
        @test restored.reference[] === carrier
        @test typeof(carrier[2]) === typeof(saved)
        @test isequal(carrier[2], saved)
        if saved isa AbstractVector
            @test restored.initial[2] !== previous.initial[1]
            @test carrier[2] !== previous.reference[][1]
            restored.initial[2][1] = 7f0
            @test previous.initial[1] == Float32[1, 2]
        end
    end
    # Compatible homogeneous and heterogeneous snapshots keep the existing
    # vector, including when surviving identities change their positions.
    for initial in (Float32[9, 11], Any[9.0, 11.0])
        previous = rebuild_input((:b, :a), Float32[2, 3])
        current = rebuild_input((:a, :b), initial)
        restored = PSE._preserve_temporal_input_state!(
            current, previous, previous.binding.source_ids,
        )
        @test restored.initial === initial
        @test restored.initial[1] === 3f0
        @test restored.initial[2] === 2f0
    end
end
# Ordinary heterogeneous support remains available outside finite preparation.
function mixed_factory_fixture()
    return CompositeModel(
        Object(:scene; scale=:Scene, status=Status(signals=Any[])),
        Object(:a; scale=:Leaf, parent=:scene, status=Status(signal=1.25f0)),
        Object(:b; scale=:Leaf, parent=:scene, status=Status(signal=2.5));
        applications=(
            ModelSpec(Source(0f0); name=:source, on=Many(scale=:Leaf)),
            ModelSpec(Consumer{Float64}(); name=:consumer, on=One(scale=:Scene),
                inputs=(PreviousTimeStep(:signals) => Many(scale=:Leaf,
                    within=SceneScope(), application=:source, var=:signal),)),
        ), environment=(duration=Hour(1),))
end
@testset "mixed private reference creation keeps its explicit finite evidence gap" begin
    model = mixed_factory_fixture()
    simulation = run!(model; steps=0, outputs=:none)
    temporal = input(simulation)
    @test temporal.initial isa Vector{Any}
    @test typeof.(temporal.initial) == [Float32, Float64]
    @test temporal.reference[] isa PSE.ObjectRefVector
    @test typeof.(temporal.reference[]) == [Float32, Float64]
    for (id, reference) in zip(temporal.binding.source_ids, parent(temporal.reference[]))
        @test reference !== PSE.refvalue(model_status(model, id), :signal)
    end
    compiled = simulation.compiled
    source_types = unique(typeof(view) for ((application, _), view) in compiled.status_views_by_target
        if application === :source)
    schema = PSE.CompiledMetadataTable((
        source=Vector{Union{source_types...}}(),
        consumer=Vector{typeof(compiled.status_views_by_target[(:consumer, ObjectId(:scene))])}(),
    ))
    prototype = Vector{Union{unique(typeof(binding) for binding in compiled.input_bindings)...}}()
    before = model.binding_cache
    @test_throws "mixed private ObjectRefVector storage requires source-reference family evidence" PSE._prepare_simulation!(
        model; steps=0, outputs=:none, constants=PSE.Constants(),
        status_view_schema=schema, input_binding_storage=prototype)
    @test model.binding_cache === before
    @test typeof.(temporal.initial) == [Float32, Float64]
    step!(simulation)
    @test final_state(simulation, :scene).total === 3.75
end


struct PairedSource <: AbstractTyped_Initial_SourceModel end
PSE.outputs_(::PairedSource) = (a=0f0, b=0f0)
function PSE.run!(::PairedSource, status, environment, constants, context)
    status.a += one(status.a)
    status.b += one(status.b)
    return nothing
end
struct PairedConsumer <: AbstractTyped_Initial_ConsumerModel end
PSE.inputs_(::PairedConsumer) = (first_values=Required(AbstractVector), second_values=Required(AbstractVector))
PSE.outputs_(::PairedConsumer) = (total=0.0,)
function PSE.run!(::PairedConsumer, status, environment, constants, context)
    status.total = sum(status.first_values; init=zero(status.total)) +
        sum(status.second_values; init=zero(status.total))
    return nothing
end

function paired_temporal_scene()
    return CompositeModel(
        Object(:scene; scale=:Scene,
            status=Status(first_values=Float32[], second_values=Float32[], total=0.0)),
        Object(:a; scale=:Leaf, parent=:scene, status=Status(a=2f0, b=3f0)),
        Object(:other; scale=:Scene),
        # A real configured source family exists before preparation, outside the
        # consumer's Subtree. It contributes type evidence, never consumer values.
        Object(:outside; scale=:Leaf, parent=:other, status=Status(a=0f0, b=0.0));
        applications=(
            ModelSpec(PairedSource(); name=:paired_source, on=Many(scale=:Leaf)),
            ModelSpec(PairedConsumer(); name=:paired_consumer, on=One(id=:scene), inputs=(
                PreviousTimeStep(:first_values) => Many(scale=:Leaf, within=Subtree(), application=:paired_source, var=:a),
                PreviousTimeStep(:second_values) => Many(scale=:Leaf, within=Subtree(), application=:paired_source, var=:b),
            )),
        ), environment=(duration=Hour(1),))
end

@testset "configured temporal growth preserves snapshots and complete values" begin
    model = paired_temporal_scene()
    simulation = run!(model; steps=1, outputs=:all)
    @test final_state(simulation, :scene).total === 5.0
    old_inputs = simulation.compiled.status_views_by_target[
        (:paired_consumer, ObjectId(:scene))].temporal_inputs
    first_private, second_private = map(old_inputs) do temporal
        only(parent(temporal.reference[]))
    end
    @test second_private isa Base.RefValue{Float32}
    @test first_private !== PSE.refvalue(model_status(model, :a), :a)
    @test second_private !== PSE.refvalue(model_status(model, :a), :b)

    register_object!(model, Object(:b; scale=:Leaf, parent=:scene,
        status=Status(a=10f0, b=20.0)))
    step!(simulation)
    current = simulation.compiled.status_views_by_target[
        (:paired_consumer, ObjectId(:scene))].temporal_inputs
    # Mixed snapshot storage rebuilds the private views. Existing values survive
    # without mutating a saved view or sharing live canonical source cells.
    @test first(current[1].reference[]) === 3f0
    @test first(current[2].reference[]) === 4f0
    @test first_private[] === 2f0
    @test second_private[] === 3f0
    @test first(parent(current[1].reference[])) !== PSE.refvalue(model_status(model, :a), :a)
    @test first(parent(current[2].reference[])) !== PSE.refvalue(model_status(model, :a), :b)
    @test last(parent(current[2].reference[])) isa Base.RefValue{Float64}
    @test last(parent(current[2].reference[])) !== PSE.refvalue(model_status(model, :b), :b)
    @test current[1].binding.source_ids == [ObjectId(:a), ObjectId(:b)]
    @test current[2].binding.source_ids == [ObjectId(:a), ObjectId(:b)]
    @test final_state(simulation, :scene).total === 37.0
    @test outputs(simulation)[(:paired_consumer, ObjectId(:scene), :total)] ==
        [(1.0, 5.0), (2.0, 37.0)]
end

@testset "an unprepared temporal family cannot partly extend private snapshots" begin
    model = paired_temporal_scene()
    simulation = run!(model; steps=1, outputs=:all)
    temporal_inputs = simulation.compiled.status_views_by_target[
        (:paired_consumer, ObjectId(:scene))].temporal_inputs
    before = map(temporal_inputs) do temporal
        (initial=copy(temporal.initial), values=collect(temporal.reference[]),
            references=Tuple(parent(temporal.reference[])), owner=temporal.reference)
    end
    history = copy(outputs(simulation)[(:paired_consumer, ObjectId(:scene), :total)])
    # The first input's Ref32 is admitted. The second has neither the configured
    # Ref32 nor Ref64 type, so no existing private snapshot may be extended.
    register_object!(model, Object(:b; scale=:Leaf, parent=:scene,
        status=Status(a=10f0, b=big"20.0")))
    @test_throws "outside its prepared Many family" step!(simulation)
    for (temporal, saved) in zip(temporal_inputs, before)
        @test temporal.initial == saved.initial
        @test collect(temporal.reference[]) == saved.values
        @test Tuple(parent(temporal.reference[])) === saved.references
        @test temporal.reference === saved.owner
    end
    @test outputs(simulation)[(:paired_consumer, ObjectId(:scene), :total)] == history
end

end

module PreparedPublicationChecks
using Dates, Random, Test, PlantSimEngine
const PSE = PlantSimEngine
import ..TemporalInitialTypingChecks: AbstractTyped_Initial_SourceModel, Consumer
struct PublicationSource{T,R} <: AbstractTyped_Initial_SourceModel
    initial::T
    rng::R
end
PSE.outputs_(model::PublicationSource) = (signal=model.initial, visits=0)
function PSE.run!(model::PublicationSource, status, environment, constants, context)
    status.signal += rand(model.rng, typeof(status.signal))
    status.visits += 1
    return nothing
end

# A model-owned RNG and an unconsumed output distinguish the :none and :all
# publication shapes while keeping both future applications initially empty.
function scene(; leaf=false, outputs=:none)
    rng = Xoshiro(917)
    objects = Object[Object(:scene; scale=:Scene, status=Status(signals=Float64[]))]
    leaf && push!(objects, Object(:leaf; scale=:Leaf, parent=:scene,
        status=Status(signal=2.0, visits=0, signals=Float64[])))
    model = CompositeModel(objects...; applications=(
        ModelSpec(PublicationSource(0.0, rng); name=:source, on=Many(scale=:Leaf)),
        ModelSpec(Consumer{Float64}(); name=:consumer, on=Many(scale=:Leaf),
            inputs=(PreviousTimeStep(:signals) => Many(scale=:Leaf, within=SceneScope(),
                application=:source, var=:signal),)),
    ), environment=(duration=Hour(1),))
    simulation = run!(model; steps=0, outputs)
    return (; model, simulation, rng)
end

group(simulation, id) = only(group for group in simulation.execution_plan.groups
    if group.application.id === id)
real_batch(simulation, id) = only(group(simulation, id).batches)
schema(batch) = PSE.PreparedExecutionBatchSchema{Vector{typeof(batch)}}()
variables(simulation, id) = Tuple(get(
    simulation.output_retention.retained_outputs_by_application, id, ()))
states(data) = Dict(object.id => deepcopy(NamedTuple(object.status))
    for object in model_objects(data.model))
history(data) = Dict(key => [(time, deepcopy(value)) for (time, value) in stream]
    for (key, stream) in outputs(data.simulation))
rng_probe(data) = rand(copy(data.rng), UInt64, 8)
function assert_parity(ordinary, prepared)
    @test current_step(ordinary.simulation) == current_step(prepared.simulation)
    @test states(ordinary) == states(prepared)
    @test history(ordinary) == history(prepared)
    @test rng_probe(ordinary) == rng_probe(prepared)
end

function check_initially_empty_publication()
    witness = scene(; leaf=true)
    before_rng = rng_probe(witness)
    future_batch = real_batch(witness.simulation, :source)
    future_schema = schema(future_batch)
    @test rng_probe(witness) == before_rng
    @test !isempty(variables(witness.simulation, :source))

    ordinary, candidate = scene(), scene()
    # The schema is learned from a real nonempty scene before either target exists.
    @test isempty(variables(candidate.simulation, :source))
    application = candidate.simulation.compiled.applications_by_id[:source]
    @test isempty(application.target_ids)
    @test typeof(application) === fieldtype(typeof(future_batch), :application)
    future_consumer = real_batch(witness.simulation, :consumer)
    schemas = (source=future_schema, consumer=schema(future_consumer))
    before = states(candidate)
    before_random = rng_probe(candidate)
    cells = Dict((object.id, name) => PSE.refvalue(object.status, name)
        for object in model_objects(candidate.model) for name in keys(object.status))
    current_variables = variables(candidate.simulation, :source)
    future_variables = variables(witness.simulation, :source)
    valid_preconditions = isempty(current_variables) && !isempty(future_variables) &&
        isempty(application.target_ids) &&
        typeof(application) === fieldtype(typeof(future_batch), :application)
    @test valid_preconditions
    valid_preconditions || return nothing
    prepared = PSE._prepare_execution_batch_schemas(candidate.simulation, schemas)
    @test prepared isa PSE.Simulation
    candidate = merge(candidate, (simulation=prepared,))
    @test states(candidate) == before
    @test rng_probe(candidate) == before_random
    @test all(PSE.refvalue(model_status(candidate.model, id), name) === cell
        for ((id, name), cell) in cells)
    @test isempty(group(prepared, :source).batches)

    step!(ordinary.simulation)
    step!(candidate.simulation)
    assert_parity(ordinary, candidate)
    for data in (ordinary, candidate)
        register_object!(data.model, Object(:newborn; scale=:Leaf, parent=:scene,
            status=Status(signal=7.0, visits=0, signals=Float64[])))
    end
    for _ in 1:3
        step!(ordinary.simulation)
        step!(candidate.simulation)
        assert_parity(ordinary, candidate)
        batch = real_batch(candidate.simulation, :source)
        @test batch isa typeof(future_batch)
        target = only(batch.targets)
        status = model_status(candidate.model, :newborn)
        @test target.status_view.canonical_status === status
        @test PSE.refvalue(target.status_view.status, :signal) === PSE.refvalue(status, :signal)
    end
    source_group = group(candidate.simulation, :source)
    previous_batches = source_group.batches
    previous_rows = only(previous_batches).targets
    retired = PSE.cohort_location(previous_rows.store, :source, ObjectId(:newborn);
        owner=previous_rows.cohort.owner)
    before_empty_rng = (rng_probe(ordinary), rng_probe(candidate))
    retained_histories = [Dict(key => value for (key, value) in history(data)
        if first(key) === :source) for data in (ordinary, candidate)]
    for data in (ordinary, candidate)
        remove_object!(data.model, :newborn)
        step!(data.simulation)
    end
    assert_parity(ordinary, candidate)
    @test rng_probe(ordinary) == before_empty_rng[1]
    @test rng_probe(candidate) == before_empty_rng[2]
    @test group(candidate.simulation, :source) === source_group
    @test source_group.batches === previous_batches
    @test isempty(source_group.batches)
    @test isnothing(PSE.cohort_location(previous_rows.store, :source, ObjectId(:newborn);
        owner=previous_rows.cohort.owner))
    @test isnothing(retired.cohort.rows[retired.row])
    for (data, old_history) in zip((ordinary, candidate), retained_histories)
        @test all(history(data)[key] == values for (key, values) in old_history)
        register_object!(data.model, Object(:regrown; scale=:Leaf, parent=:scene,
            status=Status(signal=11.0, visits=0, signals=Float64[])))
        step!(data.simulation)
    end
    assert_parity(ordinary, candidate)
    @test group(candidate.simulation, :source) === source_group
    regrown_batch = only(source_group.batches)
    @test regrown_batch isa typeof(future_batch)
    @test regrown_batch.targets.cohort === previous_rows.cohort
    regrown = PSE.cohort_location(previous_rows.store, :source, ObjectId(:regrown);
        owner=previous_rows.cohort.owner)
    @test regrown.cohort === retired.cohort
    @test regrown.row != retired.row
    @test isnothing(retired.cohort.rows[retired.row])
    regrown_status = model_status(candidate.model, :regrown)
    @test only(regrown_batch.targets).status_view.canonical_status === regrown_status
    @test PSE.refvalue(only(regrown_batch.targets).status_view.status, :signal) ===
        PSE.refvalue(regrown_status, :signal)
    for (data, old_history) in zip((ordinary, candidate), retained_histories)
        @test all(history(data)[key] == values for (key, values) in old_history)
    end
end

@testset "a real future publication schema admits an initially empty scheduled source" begin
    check_initially_empty_publication()
end

@testset "a nonempty real batch keeps strict publication-shape rejection" begin
    current = scene(; leaf=true, outputs=:none)
    different = scene(; leaf=true, outputs=:all)
    actual_group = group(current.simulation, :source)
    actual_batch = only(actual_group.batches)
    different_batch = real_batch(different.simulation, :source)
    @test !isempty(actual_batch.targets)
    @test typeof(actual_group.application) === fieldtype(typeof(different_batch), :application)
    @test length(variables(current.simulation, :source)) !=
        length(variables(different.simulation, :source))
    before, before_history, before_rng = states(current), history(current), rng_probe(current)
    original_batches = actual_group.batches
    @test_throws "Retained publication shape is outside its prepared batch schema." PSE._model_execution_batches(
        current.simulation.environment_bindings, actual_group.application,
        actual_group.membership, current.simulation.output_retention, actual_group;
        batch_schema=schema(different_batch))
    @test actual_group.batches === original_batches
    @test only(actual_group.batches) === actual_batch
    @test states(current) == before
    @test history(current) == before_history
    @test rng_probe(current) == before_rng
end

end
