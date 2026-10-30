module NativeStorageFeatures

using Dates
using Test
using MultiScaleTreeGraph
using PlantSimEngine

const PSE = PlantSimEngine
const CR = Main.CompiledRegionsExperiment
const Scalar = Main.NativeScalarDriver
const Snapshot = Main.NativeXPDriver

PSE.@process "native_feature_producer" verbose=false
PSE.@process "native_feature_consumer" verbose=false
PSE.@process "native_feature_temporal" verbose=false
PSE.@process "native_feature_distributor" verbose=false
PSE.@process "native_feature_initializer" verbose=false
PSE.@process "native_feature_touch" verbose=false
PSE.@process "native_feature_creator" verbose=false

struct NativeFeatureProducer{T} <: AbstractNative_Feature_ProducerModel
    increment::T
end
PSE.inputs_(::NativeFeatureProducer) = NamedTuple()
PSE.outputs_(model::NativeFeatureProducer) = (signal=zero(model.increment),)
PSE.run!(model::NativeFeatureProducer, status, environment, constants, context) =
    (status.signal += model.increment; nothing)
CR.region_effects(::Type{<:NativeFeatureProducer}) = :local_ports

struct NativeFeatureConsumer <: AbstractNative_Feature_ConsumerModel end
PSE.inputs_(::NativeFeatureConsumer) = (
    single=PSE.Required(Float32), optional=PSE.Default(-1.0f0),
    signals=PSE.Required(Vector{Float32}),
)
PSE.outputs_(::NativeFeatureConsumer) = (
    total=0.0f0, single_seen=0.0f0, optional_seen=0.0f0,
    seen_ids=PSE.ObjectId[], seen_values=Float32[],
)
function PSE.run!(::NativeFeatureConsumer, status, environment, constants, context)
    values_ = PSE.bound_input(context, :signals)
    status.total = sum(values_; init=0.0f0)
    status.single_seen = status.single
    status.optional_seen = status.optional
    status.seen_ids = collect(PSE.object_ids(values_))
    status.seen_values = collect(values_)
    return nothing
end

struct NativeFeatureTemporal <: AbstractNative_Feature_TemporalModel end
PSE.inputs_(::NativeFeatureTemporal) = (previous=PSE.Default(0.0f0),)
PSE.outputs_(::NativeFeatureTemporal) = (observed_previous=0.0f0,)
PSE.run!(::NativeFeatureTemporal, status, environment, constants, context) =
    (status.observed_previous = status.previous; nothing)

struct NativeFeatureDistributor <: AbstractNative_Feature_DistributorModel end
PSE.inputs_(::NativeFeatureDistributor) = NamedTuple()
PSE.outputs_(::NativeFeatureDistributor) = (assigned=PSE.Distributed(PSE.Default(0.0f0)),)
function PSE.run!(::NativeFeatureDistributor, status, environment, constants, context)
    targets = PSE.output_targets(context, (:assigned,))
    ids = collect(PSE.object_ids(targets))
    # A shuffled identified table exercises exact coverage/permutation rather
    # than relying on physical column positions or the current selector order.
    table = (object_id=reverse(ids), assigned=Float32[10 * row for row in reverse(eachindex(ids))])
    PSE.assign_outputs!(targets, table; id=:object_id)
    return nothing
end

