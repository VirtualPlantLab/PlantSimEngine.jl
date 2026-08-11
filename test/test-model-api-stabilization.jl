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
        :OutputRequest,
        :Override,
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
        :Weather,
        :add_organ!,
        :application_name,
        :applies_to,
        :bounds,
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
        :move_object!,
        :object_ids,
        :objects_from_mtg,
        :output_policy,
        :output_routing,
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
        :runtime_model,
        :step!,
        :timespec,
        :timestep_hint,
        :update_geometry!,
        :updates,
        :validate_environment_inputs,
        :value_inputs,
        :variables,
    ])
    @test public_names == expected_public_names
    advanced_names = names(PlantSimEngine.Advanced)
    diagnostic_names = names(PlantSimEngine.Diagnostics)
    graph_editor_names = names(PlantSimEngine.GraphEditor)
    environment_api_names = names(PlantSimEngine.EnvironmentAPI)
    evaluation_names = names(PlantSimEngine.Evaluation)
    @test Set(advanced_names) == Set([
        :Advanced,
        :CompiledApplicationPlan,
        :CompiledCompositeModel,
        :CompiledEnvironmentBinding,
        :CompiledEnvironmentBindings,
        :CompiledModelApplication,
        :CompiledModelCallPlan,
        :CompiledModelCallBinding,
        :CompiledModelInputPlan,
        :CompiledModelInputBinding,
        :CompiledScenarioPlan,
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
        :model_revision,
        :refresh_bindings!,
        :refresh_environment_bindings!,
        :runtime_performance,
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
        :explain_objects,
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
        :CompositeModelCompilationReport,
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
        :available_models,
        :available_processes,
        :compile_model_graph,
        :compile_model_report,
        :current_model,
        :edit_graph,
        :model_constructor_descriptor,
        :model_descriptor,
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
    for graph_editor_name in (
        :ModelGraphView,
        :compile_model_report,
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
    @test_throws "No matching ancestor" resolve_object_ids(
        model,
        Many(within=Ancestor(scale=:Plant));
        context=:plant,
    )
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

    @test !ismutabletype(typeof(scenario_plan))
    @test !ismutabletype(typeof(application_plan))
    @test ismutabletype(typeof(application))
    @test isconst(typeof(application), :plan)
    @test compiled.applications_by_id isa NamedTuple
    @test scenario_plan.call_owners isa NamedTuple
    @test scenario_plan.application_children isa NamedTuple
    @test scenario_plan.manual_application_ids == ()
    @test scenario_plan.application_order == (:leaf_source,)
    @test scenario_plan.ordered_application_plans == (application_plan,)
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
    @test only(added.applications).plan === application_plan
    @test only(added.applications).target_ids == ObjectId[ObjectId(:leaf)]
    @test only(explain_applications(added)).current_target_count == 1

    remove_object!(model, :leaf)
    removed = Advanced.refresh_bindings!(model)
    @test removed.scenario_plan === scenario_plan
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
    @test performance.counts[:application_groups_visited] == 3
    @test performance.counts[:execution_batches_visited] == 3
    @test performance.counts[:execution_targets_visited] == 3
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

    original_view =
        simulation.compiled.status_views_by_target[(:source, ObjectId(:leaf_1))]
    previous_runtime_revision = model.runtime_revision
    register_object!(model, Object(:leaf_2; scale=:Leaf))
    @test model.runtime_revision == previous_runtime_revision + 1
    continue!(simulation)
    @test simulation.runtime_revision == model.runtime_revision
    refreshed = Advanced.runtime_performance(simulation)
    @test refreshed.counts[:steps_executed] == 4
    @test refreshed.counts[:binding_refreshes] == 1
    @test refreshed.counts[:dirty_binding_objects] == 1
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

    collect_outputs(simulation; sink=nothing)
    collected = Advanced.runtime_performance(simulation)
    @test collected.counts[:output_collections] == 1
    @test collected.elapsed_seconds[:output_collection] >= 0.0
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
    @test collect(original_temporal_input.reference[]) == [0.0]

    register_object!(
        model,
        Object(:leaf_2; scale=:Leaf, parent=:plant),
    )
    continue!(simulation)

    refreshed_leaf_view =
        simulation.compiled.status_views_by_target[(:source, ObjectId(:leaf_1))]
    refreshed_plant_view =
        simulation.compiled.status_views_by_target[(:lagged_sum, ObjectId(:plant))]
    refreshed_temporal_input = only(refreshed_plant_view.temporal_inputs)
    @test refreshed_leaf_view === original_leaf_view
    @test refreshed_plant_view !== original_plant_view
    @test refreshed_temporal_input.binding.source_ids ==
          ObjectId.([:leaf_1, :leaf_2])
    @test plant_status.lagged_total == 1.0

    continue!(simulation)
    @test plant_status.lagged_total == 3.0
    performance = Advanced.runtime_performance(simulation)
    @test performance.counts[:status_views_constructed] == 2
    @test performance.counts[:output_retention_reuses] == 1
    @test !haskey(performance.counts, :output_retention_compiles)
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
    simulation = run!(model; performance=true)
    original_scene_group = only(
        group for group in simulation.execution_plan.groups
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
    refreshed_scene_target = only(only(refreshed_scene_group.batches).targets)
    performance = Advanced.runtime_performance(simulation)
    @test refreshed_scene_group === original_scene_group
    @test refreshed_scene_target === original_scene_target
    @test performance.counts[:execution_groups_reused] == 1
    @test performance.counts[:execution_targets_constructed] == 1
    @test performance.counts[:execution_batches_constructed] == 0
    @test performance.counts[:execution_groups_updated_in_place] == 1
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
            Object(:added_leaf; scale=:Leaf, parent=:plant_a),
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
    ), simulation
end

function stabilization_lifecycle_refresh_allocations(
    nleaves_per_plant,
    operation,
)
    model = stabilization_lifecycle_scene(nleaves_per_plant)
    simulation = run!(model; outputs=:none)
    if operation == :remove
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

    for operation in (:remove, :reparent, :move)
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
