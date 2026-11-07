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
struct LeafState <: AbstractClosure_LeafModel end

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

function PSE.run!(::LeafState, status, environment, constants, context)
    status.value += status.seed
    status.visits += 1
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

function make_growth()
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
            ModelSpec(LeafState(); name=:leaf, on=Many(scale=:Leaf)),
            ModelSpec(Pulse(); name=:pulse, on=One(id=:owner)),
        ),
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
    @assert environment_plan.backend isa PSE.GlobalConstant{Nothing}
    @assert environment_plan.uses_raw_global_source
    @assert isempty(application.target_ids)
    Empty = NamedTuple{(),Tuple{}}
    I = ObjectId{Symbol}
    # This descriptor is explicitly admitted alongside LeafSeedStatus above.
    # No Leaf, Status, scientific default, or callback is instantiated here.
    View = PSE.CompiledModelStatusView{LeafFullStatus,LeafFullStatus,Tuple{},Empty,Empty}
    Context = PSE.RunContext{typeof(compiled),typeof(application),Tuple{},Empty,Empty,
        typeof(simulation.temporal_streams),typeof(simulation.output_retention),
        typeof(simulation.constants),PSE.NoEnvironmentOverride,I}
    Binding = PSE.CompiledEnvironmentBinding{typeof(environment_plan),Nothing,PSE.EnvironmentContext{I}}
    Target = PSE.CompiledExecutionTarget{typeof(PSE.model_(application.spec)),View,
        Tuple{},Empty,Empty,Tuple{},Tuple{},Binding,Context,I}
    Rows = PSE.ExecutionCohortRows{Target,PSE.ExecutionCohort{Target,I}}
    return PSE.CompiledExecutionBatch{typeof(application),Rows,
        PSE.RawGlobalModelEnvironment{Nothing},PSE.CompiledOutputPublication{Tuple{}}}
end

function prepare_schema_growth()
    setup = make_growth()
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

end