function coupling_fixture(; native::Bool)
    template = PSE.CompositeModelTemplate((
        PSE.ModelSpec(NativeFeatureProducer(1.0f0); name=:produce,
            on=PSE.Many(kind=:unit), every=Hour(1)),
    ))
    instance = PSE.ObjectInstance(:plant, template;
        root=PSE.Object(:plant; parent=:scene),
        objects=(
            PSE.Object(1; kind=:unit, parent=:plant, status=(signal=0.0f0,)),
            PSE.Object(2; kind=:unit, parent=:plant, status=(signal=0.0f0,)),
        ),
        object_overrides=(PSE.Override(object=2, application=:produce,
            model=NativeFeatureProducer(2.0f0)),))
    applications = (
        PSE.ModelSpec(NativeFeatureConsumer(); name=:consume,
            on=PSE.One(id=:consumer), every=Hour(1), inputs=(
                single=PSE.One(id=1, within=PSE.SceneScope(), var=:signal),
                optional=PSE.OptionalOne(id=99, within=PSE.SceneScope(), var=:signal),
                signals=PSE.Many(kind=:unit, within=PSE.SceneScope(), var=:signal),
            )),
        PSE.ModelSpec(NativeFeatureTemporal(); name=:temporal,
            on=PSE.One(id=:temporal), every=Hour(1), inputs=(
                previous=PSE.One(id=1, within=PSE.SceneScope(), var=:signal,
                    policy=PSE.PreviousTimeStep(:previous)),
            )),
        PSE.ModelSpec(NativeFeatureDistributor(); name=:distribute,
            on=PSE.One(id=:writer), every=Hour(1),
            outputs_to=(PSE.OutputTo(PSE.Many(kind=:unit,
                within=PSE.SceneScope()); vars=(:assigned,)),)),
    )
    return PSE.CompositeModel(
        PSE.Object(:scene), instance,
        PSE.Object(:consumer; parent=:scene),
        PSE.Object(:temporal; parent=:scene),
        PSE.Object(:writer; parent=:scene);
        applications, environment=(duration=Hour(1),),
        status_storage=native ? PSE.NativeColumnStorage() : nothing)
end

struct NativeFeatureInitializer <: AbstractNative_Feature_InitializerModel end
PSE.inputs_(::NativeFeatureInitializer) = (previous_mass=PSE.Default(0.0f0),)
PSE.outputs_(::NativeFeatureInitializer) = (mass=0.0f0, initializer_runs=0)
function PSE.run!(::NativeFeatureInitializer, status, environment, constants, context)
    status.mass = status.previous_mass + 1.0f0
    status.initializer_runs += 1
    return nothing
end

struct NativeFeatureTouch <: AbstractNative_Feature_TouchModel end
PSE.inputs_(::NativeFeatureTouch) = NamedTuple()
PSE.outputs_(::NativeFeatureTouch) = (called=0,)
PSE.run!(::NativeFeatureTouch, status, environment, constants, context) =
    (status.called += 1; nothing)

struct NativeFeatureCreator <: AbstractNative_Feature_CreatorModel end
PSE.inputs_(::NativeFeatureCreator) = NamedTuple()
PSE.outputs_(::NativeFeatureCreator) = (
    created=false, newborn_mass=0.0f0, live_initializer_reference=false,
    native_before_initializer=false, manual_called=false,
)
function PSE.run!(::NativeFeatureCreator, status, environment, constants, context)
    status.created && return nothing
    parent = PSE.source_node(context, PSE.object_id(context, status))
    newborn = PSE.add_organ!(parent, context, :+, :Unit, 1;
        initial_status=(mass=4.0f0, initializer_runs=0, called=0))
    newborn_id = PSE.object_id(context, newborn)
    reference = PSE.refvalue(newborn, :mass)
    status.native_before_initializer = reference isa Base.RefArray
    initialized = PSE.run_initializer!(context, :initialize, newborn)
    status.newborn_mass = newborn.mass
    status.live_initializer_reference = reference === PSE.refvalue(initialized, :mass)
    targets = PSE.run_call!(context, :touch; objects=newborn_id)
    status.manual_called = length(targets) == 1 && newborn.called == 1
    status.created = true
    return nothing
end

function lifecycle_fixture(; native::Bool)
    root = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", :Root, 1, 0))
    return PSE.CompositeModel(root; status=node -> (node=node,),
        environment=(duration=Hour(1),),
        status_storage=native ? PSE.NativeColumnStorage() : nothing,
        applications=(
            PSE.ModelSpec(NativeFeatureCreator(); name=:creator,
                on=PSE.One(id=MultiScaleTreeGraph.node_id(root)), every=Hour(1), calls=(
                    initialize=PSE.Initializer(PSE.One(scale=:Unit, within=PSE.Subtree(), application=:initialize)),
                touch=PSE.OptionalOne(scale=:Unit, within=PSE.SceneScope(), application=:touch),
                )),
            PSE.ModelSpec(NativeFeatureInitializer(); name=:initialize,
                on=PSE.Many(scale=:Unit), every=Hour(1), inputs=(
                    previous_mass=PSE.One(within=PSE.Self(), application=:initialize,
                        var=:mass, policy=PSE.PreviousTimeStep(:previous_mass)),
                )),
            PSE.ModelSpec(NativeFeatureTouch(); name=:touch,
                on=PSE.Many(scale=:Unit), every=Hour(1)),
        ))
