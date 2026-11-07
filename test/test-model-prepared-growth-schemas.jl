module PreparedExecutionSchemaGrowthTests

using Test

using PlantSimEngine
const PSE = PlantSimEngine

@process "closure_pulse" verbose=false
@process "closure_controller" verbose=false
@process "closure_leaf" verbose=false

struct Pulse <: AbstractClosure_PulseModel end
struct HardController <: AbstractClosure_ControllerModel end
struct GrowthController <: AbstractClosure_ControllerModel
    birth_day::Base.RefValue{Int}
    seed::Base.RefValue{Float64}
end
struct LeafState <: AbstractClosure_LeafModel
    fail_after_mutation::Bool
end

PSE.inputs_(::Pulse) = NamedTuple()
PSE.outputs_(::Pulse) = (rate=0.0,)
PSE.inputs_(::Union{HardController,GrowthController}) = (rate=Default(0.0),)
PSE.outputs_(::HardController) = (ticks=0, pulse_total=0.0)
PSE.outputs_(::GrowthController) = (
    ticks=0, pulse_total=0.0, created=false, births=0, born_value=0.0,
)
PSE.inputs_(::LeafState) = (seed=Required(Real),)
PSE.outputs_(::LeafState) = (value=0.0, visits=0)

function PSE.run!(::Pulse, status, environment, constants, context)
    status.rate += 2.0
    return nothing
end

function PSE.run!(::HardController, status, environment, constants, context)
    run_call!(context, :pulse; publish=true)
    status.ticks += 1
    status.pulse_total += status.rate
    return nothing
end

function PSE.run!(model::GrowthController, status, environment, constants, context)
    run_call!(context, :pulse; publish=true)
    status.ticks += 1
    status.pulse_total += status.rate
    if !status.created && status.ticks >= model.birth_day[]
        leaf = register_object!(runtime_model(context), Object(:leaf;
            scale=:Leaf, parent=:owner, status=Status(seed=model.seed[])))
        run_initializer!(context, :initialize, leaf)
        status.created = true
        status.births += 1
    end
    if status.created
        status.born_value = model_status(runtime_model(context), :leaf).value
    end
    return nothing
end

function PSE.run!(model::LeafState, status, environment, constants, context)
    status.value += status.seed
    status.visits += 1
    model.fail_after_mutation && error("leaf initialization failed after mutation")
    return nothing
end

function make_hardcall()
    return CompositeModel(Object(:owner; scale=:Scene,
            status=Status(rate=0.0, ticks=0, pulse_total=0.0));
        applications=(
            ModelSpec(HardController(); name=:controller, on=One(id=:owner),
                inputs=(rate=One(within=Self(), application=:pulse, var=:rate),),
                calls=(pulse=One(within=Self(), application=:pulse),)),
            ModelSpec(Pulse(); name=:pulse, on=One(id=:owner)),
        ),
    )
end

function make_growth(; environment=nothing, fail_initializer=false)
    birth_day = Ref(2)
    seed = Ref(3.0)
    model = CompositeModel(Object(:owner; scale=:Scene,
            status=Status(rate=0.0, ticks=0, pulse_total=0.0,
                created=false, births=0, born_value=0.0));
        applications=(
            ModelSpec(GrowthController(birth_day, seed);
                name=:controller, on=One(id=:owner),
                inputs=(rate=One(within=Self(), application=:pulse, var=:rate),),
                calls=(
                    pulse=One(within=Self(), application=:pulse),
                    initialize=Initializer(One(within=Subtree(), scale=:Leaf, application=:leaf)),
                )),
            ModelSpec(LeafState(fail_initializer); name=:leaf, on=Many(scale=:Leaf)),
            ModelSpec(Pulse(); name=:pulse, on=One(id=:owner)),
        ), environment,
    )
    return (; model, birth_day, seed)
end

# Exact reference-field types required by this deliberately finite fixture.
# These are empty family descriptors, never fake scientific statuses or values.
const LeafSeedStatus = Status{(:seed,),Tuple{Base.RefValue{Float64}}}
const LeafFullStatus = Status{(:seed,:value,:visits),
    Tuple{Base.RefValue{Float64},Base.RefValue{Float64},Base.RefValue{Int}}}

