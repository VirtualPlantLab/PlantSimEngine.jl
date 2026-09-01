using Dates
using PlantSimEngine
using Test

PlantSimEngine.@process "stabilization_source" verbose = false

struct StabilizationSourceModel <: AbstractStabilization_SourceModel end

PlantSimEngine.inputs_(::StabilizationSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::StabilizationSourceModel) = (signal=0.0,)

function PlantSimEngine.run!(
    ::StabilizationSourceModel,
    status,
    environment,
    constants,
    context,
)
    status.signal += 1
    return nothing
end

PlantSimEngine.@process "stabilization_consumer" verbose = false

struct StabilizationConsumerModel <: AbstractStabilization_ConsumerModel end

PlantSimEngine.inputs_(::StabilizationConsumerModel) = (signal=Required(Float64), supplied=Required(Float64))
PlantSimEngine.outputs_(::StabilizationConsumerModel) = (observed=0.0,)

function PlantSimEngine.run!(
    ::StabilizationConsumerModel,
    status,
    environment,
    constants,
    context,
)
    status.observed = status.signal + status.supplied
    return nothing
end

PlantSimEngine.@process "stabilization_context" verbose = false

struct StabilizationContextModel <: AbstractStabilization_ContextModel end

PlantSimEngine.inputs_(::StabilizationContextModel) = NamedTuple()
PlantSimEngine.outputs_(::StabilizationContextModel) = (seen_revision=0,)

function PlantSimEngine.run!(
    ::StabilizationContextModel,
    status,
    environment,
    constants,
    context,
)
    status.seen_revision = Advanced.model_revision(runtime_model(context))
    return nothing
end

struct StabilizationAlternativeContextModel <: AbstractStabilization_ContextModel end

PlantSimEngine.inputs_(::StabilizationAlternativeContextModel) = NamedTuple()
PlantSimEngine.outputs_(::StabilizationAlternativeContextModel) =
    (seen_revision=0,)

function PlantSimEngine.run!(
    ::StabilizationAlternativeContextModel,
    status,
    environment,
    constants,
    context,
)
    status.seen_revision = -Advanced.model_revision(runtime_model(context))
    return nothing
end

PlantSimEngine.@process "stabilization_environment" verbose = false

struct StabilizationEnvironmentModel <: AbstractStabilization_EnvironmentModel end

PlantSimEngine.inputs_(::StabilizationEnvironmentModel) = NamedTuple()
PlantSimEngine.outputs_(::StabilizationEnvironmentModel) = (temperature_seen=0.0,)
PlantSimEngine.environment_inputs_(::StabilizationEnvironmentModel) = (T=0.0,)

function PlantSimEngine.run!(
    ::StabilizationEnvironmentModel,
    status,
    environment,
    constants,
    context,
)
    status.temperature_seen = environment.T
    return nothing
end

PlantSimEngine.@process "stabilization_lagged_sum" verbose = false

struct StabilizationLaggedSumModel <: AbstractStabilization_Lagged_SumModel end

PlantSimEngine.inputs_(::StabilizationLaggedSumModel) =
    (previous_signals=Default([0.0]),)
PlantSimEngine.outputs_(::StabilizationLaggedSumModel) = (lagged_total=0.0,)

function PlantSimEngine.run!(
    ::StabilizationLaggedSumModel,
    status,
    environment,
    constants,
    context,
)
    status.lagged_total = sum(status.previous_signals)
    return nothing
end

struct StabilizationSafeLaggedSumModel <: AbstractStabilization_Lagged_SumModel end

PlantSimEngine.inputs_(::StabilizationSafeLaggedSumModel) =
    (previous_signals=Default([0.0]),)
PlantSimEngine.outputs_(::StabilizationSafeLaggedSumModel) =
    (lagged_total=0.0,)

function PlantSimEngine.run!(
    ::StabilizationSafeLaggedSumModel,
    status,
    environment,
    constants,
    context,
)
    status.lagged_total = sum(status.previous_signals; init=0.0)
    return nothing
end

struct StabilizationMixedManySumModel <: AbstractStabilization_Lagged_SumModel end

PlantSimEngine.inputs_(::StabilizationMixedManySumModel) =
    (previous_signals=Default(Any[]),)
PlantSimEngine.outputs_(::StabilizationMixedManySumModel) =
    (lagged_total=0.0,)

function PlantSimEngine.run!(
    ::StabilizationMixedManySumModel,
    status,
    environment,
    constants,
    context,
)
    status.lagged_total = sum(status.previous_signals; init=0.0)
    return nothing
end

@testset "one-object lowering and initialization report" begin
    model = CompositeModel(
        StabilizationSourceModel(),
        StabilizationConsumerModel();
        status=(supplied=2.0,),
    )

    @test length(model_objects(model)) == 1
    @test length(model.applications) == 2
    @test only(model_objects(model)).id == ObjectId(:scene)

    timed_scene = CompositeModel(
        StabilizationSourceModel(),
        StabilizationConsumerModel();
        status=(supplied=2.0,),
        timestep=Dates.Hour(2),
    )
    @test all(
        row -> row.timestep == Dates.Hour(2),
        explain_applications(timed_scene),
    )

    explicit_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene, name=:scene, status=Status(supplied=2.0));
        applications=(
            ModelSpec(StabilizationSourceModel(); on=One(name=:scene)),
            ModelSpec(StabilizationConsumerModel(); on=One(name=:scene)),
        ),
    )
    concise_applications = explain_applications(model)
    explicit_applications = explain_applications(explicit_scene)
    @test getproperty.(concise_applications, :application_id) ==
          getproperty.(explicit_applications, :application_id)
    @test getproperty.(concise_applications, :target_ids) ==
          getproperty.(explicit_applications, :target_ids)

    report = explain_initialization(model)
    dispositions = Dict(
        (row.application_id, row.variable, row.role) => row.disposition
        for row in report
    )
    @test dispositions[(:stabilization_source, :signal, :output)] == :generated
    @test dispositions[(:stabilization_consumer, :signal, :input)] ==
          :producer_bound
    @test dispositions[(:stabilization_consumer, :supplied, :input)] == :supplied
    @test dispositions[(:stabilization_consumer, :observed, :output)] == :generated
    supplied_row = only(
        row for row in report
        if row.application_id == :stabilization_consumer &&
           row.variable == :supplied
    )
    @test supplied_row.origin == :status
    @test supplied_row.expected_type == Float64
    @test supplied_row.provided_type == Float64

    simulation = run!(model)
    @test only(model_objects(model)).status.observed == 3.0
    @test runtime_model(model) === model
    @test runtime_model(simulation) === model
    @test length(explain_applications(simulation)) == 2
    @test length(explain_initialization(simulation)) == length(report)
    @test !isempty(explain_execution_plan(simulation))

    unresolved_scene = CompositeModel(StabilizationConsumerModel())
    unresolved = filter(
        row -> row.role == :input && row.disposition == :required,
        explain_initialization(unresolved_scene),
    )
    @test Set(row.variable for row in unresolved) == Set((:signal, :supplied))
    @test all(row -> row.origin == :missing, unresolved)
    @test all(row -> occursin("add `inputs=", row.detail), unresolved)
    @test_throws "Missing required composite-model/object input" run!(unresolved_scene)

    environment_scene = CompositeModel(
        StabilizationEnvironmentModel();
        environment=(T=20.0, duration=3600.0),
    )
    temperature_row = only(
        row for row in explain_initialization(environment_scene)
        if row.role == :environment_input && row.variable == :T
    )
    @test temperature_row.disposition == :environment_bound
end

