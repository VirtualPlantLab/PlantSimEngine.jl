abstract type AbstractModelGraphSourceModel <: PlantSimEngine.AbstractModel end
import Dates

model_graph_global(application_id) = GlobalApplicationRef(application_id)
model_graph_template(instance, application_id) = TemplateApplicationRef(instance, application_id)
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

struct ModelGraphWeatherBackend <: PlantSimEngine.EnvironmentAPI.AbstractEnvironmentBackend end
struct ModelGraphCanopyBackend <: PlantSimEngine.EnvironmentAPI.AbstractEnvironmentBackend end
PlantSimEngine.EnvironmentAPI.environment_variables(::ModelGraphWeatherBackend) = (:T, :RH)
PlantSimEngine.EnvironmentAPI.environment_variables(::ModelGraphCanopyBackend) = (:T, :wind)
PlantSimEngine.EnvironmentAPI.base_step_seconds(::Union{ModelGraphWeatherBackend,ModelGraphCanopyBackend}) = 3600.0
PlantSimEngine.EnvironmentAPI.get_nsteps(::Union{ModelGraphWeatherBackend,ModelGraphCanopyBackend}) = 1

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
        window=Dates.Hour(2),
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
    @test payload["window"]["mode"] == "period"
    @test payload["window"]["unit"] == "Hour"
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
    @test source_application["updates"] isa Vector
    @test source_application["owner"] == Dict(
        "scope" => "global",
        "instance" => nothing,
        "applicationId" => "source",
        "templateId" => nothing,
    )
    @test source_application["cadence"]["mode"] == "default"
    @test isempty(source_application["environmentInputs"])
    @test isempty(source_application["environmentOutputs"])
    @test isempty(source_application["updates"])
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
    @test JSON.parse(json)["schemaVersion"] == 2

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
    @test length(view.templates) == 1
    @test only(view.templates)["source"] == "model"
    @test Set(only(view.templates)["mountedInstances"]) == Set(["plant_a", "plant_b"])
    @test Set(instance["name"] for instance in view.instances) == Set(["plant_a", "plant_b"])
    @test all(instance["templateId"] == only(view.templates)["id"] for instance in view.instances)
    @test all(instance["objectOverrides"] isa Vector for instance in view.instances)
    @test Set(application["applicationId"] for application in view.applications) ==
          Set(["plant_a__source", "plant_b__source"])
    plant_b_application = only(
        application for application in view.applications
        if application["applicationId"] == "plant_b__source"
    )
    @test plant_b_application["modelParameters"]["coefficient"]["value"] == 3.0
    @test plant_b_application["targetIds"] == ["leaf_b"]
    @test plant_b_application["owner"]["scope"] == "template"
    @test plant_b_application["owner"]["applicationId"] == "source"
    @test any(edge -> edge["kind"] == "template_mount", view.edges)
end

@testset "CompositeModel graph schema v2 catalogs and environments" begin
    template = CompositeModelTemplate((
        ModelSpec(ModelGraphSourceModel(); name=:source, on=Many(scale=:Leaf), every=Dates.Hour(1)),
    ); kind=:plant, species=:test_species)
    weather = ModelGraphWeatherBackend()
    model = CompositeModel(
        ObjectInstance(
            :plant,
            template;
            root=Object(:plant; name=:plant, scale=:Plant),
            objects=(Object(:leaf; scale=:Leaf, parent=:plant, status=Status(driver=1.0)),),
        );
        environment=weather,
    )
    view = model_graph_view(
        model;
        templates=(oil_palm=template,),
        environments=(weather=weather, canopy=ModelGraphCanopyBackend()),
    )

    @test view.metadata["sceneEnvironmentId"] == "environment:weather"
    @test only(view.instances)["templateId"] == "catalog:oil_palm"
    @test only(view.templates)["source"] == "catalog"
    @test Set(environment["id"] for environment in view.environments) ==
          Set(["environment:weather", "environment:canopy"])
    active = only(environment for environment in view.environments if environment["active"])
    @test active["variables"] == ["RH", "T"]
    application = only(view.applications)
    @test application["owner"]["applicationId"] == "source"
    @test application["cadence"]["mode"] == "period"
    @test application["cadence"]["unit"] == "Hour"
    @test application["cadence"]["value"] == 1
end

