abstract type AbstractSceneGraphSourceModel <: PlantSimEngine.AbstractModel end
abstract type AbstractSceneGraphConsumerModel <: PlantSimEngine.AbstractModel end
abstract type AbstractSceneGraphCycleAModel <: PlantSimEngine.AbstractModel end
abstract type AbstractSceneGraphCycleBModel <: PlantSimEngine.AbstractModel end
abstract type AbstractSceneGraphEnvironmentModel <: PlantSimEngine.AbstractModel end

PlantSimEngine.process_(::Type{AbstractSceneGraphSourceModel}) = :scene_graph_source
PlantSimEngine.process_(::Type{AbstractSceneGraphConsumerModel}) = :scene_graph_consumer
PlantSimEngine.process_(::Type{AbstractSceneGraphCycleAModel}) = :scene_graph_cycle_a
PlantSimEngine.process_(::Type{AbstractSceneGraphCycleBModel}) = :scene_graph_cycle_b
PlantSimEngine.process_(::Type{AbstractSceneGraphEnvironmentModel}) = :scene_graph_environment

struct SceneGraphSourceModel{T} <: AbstractSceneGraphSourceModel
    coefficient::T
end

SceneGraphSourceModel() = SceneGraphSourceModel(2.0)
PlantSimEngine.inputs_(::SceneGraphSourceModel) = (driver=-Inf,)
PlantSimEngine.outputs_(::SceneGraphSourceModel) = (signal=-Inf,)

struct SceneGraphConsumerModel <: AbstractSceneGraphConsumerModel end
PlantSimEngine.inputs_(::SceneGraphConsumerModel) = (signal=-Inf,)
PlantSimEngine.outputs_(::SceneGraphConsumerModel) = (result=-Inf,)

struct SceneGraphCycleAModel <: AbstractSceneGraphCycleAModel end
PlantSimEngine.inputs_(::SceneGraphCycleAModel) = (y=-Inf,)
PlantSimEngine.outputs_(::SceneGraphCycleAModel) = (x=-Inf,)

struct SceneGraphCycleBModel <: AbstractSceneGraphCycleBModel end
PlantSimEngine.inputs_(::SceneGraphCycleBModel) = (x=-Inf,)
PlantSimEngine.outputs_(::SceneGraphCycleBModel) = (y=-Inf,)

struct SceneGraphEnvironmentModel <: AbstractSceneGraphEnvironmentModel end
PlantSimEngine.inputs_(::SceneGraphEnvironmentModel) = NamedTuple()
PlantSimEngine.outputs_(::SceneGraphEnvironmentModel) = (result=-Inf,)
PlantSimEngine.meteo_inputs_(::SceneGraphEnvironmentModel) = (T=-Inf,)
PlantSimEngine.meteo_outputs_(::SceneGraphEnvironmentModel) = (leaf_temperature=-Inf,)

@testset "Scene graph discovery" begin
    @test AbstractSceneGraphSourceModel in available_processes()
    @test SceneGraphSourceModel in available_models(:scene_graph_source)

    descriptor = model_descriptor(SceneGraphSourceModel)
    @test descriptor["process"] == "scene_graph_source"
    @test descriptor["inputs"]["driver"] == "-Inf"
    @test descriptor["outputs"]["signal"] == "-Inf"
    @test descriptor["constructor"]["hasZeroArgConstructor"]
    @test descriptor["constructor"]["fields"][1]["name"] == "coefficient"
end

