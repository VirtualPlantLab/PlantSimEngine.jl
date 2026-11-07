module StatusViewCacheAdmissionChecks47

using PlantSimEngine, Test
const PSE = PlantSimEngine
const VIEW_KEY = (:consumer, ObjectId(:consumer))

PSE.@process "status_view_cache_admission_source" verbose=false
PSE.@process "status_view_cache_admission_scalar" verbose=false
PSE.@process "status_view_cache_admission_many" verbose=false
struct Source <: AbstractStatus_View_Cache_Admission_SourceModel
    level::Float64
end
struct ScalarConsumer <: AbstractStatus_View_Cache_Admission_ScalarModel end
struct ManyConsumer <: AbstractStatus_View_Cache_Admission_ManyModel end
PSE.inputs_(::Source) = NamedTuple()
PSE.outputs_(model::Source) = (signal=model.level,)
PSE.inputs_(::ScalarConsumer) = (signal=Required(Float64),)
PSE.inputs_(::ManyConsumer) = (signals=Required(AbstractVector),)
PSE.outputs_(::Union{ScalarConsumer,ManyConsumer}) = (value=0.0, visits=0)
PSE.run!(model::Source, status, environment, constants, context) =
    (status.signal = model.level; nothing)
function PSE.run!(::ScalarConsumer, status, environment, constants, context)
    status.value += status.signal
    status.visits += 1
    return nothing
end
function PSE.run!(::ManyConsumer, status, environment, constants, context)
    status.value += sum(bound_input(context, :signals); init=0.0)
    status.visits += 1
    return nothing
end

function fixture(mode=:one)
    mode in (:one, :many, :temporal) || error("unknown fixture mode")
    selector = mode === :many ? Many(scale=:Source, within=SceneScope(),
        application=:source, var=:signal) : One(scale=:Source, within=SceneScope(),
        application=:source, var=:signal)
    consumer = mode === :many ? ManyConsumer() : ScalarConsumer()
    inputs = mode === :many ? (signals=selector,) :
        mode === :temporal ? (PreviousTimeStep(:signal) => selector,) : (signal=selector,)
    status = mode === :many ? Status(signals=[2.0], value=0.0, visits=0) :
        Status(signal=2.0, value=0.0, visits=0)
    model = CompositeModel(Object(:scene; scale=:Scene),
        Object(:source_a; scale=:Source, parent=:scene, status=Status(signal=2.0)),
        Object(:consumer; scale=:Leaf, parent=:scene, status=status);
        applications=(
            ModelSpec(Source(2.0); name=:source, on=Many(scale=:Source)),
            ModelSpec(consumer; name=:consumer, on=One(id=:consumer), inputs=inputs),
        ))
    return (; model, simulation=run!(model; steps=0, outputs=:all), mode)
end

target(data) = only(target for batch in data.simulation.execution_plan.batches
    if batch.application.id === :consumer for target in batch.targets)
view_cache(data) = data.simulation.compiled.status_views_by_target
consumer_state(data) = deepcopy(NamedTuple(model_status(data.model, :consumer)))
consumer_cells(data) = Dict(name => PSE.refvalue(model_status(data.model, :consumer), name)
    for name in keys(model_status(data.model, :consumer)))
consumer_history(data) = Dict(key => [(time, deepcopy(value)) for (time, value) in stream]
    for (key, stream) in outputs(data.simulation) if first(key) === :consumer)

# Only metadata shells are reconstructed, using the real cache's statuses,
# references, input bindings and execution stamp. No defaults or kernels run.
function shell(view; status=view.status, canonical_status=view.canonical_status,
    temporal_inputs=view.temporal_inputs, bound_inputs=view.bound_inputs)
    return PSE.CompiledModelStatusView(view.execution_stamp, status, canonical_status,
        temporal_inputs, view.private_outputs, bound_inputs)
end

function reason(data, previous=target(data))
    simulation = data.simulation
    return PSE._model_execution_target_change_reason(previous, simulation.compiled,
        simulation.environment_bindings, simulation.compiled.applications_by_id[:consumer],
        simulation.output_retention, simulation.temporal_streams)
end

function refresh_plan!(data)
    simulation = data.simulation
    refreshed = PSE._refresh_model_execution_plan(simulation.execution_plan,
        simulation.compiled, simulation.environment_bindings, simulation.temporal_streams,
        simulation.output_retention, simulation.constants)
    simulation.execution_plan = refreshed.plan
    return refreshed
end

function assert_cells(data, before)
    after = consumer_cells(data)
    @test Set(keys(after)) == Set(keys(before))
    @test all(after[name] === reference for (name, reference) in before)
end