@testset "public namespace boundary" begin
    public_names = Set(names(PlantSimEngine))
    expected_public_names = Set([
        Symbol("@process"),
        :AbstractModel,
        :Advanced,
        :Aggregate,
        :Ancestor,
        :Atmosphere,
        :Authoring,
        :BoundMany,
        :Call,
        :CallTarget,
        :CallTargets,
        :ClockSpec,
        :CompositeModel,
        :CompositeModelTemplate,
        :Constants,
        :Default,
        :Diagnostics,
        :Environment,
        :EnvironmentAPI,
        :Evaluation,
        :GraphEditor,
        :HoldLast,
        :Initializer,
        :Input,
        :Integrate,
        :Interpolate,
        :Many,
        :ModelSpec,
        :Object,
        :ObjectId,
        :ObjectInstance,
        :One,
        :OptionalOne,
        :OutputTo,
        :OutputRequest,
        :Override,
        :OutputTargets,
        :PlantSimEngine,
        :PreviousTimeStep,
        :Relation,
        :Required,
        :RunContext,
        :SceneScope,
        :SchedulePolicy,
        :Scope,
        :Self,
        :SelfPlant,
        :Simulation,
        :Status,
        :Subtree,
        :Updates,
        :VariableContract,
        :Weather,
        :add_organ!,
        :application_name,
        :assign_outputs!,
        :applies_to,
        :bounds,
        :bound_input,
        :call_model,
        :call_targets,
        :collect_outputs,
        :commit_environment!,
        :continue!,
        :current_step,
        :dep,
        :environment_bindings,
        :environment_config,
        :environment_hint,
        :environment_inputs,
        :environment_outputs,
        :environment_window,
        :final_state,
        :geometry,
        :init_variables,
        :inputs,
        :mark_environment_binding_dirty!,
        :model_calls,
        :model_object,
        :model_objects,
        :model_status,
        :move_object!,
        :object_id,
        :object_ids,
        :objects_from_mtg,
        :output_policy,
        :output_routing,
        :outputs_to,
        :output_targets,
        :outputs,
        :position,
        :process,
        :register_object!,
        :remove_object!,
        :reparent_object!,
        :resolve_object_ids,
        :resolve_objects,
        :run!,
        :run_call!,
        :run_initializer!,
        :runtime_model,
        :source_node,
        :step!,
        :timespec,
        :timestep_hint,
        :update_geometry!,
        :updates,
        :validate_environment_inputs,
        :value_inputs,
        :variable_contracts,
        :variables,
    ])
    @test public_names == expected_public_names
    advanced_names = names(PlantSimEngine.Advanced)
    authoring_names = names(PlantSimEngine.Authoring)
    diagnostic_names = names(PlantSimEngine.Diagnostics)
    graph_editor_names = names(PlantSimEngine.GraphEditor)
    environment_api_names = names(PlantSimEngine.EnvironmentAPI)
    evaluation_names = names(PlantSimEngine.Evaluation)
    @test Set(advanced_names) == Set([
        :Advanced,
        :CompiledApplicationPlan,
        :CompiledCompositeModel,
        :CompiledDistributedOutputPlans,
        :CompiledDistributedOutputs,
        :CompiledEnvironmentBinding,
        :CompiledEnvironmentBindings,
        :CompiledModelApplication,
        :CompiledModelCallPlan,
        :CompiledModelCallBinding,
        :CompiledModelOutputDestinationBinding,
        :CompiledModelOutputDestinationPlan,
        :CompiledModelInputPlan,
        :CompiledModelInputBinding,
        :CompiledScenarioPlan,
        :LifecycleDelta,
        :LifecycleMoveEvent,
        :LifecycleObjectSnapshot,
        :LifecycleReparentEvent,
        :ObjectRefVector,
        :ObjectRegistry,
        :RuntimePerformanceCounters,
        :TimeStepTable,
        :bindings_dirty,
        :compile_composite_model,
        :compile_environment_bindings,
        :compiled_bindings,
        :compiled_environment_bindings,
        :environment_bindings_dirty,
        :environment_revision,
        :lifecycle_delta,
        :model_revision,
        :refresh_bindings!,
        :refresh_environment_bindings!,
        :runtime_performance,
    ])
    @test Set(authoring_names) == Set([
        :Authoring,
        :ModelComparison,
        :ModelDependencyDescription,
        :ModelDescription,
        :ModelDifference,
        :ModelInterface,
        :ModelParameterDescription,
        :ModelPortDescription,
        :ModelValidationReport,
        :SCHEMA_VERSION,
        :ScenarioValidationReport,
        :ValidationDiagnostic,
        :available_models,
        :available_processes,
        :compare_models,
        :compiled_model_source,
        :describe_model,
        :model_interface,
        :model_metadata,
        :parameter_metadata,
        :scenario_source,
        :to_dict,
        :to_json,
        :validate_model,
        :validate_scenario,
        :write_compiled_model_source,
    ])
    @test Set(diagnostic_names) == Set([
        :Diagnostics,
        :ObjectAddress,
        :explain_applications,
        :explain_bindings,
        :explain_calls,
        :explain_environment,
        :explain_environment_bindings,
        :explain_execution_plan,
        :explain_initialization,
        :explain_instances,
        :explain_runtime_performance,
        :explain_objects,
        :explain_output_bindings,
        :explain_output_retention,
        :explain_outputs,
        :explain_schedule,
        :explain_scopes,
        :explain_writers,
        :has_reference_carrier,
        :input_carrier,
        :input_value,
        :object_address,
    ])
    @test Set(graph_editor_names) == Set([
        :AbstractModelGraphEdit,
        :AbstractModelGraphEditorSession,
        :AddModelApplication,
        :AddModelInstance,
        :AddModelObject,
        :BreakModelCycle,
        :GraphEditor,
        :MarkModelPreviousTimeStep,
        :ModelApplicationRef,
        :ModelGraphDiagnostic,
        :ModelGraphView,
        :RemoveModelApplication,
        :RemoveModelCallBinding,
        :RemoveModelInputBinding,
        :RemoveModelInstance,
        :RemoveModelInstanceOverride,
        :RemoveModelObject,
        :RemoveModelObjectOverride,
        :RemoveModelObjectStatus,
        :RenameModelApplication,
        :ReparentModelObject,
        :ReplaceModelApplicationModel,
        :SetModelApplicationEnvironment,
        :SetModelApplicationCadence,
        :SetModelApplicationTargets,
        :SetModelCallBinding,
        :SetModelInputBinding,
        :SetModelInstanceOverride,
        :SetModelObjectMetadata,
        :SetModelObjectOverride,
        :SetModelObjectStatus,
        :SetModelObjectStatuses,
        :SetModelOutputRouting,
        :SetModelUpdateOrdering,
        :SetCompositeModelEnvironment,
        :GlobalApplicationRef,
        :TemplateApplicationRef,
        :UnmarkModelPreviousTimeStep,
        :UpdateModelApplication,
        :apply_edit!,
        :apply_model_graph_edit,
        :compile_model_graph,
        :current_model,
        :edit_graph,
        :model_graph_view,
        :model_graph_view_html,
        :model_graph_view_json,
        :redo!,
        :undo!,
        :write_model_graph_view,
    ])
    @test Set(environment_api_names) == Set([
        :AbstractEnvironmentBackend,
        :EnvironmentAPI,
        :EnvironmentContext,
        :GlobalConstant,
        :base_step_seconds,
        :bind_environment,
        :commit_environment!,
        :environment_backend,
        :environment_variables,
        :get_nsteps,
        :sample,
        :sample_environment,
        :update_index!,
    ])
    @test Set(evaluation_names) == Set([
        :EF,
        :Evaluation,
        :NRMSE,
        :RMSE,
        :dr,
        :fit,
    ])
    for public_name in (
        :CompositeModel,
        :CompositeModelTemplate,
        :Simulation,
        :RunContext,
        :CallTarget,
        :commit_environment!,
        :final_state,
        :model_objects,
        :runtime_model,
        :Authoring,
        :Diagnostics,
        :GraphEditor,
        :EnvironmentAPI,
        :Evaluation,
    )
        @test public_name in public_names
    end
    for diagnostic_name in (
        :explain_objects,
        :explain_applications,
        :explain_bindings,
        :explain_calls,
        :explain_schedule,
        :input_carrier,
        :object_address,
    )
        @test diagnostic_name ∉ public_names
        @test diagnostic_name ∈ diagnostic_names
    end
    for authoring_name in (
        :describe_model,
        :model_interface,
        :compare_models,
        :validate_model,
        :validate_scenario,
    )
        @test authoring_name ∉ public_names
        @test authoring_name ∈ authoring_names
    end
    for graph_editor_name in (
        :ModelGraphView,
        :model_graph_view,
        :AddModelApplication,
        :edit_graph,
    )
        @test graph_editor_name ∉ public_names
        @test graph_editor_name ∈ graph_editor_names
    end
    for environment_api_name in (
        :AbstractEnvironmentBackend,
        :EnvironmentContext,
        :environment_backend,
        :sample_environment,
    )
        @test environment_api_name ∉ public_names
        @test environment_api_name ∈ environment_api_names
    end
    for evaluation_name in (:fit, :RMSE, :NRMSE, :EF, :dr)
        @test evaluation_name ∉ public_names
        @test evaluation_name ∈ evaluation_names
    end
    for reducer_name in (
        :AbstractTimeReducer,
        :MeanWeighted,
        :MeanReducer,
        :SumReducer,
        :MinReducer,
        :MaxReducer,
        :FirstReducer,
        :LastReducer,
        :RadiationEnergy,
    )
        @test reducer_name ∉ public_names
    end
    for extension_name in (
        :inputs_,
        :outputs_,
        :environment_inputs_,
        :environment_outputs_,
    )
        @test extension_name ∉ public_names
        @test isdefined(PlantSimEngine, extension_name)
    end
    for internal_name in (
        :ObjectRegistry,
        :CompiledApplicationPlan,
        :CompiledModelInputPlan,
        :CompiledModelCallPlan,
        :CompiledScenarioPlan,
        :CompiledCompositeModel,
        :CompiledModelApplication,
        :compile_composite_model,
        :refresh_bindings!,
        :bindings_dirty,
        :RuntimePerformanceCounters,
        :runtime_performance,
    )
        @test internal_name ∉ public_names
        @test internal_name ∈ advanced_names
    end
    for removed_name in (
        :EnvironmentSupport,
        :AppliesTo,
        :Inputs,
        :Calls,
        :TimeStep,
        :OutputRouting,
        :Kind,
        :Species,
        :Scale,
        :with_environment!,
        :update_environment!,
        :scatter!,
        :scatter_environment_outputs!,
    )
        @test removed_name ∉ public_names
        @test !isdefined(PlantSimEngine, removed_name)
    end

    @test_throws MethodError ModelSpec(
        StabilizationSourceModel();
        applies_to=One(scale=:Leaf),
    )
    @test_throws MethodError ModelSpec(
        StabilizationSourceModel();
        timestep=Dates.Hour(1),
    )
    @test_throws MethodError run!(
        CompositeModel(StabilizationSourceModel());
        tracked_outputs=nothing,
    )
    @test_throws UndefKeywordError Override(
        object=:leaf,
        process=:stabilization_source,
        model=StabilizationSourceModel(),
    )
    @test_throws "environment=Environment" ModelSpec(
        StabilizationEnvironmentModel();
        environment=(provider=:global,),
    )
end

@testset "shared lifecycle delta journals bulk mutations" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant_a; scale=:Plant, parent=:scene),
        Object(:plant_b; scale=:Plant, parent=:scene),
        Object(:branch; scale=:Axis, parent=:plant_a),
        Object(:branch_leaf; scale=:Leaf, parent=:branch),
        Object(
            :geometry_root;
            scale=:Axis,
            parent=:plant_b,
            geometry=(cell=:sun,),
        ),
        Object(:geometry_leaf; scale=:Leaf, parent=:geometry_root),
    )
    initial_delta = Advanced.lifecycle_delta(model)
    @test length(initial_delta.added) == 7
    @test initial_delta.structural_kind == :full
    @test Advanced.model_revision(model) == 0
    @test Advanced.environment_revision(model) == 0
    @test model.runtime_revision == 0
    Advanced.refresh_environment_bindings!(model)
    scenario_plan = Advanced.compiled_bindings(model).scenario_plan
    @test isempty(Advanced.lifecycle_delta(model).added)

    base_revisions = (
        Advanced.model_revision(model),
        Advanced.environment_revision(model),
        model.runtime_revision,
    )
    PlantSimEngine._register_objects!(
        model,
        Object[
            Object(
                :added_leaf_1;
                scale=:Leaf,
                kind=:leaf,
                species=:test,
                name=:added_leaf_1,
                parent=:plant_a,
            ),
            Object(:added_leaf_2; scale=:Leaf, parent=:plant_a),
        ],
    )
    additions = Advanced.lifecycle_delta(model)
    @test (
        Advanced.model_revision(model),
        Advanced.environment_revision(model),
        model.runtime_revision,
    ) == base_revisions .+ 1
    @test additions.structural_generation == Advanced.model_revision(model)
    @test additions.environment_generation ==
          Advanced.environment_revision(model)
    @test additions.structural_kind == :addition
    @test Set(snapshot.id for snapshot in additions.added) ==
          Set(ObjectId.([:added_leaf_1, :added_leaf_2]))
    added_leaf = only(
        snapshot for snapshot in additions.added
        if snapshot.id == ObjectId(:added_leaf_1)
    )
    @test added_leaf.kind == :leaf
    @test added_leaf.species == :test
    @test added_leaf.parent == ObjectId(:plant_a)
    @test added_leaf.ancestors ==
          (ObjectId(:scene), ObjectId(:plant_a), ObjectId(:added_leaf_1))
    Advanced.refresh_environment_bindings!(model)
    @test Advanced.compiled_bindings(model).scenario_plan === scenario_plan
    @test Advanced.lifecycle_delta(model) !== additions
    @test Advanced.lifecycle_delta(model).structural_kind == :clean

    reparent_base = (
        Advanced.model_revision(model),
        Advanced.environment_revision(model),
        model.runtime_revision,
    )
    reparent_object!(model, :branch, :plant_b)
    reparented = Advanced.lifecycle_delta(model)
    @test length(reparented.reparented) == 1
    reparent_event = only(reparented.reparented)
    @test reparent_event.root_id == ObjectId(:branch)
    @test reparent_event.descendant_ids ==
          (ObjectId(:branch), ObjectId(:branch_leaf))
    @test reparent_event.old_parent == ObjectId(:plant_a)
    @test reparent_event.new_parent == ObjectId(:plant_b)
    @test reparent_event.old_ancestors_by_object[ObjectId(:branch_leaf)] ==
          (ObjectId(:scene), ObjectId(:plant_a), ObjectId(:branch), ObjectId(:branch_leaf))
    @test (
        Advanced.model_revision(model),
        Advanced.environment_revision(model),
        model.runtime_revision,
    ) == reparent_base .+ 1

    move_object!(model, :geometry_root, (cell=:shade,))
    @test (
        Advanced.model_revision(model),
        Advanced.environment_revision(model),
        model.runtime_revision,
    ) == reparent_base .+ 1
    move_event = only(Advanced.lifecycle_delta(model).moved)
    @test move_event.object_id == ObjectId(:geometry_root)
    @test move_event.affected_object_ids ==
          (ObjectId(:geometry_root), ObjectId(:geometry_leaf))
    @test move_event.old_geometry == (cell=:sun,)
    @test move_event.new_geometry == (cell=:shade,)
    Advanced.refresh_environment_bindings!(model)
    @test Advanced.compiled_bindings(model).scenario_plan === scenario_plan

    removal_base = (
        Advanced.model_revision(model),
        Advanced.environment_revision(model),
        model.runtime_revision,
    )
    remove_object!(model, :branch)
    removal = Advanced.lifecycle_delta(model)
    @test (
        Advanced.model_revision(model),
        Advanced.environment_revision(model),
        model.runtime_revision,
    ) == removal_base .+ 1
    @test Tuple(snapshot.id for snapshot in removal.removed) ==
          (ObjectId(:branch), ObjectId(:branch_leaf))
    removed_leaf = last(removal.removed)
    @test removed_leaf.parent == ObjectId(:branch)
    @test removed_leaf.ancestors ==
          (ObjectId(:scene), ObjectId(:plant_b), ObjectId(:branch), ObjectId(:branch_leaf))
    @test !haskey(model.registry.objects, ObjectId(:branch))
    @test !haskey(model.registry.objects, ObjectId(:branch_leaf))
    Advanced.refresh_environment_bindings!(model)
    @test Advanced.compiled_bindings(model).scenario_plan === scenario_plan
end

@testset "lifecycle delta supports partial cache consumption" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene);
        applications=(
            ModelSpec(
                StabilizationSourceModel();
                name=:source,
                on=Many(scale=:Leaf),
            ),
        ),
    )
    Advanced.refresh_environment_bindings!(model)
    register_object!(model, Object(:leaf_1; scale=:Leaf, parent=:scene))
    first_refresh = Advanced.refresh_bindings!(model)
    @test first_refresh.applications_by_id.source.target_ids ==
          ObjectId[ObjectId(:leaf_1)]
    after_binding_refresh = Advanced.lifecycle_delta(model)
    @test after_binding_refresh.structural_kind == :clean
    @test isempty(after_binding_refresh.structural_dirty_ids)
    @test only(after_binding_refresh.added).id == ObjectId(:leaf_1)
    @test after_binding_refresh.environment_dirty_ids ==
          Set([ObjectId(:leaf_1)])

    register_object!(model, Object(:leaf_2; scale=:Leaf, parent=:scene))
    pending = Advanced.lifecycle_delta(model)
    @test pending.structural_dirty_ids == Set([ObjectId(:leaf_2)])
    @test Tuple(snapshot.id for snapshot in pending.added) ==
          (ObjectId(:leaf_1), ObjectId(:leaf_2))
    Advanced.refresh_environment_bindings!(model)
    @test Advanced.compiled_bindings(model).applications_by_id.source.target_ids ==
          ObjectId.([:leaf_1, :leaf_2])
    @test Advanced.lifecycle_delta(model).structural_kind == :clean
    @test isempty(Advanced.lifecycle_delta(model).added)
