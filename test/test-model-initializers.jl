using Dates
using MultiScaleTreeGraph
using PlantSimEngine
using PlantSimEngine.Diagnostics
using Test

const INITIALIZER_CAPTURED_CONTEXT = Ref{Any}()

struct InitializerNonGlobalBackend <:
       PlantSimEngine.EnvironmentAPI.AbstractEnvironmentBackend end

PlantSimEngine.@process "initializer_leaf_state" verbose = false
PlantSimEngine.@process "initializer_creator" verbose = false
PlantSimEngine.@process "initializer_observer" verbose = false
PlantSimEngine.@process "initializer_observer_owner" verbose = false
PlantSimEngine.@process "initializer_mtg_creator" verbose = false
PlantSimEngine.@process "initializer_batch_creator" verbose = false
PlantSimEngine.@process "initializer_chain_source" verbose = false
PlantSimEngine.@process "initializer_chain_sink" verbose = false
PlantSimEngine.@process "initializer_chain_creator" verbose = false
PlantSimEngine.@process "initializer_split_creator" verbose = false
PlantSimEngine.@process "initializer_overlap_writer" verbose = false
PlantSimEngine.@process "initializer_cache_manual_target" verbose = false
PlantSimEngine.@process "initializer_cache_mutator" verbose = false

struct InitializerLeafStateModel <: AbstractInitializer_Leaf_StateModel
    throw_after_mutation::Bool
end

InitializerLeafStateModel() = InitializerLeafStateModel(false)

PlantSimEngine.inputs_(::InitializerLeafStateModel) = (
    previous_mass=Required(Float64),
)
PlantSimEngine.outputs_(::InitializerLeafStateModel) = (
    mass=0.0,
    initializer_runs=0,
)

function PlantSimEngine.run!(
    model::InitializerLeafStateModel,
    status,
    environment,
    constants,
    context,
)
    status.mass = status.previous_mass + 1.0
    status.initializer_runs += 1
    model.throw_after_mutation && error("initializer failed after mutation")
    return nothing
end

struct InitializerCreatorModel <: AbstractInitializer_CreatorModel
    action::Symbol
end

InitializerCreatorModel() = InitializerCreatorModel(:create)

function PlantSimEngine.dep(model::InitializerCreatorModel)
    model.action === :default_binding || return NamedTuple()
    return (
        leaf=Initializer(
            One(scale=:Leaf, application=:leaf_initializer),
        ),
    )
end

PlantSimEngine.inputs_(::InitializerCreatorModel) = NamedTuple()
PlantSimEngine.outputs_(::InitializerCreatorModel) = (
    created=false,
    initialized_mass=-1.0,
    duplicate_rejected=false,
    manual_api_rejected=false,
    failure_seen=false,
    retry_rejected=false,
    runs_after_failed_retry=-1,
    cached_initializer_batches_empty=false,
)

function PlantSimEngine.run!(
    model::InitializerCreatorModel,
    status,
    environment,
    constants,
    context,
)
    runtime = runtime_model(context)
    if model.action === :create
        status.created && return nothing
        status.cached_initializer_batches_empty = isempty(
            PlantSimEngine._model_call_targets(
                context,
                :leaf,
            ).execution_batches,
        )
        leaf = register_object!(
            runtime,
            Object(
                :new_leaf;
                scale=:Leaf,
                parent=:plant,
                status=Status(
                    mass=4.0,
                    previous_mass=4.0,
                    initializer_runs=0,
                ),
            ),
        )
        initialized = run_initializer!(context, :leaf, leaf)
        status.initialized_mass = initialized.mass
        try
            run_initializer!(context, :leaf, leaf)
        catch err
            status.duplicate_rejected = occursin(
                "already initialized",
                sprint(showerror, err),
            )
        end
        try
            call_targets(context, :leaf)
        catch err
            status.manual_api_rejected = occursin(
                "run_initializer!",
                sprint(showerror, err),
            )
        end
        status.created = true
    elseif model.action === :existing
        run_initializer!(context, :leaf, ObjectId(:existing_leaf))
    elseif model.action === :reparented
        reparent_object!(runtime, :existing_leaf, :plant_b)
        run_initializer!(context, :leaf, ObjectId(:existing_leaf))
    elseif model.action === :removed
        remove_object!(runtime, :existing_leaf)
        run_initializer!(context, :leaf, ObjectId(:existing_leaf))
    elseif model.action === :foreign
        registered = register_object!(
            runtime,
            Object(
                :foreign_identity_leaf;
                scale=:Leaf,
                parent=:plant,
                status=Status(
                    mass=4.0,
                    previous_mass=4.0,
                    initializer_runs=0,
                ),
            ),
        )
        foreign = Object(
            registered.id;
            scale=:Leaf,
            parent=:plant,
            status=Status(
                mass=4.0,
                previous_mass=4.0,
                initializer_runs=0,
            ),
        )
        run_initializer!(context, :leaf, foreign)
    elseif model.action === :failing
        leaf = register_object!(
            runtime,
            Object(
                :failing_leaf;
                scale=:Leaf,
                parent=:plant,
                status=Status(
                    mass=4.0,
                    previous_mass=4.0,
                    initializer_runs=0,
                ),
            ),
        )
        try
            run_initializer!(context, :leaf, leaf)
        catch err
            status.failure_seen = occursin(
                "failed after mutation",
                sprint(showerror, err),
            )
        end
        try
            run_initializer!(context, :leaf, leaf)
        catch err
            status.retry_rejected = occursin(
                "already initialized",
                sprint(showerror, err),
            )
        end
        status.runs_after_failed_retry = model_status(
            runtime,
            leaf,
        ).initializer_runs
    elseif model.action === :manual_binding
        leaf = register_object!(
            runtime,
            Object(
                :wrong_mode_leaf;
                scale=:Leaf,
                parent=:plant,
                status=Status(
                    mass=4.0,
                    previous_mass=4.0,
                    initializer_runs=0,
                ),
            ),
        )
        run_initializer!(context, :leaf, leaf)
    elseif model.action === :capture
        INITIALIZER_CAPTURED_CONTEXT[] = context
        status.created = true
    else
        error("Unsupported initializer test action `$(model.action)`.")
    end
    return nothing
end

struct InitializerObserverModel <: AbstractInitializer_ObserverModel end