empty_family(::Type{S}) where {S} = PSE.ObjectFamily{ObjectId{Symbol},S}(
    Union{Nothing,PSE.ObjectFamilyRow{ObjectId{Symbol},S}}[])

function with_closed_registry(model::PSE.CompositeModel; future=())
    previous = model.registry
    closed = PSE._closed_object_family_store(previous.objects)
    families = (closed.catalog.families..., map(empty_family, future)...)
    store = PSE.ObjectFamilyStore(PSE.ClosedObjectFamilyCatalog(families),
        closed.locations, closed.status_owners, copy(closed.layout_cache))
    registry = PSE.ObjectRegistry(store, previous.by_scale, previous.by_kind,
        previous.by_species, previous.ancestor_ids_by_object)
    return PSE.CompositeModel(
        registry, model.applications, model.environment, model.instances,
        model.source_adapter, model.status_conversion, model.status_conversion_records,
        model.status_source_owners, model.status_source_identities,
        model.scenario_plan_cache, model.binding_cache, model.environment_binding_cache,
        model.bindings_dirty, model.environment_bindings_dirty, model.lifecycle_delta,
        model.input_default_status_variables, model.runtime_revision, model.revision,
        model.environment_revision,
    )
end

function future_leaf_batch_type(simulation)
    compiled = simulation.compiled
    application = compiled.applications_by_id[:leaf]
    environment_plan = simulation.environment_bindings.application_plans_by_id[:leaf]
    @assert environment_plan.backend isa PSE.GlobalConstant
    @assert environment_plan.uses_raw_global_source
    @assert isempty(application.target_ids)
    Empty = NamedTuple{(),Tuple{}}
    I = ObjectId{Symbol}
    # This descriptor is explicitly admitted alongside LeafSeedStatus above.
    # No Leaf, Status, scientific default, or callback is instantiated here.
    View = PSE.CompiledModelStatusView{LeafFullStatus,LeafFullStatus,Tuple{},Empty,Empty}
    Context = PSE.RunContext{typeof(compiled),typeof(application),Tuple{},Empty,Empty,
        typeof(simulation.temporal_streams),typeof(simulation.output_retention),
        typeof(simulation.constants),PSE.NoEnvironmentOverride,I,typeof(simulation.environment_bindings)}
    Binding = PSE.CompiledEnvironmentBinding{typeof(environment_plan),Nothing,PSE.EnvironmentContext{I}}
    Target = PSE.CompiledExecutionTarget{typeof(PSE.model_(application.spec)),View,
        Tuple{},Empty,Empty,Tuple{},Tuple{},Binding,Context,I}
    Store = typeof(simulation.temporal_streams.cohorts)
    Owner = PSE._execution_store_owner_type(Store)
    Rows = PSE.ExecutionCohortRows{Target,PSE.ExecutionCohort{Target,I,Owner},Store}
    return PSE.CompiledExecutionBatch{typeof(application),Rows,
        PSE.RawGlobalModelEnvironment{typeof(environment_plan.prepared_source)},
        PSE.CompiledOutputPublication{Tuple{}}}
end

