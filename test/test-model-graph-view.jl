abstract type AbstractModelGraphSourceModel <: PlantSimEngine.AbstractModel end
abstract type AbstractModelGraphConsumerModel <: PlantSimEngine.AbstractModel end
abstract type AbstractModelGraphCycleAModel <: PlantSimEngine.AbstractModel end
abstract type AbstractModelGraphCycleBModel <: PlantSimEngine.AbstractModel end
abstract type AbstractModelGraphEnvironmentModel <: PlantSimEngine.AbstractModel end

PlantSimEngine.process_(::Type{AbstractModelGraphSourceModel}) = :model_graph_source
PlantSimEngine.process_(::Type{AbstractModelGraphConsumerModel}) = :model_graph_consumer
PlantSimEngine.process_(::Type{AbstractModelGraphCycleAModel}) = :model_graph_cycle_a
PlantSimEngine.process_(::Type{AbstractModelGraphCycleBModel}) = :model_graph_cycle_b
PlantSimEngine.process_(::Type{AbstractModelGraphEnvironmentModel}) = :model_graph_environment

struct ModelGraphSourceModel{T} <: AbstractModelGraphSourceModel
    coefficient::T
end

ModelGraphSourceModel() = ModelGraphSourceModel(2.0)
PlantSimEngine.inputs_(::ModelGraphSourceModel) = (driver=Required(Float64),)
PlantSimEngine.outputs_(::ModelGraphSourceModel) = (signal=-Inf,)

struct ModelGraphConsumerModel <: AbstractModelGraphConsumerModel end
PlantSimEngine.inputs_(::ModelGraphConsumerModel) = (signal=Required(Float64),)
PlantSimEngine.outputs_(::ModelGraphConsumerModel) = (result=-Inf,)

struct ModelGraphCycleAModel <: AbstractModelGraphCycleAModel end
PlantSimEngine.inputs_(::ModelGraphCycleAModel) = (y=Required(Float64),)
PlantSimEngine.outputs_(::ModelGraphCycleAModel) = (x=-Inf,)

struct ModelGraphCycleBModel <: AbstractModelGraphCycleBModel end
PlantSimEngine.inputs_(::ModelGraphCycleBModel) = (x=Required(Float64),)
PlantSimEngine.outputs_(::ModelGraphCycleBModel) = (y=-Inf,)

struct ModelGraphEnvironmentModel <: AbstractModelGraphEnvironmentModel end
PlantSimEngine.inputs_(::ModelGraphEnvironmentModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelGraphEnvironmentModel) = (result=-Inf,)
PlantSimEngine.environment_inputs_(::ModelGraphEnvironmentModel) = (T=-Inf,)
PlantSimEngine.environment_outputs_(::ModelGraphEnvironmentModel) = (leaf_temperature=-Inf,)

@testset "CompositeModel graph discovery" begin
    @test AbstractModelGraphSourceModel in available_processes()
    @test ModelGraphSourceModel in available_models(:model_graph_source)

    descriptor = model_descriptor(ModelGraphSourceModel)
    @test descriptor["process"] == "model_graph_source"
    @test descriptor["inputs"]["driver"]["declaration"] == "required"
    @test descriptor["inputs"]["driver"]["expectedType"] == "Float64"
    @test isnothing(descriptor["inputs"]["driver"]["default"])
    @test descriptor["outputs"]["signal"] == "-Inf"
    @test descriptor["constructor"]["hasZeroArgConstructor"]
    @test descriptor["constructor"]["fields"][1]["name"] == "coefficient"
end

@testset "CompositeModel selector diagnostics preserve normalized fields" begin
    selector = Many(
        Relation(:parent);
        within=SceneScope(),
        kind=:plant,
        species=:oil_palm,
        scale=:Leaf,
        name=:leaf_1,
        process=:energy_balance,
        application=:sunlit_energy,
        var=:temperature,
        policy=Integrate(),
        window=2.0,
        from_status=true,
        after=("radiation", :water),
    )
    payload = PlantSimEngine._model_graph_selector_criteria(selector)

    @test Set(keys(payload)) == Set([
        "selectors",
        "within",
        "kind",
        "species",
        "scale",
        "name",
        "process",
        "application",
        "var",
        "policy",
        "window",
        "from_status",
        "after",
    ])
    @test only(payload["selectors"]) == Dict(
        "type" => "Relation",
        "relation" => "parent",
    )
    @test payload["within"] == Dict("type" => "SceneScope")
    @test payload["after"] == ["radiation", "water"]