PlantSimEngine.inputs_(::InitializerObserverModel) = (
    mass=Required(Float64),
)
PlantSimEngine.outputs_(::InitializerObserverModel) = (observed_mass=-1.0,)

function PlantSimEngine.run!(
    ::InitializerObserverModel,
    status,
    environment,
    constants,
    context,
)
    status.observed_mass = status.mass
    return nothing
end

struct InitializerObserverOwnerModel <:
       AbstractInitializer_Observer_OwnerModel end

PlantSimEngine.inputs_(::InitializerObserverOwnerModel) = NamedTuple()
PlantSimEngine.outputs_(::InitializerObserverOwnerModel) = (
    owned_observed_mass=-1.0,
)

function PlantSimEngine.run!(
    ::InitializerObserverOwnerModel,
    status,
    environment,
    constants,
    context,
)
    target = only(run_call!(context, :observer; publish=true))
    status.owned_observed_mass = target.status.observed_mass
    return nothing
end

struct InitializerMTGCreatorModel <: AbstractInitializer_Mtg_CreatorModel end

PlantSimEngine.inputs_(::InitializerMTGCreatorModel) = NamedTuple()
PlantSimEngine.outputs_(::InitializerMTGCreatorModel) = (
    created=false,
    initialized_mass=-1.0,
    returned_status_is_registered=false,
    source_identity_matches=false,
    runtime_attribute_absent=false,
)

function PlantSimEngine.run!(
    ::InitializerMTGCreatorModel,
    status,
    environment,
    constants,
    context,
)
    status.created && return nothing
    runtime = runtime_model(context)
    leaf_status = add_organ!(
        source_node(context),
        runtime,
        :+,
        :Leaf,
        2;
        index=1,
        initial_status=(
            mass=4.0,
            previous_mass=4.0,
            initializer_runs=0,
        ),
    )
    status.returned_status_is_registered =
        model_status(runtime, leaf_status) === leaf_status
    status.source_identity_matches =
        source_node(runtime, leaf_status) === leaf_status.node
    status.runtime_attribute_absent = !haskey(
        node_attributes(leaf_status.node),
        :plantsimengine_status,
    )
    status.initialized_mass = run_initializer!(
        context,
        :leaf,
        leaf_status,
    ).mass
    status.created = true
    return nothing
end

struct InitializerBatchCreatorModel <: AbstractInitializer_Batch_CreatorModel
    count::Int
end

PlantSimEngine.inputs_(::InitializerBatchCreatorModel) = NamedTuple()
PlantSimEngine.outputs_(::InitializerBatchCreatorModel) = (
    initialized_count=0,
    initialized_mass_total=0.0,
)

function PlantSimEngine.run!(
    model::InitializerBatchCreatorModel,
    status,
    environment,
    constants,
    context,
)
    status.initialized_count > 0 && return nothing
    for index in 1:model.count
        leaf = register_object!(
            runtime_model(context),
            Object(
                Symbol(:batch_leaf_, index);
                scale=:Leaf,
                parent=:plant,
                status=Status(
                    mass=4.0,
                    previous_mass=4.0,
                    initializer_runs=0,
                ),
            ),
        )
        initialized = run_initializer!(context, :leaf, leaf)
        status.initialized_count += 1
        status.initialized_mass_total += initialized.mass
    end
    return nothing
end

struct InitializerChainSourceModel <:
       AbstractInitializer_Chain_SourceModel end

PlantSimEngine.inputs_(::InitializerChainSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::InitializerChainSourceModel) = (signal=0.0,)

function PlantSimEngine.run!(
    ::InitializerChainSourceModel,
    status,
    environment,
    constants,
    context,
)
    status.signal = 7.0
    return nothing
end

struct InitializerChainSinkModel <: AbstractInitializer_Chain_SinkModel end

PlantSimEngine.inputs_(::InitializerChainSinkModel) = (
    source_signal=Required(Float64),
)
PlantSimEngine.outputs_(::InitializerChainSinkModel) = (seen=-1.0,)

function PlantSimEngine.run!(
    ::InitializerChainSinkModel,
    status,
    environment,
    constants,
    context,
)
    status.seen = status.source_signal
    return nothing
end

struct InitializerChainCreatorModel <:
       AbstractInitializer_Chain_CreatorModel end

PlantSimEngine.inputs_(::InitializerChainCreatorModel) = NamedTuple()
PlantSimEngine.outputs_(::InitializerChainCreatorModel) = (
    created=false,
    sink_seen=-1.0,
)

function PlantSimEngine.run!(
    ::InitializerChainCreatorModel,
    status,
    environment,
    constants,
    context,
)
    status.created && return nothing
    runtime = runtime_model(context)
    source = register_object!(
        runtime,
        Object(
            :chain_source_object;
            scale=:Leaf,
            kind=:ChainSource,
            parent=:plant,
            status=Status(signal=0.0),
        ),
    )
    run_initializer!(context, :source, source)
    sink = register_object!(
        runtime,
        Object(
            :chain_sink_object;
            scale=:Leaf,
            kind=:ChainSink,
            parent=:plant,
            status=Status(seen=-1.0),
        ),
    )
    status.sink_seen = run_initializer!(context, :sink, sink).seen
    status.created = true
    return nothing
end

struct InitializerSplitCreatorModel <:
       AbstractInitializer_Split_CreatorModel end

PlantSimEngine.inputs_(::InitializerSplitCreatorModel) = NamedTuple()
PlantSimEngine.outputs_(::InitializerSplitCreatorModel) = (
    created=false,
    sink_seen=-1.0,
)

function PlantSimEngine.run!(
    ::InitializerSplitCreatorModel,
    status,
    environment,
    constants,
    context,
)
    status.created && return nothing
    runtime = runtime_model(context)
    if object_id(context) == ObjectId(:chain_creator_a)
        source = register_object!(
            runtime,
            Object(
                :split_chain_source;
                scale=:Leaf,
                kind=:ChainSource,
                parent=:plant,
                status=Status(signal=0.0),
            ),
        )
        run_initializer!(context, :source, source)
    elseif object_id(context) == ObjectId(:chain_creator_b)
        sink = register_object!(
            runtime,
            Object(
                :split_chain_sink;
                scale=:Leaf,
                kind=:ChainSink,
                parent=:plant,
                status=Status(seen=-1.0),
            ),
        )
        status.sink_seen = run_initializer!(context, :sink, sink).seen
    else
        error("Unexpected split creator target `$(object_id(context).value)`.")
    end
    status.created = true
    return nothing