function prepare_schema_growth(; environment=nothing, fail_initializer=false)
    setup = make_growth(; environment, fail_initializer)
    model = with_closed_registry(setup.model;future=(LeafSeedStatus,LeafFullStatus))
    simulation = run!(model;steps=0,outputs=:none)
    controller = only(simulation.execution_plan.groups)
    controller_batch = only(controller.batches)
    context = only(controller_batch.targets).context
    pulse = only(target for target in context.calls if PSE._compiled_call_name(target.binding) === :pulse)
    @test PSE._compiled_call_mode(pulse.binding) === :manual
    PulseBatch = typeof(only(PSE._materialize_call_execution_batches!(pulse)))
    pulse_schema = PSE.PreparedExecutionBatchSchema{Vector{PulseBatch}}()
    LeafBatch = future_leaf_batch_type(simulation)
    leaf_schema = PSE.PreparedExecutionBatchSchema{Vector{LeafBatch}}()
    ControllerBatch = PSE._execution_batch_type_with_call_schemas(typeof(controller_batch),
        (pulse=pulse_schema,initialize=leaf_schema))
    controller_schema = PSE.PreparedExecutionBatchSchema{Vector{ControllerBatch}}()
    before_status = model_status(model,:owner)
    before_reference = PSE.refvalue(before_status,:ticks)
    original_store = simulation.execution_plan.cohorts
    prepared = PSE._prepare_execution_batch_schemas(simulation,
        (controller=controller_schema,leaf=leaf_schema,pulse=pulse_schema))
    @test prepared.temporal_streams.streams === simulation.temporal_streams.streams
    @test prepared.execution_plan.cohorts !== original_store
    @test before_reference === PSE.refvalue(model_status(model,:owner),:ticks)
    @test current_step(prepared) == 0
    @test before_status.ticks == 0
    @test before_status.rate == 0.0
    @test !before_status.created
    return (;simulation=prepared,owner=before_status,setup.birth_day,setup.seed,LeafBatch)
end

@testset "explicit future Leaf metadata uses the canonical initializer and growth engine" begin
    for (steps,birth,seed,visits) in ((0,2,3.0,0),(1,2,3.0,0),(2,2,3.0,1),(4,2,3.0,3))
        state = prepare_schema_growth()
        state.birth_day[] = birth
        state.seed[] = seed
        leaf_group = only(group for group in state.simulation.execution_plan.groups
            if group.application.id === :leaf)
        @test isempty(leaf_group.batches)
        @test isempty(leaf_group.membership.object_ids)
        @test eltype(leaf_group.batches) === state.LeafBatch
        @test state.simulation.execution_plan.topology isa PSE.DynamicExecution
        continue!(state.simulation;steps)
        @test state.owner.ticks == steps
        @test state.owner.rate == 2.0steps
        @test state.owner.pulse_total == steps*(steps+1)
        @test state.owner.births == (steps >= birth ? 1 : 0)
        @test state.owner.created == (steps >= birth)
        if steps >= birth
            status = model_status(state.simulation.model,:leaf)
            @test status.visits == visits
            @test status.value == seed*visits
            @test state.owner.born_value == seed*visits
            current = only(group for group in state.simulation.execution_plan.groups
                if group.application.id === :leaf)
            @test current === leaf_group
            batch = only(current.batches)
            @test typeof(batch) === state.LeafBatch
            payload = only(batch.targets)
            @test payload.status_view.canonical_status === status
            @test PSE.refvalue(payload.status_view.status,:value) === PSE.refvalue(status,:value)
            @test only(batch.targets).call_context_cache.execution_stamp ===
                payload.status_view.execution_stamp
        end
    end
end


call_key(target) = (target.application.id, target.object_id.value)