end

@testset "composite model template constructor" begin
    template = CompositeModelTemplate((
        ModelSpec(StabilizationSourceModel(); on=One(scale=:Leaf)),
    ); species=:test_species)
    root = Object(:plant; scale=:Plant)
    leaf = Object(:leaf; scale=:Leaf, parent=:plant)

    model = CompositeModel(
        template;
        root=root,
        objects=(leaf,),
        environment=(duration=1.0,),
    )

    @test model isa CompositeModel
    @test only(model.instances).template === template
    @test only(model_objects(model; scale=:Plant)).species == :test_species
    @test only(model_objects(model; scale=:Leaf)).species == :test_species
    run!(model)
    @test only(model_objects(model; scale=:Leaf)).status.signal == 1.0
end

@testset "sanctioned runtime model access" begin
    model = CompositeModel(StabilizationContextModel())
    run!(model)
    @test only(model_objects(model)).status.seen_revision == Advanced.model_revision(model)
end

@testset "explicit output retention and continuation" begin
    default_scene = CompositeModel(StabilizationSourceModel())
    @test isempty(explain_output_retention(default_scene))
    @test only(explain_output_retention(default_scene; outputs=:all)).reasons ==
          (:all_outputs,)
    default_simulation = run!(default_scene; steps=2)
    @test isempty(outputs(default_simulation))
    default_batch = only(default_simulation.execution_plan.batches)
    @test !default_batch.output_publication.enabled
    @test isempty(default_batch.output_publication.variables)
    @test isempty(only(default_batch.targets).output_bindings)
    @test current_step(default_simulation) == 2
    @test final_state(default_simulation) == (signal=2.0,)
    @test final_state(default_simulation, :scene) == (signal=2.0,)
    @test final_state(
        default_simulation,
        OptionalOne(scale=:Leaf),
    ) === nothing
    @test final_state(default_simulation, Many()) ==
          Dict(:scene => (signal=2.0,))

    multi_object_scene = CompositeModel(
        Object(:leaf_1; scale=:Leaf),
        Object(:leaf_2; scale=:Leaf);
        applications=(
            ModelSpec(
                StabilizationSourceModel();
                on=Many(scale=:Leaf),
            ),
        ),
    )
    multi_object_simulation = run!(multi_object_scene)
    @test_throws Exception final_state(multi_object_simulation)
    @test final_state(multi_object_simulation, Many(scale=:Leaf)) ==
          Dict(
              :leaf_1 => (signal=1.0,),
              :leaf_2 => (signal=1.0,),
          )

    compact_display = sprint(show, default_simulation)
    @test compact_display ==
          "Simulation(steps=2, objects=1, applications=1, retained_streams=0)"
    detailed_display = sprint(show, MIME"text/plain"(), default_simulation)
    @test occursin("elapsed steps: 2", detailed_display)
    @test occursin("objects: 1", detailed_display)
    @test occursin("applications: 1", detailed_display)
    @test occursin("retained streams: 0", detailed_display)
    @test occursin("outputs=:all", detailed_display)
    @test occursin("OutputRequest", detailed_display)

    retained_scene = CompositeModel(StabilizationSourceModel())
    simulation = run!(retained_scene; steps=2, outputs=:all)
    @test current_step(simulation) == 2
    retained_batch = only(simulation.execution_plan.batches)
    @test retained_batch.output_publication.enabled
    @test retained_batch.output_publication.variables == (:signal,)
    retained_output = only(only(retained_batch.targets).output_bindings)
    @test retained_output.stream === outputs(simulation)[
        (:stabilization_source, ObjectId(:scene), :signal)
    ]
    retained_display = sprint(show, MIME"text/plain"(), simulation)
    @test occursin("retained streams: 1", retained_display)
    @test !occursin("hint:", retained_display)
    @test last.(outputs(simulation)[
        (:stabilization_source, ObjectId(:scene), :signal)
    ]) == [1.0, 2.0]

    state_before_continuation = final_state(simulation)
    @test continue!(simulation; steps=2) === simulation
    @test state_before_continuation == (signal=2.0,)
    @test final_state(simulation) == (signal=4.0,)
    @test current_step(simulation) == 4
    @test last.(outputs(simulation)[
        (:stabilization_source, ObjectId(:scene), :signal)
    ]) == [1.0, 2.0, 3.0, 4.0]

    @test step!(simulation) === simulation
    @test current_step(simulation) == 5
    @test last(outputs(simulation)[
        (:stabilization_source, ObjectId(:scene), :signal)
    ]) == (5.0, 5.0)

    fresh_result = run!(retained_scene; outputs=:all)
    @test current_step(fresh_result) == 1
    @test only(outputs(fresh_result)[
        (:stabilization_source, ObjectId(:scene), :signal)
    ]) == (1.0, 6.0)
end

@testset "self and subtree have distinct scope semantics" begin
    model = CompositeModel(
        Object(:plant; scale=:Plant),
        Object(:leaf_1; scale=:Leaf, parent=:plant),
        Object(:leaf_2; scale=:Leaf, parent=:plant),
    )

    @test resolve_object_ids(model, One(Self()); context=:plant) ==
          [ObjectId(:plant)]
    @test resolve_object_ids(model, Many(Subtree()); context=:plant) ==
          ObjectId[ObjectId(:leaf_1), ObjectId(:leaf_2), ObjectId(:plant)]
    @test resolve_object_ids(model, Many(scale=:Leaf, within=Self()); context=:plant) ==
          ObjectId[]
    @test resolve_object_ids(model, Many(scale=:Leaf, within=Subtree()); context=:plant) ==
          ObjectId[ObjectId(:leaf_1), ObjectId(:leaf_2)]

    default_scope_selector = One(scale=:Leaf)
    @test PlantSimEngine._resolve_object_ids(
        model,
        default_scope_selector,
        PlantSimEngine._compile_selector_matcher(
            model,
            default_scope_selector,
        );
        context=ObjectId(:leaf_1),
        default_to_context=true,
        default_scope=Self(),
    ) == ObjectId[ObjectId(:leaf_1)]

    ambiguous_scoped_error = try
        resolve_object_ids(
            model,
            One(scale=:Leaf, within=Subtree());
            context=:plant,
        )
        nothing
    catch error
        sprint(showerror, error)
    end
    @test contains(
        ambiguous_scoped_error,
        "available=(scales = [:Leaf],",
    )

    missing_scoped_error = try
        resolve_object_ids(
            model,
            One(scale=:Leef, within=Subtree());
            context=:plant,
        )
        nothing
    catch error
        sprint(showerror, error)
    end
    @test contains(
        missing_scoped_error,
        "available=(scales = [:Leaf, :Plant],",
    )
    @test contains(missing_scoped_error, "suggestions=(scale = [:Leaf]")

    long_scope_objects = Object[Object(:long_root; scale=:Plant)]
    long_scope_leaf_ids = Set{ObjectId}()
    parent_id = :long_root
    for index in 1:40
        object_id = Symbol(:long_scope_, index)
        object_scale = isodd(index) ? :Leaf : :Axis
        push!(
            long_scope_objects,
            Object(object_id; scale=object_scale, parent=parent_id),
        )
        object_scale == :Leaf && push!(long_scope_leaf_ids, ObjectId(object_id))
        parent_id = object_id
    end
    long_scope_model = CompositeModel(long_scope_objects...)
    @test length(
        PlantSimEngine._descendant_ids_up_to(
            long_scope_model,
            ObjectId(:long_scope_10),
            PlantSimEngine._SCOPE_FIRST_DESCENDANT_LIMIT,
        ),
    ) == 31
    @test length(
        PlantSimEngine._descendant_ids_up_to(
            long_scope_model,
            ObjectId(:long_scope_9),
            PlantSimEngine._SCOPE_FIRST_DESCENDANT_LIMIT,
        ),
    ) == PlantSimEngine._SCOPE_FIRST_DESCENDANT_LIMIT
    @test isnothing(
        PlantSimEngine._descendant_ids_up_to(
            long_scope_model,
            ObjectId(:long_scope_8),
            PlantSimEngine._SCOPE_FIRST_DESCENDANT_LIMIT,
        ),
    )
    @test isnothing(
        PlantSimEngine._descendant_ids_up_to(
            long_scope_model,
            ObjectId(:long_root),
            PlantSimEngine._SCOPE_FIRST_DESCENDANT_LIMIT,
        ),
    )
    @test Set(
        resolve_object_ids(
            long_scope_model,
            Many(scale=:Leaf, within=Subtree());
            context=:long_root,
        ),
    ) == long_scope_leaf_ids
    @test resolve_object_ids(
        long_scope_model,
        Many(scale=:Leaf, within=Subtree());
        context=:long_scope_39,
    ) == ObjectId[ObjectId(:long_scope_39)]

    @test_throws "No matching ancestor" resolve_object_ids(
        model,
        Many(within=Ancestor(scale=:Plant));
        context=:plant,
    )
end

function stabilization_compiled_selector_allocations(
    model,
    matcher,
    object_id,
    context,
)
    return @allocated PlantSimEngine._selector_matches_object_id(
        model,
        matcher,
        object_id;
        context=context,
    )
end

@testset "compiled selector matchers preserve topology semantics" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(:axis; scale=:Axis, parent=:plant),
        Object(:leaf_1; scale=:Leaf, parent=:axis),
        Object(:leaf_2; scale=:Leaf, parent=:plant),
        Object(:other_plant; scale=:Plant, parent=:scene),
        Object(:other_leaf; scale=:Leaf, parent=:other_plant),
    )
    cases = (
        (Many(Self()), :leaf_1),
        (Many(Subtree()), :plant),
        (Many(SelfPlant()), :leaf_1),
        (Many(Ancestor()), :leaf_1),
        (Many(Ancestor(scale=:Plant)), :leaf_1),
        (Many(Scope(:plant)), :leaf_1),
        (Many(Relation(:self)), :leaf_1),
        (Many(Relation(:parent)), :leaf_1),
        (Many(Relation(:children)), :plant),
        (Many(Relation(:ancestors)), :leaf_1),
        (Many(Relation(:descendants)), :plant),
        (Many(Relation(:siblings)), :axis),
    )
    all_ids = object_ids(model)
    for (selector, context) in cases
        matcher = PlantSimEngine._compile_selector_matcher(model, selector)
        matched = ObjectId[
            object_id for object_id in all_ids
            if PlantSimEngine._selector_matches_object_id(
                model,
                matcher,
                object_id;
                context=context,
            )
        ]
        PlantSimEngine._sort_object_ids!(matched)
        @test matched == resolve_object_ids(model, selector; context=context)
        for object_id in all_ids
            stabilization_compiled_selector_allocations(
                model,
                matcher,
                object_id,
                context,
            )
            @test stabilization_compiled_selector_allocations(
                model,
                matcher,
                object_id,
                ObjectId(context),
            ) == 0
        end
    end

    named_matcher = PlantSimEngine._compile_selector_matcher(
        model,
        Many(scale=:Leaf, within=Scope(:plant)),
    )
    @test named_matcher.scope isa PlantSimEngine.CompiledNamedScope
    @test named_matcher.scope.root_id == ObjectId(:plant)

    ancestor_matcher = PlantSimEngine._compile_selector_matcher(
        model,
        Many(Ancestor()),
    )
    @test_throws "No matching ancestor" PlantSimEngine._selector_matches_object_id(
        model,
        ancestor_matcher,
        ObjectId(:scene);
        context=ObjectId(:scene),
    )
end

function stabilization_selector_candidate_scene(nplants)
    objects = Object[Object(:scene; scale=:Scene, kind=:scene)]
    for index in 1:nplants
        plant_id = Symbol(:plant_, index)
        push!(objects, Object(plant_id; scale=:Plant, parent=:scene))
        push!(
            objects,
            Object(
                Symbol(plant_id, :_leaf);
                scale=:Leaf,
                parent=plant_id,
            ),
        )
    end
    return CompositeModel(
        objects...;
        applications=(
            ModelSpec(
                StabilizationSourceModel();
                name=:source,
                on=Many(scale=:Leaf),
            ),
            ModelSpec(
                StabilizationLaggedSumModel();
                name=:plant_sum,
                on=Many(scale=:Plant),
                inputs=(
                    :previous_signals => Many(
                        scale=:Leaf,
                        within=Subtree(),
                        application=:source,
                        var=:signal,
                    ),
                ),
            ),
        ),
        environment=(T=20.0, duration=Hour(1)),
    )