@testset "Scene graph application and resolved views" begin
    scene = Scene(
        Object(:leaf; name=:leaf, scale=:Leaf, kind=:organ, status=Status(driver=1.0));
        applications=(
            ModelSpec(SceneGraphSourceModel(); name=:source) |>
                AppliesTo(One(name=:leaf)),
            ModelSpec(SceneGraphConsumerModel(); name=:consumer) |>
                AppliesTo(One(name=:leaf)),
        ),
    )

    report = compile_scene_report(scene)
    @test isempty(report.diagnostics)
    @test !isnothing(report.compiled)
    @test report.application_order == [:source, :consumer]

    view = scene_graph_view(scene)
    @test view isa SceneGraphView
    @test view.metadata["objectCount"] == 1
    @test view.metadata["applicationCount"] == 2
    @test view.metadata["executionCount"] == 2
    @test !view.metadata["cyclic"]
    @test any(application -> application["applicationId"] == "source", view.applications)
    @test any(
        edge -> edge["kind"] in ("value_binding", "inferred_same_object") &&
                edge["sourceVariable"] == "signal" &&
                edge["targetVariable"] == "signal",
        view.edges,
    )

    resolved = scene_graph_view(scene; level=:resolved)
    @test length(resolved.executions) == 2
    @test any(edge -> edge["kind"] in ("value_binding", "inferred_same_object"), resolved.edges)

    json = scene_graph_view_json(view)
    @test occursin("\"applications\"", json)
    @test occursin("SceneGraphSourceModel", json)

    path = write_scene_graph_view(
        joinpath(mktempdir(), "scene-graph.html"),
        view;
        renderer=:standalone,
    )
    html = read(path, String)
    @test occursin("PlantSimEngine Scene Graph", html)
    @test occursin("pse-scene-graph-data", html)
    @test occursin("Applications", html)
end

@testset "Scene graph instances and overrides" begin
    template = ObjectTemplate(
        (
            ModelSpec(SceneGraphSourceModel(); name=:source) |>
                AppliesTo(Many(scale=:Leaf)),
        );
        kind=:plant,
        species=:test_species,
    )
    plant_a = ObjectInstance(
        :plant_a,
        template;
        root=Object(:plant_a; scale=:Plant, kind=:plant),
        objects=(Object(:leaf_a; scale=:Leaf, kind=:organ, parent=:plant_a, status=Status(driver=1.0)),),
    )
    plant_b = ObjectInstance(
        :plant_b,
        template;
        root=Object(:plant_b; scale=:Plant, kind=:plant),
        objects=(Object(:leaf_b; scale=:Leaf, kind=:organ, parent=:plant_b, status=Status(driver=1.0)),),
        overrides=(source=SceneGraphSourceModel(3.0),),
    )
    scene = Scene(plant_a, plant_b)
    view = scene_graph_view(scene)

    @test view.metadata["instanceCount"] == 2
    @test Set(instance["name"] for instance in view.instances) == Set(["plant_a", "plant_b"])
    @test Set(application["applicationId"] for application in view.applications) ==
          Set(["plant_a__source", "plant_b__source"])
    plant_b_application = only(
        application for application in view.applications
        if application["applicationId"] == "plant_b__source"
    )
    @test plant_b_application["modelParameters"]["coefficient"]["value"] == 3.0
    @test plant_b_application["targetIds"] == ["leaf_b"]
end

@testset "Scene graph invalid and cyclic reports" begin
    invalid_scene = Scene(
        Object(:leaf; name=:leaf, scale=:Leaf);
        applications=(ModelSpec(SceneGraphSourceModel(); name=:source),),
    )
    invalid_report = compile_scene_report(invalid_scene)
    @test any(diagnostic -> diagnostic.phase == :applications, invalid_report.diagnostics)
    @test_throws Exception compile_scene_report(invalid_scene; strict=true)

    cyclic_scene = Scene(
        Object(:leaf; name=:leaf, scale=:Leaf, status=Status());
        applications=(
            ModelSpec(SceneGraphCycleAModel(); name=:cycle_a) |>
                AppliesTo(One(name=:leaf)),
            ModelSpec(SceneGraphCycleBModel(); name=:cycle_b) |>
                AppliesTo(One(name=:leaf)),
        ),
    )
    report = compile_scene_report(cyclic_scene)
    @test report.cycles == [[:cycle_a, :cycle_b]]
    @test any(diagnostic -> diagnostic.code == :application_cycle, report.diagnostics)
    @test isnothing(report.compiled)

    view = scene_graph_view(cyclic_scene)
    @test view.metadata["cyclic"]
    @test length(view.cycles) == 1
    @test Set(view.cycles[1]["applicationIds"]) == Set(["cycle_a", "cycle_b"])
    @test length(view.cycles[1]["breakCandidates"]) == 2
    @test any(edge -> edge["cycle"] == true, view.edges)
    @test_throws Exception compile_scene(cyclic_scene)

    broken_scene = Scene(
        Object(:leaf; name=:leaf, scale=:Leaf, status=Status(y=0.0));
        applications=(
            ModelSpec(SceneGraphCycleAModel(); name=:cycle_a) |>
                AppliesTo(One(name=:leaf)) |>
                Inputs(PreviousTimeStep(:y) => One(within=Self(), var=:y)),
            ModelSpec(SceneGraphCycleBModel(); name=:cycle_b) |>
                AppliesTo(One(name=:leaf)),
        ),
    )
    broken_view = scene_graph_view(broken_scene)
    @test !broken_view.metadata["cyclic"]
    @test any(edge -> edge["kind"] == "previous_timestep", broken_view.edges)