@testset "prepared newborn views retain current and private environment owners" begin
    for environment in (nothing, (T=3f0,))
        state = prepare_schema_growth(; environment)
        state.birth_day[] = 100 # The test registers its real target explicitly.
        simulation = state.simulation
        step!(simulation) # Obtain a context invoked by the actual root kernel.
        controller = only(group for group in simulation.execution_plan.groups
            if group.application.id === :controller)
        context = only(only(controller.batches).targets).context
        cached = only(calls for calls in context.calls
            if PSE._compiled_call_name(calls.binding) === :initialize)
        current_owner = context.environment_bindings
        leaf_group = only(group for group in simulation.execution_plan.groups
            if group.application.id === :leaf)
        leaf = register_object!(simulation.model, Object(:leaf; scale=:Leaf,
            parent=:owner, status=Status(seed=2.5)))
        targets = PSE._targeted_new_object_call_targets(context, :initialize,
            [ObjectId(:leaf)], cached; initializer=true)
        target = only(targets)
        partial_owner = target.environment_bindings
        @test isconcretetype(eltype(targets))
        @test (@inferred PSE._with_call_target_entry(call_key, targets, target)) === (:leaf, :leaf)
        @test partial_owner !== current_owner
        @test typeof(partial_owner) === typeof(current_owner) ===
            fieldtype(typeof(cached), :environment_bindings)
        @test fieldtype(typeof(context), :environment_bindings) === typeof(current_owner)
        @test fieldtype(typeof(target.context_cache.default), :environment_bindings) ===
            typeof(partial_owner)
        TrialContext = PSE._call_context_type(target.context_cache.default, (T=9f0,))
        @test fieldtype(TrialContext, :environment_bindings) === typeof(partial_owner)
        @test context.environment_bindings === current_owner
        @test only(partial_owner.bindings).object_id == ObjectId(:leaf)
        canonical = model_status(simulation.model, leaf)
        @test target.canonical_status === canonical
        @test PSE.refvalue(target.status, :seed) === PSE.refvalue(canonical, :seed)
        @test canonical.visits == 0 && canonical.value == 0.0
        if isnothing(environment)
            # All other owners/fields belong to the real admitted newborn.
            # Only EB comes from another genuine scenario, outside its schema.
            foreign = prepare_schema_growth(; environment=(T=3f0,))
            foreign_owner = foreign.simulation.environment_bindings
            @test !(foreign_owner isa typeof(partial_owner))
            fields = (object_id=target.object_id, model=target.model,
                output_targets=target.output_targets,
                call_bindings=target.execution_target.call_bindings,
                environment_binding=target.environment_binding)
            owners = (compiled=target.compiled, environment_bindings=foreign_owner,
                temporal_streams=target.temporal_streams,
                output_retention=target.output_retention, constants=target.constants,
                environment=target.environment)
            admission = PSE._call_cohort_admission(cached.batch_schema,
                PSE.OpenExecutionCohortSchema())
            @test_throws ArgumentError PSE._with_execution_target_type(
                (args...) -> error("foreign owner entered target factory"), admission,
                target.application, target.execution_target.status_view, fields, owners)
            @test canonical.visits == 0 && canonical.value == 0.0
            @test isempty(PSE.lifecycle_delta(simulation.model).initialized_targets)
        end
        @test isempty(leaf_group.batches)
        @test PSE.cohort_location(simulation.temporal_streams.cohorts,
            :leaf, ObjectId(:leaf)) === nothing

        @test run_initializer!(context, :initialize, leaf) === canonical
        @test canonical.visits == 1 && canonical.value == 2.5
        @test (:leaf, ObjectId(:leaf)) in PSE.lifecycle_delta(simulation.model).initialized_targets
        @test isempty(leaf_group.batches)
        @test_throws "already initialized" run_initializer!(context, :initialize, leaf)
        @test canonical.visits == 1
        continue!(simulation; steps=1)
        payload = only(only(leaf_group.batches).targets)
        @test canonical.visits == 2 && canonical.value == 5.0
        @test payload.status_view.canonical_status === canonical
        @test payload.call_context_cache !== target.context_cache
        @test payload.call_context_cache.execution_stamp === target.context_cache.execution_stamp
        @test target.environment_bindings === partial_owner
    end
end

@testset "a failed prepared initializer reserves before its only kernel" begin
    state = prepare_schema_growth(; fail_initializer=true)
    state.birth_day[] = 100
    simulation = state.simulation
    step!(simulation)
    controller = only(group for group in simulation.execution_plan.groups
        if group.application.id === :controller)
    context = only(only(controller.batches).targets).context
    leaf = register_object!(simulation.model, Object(:leaf; scale=:Leaf,
        parent=:owner, status=Status(seed=3.0)))
    @test_throws "failed after mutation" run_initializer!(context, :initialize, leaf)
    canonical = model_status(simulation.model, leaf)
    @test canonical.visits == 1 && canonical.value == 3.0
    delta = PSE.lifecycle_delta(simulation.model)
    key = (:leaf, ObjectId(:leaf))
    @test key in delta.initialized_targets
    @test !delta.targeted_topology_runtime.call_context_caches[key].in_use
    @test_throws "already initialized" run_initializer!(context, :initialize, leaf)
    @test canonical.visits == 1 && canonical.value == 3.0
    @test PSE.cohort_location(simulation.temporal_streams.cohorts, :leaf, ObjectId(:leaf)) === nothing
end

end