end

function stabilization_scoped_label_candidate_scene()
    return CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:plant_1; scale=:Plant, parent=:scene),
        Object(
            :plant_1_leaf;
            scale=:Leaf,
            parent=:plant_1,
            status=Status(supplied=0.0),
        ),
        Object(:plant_2; scale=:Plant, parent=:scene),
        Object(
            :plant_2_leaf;
            scale=:Leaf,
            parent=:plant_2,
            status=Status(supplied=0.0),
        );
        applications=(
            ModelSpec(
                StabilizationSourceModel();
                name=:plant_source,
                on=Many(scale=:Plant),
            ),
            ModelSpec(
                StabilizationConsumerModel();
                name=:leaf_consumer,
                on=Many(scale=:Leaf),
                inputs=(
                    :signal => One(
                        scale=(:Plant, :Axis),
                        within=SelfPlant(),
                        application=:plant_source,
                        var=:signal,
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )
end

function stabilization_relation_candidate_scene()
    return CompositeModel(
        Object(:plant; scale=:Plant),
        Object(
            :leaf_a;
            scale=:Leaf,
            name=:leaf_a,
            parent=:plant,
        );
        applications=(
            ModelSpec(
                StabilizationSourceModel();
                name=:leaf_source,
                on=Many(scale=:Leaf),
            ),
            ModelSpec(
                StabilizationSafeLaggedSumModel();
                name=:sibling_sum,
                on=One(name=:leaf_a),
                inputs=(
                    :previous_signals => Many(
                        Relation(:siblings);
                        scale=:Leaf,
                        application=:leaf_source,
                        var=:signal,
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )
end

function stabilization_nearest_ancestor_candidate_scene()
    return CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(:phytomer_a; scale=:Phytomer, parent=:plant),
        Object(
            :female_a;
            scale=:Female,
            parent=:phytomer_a,
            status=Status(supplied=0.0),
        );
        applications=(
            ModelSpec(
                StabilizationSourceModel();
                name=:ancestor_source,
                on=Many(scale=:Phytomer),
            ),
            ModelSpec(
                StabilizationConsumerModel();
                name=:ancestor_consumer,
                on=Many(scale=:Female),
                inputs=(
                    :signal => One(
                        scale=:Phytomer,
                        within=Ancestor(scale=:Phytomer),
                        application=:ancestor_source,
                        var=:signal,
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )
end

function stabilization_selector_candidate_refresh_allocations(nplants)
    model = stabilization_selector_candidate_scene(nplants)
    simulation = run!(model; outputs=:none)
    register_object!(
        model,
        Object(
            :zz_new_leaf;
            scale=:Leaf,
            name=:unique_new_leaf_1,
            parent=:plant_1,
        ),
    )
    return @allocated PlantSimEngine._refresh_simulation_runtime!(simulation)
end

@testset "lifecycle reverse selector candidates remain local" begin
    model = stabilization_selector_candidate_scene(64)
    simulation = run!(model; outputs=:none, performance=true)
    for index in (
        simulation.compiled.dynamic_input_binding_indices,
        simulation.compiled.dynamic_call_binding_indices,
    )
        @test isnothing(index.application_target_templates)
        @test isempty(index.template_label_values)
        @test isempty(index.scope_roots)
    end
    register_object!(
        model,
        Object(
            :zz_new_leaf;
            scale=:Leaf,
            name=:unique_new_leaf_1,
            parent=:plant_1,
        ),
    )
    continue!(simulation)
    counts = Advanced.runtime_performance(simulation).counts
    @test counts[:selector_application_candidates] == 1
    @test counts[:selector_input_binding_candidates] == 1
    @test get(counts, :selector_call_binding_candidates, 0) == 0
    @test counts[:lifecycle_application_target_template_cache_misses] == 1

    register_object!(
        model,
        Object(
            :zz_new_leaf_2;
            scale=:Leaf,
            name=:unique_new_leaf_2,
            parent=:plant_1,
        ),
    )
    continue!(simulation)
    @test Advanced.runtime_performance(simulation).counts[
        :lifecycle_application_target_template_cache_hits
    ] == 1
    @test Advanced.runtime_performance(simulation).counts[
        :lifecycle_application_target_template_cache_misses
    ] == 1

    reparented_model = stabilization_selector_candidate_scene(64)
    reparented_simulation = run!(
        reparented_model;
        outputs=:none,
        performance=true,
    )
    reparent_object!(
        reparented_model,
        :plant_1_leaf,
        :plant_2,
    )
    continue!(reparented_simulation)
    reparented_counts = Advanced.runtime_performance(reparented_simulation).counts
    @test reparented_counts[:selector_application_candidates] == 1
    @test reparented_counts[:selector_input_binding_candidates] == 2
    @test get(reparented_counts, :selector_call_binding_candidates, 0) == 0
    plant_bindings = Dict(
        row.consumer_id => row.source_ids
        for row in explain_bindings(reparented_model)
        if row.application_id == :plant_sum &&
           row.consumer_id in (:plant_1, :plant_2)
    )
    @test isempty(plant_bindings[:plant_1])
    @test plant_bindings[:plant_2] == [:plant_1_leaf, :plant_2_leaf]

    scoped_label_model = stabilization_scoped_label_candidate_scene()
    scoped_label_simulation = run!(
        scoped_label_model;
        outputs=:none,
        performance=true,
    )
    register_object!(
        scoped_label_model,
        Object(
            :zz_new_leaf;
            scale=:Leaf,
            parent=:plant_1,
            status=Status(supplied=0.0),
        ),
    )
    continue!(scoped_label_simulation)
    scoped_label_counts =
        Advanced.runtime_performance(scoped_label_simulation).counts
    @test scoped_label_counts[:selector_input_binding_candidates] == 0
    new_leaf_binding = only(
        row for row in explain_bindings(scoped_label_model)
        if row.application_id == :leaf_consumer &&
           row.consumer_id == :zz_new_leaf &&
           row.input == :signal
    )
    @test new_leaf_binding.source_ids == [:plant_1]

    relation_model = stabilization_relation_candidate_scene()
    relation_simulation = run!(
        relation_model;
        outputs=:none,
        performance=true,
    )
    register_object!(
        relation_model,
        Object(:leaf_b; scale=:Leaf, parent=:plant),
    )
    continue!(relation_simulation)
    relation_counts = Advanced.runtime_performance(relation_simulation).counts
    @test relation_counts[:selector_input_binding_candidates] == 1
    sibling_binding = only(
        row for row in explain_bindings(relation_model)
        if row.application_id == :sibling_sum &&
           row.consumer_id == :leaf_a &&
           row.input == :previous_signals
    )
    @test sibling_binding.source_ids == [:leaf_b]

    stabilization_selector_candidate_refresh_allocations(8)
    small_allocations = minimum(
        stabilization_selector_candidate_refresh_allocations(8)
        for _ in 1:2
    )
    large_allocations = minimum(
        stabilization_selector_candidate_refresh_allocations(2_048)
        for _ in 1:2
    )
    @test large_allocations <= small_allocations + 32_768
end

@testset "application target templates preserve instance scope" begin
    template = CompositeModelTemplate((
        ModelSpec(
            StabilizationSourceModel();
            name=:source,
            on=Many(scale=:Leaf),
        ),
    ))
    palm_1 = ObjectInstance(
        :palm_1,
        template;
        root=Object(:template_plant_1; scale=:Plant, parent=:scene),
        objects=(
            Object(
                :template_leaf_1a;
                scale=:Leaf,
                name=:unique_leaf_1a,
                parent=:template_plant_1,
            ),
            Object(
                :template_leaf_1b;
                scale=:Leaf,
                name=:unique_leaf_1b,
                parent=:template_plant_1,
            ),
        ),
    )
    palm_2 = ObjectInstance(
        :palm_2,
        template;
        root=Object(:template_plant_2; scale=:Plant, parent=:scene),
        objects=(
            Object(
                :template_leaf_2;
                scale=:Leaf,
                name=:unique_leaf_2,
                parent=:template_plant_2,
            ),
        ),
    )
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        palm_1,
        palm_2,
    )
    compiled = Advanced.refresh_bindings!(model)
    index = compiled.scenario_plan.application_target_candidates
    key_1a = PlantSimEngine._application_target_template_key(
        index,
        model,
        ObjectId(:template_leaf_1a),
    )
    key_1b = PlantSimEngine._application_target_template_key(
        index,
        model,
        ObjectId(:template_leaf_1b),
    )
    key_2 = PlantSimEngine._application_target_template_key(
        index,
        model,
        ObjectId(:template_leaf_2),
    )
    @test key_1a == key_1b
    @test key_1a != key_2
    @test index.template_label_values == Dict(:scale => Set([:Leaf]))

    target_template_1 = PlantSimEngine._application_target_template(
        model,
        compiled,
        ObjectId(:template_leaf_1a),
    )
    target_template_2 = PlantSimEngine._application_target_template(
        model,
        compiled,
        ObjectId(:template_leaf_2),
    )
    @test Tuple(
        compiled.applications[slot].id
        for slot in target_template_1.matched_slots
    ) == (:palm_1__source,)
    @test Tuple(
        compiled.applications[slot].id
        for slot in target_template_2.matched_slots
    ) == (:palm_2__source,)
end

@testset "nearest Ancestor bindings ignore descendant additions" begin
    model = stabilization_nearest_ancestor_candidate_scene()
    simulation = run!(model; outputs=:none, performance=true)

    register_object!(
        model,
        Object(:phytomer_z; scale=:Phytomer, parent=:phytomer_a),
    )
    continue!(simulation)

    @test Advanced.runtime_performance(simulation).counts[
        :selector_input_binding_candidates
    ] == 0
    existing_binding = only(
        row for row in explain_bindings(model)
        if row.application_id == :ancestor_consumer &&
           row.consumer_id == :female_a &&
           row.input == :signal
    )
    @test existing_binding.source_ids == [:phytomer_a]
    @test model_status(model, :female_a).observed == 2.0

    register_object!(
        model,
        Object(
            :female_z;
            scale=:Female,
            parent=:phytomer_z,
            status=Status(supplied=0.0),
        ),
    )
    continue!(simulation)
    new_binding = only(
        row for row in explain_bindings(model)
        if row.application_id == :ancestor_consumer &&
           row.consumer_id == :female_z &&
           row.input == :signal
    )
    @test new_binding.source_ids == [:phytomer_z]

    reparent_object!(model, :female_z, :phytomer_a)
    continue!(simulation)
    reparented_binding = only(
        row for row in explain_bindings(model)
        if row.application_id == :ancestor_consumer &&
           row.consumer_id == :female_z &&
           row.input == :signal
    )
    @test reparented_binding.source_ids == [:phytomer_a]
end

@testset "repeated applications require explicit identity" begin
    model = CompositeModel(
        Object(:leaf; scale=:Leaf);
        applications=(
            ModelSpec(StabilizationSourceModel(); on=One(scale=:Leaf)),
            ModelSpec(StabilizationSourceModel(); on=One(scale=:Leaf)),
        ),
    )

    @test_throws "unnamed applications for process `stabilization_source`" Advanced.compile_composite_model(model)

    named_scene = CompositeModel(
        Object(:leaf; scale=:Leaf);
        applications=(
            ModelSpec(StabilizationSourceModel(); name=:source_a, on=One(scale=:Leaf)),
            ModelSpec(StabilizationSourceModel(); name=:source_b, on=One(scale=:Leaf), output_routing=(signal=:stream_only,)),
        ),
    )
    @test getproperty.(explain_applications(named_scene), :application_id) ==
          [:source_a, :source_b]
    @test explain_schedule(named_scene) isa Vector
    @test explain_bindings(named_scene) isa Vector
    @test explain_calls(named_scene) isa Vector
    @test explain_writers(named_scene) isa Vector

    ambiguous_process_scene = CompositeModel(
        Object(:leaf; scale=:Leaf, status=Status(supplied=0.0));
        applications=(
            ModelSpec(StabilizationSourceModel(); name=:source_a, on=One(scale=:Leaf)),
            ModelSpec(StabilizationSourceModel(); name=:source_b, on=One(scale=:Leaf), output_routing=(signal=:stream_only,)),
            ModelSpec(StabilizationConsumerModel(); name=:consumer, on=One(scale=:Leaf), inputs=(:signal => One(within=Self(), application=:source))),
        ),
    )
    @test_throws "application `source`, but no matching source application was found" explain_bindings(
        ambiguous_process_scene,
    )

    ordered_writer_scene = CompositeModel(
        Object(:leaf; scale=:Leaf, status=Status(supplied=0.0));
        applications=(
            ModelSpec(StabilizationSourceModel(); name=:source_a, on=One(scale=:Leaf)),
            ModelSpec(StabilizationSourceModel(); name=:source_b, on=One(scale=:Leaf), updates=Updates(:signal; after=:source_a)),
            ModelSpec(StabilizationConsumerModel(); name=:consumer, on=One(scale=:Leaf), inputs=(PreviousTimeStep(:signal) => One(within=Self(), var=:signal),)),
        ),
    )
    ordered_binding = only(
        row for row in explain_bindings(ordered_writer_scene)
        if row.application_id == :consumer && row.input == :signal
    )
    ordered_input_plans =
        Advanced.refresh_bindings!(ordered_writer_scene).scenario_plan.input_plans
    ordered_plan = only(
        plan for plan in ordered_input_plans
        if plan.application_id == :consumer && plan.input == :signal
    )
    @test ordered_plan.potential_source_application_ids ==
          (:source_a, :source_b)
    @test ordered_binding.source_application_ids == [:source_b]
end

@testset "immutable application plans survive lifecycle target refresh" begin
    model = CompositeModel(
        Object(:plant; scale=:Plant);
        applications=(
            ModelSpec(
                StabilizationSourceModel();
                name=:leaf_source,
                on=Many(scale=:Leaf),
            ),
        ),
    )

    compiled = Advanced.refresh_bindings!(model)
    scenario_plan = compiled.scenario_plan
    application = only(compiled.applications)
    application_plan = application.plan
    application_schedule = scenario_plan.application_schedule

    @test !ismutabletype(typeof(scenario_plan))
    @test !ismutabletype(typeof(application_plan))
    @test !ismutabletype(typeof(application_schedule))
    @test !ismutabletype(typeof(only(application_schedule.entries)))
    @test ismutabletype(typeof(application))
    @test isconst(typeof(application), :plan)
    @test compiled.applications_by_id isa NamedTuple
    @test scenario_plan.call_owners isa NamedTuple
    @test scenario_plan.application_children isa NamedTuple
    @test scenario_plan.manual_application_ids == ()
    @test scenario_plan.application_order == (:leaf_source,)
    @test scenario_plan.ordered_application_plans == (application_plan,)
    @test only(application_schedule.entries).application_id == :leaf_source
    @test only(application_schedule.entries).kind == :always
    @test compiled.ordered_applications == (application,)
    @test fieldnames(typeof(application)) == (:plan, :target_ids)
    @test only(scenario_plan.applications) === application_plan
    @test scenario_plan.applications_by_id[:leaf_source] === application_plan
    @test application_plan.slot == 1
    @test isempty(application.target_ids)
    @test only(explain_applications(compiled)).application_slot == 1
    @test only(explain_applications(compiled)).current_target_count == 0

    register_object!(model, Object(:leaf; scale=:Leaf, parent=:plant))
    added = Advanced.refresh_bindings!(model)
    @test added.scenario_plan === scenario_plan
    @test added.scenario_plan.application_schedule === application_schedule
    @test only(added.applications).plan === application_plan
    @test only(added.applications).target_ids == ObjectId[ObjectId(:leaf)]
    @test only(explain_applications(added)).current_target_count == 1

    remove_object!(model, :leaf)
    removed = Advanced.refresh_bindings!(model)
    @test removed.scenario_plan === scenario_plan
    @test removed.scenario_plan.application_schedule === application_schedule
    @test only(removed.applications).plan === application_plan
    @test isempty(only(removed.applications).target_ids)
    @test only(explain_applications(removed)).current_target_count == 0
end

@testset "declared input plans are consumer independent" begin
    model = CompositeModel(
        Object(:plant; scale=:Plant);
        applications=(
            ModelSpec(
                StabilizationSourceModel();
                name=:leaf_source,
                on=Many(scale=:Leaf),
            ),
            ModelSpec(
                StabilizationConsumerModel();
                name=:leaf_consumer,
                on=Many(scale=:Leaf),
                inputs=(
                    :signal => One(
                        within=Self(),
                        application=:leaf_source,
                        var=:signal,
                    ),
                ),
            ),
        ),
    )

    compiled = Advanced.refresh_bindings!(model)
    scenario_plan = compiled.scenario_plan
    input_plan = only(scenario_plan.input_plans)
    @test input_plan.slot == 1
    @test input_plan.application_slot == 2
    @test input_plan.application_id == :leaf_consumer
    @test input_plan.input == :signal
    @test input_plan.origin == :model_spec
    @test input_plan.potential_source_application_ids == (:leaf_source,)
    @test !input_plan.breaks_same_step_cycle
    @test isempty(scenario_plan.input_plans_by_application.leaf_source)
    @test only(scenario_plan.input_plans_by_application.leaf_consumer) ===
          input_plan
    @test isempty(compiled.input_bindings)
    application_rows = Dict(
        row.application_id => row for row in explain_applications(compiled)
    )
    @test application_rows[:leaf_source].input_plan_count == 0
    @test application_rows[:leaf_consumer].input_plan_count == 1
    @test application_rows[:leaf_consumer].call_plan_count == 0
    @test application_rows[:leaf_consumer].current_target_count == 0

    register_object!(
        model,
        Object(
            :leaf;
            scale=:Leaf,
            parent=:plant,
            status=Status(supplied=2.0),
        ),
    )
    refreshed = Advanced.refresh_bindings!(model)
    binding = only(refreshed.input_bindings)
    @test refreshed.scenario_plan === scenario_plan
    @test only(refreshed.scenario_plan.input_plans) === input_plan
    @test fieldnames(typeof(binding)) == (
        :plan,
        :consumer_id,
        :source_ids,
        :source_application_ids,
        :policy,
        :carrier_hint,
        :carrier,
    )
    @test binding.plan === input_plan
    @test binding.application_id == :leaf_consumer
    @test binding.consumer_id == ObjectId(:leaf)
    @test binding.selector === input_plan.selector
    @test binding.source_ids == ObjectId[ObjectId(:leaf)]
    @test binding.source_application_ids == [:leaf_source]
    binding_row = only(explain_bindings(refreshed))
    @test binding_row.input_plan_slot == 1
    @test binding_row.application_slot == 2
    @test binding_row.potential_source_application_ids == (:leaf_source,)
    @test !binding_row.breaks_same_step_cycle
end

@testset "same-object inference is compiled before objects exist" begin
    model = CompositeModel(
        Object(:plant; scale=:Plant);
        applications=(
            ModelSpec(
                StabilizationSourceModel();
                name=:leaf_source,
                on=Many(scale=:Leaf),
            ),
            ModelSpec(
                StabilizationConsumerModel();
                name=:leaf_consumer,
                on=Many(scale=:Leaf),
            ),
        ),
    )

    compiled = Advanced.refresh_bindings!(model)
    inferred_plan = only(compiled.scenario_plan.input_plans)
    @test inferred_plan.origin == :inferred_same_object
    @test inferred_plan.application_id == :leaf_consumer
    @test inferred_plan.application == :leaf_source
    @test inferred_plan.input == :signal
    @test inferred_plan.potential_source_application_ids == (:leaf_source,)
    @test !inferred_plan.breaks_same_step_cycle
    @test isempty(compiled.input_bindings)

    register_object!(
        model,
        Object(
            :leaf;
            scale=:Leaf,
            parent=:plant,
            status=Status(supplied=2.0),
        ),
    )
    refreshed = Advanced.refresh_bindings!(model)
    binding = only(refreshed.input_bindings)
    @test binding.plan === inferred_plan
    @test binding.origin == :inferred_same_object
    @test binding.consumer_id == ObjectId(:leaf)
    @test binding.source_ids == ObjectId[ObjectId(:leaf)]
    @test binding.source_application_ids == [:leaf_source]
end

@testset "invalid reparenting is atomic" begin
    model = CompositeModel(
        Object(:plant; scale=:Plant),
        Object(:leaf; scale=:Leaf, parent=:plant),
    )

    @test_throws "below its descendant" reparent_object!(model, :plant, :leaf)
    @test only(resolve_object_ids(model, One(Relation(:parent)); context=:leaf)) ==
          ObjectId(:plant)
    @test resolve_object_ids(model, Many(Relation(:children)); context=:plant) ==
          [ObjectId(:leaf)]

    @test_throws "to itself" reparent_object!(model, :plant, :plant)
    @test isnothing(only(model_objects(model; scale=:Plant)).parent)
end

@testset "instance roots are immutable lifecycle anchors" begin
    template = CompositeModelTemplate((
        ModelSpec(StabilizationSourceModel(); name=:source, on=Many(scale=:Leaf)),
    ))
    instance = ObjectInstance(
        :plant_instance,
        template;
        root=Object(:plant; scale=:Plant, parent=:branch),
        objects=(Object(:leaf; scale=:Leaf, parent=:plant),),
    )
    model = CompositeModel(
        Object(:world; scale=:Scene),
        Object(:outside; scale=:Branch),
        Object(:branch; scale=:Branch, parent=:world),
        instance,
    )

    @test_throws "immutable ObjectInstance root" remove_object!(model, :plant)
    @test_throws "immutable ObjectInstance root" remove_object!(model, :branch)
    @test object_ids(model) == ObjectId.([:branch, :leaf, :outside, :plant, :world])
    @test only(model_objects(model; name=:plant_instance)).id == ObjectId(:plant)

    @test_throws "immutable ObjectInstance root" reparent_object!(model, :plant, :outside)
    @test_throws "immutable ObjectInstance root" reparent_object!(model, :branch, :outside)
    @test only(resolve_object_ids(model, One(Relation(:parent)); context=:plant)) ==
          ObjectId(:branch)
    @test only(resolve_object_ids(model, One(Relation(:parent)); context=:branch)) ==
          ObjectId(:world)

    reparent_object!(model, :leaf, :outside)
    @test only(resolve_object_ids(model, One(Relation(:parent)); context=:leaf)) ==
          ObjectId(:outside)
    reparent_object!(model, :leaf, :plant)
    removed = remove_object!(model, :leaf)
    @test removed.id == ObjectId(:leaf)
    @test isempty(resolve_object_ids(model, Many(scale=:Leaf)))
end

@testset "continuation refreshes lifecycle targets and preserves history" begin
    model = CompositeModel(
        Object(:leaf_1; scale=:Leaf);
        applications=(
            ModelSpec(StabilizationSourceModel(); name=:source, on=Many(scale=:Leaf)),
        ),
    )
    request = OutputRequest(
        Many(scale=:Leaf),
        :signal;
        name=:leaf_signal,
        application=:source,
    )
    simulation = run!(model; outputs=request)

    register_object!(model, Object(:leaf_2; scale=:Leaf))
    continue!(simulation)
    remove_object!(model, :leaf_1)
    continue!(simulation)

    rows = collect_outputs(simulation, :leaf_signal; sink=nothing)
    leaf_1_rows = filter(row -> row.object_id == :leaf_1, rows)
    leaf_2_rows = filter(row -> row.object_id == :leaf_2, rows)
    @test getproperty.(leaf_1_rows, :timestep) == [1, 2]
    @test getproperty.(leaf_1_rows, :value) == [1.0, 2.0]
    @test getproperty.(leaf_2_rows, :timestep) == [2, 3]
    @test getproperty.(leaf_2_rows, :value) == [1.0, 2.0]
    @test all(row -> row.scale == :Leaf, rows)
end

@testset "output retention allocation boundary" begin
    model = CompositeModel(
        (Object(Symbol(:leaf_, i); scale=:Leaf) for i in 1:100)...;
        applications=(
            ModelSpec(StabilizationSourceModel(); name=:source, on=Many(scale=:Leaf)),
        ),
    )

    run!(model; steps=2, outputs=:none)
    run!(model; steps=2, outputs=:all)
    none_allocations = @allocated run!(model; steps=10, outputs=:none)
    all_allocations = @allocated run!(model; steps=10, outputs=:all)
    @test none_allocations < all_allocations
end

@testset "opt-in runtime performance counters" begin
    disabled_model = CompositeModel(StabilizationSourceModel())
    disabled_simulation = run!(disabled_model; steps=2)
    @test isnothing(Advanced.runtime_performance(disabled_simulation))
    @test isempty(Diagnostics.explain_runtime_performance(disabled_simulation))

    model = CompositeModel(
        Object(:leaf_1; scale=:Leaf);
        applications=(
            ModelSpec(StabilizationSourceModel(); name=:source, on=Many(scale=:Leaf)),
        ),
    )
    simulation = run!(
        model;
        steps=3,
        outputs=:all,
        performance=true,
    )
    performance = Advanced.runtime_performance(simulation)

    @test performance.counts[:steps_executed] == 3
    @test performance.counts[:application_groups_considered] == 3
    @test performance.counts[:application_groups_visited] == 3
    @test performance.counts[:execution_batches_visited] == 3
    @test performance.counts[:execution_targets_visited] == 3
    @test performance.counts[:runtime_dirty_checks] == 3
    @test performance.counts[:initial_application_plans_compiled] == 1
    @test performance.counts[:initial_input_plans_compiled] == 0
    @test performance.counts[:initial_call_plans_compiled] == 0
    @test performance.counts[:initial_status_views_constructed] == 1
    @test performance.counts[:initial_input_bindings_constructed] == 0
    @test performance.counts[:initial_call_bindings_constructed] == 0
    @test performance.counts[:initial_environment_bindings_constructed] == 1
    @test performance.counts[:initial_execution_targets_constructed] == 1
    @test performance.counts[:initial_execution_batches_constructed] == 1
    @test !haskey(performance.counts, :output_request_target_refreshes)
    @test !haskey(performance.counts, :output_request_selector_resolutions)
    @test performance.elapsed_seconds[:step_execution] >= 0.0
    @test performance.elapsed_seconds[:initial_composite_compile] >= 0.0
    @test performance.elapsed_seconds[:initial_binding_compile] >= 0.0
    @test performance.elapsed_seconds[:application_target_compile] >= 0.0
    @test performance.elapsed_seconds[:scenario_plan_compile] >= 0.0
    @test performance.elapsed_seconds[:call_binding_compile] >= 0.0
    @test performance.elapsed_seconds[:input_binding_compile] >= 0.0
    @test !haskey(
        performance.elapsed_seconds,
        :application_order_compile,
    )
    @test performance.elapsed_seconds[:status_view_compile] >= 0.0
    @test performance.elapsed_seconds[:initial_execution_plan_compile] >= 0.0
    @test performance.elapsed_seconds[
        :initial_execution_plan_and_model_bundle_compile
    ] >= 0.0
    @test performance.elapsed_seconds[:temporal_input_materialization] >= 0.0
    @test performance.elapsed_seconds[:environment_sampling] >= 0.0
    @test performance.elapsed_seconds[:scientific_kernel_execution] >= 0.0
    @test performance.elapsed_seconds[:output_publication] >= 0.0
    @test !haskey(
        performance.elapsed_seconds,
        :output_request_target_refresh,
    )
    @test simulation.runtime_revision == model.runtime_revision
    phase_rows = Diagnostics.explain_runtime_performance(simulation)
    @test only(
        row for row in phase_rows
        if row.metric == :scenario_plan_compile
    ).phase == :immutable_plan_compilation
    @test only(
        row for row in phase_rows
        if row.metric == :initial_execution_targets_constructed
    ).phase == :object_target_instantiation
    @test only(
        row for row in phase_rows
        if row.metric == :steps_executed
    ).phase == :steady_state_execution

    original_view =
        simulation.compiled.status_views_by_target[(:source, ObjectId(:leaf_1))]
    original_status = only(model_objects(model; scale=:Leaf)).status
    @test original_view.status === original_status
    @test original_view.canonical_status === original_status
    @test isempty(original_view.temporal_inputs)
    @test isempty(original_view.private_outputs)
    previous_runtime_revision = model.runtime_revision
    register_object!(model, Object(:leaf_2; scale=:Leaf))
    @test model.runtime_revision == previous_runtime_revision + 1
    continue!(simulation)
    @test simulation.runtime_revision == model.runtime_revision
    refreshed = Advanced.runtime_performance(simulation)
    @test refreshed.counts[:steps_executed] == 4
    @test refreshed.counts[:binding_refreshes] == 1
    @test refreshed.counts[:dirty_binding_objects] == 1
    @test refreshed.counts[:lifecycle_barriers] == 1
    @test refreshed.counts[:lifecycle_added_objects] == 1
    @test refreshed.counts[:lifecycle_environment_dirty_objects] == 1
    @test refreshed.counts[:status_views_constructed] == 1
    @test refreshed.counts[:input_binding_targets_replaced] == 0
    @test refreshed.counts[:call_binding_targets_replaced] == 0
    @test refreshed.counts[:environment_bindings_replaced] == 1
    @test refreshed.counts[:output_retention_reuses] == 1
    @test !haskey(refreshed.counts, :output_retention_compiles)
    @test refreshed.counts[:execution_plan_compiles] == 1
    @test refreshed.counts[:execution_targets_constructed] == 1
    @test refreshed.counts[:execution_batches_constructed] == 0
    @test refreshed.counts[:execution_groups_updated_in_place] == 1
    @test refreshed.elapsed_seconds[:application_target_refresh] >= 0.0
    @test refreshed.elapsed_seconds[:call_binding_refresh] >= 0.0
    @test refreshed.elapsed_seconds[:input_binding_refresh] >= 0.0
    @test !haskey(
        refreshed.elapsed_seconds,
        :application_order_refresh,
    )
    @test refreshed.elapsed_seconds[:status_view_refresh] >= 0.0
    @test simulation.compiled.status_views_by_target[
        (:source, ObjectId(:leaf_1))
    ] === original_view
    refreshed_phase_rows = Diagnostics.explain_runtime_performance(simulation)
    @test only(
        row for row in refreshed_phase_rows
        if row.metric == :lifecycle_added_objects
    ).phase == :lifecycle_buffer_update
    @test only(
        row for row in refreshed_phase_rows
        if row.metric == :application_target_refresh
    ).phase == :lifecycle_buffer_update

    collect_outputs(simulation; sink=nothing)
    collected = Advanced.runtime_performance(simulation)
    @test collected.counts[:output_collections] == 1
    @test collected.elapsed_seconds[:output_collection] >= 0.0
    collected_phase_rows = Diagnostics.explain_runtime_performance(simulation)
    @test only(
        row for row in collected_phase_rows
        if row.metric == :output_collections
    ).phase == :output_collection
end

@testset "incremental lifecycle preserves temporal state" begin
    model = CompositeModel(
        Object(:plant; scale=:Plant),
        Object(:leaf_1; scale=:Leaf, parent=:plant);
        applications=(
            ModelSpec(StabilizationSourceModel(); name=:source, on=Many(scale=:Leaf)),
            ModelSpec(StabilizationLaggedSumModel(); name=:lagged_sum, on=One(scale=:Plant), inputs=(PreviousTimeStep(:previous_signals) => Many(
                        scale=:Leaf,
                        within=Subtree(),
                        application=:source,
                        var=:signal,
                    ),)),
        ),
    )
    simulation = run!(model; performance=true)
    plant_status = only(model_objects(model; scale=:Plant)).status
    @test plant_status.lagged_total == 0.0

    original_leaf_view =
        simulation.compiled.status_views_by_target[(:source, ObjectId(:leaf_1))]
    original_plant_view =
        simulation.compiled.status_views_by_target[(:lagged_sum, ObjectId(:plant))]
    original_temporal_input = only(original_plant_view.temporal_inputs)
    original_temporal_storage = original_temporal_input.reference[]
    original_temporal_reference = only(parent(original_temporal_storage))
    original_lagged_target = only(
        target
        for batch in simulation.execution_plan.batches
        if batch.application.id == :lagged_sum
        for target in batch.targets
    )
    original_runtime_temporal_input = only(original_lagged_target.input_bindings)
    original_source_stream = only(
        original_runtime_temporal_input.source_streams,
    )
    @test collect(original_temporal_input.reference[]) == [0.0]

    register_object!(
        model,
        Object(:leaf_2; scale=:Leaf, parent=:plant),
    )
    @test ObjectId(:leaf_2) ∉
          simulation.compiled.applications_by_id.source.target_ids
    pending_delta = Advanced.lifecycle_delta(model)
    @test pending_delta.structural_kind == :addition
    @test only(pending_delta.added).id == ObjectId(:leaf_2)
    continue!(simulation)

    refreshed_leaf_view =
        simulation.compiled.status_views_by_target[(:source, ObjectId(:leaf_1))]
    refreshed_plant_view =
        simulation.compiled.status_views_by_target[(:lagged_sum, ObjectId(:plant))]
    refreshed_temporal_input = only(refreshed_plant_view.temporal_inputs)
    @test refreshed_leaf_view === original_leaf_view
    @test refreshed_plant_view === original_plant_view
    @test refreshed_temporal_input === original_temporal_input
    @test refreshed_temporal_input.reference[] === original_temporal_storage
    @test first(parent(refreshed_temporal_input.reference[])) ===
          original_temporal_reference
    @test refreshed_temporal_input.binding.source_ids ==
          ObjectId.([:leaf_1, :leaf_2])
    refreshed_lagged_target = only(
        target
        for batch in simulation.execution_plan.batches
        if batch.application.id == :lagged_sum
        for target in batch.targets
    )
    refreshed_runtime_temporal_input =
        only(refreshed_lagged_target.input_bindings)
    @test refreshed_lagged_target === original_lagged_target
    @test refreshed_runtime_temporal_input ===
          original_runtime_temporal_input
    @test first(refreshed_runtime_temporal_input.source_streams) ===
          original_source_stream
    @test length(refreshed_runtime_temporal_input.source_streams) == 2
    @test plant_status.lagged_total == 1.0

    continue!(simulation)
    @test plant_status.lagged_total == 3.0
    performance = Advanced.runtime_performance(simulation)
    @test performance.counts[:status_views_constructed] == 1
    @test performance.counts[:lifecycle_barriers] == 1
    @test performance.counts[:lifecycle_added_objects] == 1
    @test performance.counts[:lifecycle_environment_dirty_objects] == 1
    @test performance.counts[:output_retention_reuses] == 1
    @test !haskey(performance.counts, :output_retention_compiles)
end

@testset "incremental Many source applications use the complete source set" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:produced,
            parent=:plant,
        );
        applications=(
            ModelSpec(
                StabilizationSourceModel();
                name=:source,
                on=Many(scale=:Leaf, kind=:produced),
            ),
            ModelSpec(
                StabilizationSafeLaggedSumModel();
                name=:sum,
                on=One(scale=:Plant),
                inputs=(
                    :previous_signals => Many(
                        scale=:Leaf,
                        within=Subtree(),
                        application=:source,
                        var=:signal,
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )
    simulation = run!(model; outputs=:none)
    plant = only(model_objects(model; scale=:Plant)).status
    binding = only(
        simulation.compiled.input_bindings_by_target[
            (:sum, ObjectId(:plant))
        ],
    )
    carrier = binding.carrier
    @test plant.lagged_total == 1.0
    @test binding.source_application_ids == [:source]

    register_object!(
        model,
        Object(
            :leaf_2;
            scale=:Leaf,
            kind=:supplied,
            parent=:plant,
            status=Status(signal=10.0),
        ),
    )
    continue!(simulation)

    refreshed_binding = only(
        simulation.compiled.input_bindings_by_target[
            (:sum, ObjectId(:plant))
        ],
    )
    @test refreshed_binding === binding
    @test refreshed_binding.carrier === carrier
    @test refreshed_binding.source_ids == ObjectId.([:leaf_1, :leaf_2])
    @test refreshed_binding.source_application_ids == [:source]
    @test plant.lagged_total == 12.0
end

@testset "new consumers reuse an updated plant-wide Many carrier" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(:leaf_1; scale=:Leaf, parent=:plant),
        Object(:axis_1; scale=:Axis, parent=:plant);
        applications=(
            ModelSpec(
                StabilizationSourceModel();
                name=:source,
                on=Many(scale=:Leaf),
            ),
            ModelSpec(
                StabilizationSafeLaggedSumModel();
                name=:plant_wide_sum,
                on=Many(scale=:Axis),
                inputs=(
                    :previous_signals => Many(
                        scale=:Leaf,
                        within=SelfPlant(),
                        application=:source,
                        var=:signal,
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )
    simulation = run!(model; outputs=:none, performance=true)
    original_binding = only(
        simulation.compiled.input_bindings_by_target[
            (:plant_wide_sum, ObjectId(:axis_1))
        ],
    )

    register_object!(model, Object(:leaf_2; scale=:Leaf, parent=:plant))
    register_object!(model, Object(:axis_2; scale=:Axis, parent=:plant))
    continue!(simulation)

    refreshed_binding = only(
        simulation.compiled.input_bindings_by_target[
            (:plant_wide_sum, ObjectId(:axis_1))
        ],
    )
    new_binding = only(
        simulation.compiled.input_bindings_by_target[
            (:plant_wide_sum, ObjectId(:axis_2))
        ],
    )
    @test refreshed_binding === original_binding
    @test new_binding.source_ids === original_binding.source_ids
    @test new_binding.source_application_ids ===
          original_binding.source_application_ids
    @test new_binding.carrier === original_binding.carrier
    @test new_binding.source_ids == ObjectId.([:leaf_1, :leaf_2])
    axis_2_status =
        PlantSimEngine._model_object(model, ObjectId(:axis_2)).status
    @test propertynames(axis_2_status) ==
          (:lagged_total, :previous_signals)
    @test axis_2_status.previous_signals === new_binding.carrier
    @test :previous_signals ∉ get(
        model.input_default_status_variables,
        ObjectId(:axis_2),
        Set{Symbol}(),
    )
    @test PlantSimEngine._model_object(model, ObjectId(:axis_1)).status !==
          axis_2_status
    performance = Advanced.runtime_performance(simulation)
    @test performance.counts[:many_input_binding_precompile_reuses] == 1
    @test performance.counts[:input_default_status_rewrites_avoided] == 1
end

function stabilization_shared_many_consumer_scene(
    axis_count;
    initial_leaf_id=:leaf_a,
)
    objects = Object[
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(initial_leaf_id; scale=:Leaf, parent=:plant),
    ]
    append!(
        objects,
        (
            Object(Symbol(:axis_, index); scale=:Axis, parent=:plant)
            for index in 1:axis_count
        ),
    )
    return CompositeModel(
        objects...;
        applications=(
            ModelSpec(
                StabilizationSourceModel();
                name=:shared_many_source,
                on=Many(scale=:Leaf),
            ),
            ModelSpec(
                StabilizationSafeLaggedSumModel();
                name=:shared_many_consumer,
                on=Many(scale=:Axis),
                inputs=(
                    :previous_signals => Many(
                        scale=:Leaf,
                        within=SelfPlant(),
                        application=:shared_many_source,
                        var=:signal,
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )
end

function stabilization_shared_many_bindings(simulation, axis_count)
    return PlantSimEngine.CompiledModelInputBinding[
        only(
            simulation.compiled.input_bindings_by_target[
                (:shared_many_consumer, ObjectId(Symbol(:axis_, index)))
            ],
        ) for index in 1:axis_count
    ]
end

@testset "shared same-rate Many bindings use one lifecycle candidate" begin
    axis_count = 32
    model = stabilization_shared_many_consumer_scene(axis_count)
    simulation = run!(model; outputs=:none, performance=true)
    original_bindings =
        stabilization_shared_many_bindings(simulation, axis_count)
    original = first(original_bindings)
    original_source_ids = original.source_ids
    original_source_application_ids = original.source_application_ids
    original_carrier = original.carrier
    original_references = parent(original.carrier)
    @test all(
        binding ->
            binding.source_ids === original.source_ids &&
            binding.source_application_ids ===
            original.source_application_ids &&
            binding.carrier === original.carrier,
        original_bindings,
    )

    register_object!(
        model,
        Object(:leaf_z; scale=:Leaf, parent=:plant),
    )
    continue!(simulation)

    refreshed_bindings =
        stabilization_shared_many_bindings(simulation, axis_count)
    refreshed = first(refreshed_bindings)
    @test Advanced.runtime_performance(simulation).counts[
        :selector_input_binding_candidates
    ] == 1
    @test Advanced.runtime_performance(simulation).counts[
        :lifecycle_many_input_binding_direct_appends
    ] == 1
    @test Advanced.runtime_performance(simulation).counts[
        :lifecycle_many_input_binding_direct_sources_appended
    ] == 1
    direct_append_row = only(
        row for row in Diagnostics.explain_runtime_performance(simulation)
        if row.metric == :lifecycle_many_input_binding_direct_appends
    )
    @test direct_append_row.phase == :lifecycle_buffer_update
    @test refreshed === original
    @test refreshed.source_ids === original_source_ids
    @test refreshed.source_application_ids ===
          original_source_application_ids
    @test refreshed.source_ids == ObjectId.([:leaf_a, :leaf_z])
    @test refreshed.carrier === original_carrier
    @test parent(refreshed.carrier) === original_references
    @test parent(refreshed.carrier)[end] ===
          PlantSimEngine.refvalue(model_status(model, :leaf_z), :signal)
    @test all(
        binding ->
            binding.source_ids === refreshed.source_ids &&
            binding.source_application_ids ===
            refreshed.source_application_ids &&
            binding.carrier === refreshed.carrier,
        refreshed_bindings,
    )
    @test all(
        model_object(model, Symbol(:axis_, index)).status.lagged_total == 3.0
        for index in 1:axis_count
    )
    model_status(model, :leaf_z).signal = 11.0
    @test refreshed.carrier[end] == 11.0
end

@testset "shared Many fallback rewires every consumer and rebuilds its index" begin
    axis_count = 2
    model = stabilization_shared_many_consumer_scene(
        axis_count;
        initial_leaf_id=:leaf_z,
    )
    simulation = run!(model; outputs=:none, performance=true)
    initial_bindings =
        stabilization_shared_many_bindings(simulation, axis_count)
    initial_carrier = first(initial_bindings).carrier

    # This ID sorts before the existing source, forcing the general rebuild
    # path instead of the monotonic in-place append.
    register_object!(
        model,
        Object(:leaf_a; scale=:Leaf, parent=:plant),
    )
    continue!(simulation)

    rebuilt_bindings =
        stabilization_shared_many_bindings(simulation, axis_count)
    rebuilt = first(rebuilt_bindings)
    @test Advanced.runtime_performance(simulation).counts[
        :selector_input_binding_candidates
    ] == 1
    @test get(
        Advanced.runtime_performance(simulation).counts,
        :lifecycle_many_input_binding_direct_appends,
        0,
    ) == 0
    @test rebuilt.carrier !== initial_carrier
    @test rebuilt.source_ids == ObjectId.([:leaf_a, :leaf_z])
    @test all(binding -> binding.carrier === rebuilt.carrier, rebuilt_bindings)
    @test all(
        model_object(model, Symbol(:axis_, index)).status.previous_signals ===
        rebuilt.carrier for index in 1:axis_count
    )

    # Forced structural keys remain exact: both consumer bindings are selected
    # for source removal even though their dynamic addition index is compact.
    remove_object!(model, :leaf_a)
    continue!(simulation)
    register_object!(
        model,
        Object(:leaf_zz; scale=:Leaf, parent=:plant),
    )
    continue!(simulation)

    final_bindings =
        stabilization_shared_many_bindings(simulation, axis_count)
    final = first(final_bindings)
    @test Advanced.runtime_performance(simulation).counts[
        :selector_input_binding_candidates
    ] == 4
    @test final.source_ids == ObjectId.([:leaf_z, :leaf_zz])
    @test all(binding -> binding.carrier === final.carrier, final_bindings)
end

@testset "shared ObjectRefVector carriers keep one lifecycle candidate" begin
    axis_count = 4
    objects = Object[
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(
            :leaf_a;
            scale=:Leaf,
            parent=:plant,
            status=Status(signal=1.0),
        ),
        Object(
            :leaf_b;
            scale=:Leaf,
            parent=:plant,
            status=Status(signal=2),
        ),
    ]
    append!(
        objects,
        (
            Object(Symbol(:axis_, index); scale=:Axis, parent=:plant)
            for index in 1:axis_count
        ),
    )
    model = CompositeModel(
        objects...;
        applications=(
            ModelSpec(
                StabilizationMixedManySumModel();
                name=:mixed_many_consumer,
                on=Many(scale=:Axis),
                inputs=(
                    :previous_signals => Many(
                        scale=:Leaf,
                        within=SelfPlant(),
                        var=:signal,
                        from_status=true,
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )
    simulation = run!(model; outputs=:none, performance=true)
    bindings = PlantSimEngine.CompiledModelInputBinding[
        only(
            simulation.compiled.input_bindings_by_target[
                (:mixed_many_consumer, ObjectId(Symbol(:axis_, index)))
            ],
        ) for index in 1:axis_count
    ]
    carrier = first(bindings).carrier
    @test carrier isa PlantSimEngine.ObjectRefVector
    @test all(binding -> binding.carrier === carrier, bindings)

    register_object!(
        model,
        Object(
            :leaf_z;
            scale=:Leaf,
            parent=:plant,
            status=Status(signal=3 // 1),
        ),
    )
    continue!(simulation)

    refreshed = PlantSimEngine.CompiledModelInputBinding[
        only(
            simulation.compiled.input_bindings_by_target[
                (:mixed_many_consumer, ObjectId(Symbol(:axis_, index)))
            ],
        ) for index in 1:axis_count
    ]
    @test Advanced.runtime_performance(simulation).counts[
        :selector_input_binding_candidates
    ] == 1
    @test all(binding -> binding.carrier === carrier, refreshed)
    @test collect(carrier) == [1.0, 2, 3 // 1]
end

@testset "temporal Many bindings keep per-consumer lifecycle candidates" begin
    axis_count = 2
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(:leaf_a; scale=:Leaf, parent=:plant),
        Object(:axis_1; scale=:Axis, parent=:plant),
        Object(:axis_2; scale=:Axis, parent=:plant);
        applications=(
            ModelSpec(
                StabilizationSourceModel();
                name=:temporal_many_source,
                on=Many(scale=:Leaf),
            ),
            ModelSpec(
                StabilizationSafeLaggedSumModel();
                name=:temporal_many_consumer,
                on=Many(scale=:Axis),
                inputs=(
                    PreviousTimeStep(:previous_signals) => Many(
                        scale=:Leaf,
                        within=SelfPlant(),
                        application=:temporal_many_source,
                        var=:signal,
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )
    simulation = run!(
        model;
        steps=2,
        outputs=:none,
        performance=true,
    )

    register_object!(
        model,
        Object(:leaf_z; scale=:Leaf, parent=:plant),
    )
    continue!(simulation)

    @test Advanced.runtime_performance(simulation).counts[
        :selector_input_binding_candidates
    ] == axis_count
    first_view = simulation.compiled.status_views_by_target[
        (:temporal_many_consumer, ObjectId(:axis_1))
    ]
    second_view = simulation.compiled.status_views_by_target[
        (:temporal_many_consumer, ObjectId(:axis_2))
    ]
    @test length(first_view.status.previous_signals) == 2
    @test length(second_view.status.previous_signals) == 2
    @test first_view.status.previous_signals !==
          second_view.status.previous_signals

    remove_object!(model, :leaf_z)
    continue!(simulation)
    first_view_after_removal = simulation.compiled.status_views_by_target[
        (:temporal_many_consumer, ObjectId(:axis_1))
    ]
    second_view_after_removal = simulation.compiled.status_views_by_target[
        (:temporal_many_consumer, ObjectId(:axis_2))
    ]
    @test length(first_view_after_removal.status.previous_signals) == 1
    @test length(second_view_after_removal.status.previous_signals) == 1
    @test first_view_after_removal.status.previous_signals !==
          second_view_after_removal.status.previous_signals
end

@testset "incremental execution plan reuses unaffected groups" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:leaf_1; scale=:Leaf, parent=:scene);
        applications=(
            ModelSpec(StabilizationSourceModel(); name=:leaf_source, on=Many(scale=:Leaf)),
            ModelSpec(StabilizationSourceModel(); name=:scene_source, on=One(scale=:Scene)),
        ),
    )
    simulation = run!(model; outputs=:all, performance=true)
    original_groups = simulation.execution_plan.groups
    original_batches = simulation.execution_plan.batches
    original_groups_by_application_slot =
        simulation.execution_plan.groups_by_application_slot
    original_schedule = simulation.execution_plan.schedule
    original_leaf_group = only(
        group for group in original_groups
        if group.application.id == :leaf_source
    )
    original_leaf_batch = only(original_leaf_group.batches)
    original_leaf_target = only(original_leaf_batch.targets)
    original_leaf_context = original_leaf_target.context
    @test original_leaf_context isa PlantSimEngine.RunContext
    original_scene_group = only(
        group for group in original_groups
        if group.application.id == :scene_source
    )
    original_scene_target = only(only(original_scene_group.batches).targets)

    register_object!(
        model,
        Object(:leaf_2; scale=:Leaf, parent=:scene),
    )
    continue!(simulation)

    refreshed_scene_group = only(
        group for group in simulation.execution_plan.groups
        if group.application.id == :scene_source
    )
    refreshed_leaf_group = only(
        group for group in simulation.execution_plan.groups
        if group.application.id == :leaf_source
    )
    refreshed_scene_target = only(only(refreshed_scene_group.batches).targets)
    performance = Advanced.runtime_performance(simulation)
    @test simulation.execution_plan.groups === original_groups
    @test simulation.execution_plan.batches === original_batches
    @test simulation.execution_plan.groups_by_application_slot ===
          original_groups_by_application_slot
    @test simulation.execution_plan.schedule === original_schedule
    @test refreshed_leaf_group === original_leaf_group
    @test only(refreshed_leaf_group.batches) === original_leaf_batch
    @test first(original_leaf_batch.targets) === original_leaf_target
    @test first(original_leaf_batch.targets).context === original_leaf_context
    @test [target.object_id for target in original_leaf_batch.targets] ==
          ObjectId.([:leaf_1, :leaf_2])
    @test original_leaf_batch.context_state.compiled === simulation.compiled
    @test original_leaf_batch.context_state.environment_bindings ===
          simulation.environment_bindings
    @test all(original_leaf_batch.targets) do target
        target.context.compiled === simulation.compiled &&
            target.context.environment_bindings ===
            simulation.environment_bindings &&
            target.context.time == current_step(simulation)
    end
    @test refreshed_scene_group === original_scene_group
    @test refreshed_scene_target === original_scene_target
    @test performance.counts[:execution_groups_reused] == 1
    @test performance.counts[:execution_targets_constructed] == 1
    @test performance.counts[:execution_batches_constructed] == 0
    @test performance.counts[:execution_groups_updated_in_place] == 1

    current_compiled = simulation.compiled
    current_environment_bindings = simulation.environment_bindings
    continue!(simulation)
    @test original_leaf_batch.context_state.compiled === current_compiled
    @test original_leaf_batch.context_state.environment_bindings ===
          current_environment_bindings
    @test all(
        target -> target.context.time == current_step(simulation),
        original_leaf_batch.targets,
    )

    float32_time = Float32(current_step(simulation) + 1)
    @test isnothing(PlantSimEngine._synchronize_model_execution_batch_contexts!(
        original_leaf_batch,
        simulation.compiled,
        simulation.environment_bindings,
        simulation.temporal_streams,
        simulation.output_retention,
        float32_time,
        simulation.constants,
    ))
    float32_target = first(original_leaf_batch.targets)
    @test PlantSimEngine._run_model_execution_target!(
        simulation.compiled,
        simulation.environment_bindings,
        original_leaf_batch.application,
        float32_target,
        float32_time,
        simulation.constants,
        simulation.temporal_streams,
        simulation.output_retention,
        nothing,
        false,
    ) === float32_target.status
    @test float32_target.context.time == Float64(float32_time)
end

@testset "execution plan addition falls back when a group is created" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene);
        applications=(
            ModelSpec(
                StabilizationSourceModel();
                name=:leaf_source,
                on=Many(scale=:Leaf),
            ),
            ModelSpec(
                StabilizationSourceModel();
                name=:scene_source,
                on=One(scale=:Scene),
            ),
        ),
    )
    simulation = run!(model; outputs=:none)
    original_groups = simulation.execution_plan.groups
    original_batches = simulation.execution_plan.batches

    register_object!(
        model,
        Object(:leaf_1; scale=:Leaf, parent=:scene),
    )
    continue!(simulation)

    @test simulation.execution_plan.groups !== original_groups
    @test simulation.execution_plan.batches !== original_batches
    leaf_group = only(
        group for group in simulation.execution_plan.groups
        if group.application.id == :leaf_source
    )
    @test only(only(leaf_group.batches).targets).object_id ==
          ObjectId(:leaf_1)
    @test model_object(model, :leaf_1).status.signal == 1.0
end

@testset "execution plan pure-addition staging is transactional" begin
    context_models = PlantSimEngine.ObjectModelOverrides(
        StabilizationContextModel(),
        Dict(
            ObjectId(:leaf_z) => StabilizationAlternativeContextModel(),
        ),
    )
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:leaf_a; scale=:Leaf, parent=:scene),
        Object(:leaf_z; scale=:Leaf, parent=:scene);
        applications=(
            ModelSpec(
                StabilizationSourceModel();
                name=:leaf_source,
                on=Many(scale=:Leaf),
            ),
            ModelSpec(
                context_models;
                name=:leaf_context,
                on=Many(scale=:Leaf),
            ),
        ),
    )
    simulation = run!(model; outputs=:none, performance=true)
    original_groups = simulation.execution_plan.groups
    original_batches = simulation.execution_plan.batches
    original_source_group = only(
        group for group in original_groups
        if group.application.id == :leaf_source
    )
    original_source_batch = only(original_source_group.batches)
    original_context_group = only(
        group for group in original_groups
        if group.application.id == :leaf_context
    )
    @test [
        [target.object_id for target in batch.targets]
        for batch in original_context_group.batches
    ] == [ObjectId.([:leaf_a]), ObjectId.([:leaf_z])]

    register_object!(
        model,
        Object(:leaf_zz; scale=:Leaf, parent=:scene),
    )
    continue!(simulation)

    # The first application was append-compatible, but the second needed a
    # new concrete batch. Global staging must leave both old groups untouched
    # before the general fallback replaces the plan.
    @test [target.object_id for target in original_source_batch.targets] ==
          ObjectId.([:leaf_a, :leaf_z])
    @test [
        [target.object_id for target in batch.targets]
        for batch in original_context_group.batches
    ] == [ObjectId.([:leaf_a]), ObjectId.([:leaf_z])]
    @test simulation.execution_plan.groups !== original_groups
    @test simulation.execution_plan.batches !== original_batches

    refreshed_source_group = only(
        group for group in simulation.execution_plan.groups
        if group.application.id == :leaf_source
    )
    refreshed_context_group = only(
        group for group in simulation.execution_plan.groups
        if group.application.id == :leaf_context
    )
    @test [
        target.object_id for batch in refreshed_source_group.batches
        for target in batch.targets
    ] == ObjectId.([:leaf_a, :leaf_z, :leaf_zz])
    @test [
        [target.object_id for target in batch.targets]
        for batch in refreshed_context_group.batches
    ] == [
        ObjectId.([:leaf_a]),
        ObjectId.([:leaf_z]),
        ObjectId.([:leaf_zz]),
    ]
    performance = Advanced.runtime_performance(simulation)
    @test performance.counts[:execution_targets_constructed] == 2
    @test performance.counts[:execution_batches_constructed] == 4
    @test get(
        performance.counts,
        :execution_groups_updated_in_place,
        0,
    ) == 0
    @test model_object(model, :leaf_zz).status.signal == 1.0
end

function stabilization_lifecycle_scene(nleaves_per_plant)
    objects = Object[
        Object(:scene; scale=:Scene),
        Object(:plant_a; scale=:Plant, parent=:scene),
        Object(:plant_b; scale=:Plant, parent=:scene),
        Object(:moving_leaf; scale=:Leaf, parent=:plant_a),
        Object(:removed_leaf; scale=:Leaf, parent=:plant_a),
        Object(
            :geometry_leaf;
            scale=:Leaf,
            parent=:plant_b,
            geometry=(cell=:sun,),
        ),
    ]
    for plant in (:plant_a, :plant_b)
        for index in 1:nleaves_per_plant
            push!(
                objects,
                Object(
                    Symbol(plant, :_leaf_, index);
                    scale=:Leaf,
                    parent=plant,
                ),
            )
        end
    end
    return CompositeModel(
        objects...;
        applications=(
            ModelSpec(
                StabilizationSourceModel();
                name=:source,
                on=Many(scale=:Leaf),
            ),
            ModelSpec(
                StabilizationLaggedSumModel();
                name=:plant_sum,
                on=Many(scale=:Plant),
                inputs=(
                    :previous_signals => Many(
                        scale=:Leaf,
                        within=Subtree(),
                        application=:source,
                        var=:signal,
                    ),
                ),
            ),
        ),
        environment=(T=20.0, duration=Hour(1)),
    )
end

function stabilization_lifecycle_work(nleaves_per_plant, operation)
    model = stabilization_lifecycle_scene(nleaves_per_plant)
    simulation = run!(
        model;
        steps=2,
        outputs=:all,
        performance=true,
    )
    unaffected_key = (
        :source,
        ObjectId(Symbol(:plant_b_leaf_, nleaves_per_plant)),
    )
    unaffected_view =
        simulation.compiled.status_views_by_target[unaffected_key]

    if operation == :add
        register_object!(
            model,
            Object(:zz_added_leaf; scale=:Leaf, parent=:plant_a),
        )
    elseif operation == :remove
        remove_object!(model, :removed_leaf)
    elseif operation == :reparent
        reparent_object!(model, :moving_leaf, :plant_b)
    elseif operation == :move
        move_object!(model, :geometry_leaf, (cell=:shade,))
    else
        error("Unknown stabilization lifecycle operation `$(operation)`.")
    end
    continue!(simulation)

    @test simulation.compiled.status_views_by_target[unaffected_key] ===
          unaffected_view
    performance = Advanced.runtime_performance(simulation)
    return (
        status_views=get(performance.counts, :status_views_constructed, 0),
        execution_targets=get(
            performance.counts,
            :execution_targets_constructed,
            0,
        ),
        execution_batches=get(
            performance.counts,
            :execution_batches_constructed,
            0,
        ),
        execution_groups_updated=get(
            performance.counts,
            :execution_groups_updated_in_place,
            0,
        ),
        binding_refreshes=get(performance.counts, :binding_refreshes, 0),
        environment_refreshes=get(
            performance.counts,
            :environment_refreshes,
            0,
        ),
        lifecycle_barriers=get(
            performance.counts,
            :lifecycle_barriers,
            0,
        ),
        lifecycle_added=get(
            performance.counts,
            :lifecycle_added_objects,
            0,
        ),
        lifecycle_removed=get(
            performance.counts,
            :lifecycle_removed_objects,
            0,
        ),
        lifecycle_reparented=get(
            performance.counts,
            :lifecycle_reparented_objects,
            0,
        ),
        lifecycle_moved=get(
            performance.counts,
            :lifecycle_moved_objects,
            0,
        ),
        lifecycle_environment_dirty=get(
            performance.counts,
            :lifecycle_environment_dirty_objects,
            0,
        ),
    ), simulation
end

function stabilization_lifecycle_refresh_allocations(
    nleaves_per_plant,
    operation,
)
    model = stabilization_lifecycle_scene(nleaves_per_plant)
    simulation = run!(model; outputs=:none)
    if operation == :add
        register_object!(
            model,
            Object(:zz_added_leaf; scale=:Leaf, parent=:plant_a),
        )
    elseif operation == :remove
        remove_object!(model, :removed_leaf)
    elseif operation == :reparent
        reparent_object!(model, :moving_leaf, :plant_b)
    elseif operation == :move
        move_object!(model, :geometry_leaf, (cell=:shade,))
    else
        error("Unknown stabilization lifecycle operation `$(operation)`.")
    end
    return @allocated PlantSimEngine._refresh_simulation_runtime!(simulation)
end

@testset "lifecycle work counts scale with the structural delta" begin
    for operation in (:add, :remove, :reparent, :move)
        small_work, small_simulation =
            stabilization_lifecycle_work(8, operation)
        large_work, large_simulation =
            stabilization_lifecycle_work(256, operation)
        @test small_work == large_work
        @test small_work.status_views <= 3
        @test small_work.execution_targets <= 3
        @test small_work.execution_batches == 0
        @test small_work.execution_groups_updated <= 3
        @test small_work.lifecycle_barriers == 1
        @test small_work.lifecycle_environment_dirty == 1
        @test small_work.lifecycle_added == (operation == :add ? 1 : 0)
        @test small_work.lifecycle_removed ==
              (operation == :remove ? 1 : 0)
        @test small_work.lifecycle_reparented ==
              (operation == :reparent ? 1 : 0)
        @test small_work.lifecycle_moved == (operation == :move ? 1 : 0)

        if operation == :remove
            @test !haskey(
                small_simulation.compiled.status_views_by_target,
                (:source, ObjectId(:removed_leaf)),
            )
            @test haskey(
                outputs(small_simulation),
                (:source, ObjectId(:removed_leaf), :signal),
            )
            @test all(
                row.object_id != :removed_leaf
                for row in Diagnostics.explain_environment_bindings(
                    small_simulation,
                )
            )
        elseif operation == :reparent
            rows = Diagnostics.explain_bindings(small_simulation)
            plant_a = only(
                row for row in rows
                if row.application_id == :plant_sum &&
                   row.consumer_id == :plant_a
            )
            plant_b = only(
                row for row in rows
                if row.application_id == :plant_sum &&
                   row.consumer_id == :plant_b
            )
            @test :moving_leaf ∉ plant_a.source_ids
            @test :moving_leaf ∈ plant_b.source_ids
        end
    end

    for operation in (:add, :remove, :reparent, :move)
        stabilization_lifecycle_refresh_allocations(8, operation)
        small_allocations = minimum(
            stabilization_lifecycle_refresh_allocations(8, operation)
            for _ in 1:2
        )
        large_allocations = minimum(
            stabilization_lifecycle_refresh_allocations(2048, operation)
            for _ in 1:2
        )
        @test large_allocations <= small_allocations + 16_384
    end
end