end

struct InitializerOverlapWriterModel <:
       AbstractInitializer_Overlap_WriterModel end

PlantSimEngine.inputs_(::InitializerOverlapWriterModel) = NamedTuple()
PlantSimEngine.outputs_(::InitializerOverlapWriterModel) = (mass=0.0,)

function PlantSimEngine.run!(
    ::InitializerOverlapWriterModel,
    status,
    environment,
    constants,
    context,
)
    status.mass = 99.0
    return nothing
end

const INITIALIZER_CACHE_BASE_COMPILED = Ref{Any}()

struct InitializerCacheManualTargetModel <:
       AbstractInitializer_Cache_Manual_TargetModel end

PlantSimEngine.inputs_(::InitializerCacheManualTargetModel) = NamedTuple()
PlantSimEngine.outputs_(::InitializerCacheManualTargetModel) = (
    signal=0.0,
    refreshed_plan=false,
)

function PlantSimEngine.run!(
    ::InitializerCacheManualTargetModel,
    status,
    environment,
    constants,
    context,
)
    status.signal = 7.0
    status.refreshed_plan = context.compiled !== INITIALIZER_CACHE_BASE_COMPILED[]
    return nothing
end

struct InitializerCacheMutatorModel <:
       AbstractInitializer_Cache_MutatorModel end

PlantSimEngine.inputs_(::InitializerCacheMutatorModel) = NamedTuple()
PlantSimEngine.outputs_(::InitializerCacheMutatorModel) = (
    created=false,
    targeted_value=-1.0,
    refreshed_plan=false,
    cache_invalidated=false,
    bindings_remained_dirty=false,
)

function PlantSimEngine.run!(
    ::InitializerCacheMutatorModel,
    status,
    environment,
    constants,
    context,
)
    status.created && return nothing
    runtime = runtime_model(context)
    if object_id(context) == ObjectId(:cache_creator_a)
        leaf = register_object!(
            runtime,
            Object(
                :cache_leaf_a;
                scale=:Leaf,
                kind=:CacheLeaf,
                parent=:plant,
                status=Status(signal=0.0, refreshed_plan=false),
            ),
        )
        run_call!(context, :manual_leaf; objects=leaf, publish=false)
    elseif object_id(context) == ObjectId(:cache_creator_b)
        leaf = register_object!(
            runtime,
            Object(
                :cache_leaf_b;
                scale=:Leaf,
                kind=:CacheLeaf,
                parent=:plant,
                status=Status(signal=0.0, refreshed_plan=false),
            ),
        )
        reparent_object!(runtime, :cache_leaf_a, :plant_b)
        status.cache_invalidated = isnothing(
            PlantSimEngine.lifecycle_delta(runtime).targeted_topology_runtime,
        )
        target = only(
            run_call!(
                context,
                :manual_leaf;
                objects=leaf,
                publish=false,
            ),
        )
        status.targeted_value = target.status.signal
        status.refreshed_plan = target.status.refreshed_plan
        status.bindings_remained_dirty =
            PlantSimEngine.bindings_dirty(runtime)
    else
        error("Unexpected cache mutator target `$(object_id(context).value)`.")
    end
    status.created = true
    return nothing
end

PlantSimEngine.@process "initializer_exact_biomass" verbose = false
PlantSimEngine.@process "initializer_exact_respiration" verbose = false
PlantSimEngine.@process "initializer_exact_creator" verbose = false
PlantSimEngine.@process "initializer_distributed_writer" verbose = false
PlantSimEngine.@process "initializer_distributed_direct" verbose = false
PlantSimEngine.@process "initializer_distributed_lagged" verbose = false
PlantSimEngine.@process "initializer_distributed_creator" verbose = false

struct InitializerExactBiomassModel <: AbstractInitializer_Exact_BiomassModel end

PlantSimEngine.inputs_(::InitializerExactBiomassModel) = NamedTuple()
PlantSimEngine.outputs_(::InitializerExactBiomassModel) = (biomass=0.0,)

function PlantSimEngine.run!(
    ::InitializerExactBiomassModel,
    status,
    environment,
    constants,
    context,
)
    return nothing
end

struct InitializerExactRespirationModel <:
       AbstractInitializer_Exact_RespirationModel end

PlantSimEngine.inputs_(::InitializerExactRespirationModel) = (
    biomass=Required(Float64),
)
PlantSimEngine.outputs_(::InitializerExactRespirationModel) = (Rm=-Inf,)

function PlantSimEngine.run!(
    ::InitializerExactRespirationModel,
    status,
    environment,
    constants,
    context,
)
    status.Rm = 2.0 * status.biomass
    return nothing
end

struct InitializerExactCreatorModel <: AbstractInitializer_Exact_CreatorModel end

PlantSimEngine.inputs_(::InitializerExactCreatorModel) = NamedTuple()
PlantSimEngine.outputs_(::InitializerExactCreatorModel) = (initialized_Rm=-Inf,)

function PlantSimEngine.run!(
    ::InitializerExactCreatorModel,
    status,
    environment,
    constants,
    context,
)
    leaf = register_object!(
        runtime_model(context),
        Object(
            :exact_new_leaf;
            scale=:Leaf,
            parent=:plant,
            status=Status(biomass=4.0),
        ),
    )
    status.initialized_Rm = run_initializer!(
        context,
        :respiration,
        leaf,
    ).Rm
    return nothing
end

struct InitializerDistributedWriterModel{T} <:
       AbstractInitializer_Distributed_WriterModel
    multiplier::T
end

PlantSimEngine.inputs_(::InitializerDistributedWriterModel) = NamedTuple()
PlantSimEngine.outputs_(::InitializerDistributedWriterModel) = NamedTuple()

function PlantSimEngine.run!(
    model::InitializerDistributedWriterModel,
    status,
    environment,
    constants,
    context,
)
    targets = output_targets(context, :plants)
    fill!(targets.columns.incident_par, model.multiplier * context.time)
    return nothing
end

struct InitializerDistributedDirectModel <:
       AbstractInitializer_Distributed_DirectModel end