end

@testset "CompositeModel graph application and resolved views" begin
    model = CompositeModel(
        Object(:leaf; name=:leaf, scale=:Leaf, kind=:organ, status=Status(driver=1.0));
        applications=(
            ModelSpec(ModelGraphSourceModel(); name=:source, on=One(name=:leaf)),
            ModelSpec(ModelGraphConsumerModel(); name=:consumer, on=One(name=:leaf)),
        ),
    )

    report = compile_model_report(model)
    @test isempty(report.diagnostics)
    @test !isnothing(report.compiled)
    @test report.application_order == [:source, :consumer]

    view = model_graph_view(model)
    @test view isa ModelGraphView
    @test view.metadata["objectCount"] == 1
    @test view.metadata["applicationCount"] == 2
    @test view.metadata["executionCount"] == 2
    @test !view.metadata["cyclic"]
    @test any(application -> application["applicationId"] == "source", view.applications)
    source_application = only(
        application for application in view.applications
        if application["applicationId"] == "source"
    )
    @test source_application["inputs"] isa Vector
    @test source_application["outputs"] isa Vector
    @test source_application["environmentInputs"] isa Vector
    @test source_application["environmentOutputs"] isa Vector
    @test isempty(source_application["environmentInputs"])
    @test isempty(source_application["environmentOutputs"])
    @test any(
        edge -> edge["kind"] in ("value_binding", "inferred_same_object") &&
                edge["sourceVariable"] == "signal" &&
                edge["targetVariable"] == "signal",
        view.edges,
    )

    resolved = model_graph_view(model; level=:resolved)
    @test length(resolved.executions) == 2
    @test any(edge -> edge["kind"] in ("value_binding", "inferred_same_object"), resolved.edges)

    json = model_graph_view_json(view)
    @test occursin("\"applications\"", json)
    @test occursin("ModelGraphSourceModel", json)

    path = write_model_graph_view(
        joinpath(mktempdir(), "model-graph.html"),
        view;
        renderer=:standalone,
    )
    html = read(path, String)
    @test occursin("PlantSimEngine CompositeModel Graph", html)
    @test occursin("pse-model-graph-data", html)
    @test occursin("Applications", html)
end