@testset "cached view admission keeps compatible scalar, Many and temporal owners" begin
    for mode in (:one, :many, :temporal)
        data, control = fixture(mode), fixture(mode)
        previous = target(data)
        context, cache = previous.context, previous.call_context_cache
        references = consumer_cells(data)
        before = consumer_state(data)
        views = view_cache(data)
        @test valtype(typeof(views)) === Any
        original = views[VIEW_KEY]
        compatible = shell(original)
        @test compatible isa PSE.CompiledModelStatusView
        @test compatible !== original
        views[VIEW_KEY] = compatible
        @test reason(data) === nothing
        retained = PSE._compiled_model_execution_target_from_previous(previous,
            data.simulation.compiled, data.simulation.environment_bindings,
            data.simulation.compiled.applications_by_id[:consumer], ObjectId(:consumer),
            data.simulation.temporal_streams, data.simulation.output_retention,
            data.simulation.constants)
        @test retained === previous
        refreshed = refresh_plan!(data)
        @test refreshed.targets_constructed == 0
        @test target(data) === previous
        @test previous.status_view === original
        @test target(data).context === context
        @test target(data).call_context_cache === cache
        @test cache.execution_stamp === original.execution_stamp === compatible.execution_stamp
        @test target(data).bound_inputs === compatible.bound_inputs
        @test consumer_state(data) == before
        assert_cells(data, references)
        if mode === :temporal
            @test only(previous.input_bindings).compiled === only(compatible.temporal_inputs)
        elseif mode === :many
            @test previous.context.bound_inputs.signals === compatible.bound_inputs.signals
        end
        step!(data.simulation)
        step!(control.simulation)
        @test consumer_state(data) == consumer_state(control)
        @test consumer_history(data) == consumer_history(control)
        @test target(data) === previous
        @test target(data).context === context
        assert_cells(data, references)
    end
end

@testset "cached view admission preserves canonical, bound and temporal identity reasons" begin
    data, other = fixture(), fixture()
    original = view_cache(data)[VIEW_KEY]
    delete!(view_cache(data), VIEW_KEY)
    @test reason(data) === :missing_status_view
    view_cache(data)[VIEW_KEY] = original
    # An actual foreign object's canonical status must still be rejected even
    # though its numerical state and concrete type match the current object.
    view_cache(data)[VIEW_KEY] = shell(original;
        canonical_status=model_status(other.model, :consumer))
    @test consumer_state(data) == consumer_state(other)
    @test reason(data) === :canonical_status
    view_cache(data)[VIEW_KEY] = original
    @test reason(data) === nothing

    for mode in (:many, :temporal)
        data, control = fixture(mode), fixture(mode)
        previous = target(data)
        original = view_cache(data)[VIEW_KEY]
        references = consumer_cells(data)
        before = consumer_state(data)
        replacement = if mode === :many
            old = original.bound_inputs.signals
            aligned_ids = copy(getfield(object_ids(old), :ids))
            bound = PSE.BoundMany(aligned_ids, parent(old))
            @test collect(bound) == collect(old)
            @test parent(bound) === parent(old)
            shell(original; bound_inputs=(signals=bound,))
        else
            old = only(original.temporal_inputs)
            input = PSE.CompiledTemporalInput(old.binding, copy(old.source_applications),
                old.initial, old.reference)
            @test input !== old
            @test input.reference === old.reference
            shell(original; temporal_inputs=(input,))
        end
        view_cache(data)[VIEW_KEY] = replacement
        @test reason(data) === (mode === :many ? :bound_inputs : :temporal_inputs)
        @test consumer_state(data) == before
        refreshed = refresh_plan!(data)
        current = target(data)
        @test refreshed.targets_constructed == 1
        @test current !== previous
        @test current.context !== previous.context
        @test current.call_context_cache !== previous.call_context_cache
        @test current.status_view === replacement
        @test current.call_context_cache.execution_stamp === previous.call_context_cache.execution_stamp
        @test reason(data) === nothing
        assert_cells(data, references)
        step!(data.simulation)
        step!(control.simulation)
        @test consumer_state(data) == consumer_state(control)
        @test consumer_history(data) == consumer_history(control)
        assert_cells(data, references)
    end
end

@testset "real source replacement changes a Ref and rebuilds without changing science" begin
    data, control = fixture(), fixture()
    previous = target(data)
    input_reference = PSE.refvalue(previous.status_view.status, :signal)
    value_reference = PSE.refvalue(previous.status_view.status, :value)
    visits_reference = PSE.refvalue(previous.status_view.status, :visits)
    remove_object!(data.model, :source_a)
    replacement = register_object!(data.model,
        Object(:source_b; scale=:Source, parent=:scene, status=Status(signal=2.0)))
    compiled = PSE.Advanced.refresh_bindings!(data.model)
    environment = PSE.refresh_environment_bindings!(data.model, compiled)
    current_view = compiled.status_views_by_target[VIEW_KEY]
    @test valtype(typeof(compiled.status_views_by_target)) === Any
    @test current_view isa PSE.CompiledModelStatusView
    @test PSE.refvalue(current_view.status, :signal) !== input_reference
    @test PSE.refvalue(current_view.status, :signal) === PSE.refvalue(replacement.status, :signal)
    @test current_view.status.signal == input_reference[] == 2.0
    @test PSE._model_execution_target_change_reason(previous, compiled, environment,
        compiled.applications_by_id[:consumer], data.simulation.output_retention,
        data.simulation.temporal_streams) === :status_view
    step!(data.simulation)
    step!(control.simulation)
    current = target(data)
    @test current !== previous
    @test current.context !== previous.context
    @test current.call_context_cache !== previous.call_context_cache
    @test PSE.refvalue(current.status_view.status, :signal) !== input_reference
    @test PSE.refvalue(current.status_view.status, :value) === value_reference
    @test PSE.refvalue(current.status_view.status, :visits) === visits_reference
    @test current.call_context_cache.execution_stamp === previous.call_context_cache.execution_stamp
    @test consumer_state(data) == consumer_state(control)
    @test consumer_history(data) == consumer_history(control)
    @test reason(data) === nothing
end

end # module StatusViewCacheAdmissionChecks47