PlantSimEngine.inputs_(::InitializerDistributedDirectModel) = (
    incident_par=Required(Float64),
)
PlantSimEngine.outputs_(::InitializerDistributedDirectModel) = (
    direct_seen=-Inf,
)

function PlantSimEngine.run!(
    ::InitializerDistributedDirectModel,
    status,
    environment,
    constants,
    context,
)
    status.direct_seen = status.incident_par
    return nothing
end

struct InitializerDistributedLaggedModel <:
       AbstractInitializer_Distributed_LaggedModel end

PlantSimEngine.inputs_(::InitializerDistributedLaggedModel) = (
    previous_incident_par=Required(Vector{Float64}),
)
PlantSimEngine.outputs_(::InitializerDistributedLaggedModel) = (
    lagged_total=-Inf,
)

function PlantSimEngine.run!(
    ::InitializerDistributedLaggedModel,
    status,
    environment,
    constants,
    context,
)
    status.lagged_total = sum(status.previous_incident_par)
    return nothing
end

struct InitializerDistributedCreatorModel <:
       AbstractInitializer_Distributed_CreatorModel end

PlantSimEngine.inputs_(::InitializerDistributedCreatorModel) = NamedTuple()
PlantSimEngine.outputs_(::InitializerDistributedCreatorModel) = (
    created=false,
    direct_seen=-Inf,
    lagged_total=-Inf,
)

function PlantSimEngine.run!(
    ::InitializerDistributedCreatorModel,
    status,
    environment,
    constants,
    context,
)
    context.time == 2 || return nothing
    status.created && return nothing
    leaf = register_object!(
        runtime_model(context),
        Object(
            :distributed_new_leaf;
            scale=:Leaf,
            parent=:plant_a,
            status=Status(previous_incident_par=[-1.0, -1.0]),
        ),
    )
    status.direct_seen = run_initializer!(
        context,
        :direct,
        leaf,
    ).direct_seen
    status.lagged_total = run_initializer!(
        context,
        :lagged,
        leaf,
    ).lagged_total
    status.created = true
    return nothing
end

function initializer_leaf_application(;
    every=nothing,
    output_routing=NamedTuple(),
    outputs_to=NamedTuple(),
    calls=NamedTuple(),
    environment=nothing,
    policy=PreviousTimeStep(:previous_mass),
    throw_after_mutation=false,
)
    return ModelSpec(
        InitializerLeafStateModel(throw_after_mutation);
        name=:leaf_initializer,
        on=Many(scale=:Leaf),
        inputs=(
            previous_mass=One(
                within=Self(),
                application=:leaf_initializer,
                var=:mass,
                policy=policy,
            ),
        ),
        calls=calls,
        every=every,
        environment=environment,
        outputs_to=outputs_to,
        output_routing=output_routing,
    )
end

function initializer_creator_application(
    action=:create;
    binding=Initializer(
        One(scale=:Leaf, application=:leaf_initializer),
    ),
    every=nothing,
)
    return ModelSpec(
        InitializerCreatorModel(action);
        name=:creator,
        on=One(scale=:Scene),
        calls=(leaf=binding,),
        every=every,
    )
end

function initializer_observer_application()
    return ModelSpec(
        InitializerObserverModel();
        name=:observer,
        on=Many(scale=:Leaf),
        inputs=(
            mass=One(
                within=Self(),
                application=:leaf_initializer,
                var=:mass,
            ),
        ),
    )
end

@testset "PreviousTimeStep initializer uses newborn canonical state" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene);
        applications=(
            ModelSpec(
                InitializerExactRespirationModel();
                name=:respiration,
                on=Many(scale=:Leaf),
                inputs=(
                    biomass=One(
                        within=Self(),
                        application=:biomass_source,
                        var=:biomass,
                        policy=PreviousTimeStep(:biomass),
                    ),
                ),
            ),
            ModelSpec(
                InitializerExactCreatorModel();
                name=:creator,
                on=One(scale=:Scene),
                calls=(
                    respiration=Initializer(
                        One(scale=:Leaf, application=:respiration),
                    ),
                ),
            ),
            ModelSpec(
                InitializerExactBiomassModel();
                name=:biomass_source,
                on=Many(scale=:Leaf),
            ),
        ),
        environment=(duration=Hour(1),),
    )

    compiled = Advanced.refresh_bindings!(model)
    @test compiled.application_order ==
          (:respiration, :creator, :biomass_source)
    simulation = run!(model; steps=1, outputs=:all)
    leaf_status = model_status(model, :exact_new_leaf)
    @test leaf_status.biomass == 4.0
    @test leaf_status.Rm == 8.0
    @test model_status(model, :scene).initialized_Rm == 8.0
    @test isempty(
        outputs(simulation)[
            (:respiration, ObjectId(:exact_new_leaf), :Rm)
        ],
    )
    @test last.(
        outputs(simulation)[
            (:biomass_source, ObjectId(:exact_new_leaf), :biomass)
        ],
    ) == [4.0]
end