@testset "CompositeModel graph instances and overrides" begin
    template = CompositeModelTemplate(
        (
            ModelSpec(ModelGraphSourceModel(); name=:source, on=Many(scale=:Leaf)),
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
        overrides=(source=ModelGraphSourceModel(3.0),),
    )
    model = CompositeModel(plant_a, plant_b)
    view = model_graph_view(model)

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

@testset "CompositeModel graph invalid and cyclic reports" begin
    invalid_scene = CompositeModel(
        Object(:leaf; name=:leaf, scale=:Leaf);
        applications=(ModelSpec(ModelGraphSourceModel(); name=:source),),
    )
    invalid_report = compile_model_report(invalid_scene)
    @test any(diagnostic -> diagnostic.phase == :applications, invalid_report.diagnostics)
    @test_throws Exception compile_model_report(invalid_scene; strict=true)

    cyclic_scene = CompositeModel(
        Object(:leaf; name=:leaf, scale=:Leaf, status=Status());
        applications=(
            ModelSpec(ModelGraphCycleAModel(); name=:cycle_a, on=One(name=:leaf)),
            ModelSpec(ModelGraphCycleBModel(); name=:cycle_b, on=One(name=:leaf)),
        ),
    )
    report = compile_model_report(cyclic_scene)
    @test report.cycles == [[:cycle_a, :cycle_b]]
    @test any(diagnostic -> diagnostic.code == :application_cycle, report.diagnostics)
    @test isnothing(report.compiled)

    view = model_graph_view(cyclic_scene)
    @test view.metadata["cyclic"]
    @test length(view.cycles) == 1
    @test Set(view.cycles[1]["applicationIds"]) == Set(["cycle_a", "cycle_b"])
    @test length(view.cycles[1]["breakCandidates"]) == 2
    @test any(edge -> edge["cycle"] == true, view.edges)
    @test_throws Exception compile_composite_model(cyclic_scene)

    broken_scene = CompositeModel(
        Object(:leaf; name=:leaf, scale=:Leaf, status=Status(y=0.0));
        applications=(
            ModelSpec(ModelGraphCycleAModel(); name=:cycle_a, on=One(name=:leaf), inputs=(PreviousTimeStep(:y) => One(within=Self(), var=:y))),
            ModelSpec(ModelGraphCycleBModel(); name=:cycle_b, on=One(name=:leaf)),
        ),
    )
    broken_view = model_graph_view(broken_scene)
    @test !broken_view.metadata["cyclic"]
    @test any(edge -> edge["kind"] == "previous_timestep", broken_view.edges)
end

@testset "CompositeModel graph initialization comes from Julia" begin
    model = CompositeModel(
        Object(:leaf; name=:leaf, scale=:Leaf, status=Status());
        applications=(
            ModelSpec(ModelGraphConsumerModel(); name=:consumer, on=One(name=:leaf)),
        ),
    )
    view = model_graph_view(model)
    unresolved = only(
        row for row in view.initialization
        if row["applicationId"] == "consumer" && row["variable"] == "signal"
    )
    @test unresolved["disposition"] == "required"
    @test view.metadata["unresolvedInitializationCount"] == 1
end

@testset "CompositeModel graph edits are transactional" begin
    model = CompositeModel(Object(:leaf; name=:leaf, scale=:Leaf, status=Status(driver=1.0)))
    source_spec = ModelSpec(ModelGraphSourceModel(); name=:source, on=One(name=:leaf))
    with_source = apply_model_graph_edit(model, AddModelApplication(source_spec))
    @test isempty(model.applications)
    @test length(with_source.applications) == 1
    @test_throws "already exists" apply_model_graph_edit(
        with_source,
        AddModelApplication(source_spec),
    )
    @test length(with_source.applications) == 1

    changed_model = apply_model_graph_edit(
        with_source,
        ReplaceModelApplicationModel(:source, ModelGraphSourceModel(4.0)),
    )
    changed_view = model_graph_view(changed_model)
    changed_application = only(changed_view.applications)
    @test changed_application["modelParameters"]["coefficient"]["value"] == 4.0

    changed_status = apply_model_graph_edit(
        changed_model,
        SetModelObjectStatus(:leaf, :driver, 3.0),
    )
    @test only(model_objects(changed_status)).status.driver == 3.0
    @test only(model_objects(changed_model)).status.driver == 1.0

    removed = apply_model_graph_edit(
        changed_status,
        RemoveModelApplication(:source),
    )
    @test isempty(removed.applications)
end

@testset "CompositeModel graph edit breaks inferred cycles" begin
    model = CompositeModel(
        Object(:leaf; name=:leaf, scale=:Leaf, status=Status(y=0.0));
        applications=(
            ModelSpec(ModelGraphCycleAModel(); name=:cycle_a, on=One(name=:leaf)),
            ModelSpec(ModelGraphCycleBModel(); name=:cycle_b, on=One(name=:leaf)),
        ),
    )
    @test model_graph_view(model).metadata["cyclic"]

    broken = apply_model_graph_edit(
        model,
        MarkModelPreviousTimeStep(:cycle_a, :y),
    )
    broken_view = model_graph_view(broken)
    @test !broken_view.metadata["cyclic"]
    @test any(edge -> edge["kind"] == "previous_timestep", broken_view.edges)

    restored = apply_model_graph_edit(
        broken,
        UnmarkModelPreviousTimeStep(:cycle_a, :y),
    )
    @test model_graph_view(restored).metadata["cyclic"]

    initialized_scene = CompositeModel(
        Object(:leaf; name=:leaf, scale=:Leaf, status=Status());
        applications=(
            ModelSpec(ModelGraphCycleAModel(); name=:cycle_a, on=One(name=:leaf)),
            ModelSpec(ModelGraphCycleBModel(); name=:cycle_b, on=One(name=:leaf)),
        ),
    )
    lagged_without_initial_value = apply_model_graph_edit(
        initialized_scene,
        MarkModelPreviousTimeStep(:cycle_a, :y),
    )
    lagged_row = only(
        row for row in model_graph_view(lagged_without_initial_value).initialization
        if row["applicationId"] == "cycle_a" && row["variable"] == "y"
    )
    @test lagged_row["previousTimeStep"]
    @test lagged_row["disposition"] == "required"
    initialized_break = apply_model_graph_edit(
        initialized_scene,
        BreakModelCycle(:cycle_a, :y, true, 0.25),
    )
    @test !model_graph_view(initialized_break).metadata["cyclic"]
    @test only(model_objects(initialized_break)).status.y == 0.25
end

@testset "CompositeModel graph edits preserve application configuration" begin
    model = CompositeModel(
        Object(:leaf; name=:leaf, scale=:Leaf, kind=:organ, status=Status(driver=1.0));
        applications=(
            ModelSpec(ModelGraphSourceModel(); name=:source, on=One(name=:leaf)),
        ),
    )

    configured = apply_model_graph_edit(
        model,
        SetModelApplicationEnvironment(:source, (provider=:model, sources=(T=:temperature,))),
    )
    configured = apply_model_graph_edit(
        configured,
        SetModelOutputRouting(:source, :signal, :stream_only),
    )
    configured = apply_model_graph_edit(
        configured,
        SetModelUpdateOrdering(:source, (Updates(:signal; after=:driver),)),
    )
    spec = only(configured.applications)
    @test environment_config(spec).config ==
          (provider=:model, sources=(T=:temperature,))
    @test output_routing(spec) == (signal=:stream_only,)
    @test only(updates(spec)).variables == (:signal,)
    configured_application = only(model_graph_view(configured).applications)
    @test configured_application["environment"]["provider"] == "model"
    @test configured_application["outputRouting"]["signal"] == "stream_only"
    @test configured_application["updates"] == [Dict(
        "variables" => ["signal"],
        "after" => ["driver"],
    )]

    ordered_writers = CompositeModel(
        Object(:leaf; name=:leaf, scale=:Leaf, status=Status(driver=1.0));
        applications=(
            ModelSpec(ModelGraphSourceModel(1.0); name=:first_writer, on=One(name=:leaf)),
            ModelSpec(ModelGraphSourceModel(2.0); name=:second_writer, on=One(name=:leaf), updates=Updates(:signal; after=:first_writer)),
        ),
    )
    update_edge = only(
        edge for edge in model_graph_view(ordered_writers).edges
        if edge["kind"] == "update_order"
    )
    @test update_edge["sourceApplicationId"] == "first_writer"
    @test update_edge["targetApplicationId"] == "second_writer"
    @test update_edge["variables"] == ["signal"]

    environment_scene = CompositeModel(
        Object(:leaf; name=:leaf, scale=:Leaf);
        applications=(
            ModelSpec(ModelGraphEnvironmentModel(); name=:environment_user, on=One(name=:leaf), environment=Environment(provider=:forcing, sink=:canopy)),
        ),
    )
    environment_edges = [
        edge for edge in model_graph_view(environment_scene).edges
        if edge["kind"] == "environment_binding" && edge["projection"] == "applications"
    ]
    @test length(environment_edges) == 2
    @test Set(edge["sourceVariable"] for edge in environment_edges) ==
          Set(["T", "leaf_temperature"])
    @test all(haskey(edge, "provider") for edge in environment_edges)
    environment_input_edge = only(
        edge for edge in environment_edges if edge["sourceVariable"] == "T"
    )
    environment_output_edge = only(
        edge for edge in environment_edges if edge["sourceVariable"] == "leaf_temperature"
    )
    @test environment_input_edge["provider"] == "forcing"
    @test environment_output_edge["provider"] == "canopy"
    @test environment_output_edge["sink"] == "canopy"

    metadata = apply_model_graph_edit(
        configured,
        SetModelObjectMetadata(:leaf; scale=:Organ, kind=:leaf, species=:test, name=:leaf_1),
    )
    object = only(model_objects(metadata))
    @test (object.scale, object.kind, object.species, object.name) == (:Organ, :leaf, :test, :leaf_1)
    @test object_ids(metadata; scale=:Organ) == [ObjectId(:leaf)]
    @test isempty(object_ids(metadata; scale=:Leaf))

    without_status = apply_model_graph_edit(metadata, RemoveModelObjectStatus(:leaf, :driver))
    @test isnothing(only(model_objects(without_status)).status)
    @test only(model_objects(metadata)).status.driver == 1.0
end

@testset "CompositeModel graph edit command coverage" begin
    model = CompositeModel(
        Object(:source_object; name=:source_object, scale=:Leaf, status=Status(driver=1.0)),
        Object(:consumer_object; name=:consumer_object, scale=:Plant);
        applications=(
            ModelSpec(ModelGraphSourceModel(); name=:source, on=One(name=:source_object)),
            ModelSpec(ModelGraphConsumerModel(); name=:consumer, on=One(name=:consumer_object)),
        ),
    )

    configured = apply_model_graph_edit(
        model,
        SetModelApplicationTargets(:consumer, OptionalOne(name=:consumer_object)),
    )
    configured = apply_model_graph_edit(
        configured,
        SetModelInputBinding(
            :consumer,
            :signal,
            One(name=:source_object, application=:source, var=:signal),
        ),
    )
    configured = apply_model_graph_edit(
        configured,
        SetModelCallBinding(
            :consumer,
            :source_call,
            One(name=:source_object, application=:source),
        ),
    )
    configured = apply_model_graph_edit(
        configured,
        SetModelApplicationTimeStep(:consumer, ClockSpec(2.0)),
    )
    configured = apply_model_graph_edit(
        configured,
        SetModelUpdateOrdering(:consumer, (Updates(:result; after=:source),)),
    )

    consumer = PlantSimEngine._model_edit_spec(configured, :consumer)
    @test applies_to(consumer) isa OptionalOne
    @test PlantSimEngine.criteria(value_inputs(consumer).signal).application == :source
    @test PlantSimEngine.criteria(model_calls(consumer).source_call).application == :source
    @test consumer.timestep == ClockSpec(2.0)
    consumer_view = only(
        application for application in model_graph_view(configured).applications
        if application["applicationId"] == "consumer"
    )
    @test haskey(consumer_view["inputBindings"], "signal")
    @test haskey(consumer_view["callBindings"], "source_call")

    renamed = apply_model_graph_edit(configured, RenameModelApplication(:source, :driver_source))
    renamed_consumer = PlantSimEngine._model_edit_spec(renamed, :consumer)
    @test PlantSimEngine.criteria(value_inputs(renamed_consumer).signal).application == :driver_source
    @test PlantSimEngine.criteria(model_calls(renamed_consumer).source_call).application == :driver_source
    @test PlantSimEngine._update_after(only(updates(renamed_consumer))) == (:driver_source,)
    @test_throws "already exists" apply_model_graph_edit(
        renamed,
        RenameModelApplication(:driver_source, :consumer),
    )

    without_input = apply_model_graph_edit(
        renamed,
        RemoveModelInputBinding(:consumer, :signal),
    )
    @test isempty(value_inputs(PlantSimEngine._model_edit_spec(without_input, :consumer)))
    without_call = apply_model_graph_edit(
        without_input,
        RemoveModelCallBinding(:consumer, :source_call),
    )
    @test isempty(model_calls(PlantSimEngine._model_edit_spec(without_call, :consumer)))

    with_objects = apply_model_graph_edit(
        without_call,
        AddModelObject(Object(:child; name=:child, scale=:Leaf, parent=:consumer_object)),
    )
    with_objects = apply_model_graph_edit(
        with_objects,
        ReparentModelObject(:child, :source_object),
    )
    @test PlantSimEngine._model_object(with_objects, ObjectId(:child)).parent == ObjectId(:source_object)
    with_objects = apply_model_graph_edit(
        with_objects,
        SetModelObjectStatuses([:source_object, :child], :shared_value, 5),
    )
    @test all(
        PlantSimEngine._model_object(with_objects, ObjectId(id)).status.shared_value == 5
        for id in (:source_object, :child)
    )
    without_child = apply_model_graph_edit(with_objects, RemoveModelObject(:child))
    @test !(ObjectId(:child) in object_ids(without_child))
    @test ObjectId(:child) in object_ids(with_objects)
end

function model_graph_override_fixture()
    template = CompositeModelTemplate(
        (
            ModelSpec(ModelGraphSourceModel(1.0); name=:source, on=Many(scale=:Leaf)),
        );
        kind=:plant,
        species=:test_species,
    )
    return CompositeModel(
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

@testset "CompositeModel graph instance override edit" begin
    model = model_graph_override_fixture()
    @test length(model.instances) == 2
    _, instance = PlantSimEngine._model_edit_instance(model, :plant_b)
    @test PlantSimEngine._model_edit_template_application_id(instance, :source) == :source
    overrides = PlantSimEngine._model_edit_namedtuple_set(
        instance.overrides,
        :source,
        ModelGraphSourceModel(2.0),
    )
    @test haskey(overrides, :source)
    replacement = PlantSimEngine._model_edit_normalize_instance(instance; overrides=overrides)
    @test replacement.name == :plant_b
    instance_override = apply_model_graph_edit(
        model,
        SetModelInstanceOverride(:plant_b, :source, ModelGraphSourceModel(2.0)),
    )
    view = model_graph_view(instance_override)
    plant_a = only(application for application in view.applications if application["applicationId"] == "plant_a__source")
    plant_b = only(application for application in view.applications if application["applicationId"] == "plant_b__source")
    @test plant_a["modelParameters"]["coefficient"]["value"] == 1.0
    @test plant_b["modelParameters"]["coefficient"]["value"] == 2.0

    restored_instance = apply_model_graph_edit(
        instance_override,
        RemoveModelInstanceOverride(:plant_b, :source),
    )
    restored_b = only(
        application for application in model_graph_view(restored_instance).applications
        if application["applicationId"] == "plant_b__source"
    )
    @test restored_b["modelParameters"]["coefficient"]["value"] == 1.0
    @test model_graph_view(model).metadata["applicationCount"] == 2
    @test_throws Exception apply_model_graph_edit(
        model,
        SetModelInstanceOverride(:plant_b, :source, ModelGraphConsumerModel()),
    )
end

@testset "CompositeModel graph object override edit" begin
    model = model_graph_override_fixture()
    @test length(model.instances) == 2
    object_override = apply_model_graph_edit(
        model,
        SetModelObjectOverride(:plant_a, :leaf_a, :source, ModelGraphSourceModel(3.0)),
    )
    application = only(
        application for application in model_graph_view(object_override).applications
        if application["applicationId"] == "plant_a__source"
    )
    @test application["modelStorage"] == "per_object_override"
    @test only(application["objectOverrides"])["parameters"]["coefficient"]["value"] == 3.0

    restored_object = apply_model_graph_edit(
        object_override,
        RemoveModelObjectOverride(:plant_a, :leaf_a, :source),
    )
    restored_application = only(
        application for application in model_graph_view(restored_object).applications
        if application["applicationId"] == "plant_a__source"
    )
    @test restored_application["modelStorage"] == "shared_application"
    @test_throws Exception apply_model_graph_edit(
        model,
        SetModelObjectOverride(:plant_a, :leaf_a, :source, ModelGraphConsumerModel()),
    )
end


@testset "CompositeModel graph shared template application edit" begin
    model = model_graph_override_fixture()
    updated = apply_model_graph_edit(
        model,
        UpdateModelTemplateApplication(
            :plant_a,
            :plant_a__source,
            ModelGraphSourceModel(4.0),
            Many(scale=:Leaf),
            ClockSpec(2.0),
        ),
    )
    applications = model_graph_view(updated).applications
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
        for application in model_graph_view(model).applications
    )
end