end

@testset "Scene graph initialization comes from Julia" begin
    scene = Scene(
        Object(:leaf; name=:leaf, scale=:Leaf, status=Status());
        applications=(
            ModelSpec(SceneGraphConsumerModel(); name=:consumer) |>
                AppliesTo(One(name=:leaf)),
        ),
    )
    view = scene_graph_view(scene)
    unresolved = only(
        row for row in view.initialization
        if row["applicationId"] == "consumer" && row["variable"] == "signal"
    )
    @test unresolved["disposition"] == "unresolved"
    @test view.metadata["unresolvedInitializationCount"] == 1
end

@testset "Scene graph edits are transactional" begin
    scene = Scene(Object(:leaf; name=:leaf, scale=:Leaf, status=Status(driver=1.0)))
    source_spec = ModelSpec(SceneGraphSourceModel(); name=:source) |>
                  AppliesTo(One(name=:leaf))
    with_source = apply_scene_graph_edit(scene, AddSceneApplication(source_spec))
    @test isempty(scene.applications)
    @test length(with_source.applications) == 1
    @test_throws "already exists" apply_scene_graph_edit(
        with_source,
        AddSceneApplication(source_spec),
    )
    @test length(with_source.applications) == 1

    changed_model = apply_scene_graph_edit(
        with_source,
        ReplaceSceneApplicationModel(:source, SceneGraphSourceModel(4.0)),
    )
    changed_view = scene_graph_view(changed_model)
    changed_application = only(changed_view.applications)
    @test changed_application["modelParameters"]["coefficient"]["value"] == 4.0

    changed_status = apply_scene_graph_edit(
        changed_model,
        SetSceneObjectStatus(:leaf, :driver, 3.0),
    )
    @test only(scene_objects(changed_status)).status.driver == 3.0
    @test only(scene_objects(changed_model)).status.driver == 1.0

    removed = apply_scene_graph_edit(
        changed_status,
        RemoveSceneApplication(:source),
    )
    @test isempty(removed.applications)
end

@testset "Scene graph edit breaks inferred cycles" begin
    scene = Scene(
        Object(:leaf; name=:leaf, scale=:Leaf, status=Status(y=0.0));
        applications=(
            ModelSpec(SceneGraphCycleAModel(); name=:cycle_a) |>
                AppliesTo(One(name=:leaf)),
            ModelSpec(SceneGraphCycleBModel(); name=:cycle_b) |>
                AppliesTo(One(name=:leaf)),
        ),
    )
    @test scene_graph_view(scene).metadata["cyclic"]

    broken = apply_scene_graph_edit(
        scene,
        MarkScenePreviousTimeStep(:cycle_a, :y),
    )
    broken_view = scene_graph_view(broken)
    @test !broken_view.metadata["cyclic"]
    @test any(edge -> edge["kind"] == "previous_timestep", broken_view.edges)

    restored = apply_scene_graph_edit(
        broken,
        UnmarkScenePreviousTimeStep(:cycle_a, :y),
    )
    @test scene_graph_view(restored).metadata["cyclic"]

    initialized_scene = Scene(
        Object(:leaf; name=:leaf, scale=:Leaf, status=Status());
        applications=(
            ModelSpec(SceneGraphCycleAModel(); name=:cycle_a) |>
                AppliesTo(One(name=:leaf)),
            ModelSpec(SceneGraphCycleBModel(); name=:cycle_b) |>
                AppliesTo(One(name=:leaf)),
        ),
    )
    lagged_without_initial_value = apply_scene_graph_edit(
        initialized_scene,
        MarkScenePreviousTimeStep(:cycle_a, :y),
    )
    lagged_row = only(
        row for row in scene_graph_view(lagged_without_initial_value).initialization
        if row["applicationId"] == "cycle_a" && row["variable"] == "y"
    )
    @test lagged_row["previousTimeStep"]
    @test lagged_row["disposition"] == "unresolved"
    initialized_break = apply_scene_graph_edit(
        initialized_scene,
        BreakSceneCycle(:cycle_a, :y, true, 0.25),
    )
    @test !scene_graph_view(initialized_break).metadata["cyclic"]
    @test only(scene_objects(initialized_break)).status.y == 0.25