@testset "CompositeModel template bindings stay instance-local" begin
    template = CompositeModelTemplate((
        ModelSpec(ModelGraphSourceModel(); name=:source, on=Many(scale=:Leaf)),
        ModelSpec(ModelGraphConsumerModel(); name=:consumer, on=Many(scale=:Leaf)),
    ))
    model = CompositeModel(
        ObjectInstance(
            :plant_a,
            template;
            root=Object(:plant_a; name=:plant_a, scale=:Plant),
            objects=(Object(:leaf_a; scale=:Leaf, parent=:plant_a, status=Status(driver=1.0)),),
        ),
        ObjectInstance(
            :plant_b,
            template;
            root=Object(:plant_b; name=:plant_b, scale=:Plant),
            objects=(Object(:leaf_b; scale=:Leaf, parent=:plant_b, status=Status(driver=1.0)),),
        ),
    )
    report = compile_model_report(model)
    bindings = [binding for binding in report.input_bindings if binding.input == :signal]

    @test length(bindings) == 2
    @test all(length(binding.source_ids) == 1 for binding in bindings)
    @test Set((binding.consumer_id.value, only(binding.source_ids).value) for binding in bindings) ==
          Set([(:leaf_a, :leaf_a), (:leaf_b, :leaf_b)])
    @test Set(only(binding.source_application_ids) for binding in bindings) ==
          Set([:plant_a__source, :plant_b__source])
end