end

function _feature_snapshot(simulation; ignore_native_flag=false)
    model = PSE.runtime_model(simulation)
    states = map(collect(PSE.model_objects(model))) do object
        # Structural scene/instance parents legitimately have no runtime
        # Status. Preserve that fact instead of asking final_state for one.
        fields = if object.status isa PSE.Status
            state = PSE.final_state(simulation, object.id)
            sort!([(name=string(name), observation=Snapshot._xp_logical_value(value))
                for (name, value) in pairs(state)
                if !(ignore_native_flag && name === :native_before_initializer)];
                by=field -> field.name)
        else
            Snapshot._xp_logical_value(object.status)
        end
        (id=repr(object.id.value), parent=repr(object.parent), scale=object.scale,
            kind=object.kind, species=object.species,
            has_status=object.status isa PSE.Status, fields)
    end
    sort!(states; by=state -> state.id)
    history = sort!([(key=repr(key),
        samples=Snapshot._xp_logical_value(deepcopy(collect(stream))))
        for (key, stream) in pairs(PSE.outputs(simulation))
        if !(ignore_native_flag && occursin("native_before_initializer", repr(key)))];
        by=stream -> stream.key)
    return (step=PSE.current_step(simulation), states, history)
end

function native_storage_feature_checks()
    reports = Any[]
    @testset "Native canonical storage preserves public feature boundaries" begin
        control = PSE.run!(coupling_fixture(native=false); steps=0, outputs=:all)
        candidate = PSE.run!(coupling_fixture(native=true); steps=0, outputs=:all)
        program = Scalar.compile_native_scalar(candidate)
        source = PSE.model_status(PSE.runtime_model(candidate), 1)
        external = PSE.refvalue(source, :signal)
        for step in 1:2
            PSE.continue!(control; steps=1)
            Scalar.advance_native_scalar!(program; steps=1)
            @test isequal(_feature_snapshot(candidate), _feature_snapshot(control))
            consumer = PSE.final_state(candidate, :consumer)
            @test consumer.total === Float32(3 * step)
            @test consumer.single_seen === Float32(step)
            @test consumer.optional_seen === -1.0f0
            @test Set(consumer.seen_ids) == Set(PSE.ObjectId.((1, 2)))
            @test PSE.final_state(candidate, :temporal).observed_previous === Float32(step - 1)
        end
        @test PSE.refvalue(PSE.model_status(PSE.runtime_model(candidate), 1), :signal) === external
        @test PSE.final_state(candidate, 1).assigned === 10.0f0
        @test PSE.final_state(candidate, 2).assigned === 20.0f0
        @test Scalar.native_scalar_report(program).ordered_batch_executions > 0
        # Hand the same live native simulation back to the ordinary executor.
        PSE.continue!(control; steps=1)
        PSE.continue!(candidate; steps=1)
        @test isequal(_feature_snapshot(candidate), _feature_snapshot(control))
        push!(reports, (case=:coupling_templates_overrides_temporal_distributed,
            report=Scalar.native_scalar_report(program)))

        control = PSE.run!(lifecycle_fixture(native=false); steps=0, outputs=:all)
        candidate = PSE.run!(lifecycle_fixture(native=true); steps=0, outputs=:all)
        program = Scalar.compile_native_scalar(candidate)
        for _ in 1:2
            PSE.continue!(control; steps=1)
            Scalar.advance_native_scalar!(program; steps=1)
            @test isequal(_feature_snapshot(candidate; ignore_native_flag=true),
                _feature_snapshot(control; ignore_native_flag=true))
        end
        creator = only(PSE.model_objects(PSE.runtime_model(candidate); scale=:Root)).status
        @test creator.native_before_initializer
        @test creator.live_initializer_reference
        @test creator.manual_called
        @test creator.newborn_mass === 5.0f0
        push!(reports, (case=:mtg_newborn_initializer_and_manual_call,
            report=Scalar.native_scalar_report(program)))
    end
    return (passed=true, cases=length(reports), reports,
        qualification=:bounded_native_ownership_and_ordinary_fallback_features)
end

end # module