end

@testset "Scene graph edits preserve application configuration" begin
    scene = Scene(
        Object(:leaf; name=:leaf, scale=:Leaf, kind=:organ, status=Status(driver=1.0));
        applications=(
            ModelSpec(SceneGraphSourceModel(); name=:source) |>
                AppliesTo(One(name=:leaf)),
        ),
    )

    configured = apply_scene_graph_edit(
        scene,
        SetSceneApplicationEnvironment(:source, (provider=:scene, sources=(T=:temperature,))),
    )
    configured = apply_scene_graph_edit(
        configured,
        SetSceneOutputRouting(:source, :signal, :stream_only),
    )
    configured = apply_scene_graph_edit(
        configured,
        SetSceneUpdateOrdering(:source, (Updates(:signal; after=:driver),)),
    )
    spec = only(configured.applications)
    @test environment_config(spec) == (provider=:scene, sources=(T=:temperature,))
    @test output_routing(spec) == (signal=:stream_only,)
    @test only(updates(spec)).variables == (:signal,)
    configured_application = only(scene_graph_view(configured).applications)
    @test configured_application["environment"]["provider"] == "scene"
    @test configured_application["outputRouting"]["signal"] == "stream_only"
    @test configured_application["updates"] == [Dict(
        "variables" => ["signal"],
        "after" => ["driver"],
    )]

    ordered_writers = Scene(
        Object(:leaf; name=:leaf, scale=:Leaf, status=Status(driver=1.0));
        applications=(
            ModelSpec(SceneGraphSourceModel(1.0); name=:first_writer) |>
                AppliesTo(One(name=:leaf)),
            ModelSpec(SceneGraphSourceModel(2.0); name=:second_writer) |>
                AppliesTo(One(name=:leaf)) |>
                Updates(:signal; after=:first_writer),
        ),
    )
    update_edge = only(
        edge for edge in scene_graph_view(ordered_writers).edges
        if edge["kind"] == "update_order"
    )
    @test update_edge["sourceApplicationId"] == "first_writer"
    @test update_edge["targetApplicationId"] == "second_writer"
    @test update_edge["variables"] == ["signal"]

    environment_scene = Scene(
        Object(:leaf; name=:leaf, scale=:Leaf);
        applications=(
            ModelSpec(SceneGraphEnvironmentModel(); name=:environment_user) |>
                AppliesTo(One(name=:leaf)),
        ),
    )
    environment_edges = [
        edge for edge in scene_graph_view(environment_scene).edges
        if edge["kind"] == "environment_binding" && edge["projection"] == "applications"
    ]
    @test length(environment_edges) == 2
    @test Set(edge["sourceVariable"] for edge in environment_edges) ==
          Set(["T", "leaf_temperature"])
    @test all(haskey(edge, "provider") for edge in environment_edges)

    metadata = apply_scene_graph_edit(
        configured,
        SetSceneObjectMetadata(:leaf; scale=:Organ, kind=:leaf, species=:test, name=:leaf_1),
    )
    object = only(scene_objects(metadata))
    @test (object.scale, object.kind, object.species, object.name) == (:Organ, :leaf, :test, :leaf_1)
    @test object_ids(metadata; scale=:Organ) == [ObjectId(:leaf)]
    @test isempty(object_ids(metadata; scale=:Leaf))

    without_status = apply_scene_graph_edit(metadata, RemoveSceneObjectStatus(:leaf, :driver))
    @test isnothing(only(scene_objects(without_status)).status)
    @test only(scene_objects(metadata)).status.driver == 1.0
end