@testset "CompositeModel graph resolves selector multiplicity globally and per template" begin
    global_model = CompositeModel(
        Object(:plant; name=:plant, scale=:Plant, status=Status(driver=1.0)),
        Object(:leaf_1; scale=:Leaf, parent=:plant, status=Status(driver=1.0)),
        Object(:leaf_2; scale=:Leaf, parent=:plant, status=Status(driver=1.0));
        applications=(
            ModelSpec(ModelGraphSourceModel(); name=:one, on=One(scale=:Plant)),
            ModelSpec(ModelGraphSourceModel(); name=:optional, on=OptionalOne(scale=:Flower)),
            ModelSpec(ModelGraphSourceModel(); name=:many, on=Many(scale=:Leaf)),
        ),
    )
    global_counts = Dict(
        application["applicationId"] => application["targetCount"]
        for application in model_graph_view(global_model).applications
    )
    @test global_counts == Dict("one" => 1, "optional" => 0, "many" => 2)

    template = CompositeModelTemplate((
        ModelSpec(ModelGraphSourceModel(); name=:one, on=One(scale=:Plant)),
        ModelSpec(ModelGraphSourceModel(); name=:optional, on=OptionalOne(scale=:Flower)),
        ModelSpec(ModelGraphSourceModel(); name=:many, on=Many(scale=:Leaf)),
    ))
    template_model = CompositeModel(
        ObjectInstance(
            :plant_a,
            template;
            root=Object(:plant_a; name=:plant_a, scale=:Plant, status=Status(driver=1.0)),
            objects=(
                Object(:leaf_a_1; scale=:Leaf, parent=:plant_a, status=Status(driver=1.0)),
                Object(:leaf_a_2; scale=:Leaf, parent=:plant_a, status=Status(driver=1.0)),
            ),
        ),
        ObjectInstance(
            :plant_b,
            template;
            root=Object(:plant_b; name=:plant_b, scale=:Plant, status=Status(driver=1.0)),
            objects=(Object(:leaf_b; scale=:Leaf, parent=:plant_b, status=Status(driver=1.0)),),
        ),
    )
    template_counts = Dict(
        application["applicationId"] => application["targetCount"]
        for application in model_graph_view(template_model).applications
    )
    @test template_counts == Dict(
        "plant_a__one" => 1,
        "plant_a__optional" => 0,
        "plant_a__many" => 2,
        "plant_b__one" => 1,
        "plant_b__optional" => 0,
        "plant_b__many" => 1,
    )
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
        ReplaceModelApplicationModel(model_graph_global(:source), ModelGraphSourceModel(4.0)),
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
        RemoveModelApplication(model_graph_global(:source)),
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
        MarkModelPreviousTimeStep(model_graph_global(:cycle_a), :y),
    )
    broken_view = model_graph_view(broken)
    @test !broken_view.metadata["cyclic"]
    @test any(edge -> edge["kind"] == "previous_timestep", broken_view.edges)

    restored = apply_model_graph_edit(
        broken,
        UnmarkModelPreviousTimeStep(model_graph_global(:cycle_a), :y),
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
        MarkModelPreviousTimeStep(model_graph_global(:cycle_a), :y),
    )
    lagged_row = only(
        row for row in model_graph_view(lagged_without_initial_value).initialization
        if row["applicationId"] == "cycle_a" && row["variable"] == "y"
    )
    @test lagged_row["previousTimeStep"]
    @test lagged_row["disposition"] == "required"
    initialized_break = apply_model_graph_edit(
        initialized_scene,
        BreakModelCycle(model_graph_global(:cycle_a), :y, true, 0.25),
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
        SetModelApplicationEnvironment(model_graph_global(:source), (provider=:model, sources=(T=:temperature,))),
    )
    configured = apply_model_graph_edit(
        configured,
        SetModelOutputRouting(model_graph_global(:source), :signal, :stream_only),
    )
    configured = apply_model_graph_edit(
        configured,
        SetModelUpdateOrdering(model_graph_global(:source), (Updates(:signal; after=:driver),)),
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
        SetModelApplicationTargets(model_graph_global(:consumer), OptionalOne(name=:consumer_object)),
    )
    configured = apply_model_graph_edit(
        configured,
        SetModelInputBinding(
            model_graph_global(:consumer),
            :signal,
            One(name=:source_object, application=:source, var=:signal),
        ),
    )
    configured = apply_model_graph_edit(
        configured,
        SetModelCallBinding(
            model_graph_global(:consumer),
            :source_call,
            One(name=:source_object, application=:source),
        ),
    )
    configured = apply_model_graph_edit(
        configured,
        SetModelApplicationCadence(model_graph_global(:consumer), Dates.Hour(2)),
    )
    configured = apply_model_graph_edit(
        configured,
        SetModelUpdateOrdering(model_graph_global(:consumer), (Updates(:result; after=:source),)),
    )

    consumer = PlantSimEngine._model_edit_spec(configured, model_graph_global(:consumer))
    @test applies_to(consumer) isa OptionalOne
    @test PlantSimEngine.criteria(value_inputs(consumer).signal).application == :source
    @test PlantSimEngine.criteria(model_calls(consumer).source_call).application == :source
    @test consumer.timestep == Dates.Hour(2)
    consumer_view = only(
        application for application in model_graph_view(configured).applications
        if application["applicationId"] == "consumer"
    )
    @test haskey(consumer_view["inputBindings"], "signal")
    @test haskey(consumer_view["callBindings"], "source_call")

    renamed = apply_model_graph_edit(configured, RenameModelApplication(model_graph_global(:source), :driver_source))
    renamed_consumer = PlantSimEngine._model_edit_spec(renamed, model_graph_global(:consumer))
    @test PlantSimEngine.criteria(value_inputs(renamed_consumer).signal).application == :driver_source
    @test PlantSimEngine.criteria(model_calls(renamed_consumer).source_call).application == :driver_source
    @test PlantSimEngine._update_after(only(updates(renamed_consumer))) == (:driver_source,)
    @test_throws "already exists" apply_model_graph_edit(
        renamed,
        RenameModelApplication(model_graph_global(:driver_source), :consumer),
    )

    without_input = apply_model_graph_edit(
        renamed,
        RemoveModelInputBinding(model_graph_global(:consumer), :signal),
    )
    @test isempty(value_inputs(PlantSimEngine._model_edit_spec(without_input, model_graph_global(:consumer))))
    without_call = apply_model_graph_edit(
        without_input,
        RemoveModelCallBinding(model_graph_global(:consumer), :source_call),
    )
    @test isempty(model_calls(PlantSimEngine._model_edit_spec(without_call, model_graph_global(:consumer))))

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


