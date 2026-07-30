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
    public_names = names(PlantSimEngine)
    advanced_names = names(PlantSimEngine.Advanced)
    for public_name in (
        :CompositeModel,
        :CompositeModelTemplate,
        :Simulation,
        :RunContext,
        :CallTarget,
        :EnvironmentContext,
        :commit_environment!,
        :model_objects,
        :runtime_model,
        :explain_applications,
    )
        @test public_name in public_names
    end
    for internal_name in (
        :ObjectRegistry,
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

    retained_scene = CompositeModel(StabilizationSourceModel())
    simulation = run!(retained_scene; steps=2, outputs=:all)
    @test current_step(simulation) == 2
    @test last.(outputs(simulation)[
        (:stabilization_source, ObjectId(:scene), :signal)
    ]) == [1.0, 2.0]

    @test continue!(simulation; steps=2) === simulation
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
            ModelSpec(StabilizationConsumerModel(); name=:consumer, on=One(scale=:Leaf), inputs=(:signal => One(within=Self(), process=:stabilization_source))),
        ),
    )
    @test_throws "matched several source applications `[:source_a, :source_b]`" explain_bindings(
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
    @test performance.counts[:initial_status_views_constructed] == 1
    @test performance.counts[:initial_execution_targets_constructed] == 1
    @test performance.counts[:initial_execution_batches_constructed] == 1
    @test performance.elapsed_seconds[:step_execution] >= 0.0
    @test performance.elapsed_seconds[:initial_binding_compile] >= 0.0
    @test performance.elapsed_seconds[:initial_execution_plan_compile] >= 0.0

    original_view =
        simulation.compiled.status_views_by_target[(:source, ObjectId(:leaf_1))]
    register_object!(model, Object(:leaf_2; scale=:Leaf))
    continue!(simulation)
    refreshed = Advanced.runtime_performance(simulation)
    @test refreshed.counts[:steps_executed] == 4
    @test refreshed.counts[:binding_refreshes] == 1
    @test refreshed.counts[:dirty_binding_objects] == 1
    @test refreshed.counts[:status_views_constructed] == 1
    @test refreshed.counts[:output_retention_reuses] == 1
    @test !haskey(refreshed.counts, :output_retention_compiles)
    @test refreshed.counts[:execution_plan_compiles] == 1
    @test refreshed.counts[:execution_targets_constructed] == 1
    @test refreshed.counts[:execution_batches_constructed] == 1
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
    @test performance.counts[:execution_batches_constructed] == 1
end