@testset "Scene graph edit command coverage" begin
    scene = Scene(
        Object(:source_object; name=:source_object, scale=:Leaf, status=Status(driver=1.0)),
        Object(:consumer_object; name=:consumer_object, scale=:Plant);
        applications=(
            ModelSpec(SceneGraphSourceModel(); name=:source) |>
                AppliesTo(One(name=:source_object)),
            ModelSpec(SceneGraphConsumerModel(); name=:consumer) |>
                AppliesTo(One(name=:consumer_object)),
        ),
    )

    configured = apply_scene_graph_edit(
        scene,
        SetSceneApplicationTargets(:consumer, OptionalOne(name=:consumer_object)),
    )
    configured = apply_scene_graph_edit(
        configured,
        SetSceneInputBinding(
            :consumer,
            :signal,
            One(name=:source_object, application=:source, var=:signal),
        ),
    )
    configured = apply_scene_graph_edit(
        configured,
        SetSceneCallBinding(
            :consumer,
            :source_call,
            One(name=:source_object, application=:source),
        ),
    )
    configured = apply_scene_graph_edit(
        configured,
        SetSceneApplicationTimeStep(:consumer, ClockSpec(2.0)),
    )
    configured = apply_scene_graph_edit(
        configured,
        SetSceneUpdateOrdering(:consumer, (Updates(:result; after=:source),)),
    )

    consumer = PlantSimEngine._scene_edit_spec(configured, :consumer)
    @test applies_to(consumer) isa OptionalOne
    @test PlantSimEngine.criteria(value_inputs(consumer).signal).application == :source
    @test PlantSimEngine.criteria(model_calls(consumer).source_call).application == :source
    @test consumer.timestep == ClockSpec(2.0)
    consumer_view = only(
        application for application in scene_graph_view(configured).applications
        if application["applicationId"] == "consumer"
    )
    @test haskey(consumer_view["inputBindings"], "signal")
    @test haskey(consumer_view["callBindings"], "source_call")

    renamed = apply_scene_graph_edit(configured, RenameSceneApplication(:source, :driver_source))
    renamed_consumer = PlantSimEngine._scene_edit_spec(renamed, :consumer)
    @test PlantSimEngine.criteria(value_inputs(renamed_consumer).signal).application == :driver_source
    @test PlantSimEngine.criteria(model_calls(renamed_consumer).source_call).application == :driver_source
    @test PlantSimEngine._update_after(only(updates(renamed_consumer))) == (:driver_source,)
    @test_throws "already exists" apply_scene_graph_edit(
        renamed,
        RenameSceneApplication(:driver_source, :consumer),
    )

    without_input = apply_scene_graph_edit(
        renamed,
        RemoveSceneInputBinding(:consumer, :signal),
    )
    @test isempty(value_inputs(PlantSimEngine._scene_edit_spec(without_input, :consumer)))
    without_call = apply_scene_graph_edit(
        without_input,
        RemoveSceneCallBinding(:consumer, :source_call),
    )
    @test isempty(model_calls(PlantSimEngine._scene_edit_spec(without_call, :consumer)))

    with_objects = apply_scene_graph_edit(
        without_call,
        AddSceneObject(Object(:child; name=:child, scale=:Leaf, parent=:consumer_object)),
    )
    with_objects = apply_scene_graph_edit(
        with_objects,
        ReparentSceneObject(:child, :source_object),
    )
    @test PlantSimEngine._scene_object(with_objects, ObjectId(:child)).parent == ObjectId(:source_object)
    with_objects = apply_scene_graph_edit(
        with_objects,
        SetSceneObjectStatuses([:source_object, :child], :shared_value, 5),
    )
    @test all(
        PlantSimEngine._scene_object(with_objects, ObjectId(id)).status.shared_value == 5
        for id in (:source_object, :child)
    )
    without_child = apply_scene_graph_edit(with_objects, RemoveSceneObject(:child))
    @test !(ObjectId(:child) in object_ids(without_child))
    @test ObjectId(:child) in object_ids(with_objects)
end