@testset "CompositeModel global rename rewrites shared template declarations" begin
    template = CompositeModelTemplate((
        ModelSpec(
            ModelGraphConsumerModel();
            name=:consumer,
            on=Many(scale=:Leaf),
            inputs=(signal=One(within=SceneScope(), application=:source, var=:signal),),
        ),
    ))
    model = CompositeModel(
        ObjectInstance(
            :plant,
            template;
            root=Object(:plant; name=:plant, scale=:Plant),
            objects=(Object(:leaf; scale=:Leaf, parent=:plant, status=Status(driver=1.0)),),
        );
        applications=(
            ModelSpec(ModelGraphSourceModel(); name=:source, on=One(name=:leaf)),
        ),
    )
    renamed = apply_model_graph_edit(
        model,
        RenameModelApplication(model_graph_global(:source), :renamed_source),
    )
    template_spec = PlantSimEngine.as_model_spec(
        only(only(renamed.instances).template.applications),
    )
    @test PlantSimEngine.criteria(value_inputs(template_spec).signal).application == :renamed_source
    mounted_spec = PlantSimEngine._model_edit_spec(
        renamed,
        model_graph_template(:plant, :consumer),
    )
    @test PlantSimEngine.criteria(value_inputs(mounted_spec).signal).application == :renamed_source
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
        UpdateModelApplication(
            model_graph_template(:plant_a, :source),
            ModelGraphSourceModel(4.0),
            :source,
            Many(scale=:Leaf),
            Dates.Hour(2),
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
    @test all(
        application["cadence"]["mode"] == "period" &&
        application["cadence"]["unit"] == "Hour" &&
        application["cadence"]["value"] == 2
        for application in applications
    )
    @test all(
        application["modelParameters"]["coefficient"]["value"] == 1.0
        for application in model_graph_view(model).applications
    )

    preset_view = model_graph_view(updated; templates=(preset=first(model.instances).template,))
    @test Set(template["source"] for template in preset_view.templates) == Set(["catalog", "model"])
    @test isempty(only(template for template in preset_view.templates if template["source"] == "catalog")["mountedInstances"])
    @test Set(only(template for template in preset_view.templates if template["source"] == "model")["mountedInstances"]) ==
          Set(["plant_a", "plant_b"])
end


@testset "CompositeModel graph instance transactions retain object subtrees" begin
    template = CompositeModelTemplate((
        ModelSpec(ModelGraphSourceModel(); name=:source, on=Many(scale=:Leaf)),
    ))
    base = CompositeModel(
        Object(:plant; name=:plant, scale=:Plant),
        Object(:leaf; scale=:Leaf, parent=:plant, status=Status(driver=1.0)),
    )
    mounted = apply_model_graph_edit(base, AddModelInstance(:plant, template, :plant))
    @test length(mounted.instances) == 1
    @test Set(object.id for object in model_objects(mounted)) == Set([ObjectId(:plant), ObjectId(:leaf)])
    @test only(model_graph_view(mounted).applications)["targetIds"] == ["leaf"]
    @test isempty(base.instances)

    atomic = apply_model_graph_edit(
        CompositeModel(),
        AddModelInstance(
            :new_plant,
            template,
            :new_plant;
            root_object=Object(:new_plant; name=:new_plant, scale=:Plant, kind=:plant),
        ),
    )
    @test only(atomic.instances).name == :new_plant
    @test ObjectId(:new_plant) in object_ids(atomic)

    unmounted = apply_model_graph_edit(mounted, RemoveModelInstance(:plant))
    @test isempty(unmounted.instances)
    @test isempty(unmounted.applications)
    @test Set(object.id for object in model_objects(unmounted)) == Set([ObjectId(:plant), ObjectId(:leaf)])
    @test_throws "Unmount object instance" apply_model_graph_edit(
        mounted,
        RemoveModelObject(:plant),
    )
    @test_throws "must keep the instance name" apply_model_graph_edit(
        mounted,
        SetModelObjectMetadata(:plant; name=:renamed_root),
    )

    @test_throws Exception apply_model_graph_edit(
        mounted,
        AddModelInstance(:overlap, template, :leaf),
    )
    @test length(mounted.instances) == 1

    two_plants = model_graph_override_fixture()
    @test_throws "ownership boundary" apply_model_graph_edit(
        two_plants,
        ReparentModelObject(:leaf_a, :plant_b),
    )
    @test PlantSimEngine._model_object(two_plants, ObjectId(:leaf_a)).parent == ObjectId(:plant_a)
end


@testset "CompositeModel graph replaces scene environment transactionally" begin
    model = CompositeModel(
        Object(:leaf; name=:leaf, scale=:Leaf, status=Status(driver=1.0));
        applications=(ModelSpec(ModelGraphSourceModel(); name=:source, on=One(name=:leaf)),),
        environment=ModelGraphWeatherBackend(),
    )
    changed = apply_model_graph_edit(
        model,
        SetCompositeModelEnvironment(ModelGraphCanopyBackend()),
    )
    @test changed.environment isa ModelGraphCanopyBackend
    @test model.environment isa ModelGraphWeatherBackend
    @test length(changed.applications) == 1
    @test length(model_objects(changed)) == 1
end