@testset "initializer resolves distributed current and prior sources" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant_a; name=:plant_a, scale=:Plant, parent=:scene),
        Object(:plant_b; name=:plant_b, scale=:Plant, parent=:scene);
        applications=(
            ModelSpec(
                InitializerDistributedWriterModel(10.0);
                name=:writer_a,
                on=One(scale=:Scene),
                outputs_to=(
                    plants=OutputTo(
                        Many(name=:plant_a, within=SceneScope());
                        vars=(incident_par=Default(0.0),),
                    ),
                ),
            ),
            ModelSpec(
                InitializerDistributedWriterModel(100.0);
                name=:writer_b,
                on=One(scale=:Scene),
                outputs_to=(
                    plants=OutputTo(
                        Many(name=:plant_b, within=SceneScope());
                        vars=(incident_par=Default(0.0),),
                    ),
                ),
            ),
            ModelSpec(
                InitializerDistributedDirectModel();
                name=:distributed_direct,
                on=Many(scale=:Leaf),
                inputs=(
                    incident_par=One(
                        Relation(:parent);
                        application=:writer_a,
                        var=:incident_par,
                    ),
                ),
            ),
            ModelSpec(
                InitializerDistributedLaggedModel();
                name=:distributed_lagged,
                on=Many(scale=:Leaf),
                inputs=(
                    previous_incident_par=Many(
                        scale=:Plant,
                        within=SceneScope(),
                        var=:incident_par,
                        policy=PreviousTimeStep(:previous_incident_par),
                    ),
                ),
            ),
            ModelSpec(
                InitializerDistributedCreatorModel();
                name=:distributed_creator,
                on=One(scale=:Scene),
                calls=(
                    direct=Initializer(
                        One(scale=:Leaf, application=:distributed_direct),
                    ),
                    lagged=Initializer(
                        One(scale=:Leaf, application=:distributed_lagged),
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )

    compiled = Advanced.refresh_bindings!(model)
    @test compiled.distributed_outputs isa
          PlantSimEngine.CompiledDistributedOutputs
    @test findfirst(==(:writer_a), compiled.application_order) <
          findfirst(==(:distributed_creator), compiled.application_order)
    @test findfirst(==(:writer_b), compiled.application_order) <
          findfirst(==(:distributed_creator), compiled.application_order)

    run!(model; steps=2, outputs=:all)
    creator = model_status(model, :scene)
    leaf = model_status(model, :distributed_new_leaf)
    @test creator.created
    @test creator.direct_seen == 20.0
    @test creator.lagged_total == 110.0
    @test leaf.direct_seen == 20.0
    @test leaf.lagged_total == 110.0
    @test model_status(model, :plant_a).incident_par == 20.0
    @test model_status(model, :plant_b).incident_par == 200.0
end

@testset "initializer orders a distinct root hard-call owner" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene);
        applications=(
            ModelSpec(
                InitializerObserverOwnerModel();
                name=:observer_owner,
                on=One(scale=:Scene),
                calls=(
                    observer=Many(scale=:Leaf, application=:observer),
                ),
            ),
            initializer_observer_application(),
            initializer_creator_application(),
            initializer_leaf_application(),
        ),
        environment=(duration=Hour(1),),
    )

    compiled = Advanced.refresh_bindings!(model)
    @test :observer_owner in
          compiled.scenario_plan.application_children.creator
    schedule = Dict(row.application_id => row for row in explain_schedule(compiled))
    @test schedule[:observer_owner].root_scheduled
    @test !schedule[:observer].root_scheduled
    @test findfirst(==(:creator), compiled.application_order) <
          findfirst(==(:observer_owner), compiled.application_order)

    run!(model; steps=1, outputs=:all)
    @test model_status(model, :scene).owned_observed_mass == 5.0
    @test model_status(model, :new_leaf).observed_mass == 5.0
end

@testset "MTG add_organ! status is the initializer target identity" begin
    root = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    plant = Node(
        root,
        MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1),
    )
    model = CompositeModel(
        root;
        applications=(
            ModelSpec(
                InitializerMTGCreatorModel();
                name=:mtg_creator,
                on=One(scale=:Plant),
                calls=(
                    leaf=Initializer(
                        One(
                            scale=:Leaf,
                            within=Subtree(),
                            application=:leaf_initializer,
                        ),
                    ),
                ),
            ),
            initializer_leaf_application(),
        ),
        environment=(duration=Hour(1),),
    )

    run!(model; steps=1, outputs=:all)
    creator = model_status(model, plant)
    @test creator.created
    @test creator.initialized_mass == 5.0
    @test creator.returned_status_is_registered
    @test creator.source_identity_matches
    @test creator.runtime_attribute_absent

    leaf_object = only(model_objects(model; scale=:Leaf))
    leaf_status = model_status(model, leaf_object.id)
    leaf_node = source_node(model, leaf_status)
    @test leaf_status === leaf_object.status
    @test source_node(model, leaf_object.id) === leaf_node
    @test !haskey(node_attributes(leaf_node), :plantsimengine_status)
    @test leaf_status.mass == 5.0
    @test leaf_status.initializer_runs == 1
end

@testset "mounted template preserves initializer mode and application identity" begin
    template = CompositeModelTemplate((
        ModelSpec(
            InitializerCreatorModel(:existing);
            name=:creator,
            on=One(scale=:Plant),
            calls=(
                leaf=Initializer(
                    One(
                        scale=:Leaf,
                        within=Subtree(),
                        application=:leaf_initializer,
                    ),
                ),
            ),
        ),
        initializer_leaf_application(),
    ))
    model = CompositeModel(
        ObjectInstance(
            :palm,
            template;
            root=Object(:palm; scale=:Plant),
            objects=(
                Object(
                    :leaf;
                    scale=:Leaf,
                    parent=:palm,
                    status=Status(
                        mass=4.0,
                        previous_mass=4.0,
                        initializer_runs=0,
                    ),
                ),
            ),
        );
        environment=(duration=Hour(1),),
    )

    compiled = Advanced.refresh_bindings!(model)
    mounted_creator = compiled.applications_by_id[:palm__creator]
    mounted_binding = model_calls(mounted_creator.spec).leaf
    @test mounted_binding isa Initializer
    @test PlantSimEngine._call_binding_mode(mounted_binding) == :initializer
    @test PlantSimEngine.criteria(mounted_binding.selector).application ==
          :palm__leaf_initializer
    call = only(compiled.call_bindings)
    @test PlantSimEngine._compiled_call_mode(call) == :initializer
    @test call.potential_callee_application_ids == (:palm__leaf_initializer,)
    @test call.callee_application_ids == [:palm__leaf_initializer]
    @test isempty(call.callee_object_ids)
end

@testset "many additions remain explicit one-shot initializer targets" begin
    batch_size = 32
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene);
        applications=(
            ModelSpec(
                InitializerBatchCreatorModel(batch_size);
                name=:batch_creator,
                on=One(scale=:Scene),
                calls=(
                    leaf=Initializer(
                        One(scale=:Leaf, application=:leaf_initializer),
                    ),
                ),
            ),
            initializer_leaf_application(),
        ),
        environment=(duration=Hour(1),),
    )

    compiled = Advanced.refresh_bindings!(model)
    call = only(compiled.call_bindings)
    @test isempty(call.callee_object_ids)
    run!(model; steps=1, outputs=:none)

    creator = model_status(model, :scene)
    @test creator.initialized_count == batch_size
    @test creator.initialized_mass_total == 5.0 * batch_size
    leaves = model_objects(model; scale=:Leaf)
    @test length(leaves) == batch_size
    @test all(leaf -> leaf.status.mass == 5.0, leaves)
    @test all(leaf -> leaf.status.initializer_runs == 1, leaves)