function scene_graph_override_fixture()
    template = ObjectTemplate(
        (
            ModelSpec(SceneGraphSourceModel(1.0); name=:source) |>
                AppliesTo(Many(scale=:Leaf)),
        );
        kind=:plant,
        species=:test_species,
    )
    return Scene(
        ObjectInstance(
            :plant_a,
            template;
            root=Object(:plant_a; scale=:Plant),
            objects=(Object(:leaf_a; scale=:Leaf, parent=:plant_a, status=Status(driver=1.0)),),
        ),
        ObjectInstance(
            :plant_b,
            template;
            root=Object(:plant_b; scale=:Plant),
            objects=(Object(:leaf_b; scale=:Leaf, parent=:plant_b, status=Status(driver=1.0)),),
        ),
    )
end

@testset "Scene graph instance override edit" begin
    scene = scene_graph_override_fixture()
    @test length(scene.instances) == 2
    _, instance = PlantSimEngine._scene_edit_instance(scene, :plant_b)
    @test PlantSimEngine._scene_edit_template_application_id(instance, :source) == :source
    overrides = PlantSimEngine._scene_edit_namedtuple_set(
        instance.overrides,
        :source,
        SceneGraphSourceModel(2.0),
    )
    @test haskey(overrides, :source)
    replacement = PlantSimEngine._scene_edit_normalize_instance(instance; overrides=overrides)
    @test replacement.name == :plant_b
    instance_override = apply_scene_graph_edit(
        scene,
        SetSceneInstanceOverride(:plant_b, :source, SceneGraphSourceModel(2.0)),
    )
    view = scene_graph_view(instance_override)
    plant_a = only(application for application in view.applications if application["applicationId"] == "plant_a__source")
    plant_b = only(application for application in view.applications if application["applicationId"] == "plant_b__source")
    @test plant_a["modelParameters"]["coefficient"]["value"] == 1.0
    @test plant_b["modelParameters"]["coefficient"]["value"] == 2.0

    restored_instance = apply_scene_graph_edit(
        instance_override,
        RemoveSceneInstanceOverride(:plant_b, :source),
    )
    restored_b = only(
        application for application in scene_graph_view(restored_instance).applications
        if application["applicationId"] == "plant_b__source"
    )
    @test restored_b["modelParameters"]["coefficient"]["value"] == 1.0
    @test scene_graph_view(scene).metadata["applicationCount"] == 2
    @test_throws Exception apply_scene_graph_edit(
        scene,
        SetSceneInstanceOverride(:plant_b, :source, SceneGraphConsumerModel()),
    )
end

@testset "Scene graph object override edit" begin
    scene = scene_graph_override_fixture()
    @test length(scene.instances) == 2
    object_override = apply_scene_graph_edit(
        scene,
        SetSceneObjectOverride(:plant_a, :leaf_a, :source, SceneGraphSourceModel(3.0)),
    )
    application = only(
        application for application in scene_graph_view(object_override).applications
        if application["applicationId"] == "plant_a__source"
    )
    @test application["modelStorage"] == "per_object_override"
    @test only(application["objectOverrides"])["parameters"]["coefficient"]["value"] == 3.0

    restored_object = apply_scene_graph_edit(
        object_override,
        RemoveSceneObjectOverride(:plant_a, :leaf_a, :source),
    )
    restored_application = only(
        application for application in scene_graph_view(restored_object).applications
        if application["applicationId"] == "plant_a__source"
    )
    @test restored_application["modelStorage"] == "shared_application"
    @test_throws Exception apply_scene_graph_edit(
        scene,
        SetSceneObjectOverride(:plant_a, :leaf_a, :source, SceneGraphConsumerModel()),
    )
end


@testset "Scene graph shared template application edit" begin
    scene = scene_graph_override_fixture()
    updated = apply_scene_graph_edit(
        scene,
        UpdateSceneTemplateApplication(
            :plant_a,
            :plant_a__source,
            SceneGraphSourceModel(4.0),
            Many(scale=:Leaf),
            ClockSpec(2.0),
        ),
    )
    applications = scene_graph_view(updated).applications
    @test Set(application["applicationId"] for application in applications) ==
          Set(["plant_a__source", "plant_b__source"])
    @test all(
        application["modelParameters"]["coefficient"]["value"] == 4.0
        for application in applications
    )
    @test all(application["targetCount"] == 1 for application in applications)
    @test all(!isnothing(application["timestep"]) for application in applications)
    @test all(
        application["modelParameters"]["coefficient"]["value"] == 1.0
        for application in scene_graph_view(scene).applications
    )
end