end

@testset "later newborn resolves an earlier initialized newborn" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene);
        applications=(
            ModelSpec(
                InitializerChainSourceModel();
                name=:chain_source,
                on=Many(scale=:Leaf, kind=:ChainSource),
            ),
            ModelSpec(
                InitializerChainSinkModel();
                name=:chain_sink,
                on=Many(scale=:Leaf, kind=:ChainSink),
                inputs=(
                    source_signal=One(
                        scale=:Leaf,
                        kind=:ChainSource,
                        within=SceneScope(),
                        application=:chain_source,
                        var=:signal,
                    ),
                ),
            ),
            ModelSpec(
                InitializerChainCreatorModel();
                name=:chain_creator,
                on=One(scale=:Scene),
                calls=(
                    source=Initializer(
                        One(
                            scale=:Leaf,
                            kind=:ChainSource,
                            within=SceneScope(),
                            application=:chain_source,
                        ),
                    ),
                    sink=Initializer(
                        One(
                            scale=:Leaf,
                            kind=:ChainSink,
                            within=SceneScope(),
                            application=:chain_sink,
                        ),
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )

    compiled = Advanced.refresh_bindings!(model)
    @test findfirst(==(:chain_source), compiled.application_order) <
          findfirst(==(:chain_sink), compiled.application_order) <
          findfirst(==(:chain_creator), compiled.application_order)
    run!(model; steps=1, outputs=:none)
    @test model_status(model, :chain_source_object).signal == 7.0
    @test model_status(model, :chain_sink_object).seen == 7.0
    @test model_status(model, :scene).sink_seen == 7.0
end

@testset "newborn overlay spans creator targets before the barrier" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(
            :chain_creator_a;
            scale=:Creator,
            kind=:ChainCreator,
            parent=:scene,
        ),
        Object(
            :chain_creator_b;
            scale=:Creator,
            kind=:ChainCreator,
            parent=:scene,
        );
        applications=(
            ModelSpec(
                InitializerChainSourceModel();
                name=:chain_source,
                on=Many(scale=:Leaf, kind=:ChainSource),
            ),
            ModelSpec(
                InitializerChainSinkModel();
                name=:chain_sink,
                on=Many(scale=:Leaf, kind=:ChainSink),
                inputs=(
                    source_signal=One(
                        scale=:Leaf,
                        kind=:ChainSource,
                        within=SceneScope(),
                        application=:chain_source,
                        var=:signal,
                    ),
                ),
            ),
            ModelSpec(
                InitializerSplitCreatorModel();
                name=:split_creator,
                on=Many(scale=:Creator, kind=:ChainCreator),
                calls=(
                    source=Initializer(
                        One(
                            scale=:Leaf,
                            kind=:ChainSource,
                            within=SceneScope(),
                            application=:chain_source,
                        ),
                    ),
                    sink=Initializer(
                        One(
                            scale=:Leaf,
                            kind=:ChainSink,
                            within=SceneScope(),
                            application=:chain_sink,
                        ),
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )

    compiled = Advanced.refresh_bindings!(model)
    @test compiled.applications_by_id[:split_creator].target_ids ==
          [ObjectId(:chain_creator_a), ObjectId(:chain_creator_b)]
    run!(model; steps=1, outputs=:none)
    @test model_status(model, :split_chain_source).signal == 7.0
    @test model_status(model, :split_chain_sink).seen == 7.0
    @test model_status(model, :chain_creator_b).sink_seen == 7.0
end

@testset "mixed structural events invalidate the targeted newborn cache" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(:plant_b; scale=:Plant, parent=:scene),
        Object(
            :cache_creator_a;
            scale=:Creator,
            kind=:CacheCreator,
            parent=:scene,
        ),
        Object(
            :cache_creator_b;
            scale=:Creator,
            kind=:CacheCreator,
            parent=:scene,
        );
        applications=(
            ModelSpec(
                InitializerCacheManualTargetModel();
                name=:cache_manual_target,
                on=Many(
                    scale=:Leaf,
                    kind=:CacheLeaf,
                    within=Scope(:plant),
                ),
            ),
            ModelSpec(
                InitializerCacheMutatorModel();
                name=:cache_mutator,
                on=Many(scale=:Creator, kind=:CacheCreator),
                calls=(
                    manual_leaf=Many(
                        scale=:Leaf,
                        kind=:CacheLeaf,
                        within=SceneScope(),
                        application=:cache_manual_target,
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )

    compiled = Advanced.refresh_bindings!(model)
    INITIALIZER_CACHE_BASE_COMPILED[] = compiled
    @test compiled.applications_by_id[:cache_mutator].target_ids ==
          [ObjectId(:cache_creator_a), ObjectId(:cache_creator_b)]
    simulation = run!(model; steps=1, outputs=:none)

    @test model_object(model, :cache_leaf_a).parent == ObjectId(:plant_b)
    @test model_status(model, :cache_leaf_b).signal == 7.0
    @test model_status(model, :cache_leaf_b).refreshed_plan
    @test model_status(model, :cache_creator_b).targeted_value == 7.0
    @test model_status(model, :cache_creator_b).refreshed_plan
    @test model_status(model, :cache_creator_b).cache_invalidated
    @test !model_status(model, :cache_creator_b).bindings_remained_dirty
    @test simulation.compiled.applications_by_id[:cache_manual_target].target_ids ==
          [ObjectId(:cache_leaf_b)]
end

@testset "scheduled newborn initializer lifecycle" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(
            :existing_leaf_a;
            scale=:Leaf,
            parent=:plant,
            status=Status(
                mass=10.0,
                previous_mass=10.0,
                initializer_runs=0,
            ),
        ),
        Object(
            :existing_leaf_b;
            scale=:Leaf,
            parent=:plant,
            status=Status(
                mass=20.0,
                previous_mass=20.0,
                initializer_runs=0,
            ),
        );
        # Intentionally authored in the opposite order. The initializer
        # contract must establish leaf initializer -> creator -> observer.
        applications=(
            initializer_observer_application(),
            initializer_creator_application(),
            initializer_leaf_application(),
        ),
        environment=(duration=Hour(2),),
    )

    compiled = Advanced.refresh_bindings!(model)
    scenario_plan = compiled.scenario_plan
    @test scenario_plan.manual_application_ids == ()
    @test compiled.application_order ==
          (:leaf_initializer, :creator, :observer)
    @test scenario_plan.application_children.leaf_initializer ==
          (:observer, :creator)
    @test scenario_plan.application_children.creator == (:observer,)

    call = only(explain_calls(compiled))
    @test call.mode == :initializer
    @test call.application == :leaf_initializer
    @test call.potential_callee_application_ids == (:leaf_initializer,)
    @test isempty(call.callee_object_ids)
    @test call.callee_application_ids == [:leaf_initializer]
    @test call.publication_policy == :canonical_status_only
    @test !call.default_publish
    @test !call.accepted_publish

    schedule = Dict(row.application_id => row for row in explain_schedule(compiled))
    @test schedule[:leaf_initializer].root_scheduled
    @test !schedule[:leaf_initializer].manual_call_only
    @test schedule[:leaf_initializer].initializer_target
    @test !schedule[:creator].initializer_target

    simulation = run!(model; steps=1, outputs=:all, performance=true)
    @test simulation.compiled.scenario_plan === scenario_plan
    scene_status = model_status(model, :scene)
    leaf_status = model_status(model, :new_leaf)
    @test scene_status.created
    @test scene_status.initialized_mass == 5.0
    @test scene_status.duplicate_rejected
    @test scene_status.manual_api_rejected
    @test scene_status.cached_initializer_batches_empty
    @test leaf_status.mass == 5.0
    @test leaf_status.initializer_runs == 1
    @test leaf_status.observed_mass == 5.0

    writer = only(
        row for row in explain_writers(simulation.compiled)
        if row.object_id == :new_leaf && row.variable == :mass
    )
    @test writer.application_ids == [:leaf_initializer]
    retained_key = (:leaf_initializer, ObjectId(:new_leaf), :mass)
    @test isempty(get(outputs(simulation), retained_key, []))
    @test get(
        Advanced.runtime_performance(simulation).counts,
        :selector_call_binding_candidates,
        0,
    ) == 0
    @test isempty(only(explain_calls(simulation.compiled)).callee_object_ids)

    continue!(simulation; steps=1)
    @test simulation.compiled.scenario_plan === scenario_plan
    @test model_status(model, :new_leaf).mass == 6.0
    @test model_status(model, :new_leaf).initializer_runs == 2
    @test model_status(model, :new_leaf).observed_mass == 6.0
    retained_mass = outputs(simulation)[retained_key]
    @test last.(retained_mass) == [6.0]
end

@testset "initializer reservation ends at the structural barrier" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene);
        applications=(
            initializer_creator_application(:capture),
            initializer_leaf_application(),
        ),
        environment=(duration=Hour(1),),
    )
    run!(model; steps=1, outputs=:none)
    context = INITIALIZER_CAPTURED_CONTEXT[]

    first = register_object!(
        model,
        Object(
            :reused_leaf;
            scale=:Leaf,
            parent=:plant,
            status=Status(
                mass=4.0,
                previous_mass=4.0,
                initializer_runs=0,
            ),
        ),
    )
    @test run_initializer!(context, :leaf, first).initializer_runs == 1
    Advanced.refresh_bindings!(model)
    @test Advanced.environment_bindings_dirty(model)
    @test isempty(Advanced.lifecycle_delta(model).initialized_targets)

    remove_object!(model, first.id)
    Advanced.refresh_bindings!(model)
    @test Advanced.environment_bindings_dirty(model)
    second = register_object!(
        model,
        Object(
            :reused_leaf;
            scale=:Leaf,
            parent=:plant,
            status=Status(
                mass=4.0,
                previous_mass=4.0,
                initializer_runs=0,
            ),
        ),
    )
    @test second !== first
    reused_status = run_initializer!(context, :leaf, second)
    @test reused_status.mass == 5.0
    @test reused_status.initializer_runs == 1
end

@testset "initializer declarations fail before ambiguous execution" begin
    @test_throws "requires `One(...)`" Initializer(Many(scale=:Leaf))
    @test_throws "Use `Initializer(...)` directly" Call(
        Initializer(One(scale=:Leaf, application=:leaf_initializer)),
    )

    default_binding = ModelSpec(
        InitializerCreatorModel(:default_binding);
        name=:creator,
        on=One(scale=:Scene),
    )
    @test model_calls(default_binding).leaf isa Initializer
    @test isempty(keys(dep(default_binding)))

    missing_application = CompositeModel(
        Object(:scene; scale=:Scene);
        applications=(
            initializer_creator_application(
                binding=Initializer(One(scale=:Leaf)),
            ),
            initializer_leaf_application(),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "must name one scheduled target" Advanced.refresh_bindings!(
        missing_application,
    )

    incompatible_cadence = CompositeModel(
        Object(:scene; scale=:Scene);
        applications=(
            initializer_creator_application(every=Day(1)),
            initializer_leaf_application(every=Hour(1)),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "incompatible cadence" Advanced.refresh_bindings!(
        incompatible_cadence,
    )

    incompatible_phase = CompositeModel(
        Object(:scene; scale=:Scene);
        applications=(
            initializer_creator_application(every=ClockSpec(1.0, 0.0)),
            initializer_leaf_application(every=ClockSpec(1.0, 0.5)),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "incompatible cadence" Advanced.refresh_bindings!(
        incompatible_phase,
    )

    mixed_manual = CompositeModel(
        Object(:scene; scale=:Scene);
        applications=(
            ModelSpec(
                InitializerCreatorModel();
                name=:creator,
                on=One(scale=:Scene),
                calls=(
                    leaf=Initializer(
                        One(scale=:Leaf, application=:leaf_initializer),
                    ),
                    manual_leaf=Many(
                        scale=:Leaf,
                        application=:leaf_initializer,
                    ),
                ),
            ),
            initializer_leaf_application(),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "both a manual-call-only target and an initializer target" Advanced.refresh_bindings!(
        mixed_manual,
    )

    duplicate_owner = CompositeModel(
        Object(:scene; scale=:Scene);
        applications=(
            ModelSpec(
                InitializerCreatorModel();
                name=:creator,
                on=One(scale=:Scene),
                calls=(
                    leaf=Initializer(
                        One(scale=:Leaf, application=:leaf_initializer),
                    ),
                    second_leaf=Initializer(
                        One(scale=:Leaf, application=:leaf_initializer),
                    ),
                ),
            ),
            initializer_leaf_application(),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "several initializer bindings" Advanced.refresh_bindings!(
        duplicate_owner,
    )

    overlapping_local_writer = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene);
        applications=(
            initializer_creator_application(),
            initializer_leaf_application(),
            ModelSpec(
                InitializerOverlapWriterModel();
                name=:later_writer,
                on=Many(scale=:Leaf),
                updates=(Updates(:mass; after=:leaf_initializer),),
            ),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "must be the sole canonical writer of output `mass`" Advanced.refresh_bindings!(
        overlapping_local_writer,
    )

    overlapping_distributed_writer = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene);
        applications=(
            initializer_creator_application(),
            initializer_leaf_application(),
            ModelSpec(
                InitializerOverlapWriterModel();
                name=:distributed_writer,
                on=One(scale=:Scene),
                outputs_to=(
                    leaves=OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=(mass=Default(0.0),),
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "Potential overlapping writer application(s): `(:distributed_writer,)`" Advanced.refresh_bindings!(
        overlapping_distributed_writer,
    )

    stream_only_target = CompositeModel(
        Object(:scene; scale=:Scene);
        applications=(
            initializer_creator_application(),
            initializer_leaf_application(
                output_routing=(mass=:stream_only,),
            ),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "stream-only output" Advanced.refresh_bindings!(
        stream_only_target,
    )

    distributed_target = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene);
        applications=(
            initializer_creator_application(),
            initializer_leaf_application(
                outputs_to=(
                    plant=OutputTo(
                        One(scale=:Plant, within=SceneScope());
                        vars=(mass=Default(0.0),),
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "declares `outputs_to`" Advanced.refresh_bindings!(
        distributed_target,
    )

    nested_target = CompositeModel(
        Object(:scene; scale=:Scene);
        applications=(
            initializer_creator_application(),
            initializer_leaf_application(
                calls=(
                    nested=Many(
                        scale=:Leaf,
                        application=:nested_child,
                    ),
                ),
            ),
            ModelSpec(
                InitializerCreatorModel(:existing);
                name=:nested_child,
                on=Many(scale=:Leaf),
            ),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "declares hard calls" Advanced.refresh_bindings!(
        nested_target,
    )

    non_global_target = CompositeModel(
        Object(:scene; scale=:Scene);
        applications=(
            initializer_creator_application(),
            initializer_leaf_application(
                environment=Environment(
                    backend=InitializerNonGlobalBackend(),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "non-global environment backend" Advanced.refresh_bindings!(
        non_global_target,
    )

    unsupported_temporal_target = CompositeModel(
        Object(:scene; scale=:Scene);
        applications=(
            initializer_creator_application(),
            initializer_leaf_application(policy=Interpolate()),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "Only `PreviousTimeStep` is defined" Advanced.refresh_bindings!(
        unsupported_temporal_target,
    )

    downstream_temporal_consumer = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene);
        applications=(
            initializer_creator_application(),
            initializer_leaf_application(),
            ModelSpec(
                InitializerObserverModel();
                name=:temporal_consumer,
                on=One(scale=:Scene),
                inputs=(
                    mass=Many(
                        scale=:Leaf,
                        within=SceneScope(),
                        application=:leaf_initializer,
                        var=:mass,
                        policy=Integrate(),
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "does not publish a mid-step temporal sample" Advanced.refresh_bindings!(
        downstream_temporal_consumer,
    )

    downstream_previous_timestep_consumer = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene);
        applications=(
            initializer_creator_application(),
            initializer_leaf_application(),
            ModelSpec(
                InitializerObserverModel();
                name=:previous_timestep_consumer,
                on=One(scale=:Scene),
                inputs=(
                    mass=One(
                        scale=:Leaf,
                        within=SceneScope(),
                        application=:leaf_initializer,
                        var=:mass,
                        policy=PreviousTimeStep(:mass),
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "downstream temporal policies (including `PreviousTimeStep`) are unsupported" Advanced.refresh_bindings!(
        downstream_previous_timestep_consumer,
    )
end

@testset "initializer runtime accepts additions only" begin
    existing = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(
            :existing_leaf;
            scale=:Leaf,
            parent=:plant,
            status=Status(
                mass=4.0,
                previous_mass=4.0,
                initializer_runs=0,
            ),
        );
        applications=(
            initializer_creator_application(:existing),
            initializer_leaf_application(),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "no pending structural addition" run!(existing)

    reparented = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(:plant_b; scale=:Plant, parent=:scene),
        Object(
            :existing_leaf;
            scale=:Leaf,
            parent=:plant,
            status=Status(
                mass=4.0,
                previous_mass=4.0,
                initializer_runs=0,
            ),
        );
        applications=(
            initializer_creator_application(:reparented),
            initializer_leaf_application(),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "pure object-addition lifecycle event" run!(reparented)

    removed = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(
            :existing_leaf;
            scale=:Leaf,
            parent=:plant,
            status=Status(
                mass=4.0,
                previous_mass=4.0,
                initializer_runs=0,
            ),
        );
        applications=(
            initializer_creator_application(:removed),
            initializer_leaf_application(),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "No model object with id `existing_leaf`" run!(removed)

    foreign = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene);
        applications=(
            initializer_creator_application(:foreign),
            initializer_leaf_application(),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "not the Object instance registered by this model" run!(foreign)

    poisoned = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene);
        applications=(
            initializer_creator_application(:failing),
            initializer_leaf_application(throw_after_mutation=true),
        ),
        environment=(duration=Hour(1),),
    )
    run!(poisoned)
    poisoned_creator = model_status(poisoned, :scene)
    @test poisoned_creator.failure_seen
    @test poisoned_creator.retry_rejected
    @test poisoned_creator.runs_after_failed_retry == 1
    @test model_status(poisoned, :failing_leaf).initializer_runs == 1

    manual_binding = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene);
        applications=(
            initializer_creator_application(
                :manual_binding;
                binding=Many(
                    scale=:Leaf,
                    application=:leaf_initializer,
                ),
            ),
            initializer_leaf_application(),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "manual hard call, not an `Initializer`" run!(manual_binding)
    @test_throws ArgumentError run_initializer!(nothing, :leaf, :new_leaf)
end
