abstract type AbstractEditorSourceModel <: PlantSimEngine.AbstractModel end
abstract type AbstractEditorConsumerModel <: PlantSimEngine.AbstractModel end
PlantSimEngine.process_(::Type{AbstractEditorSourceModel}) = :editor_source
PlantSimEngine.process_(::Type{AbstractEditorConsumerModel}) = :editor_consumer

struct EditorSourceModel <: AbstractEditorSourceModel end
PlantSimEngine.inputs_(::EditorSourceModel) = (driver=Required(Float64),)
PlantSimEngine.outputs_(::EditorSourceModel) = (signal=-Inf,)

struct EditorConsumerModel <: AbstractEditorConsumerModel end
PlantSimEngine.inputs_(::EditorConsumerModel) = (signal=Required(Float64),)
PlantSimEngine.outputs_(::EditorConsumerModel) = (result=-Inf,)

struct EditorEnvironmentBackend <: PlantSimEngine.EnvironmentAPI.AbstractEnvironmentBackend
    name::Symbol
end
PlantSimEngine.EnvironmentAPI.environment_variables(::EditorEnvironmentBackend) = (:T, :RH)
PlantSimEngine.EnvironmentAPI.base_step_seconds(::EditorEnvironmentBackend) = 3600.0
PlantSimEngine.EnvironmentAPI.get_nsteps(::EditorEnvironmentBackend) = 1

editor_global_ref(application_id) = Dict(
    "scope" => "global",
    "applicationId" => string(application_id),
    "instance" => nothing,
)

editor_template_ref(instance, application_id) = Dict(
    "scope" => "template",
    "applicationId" => string(application_id),
    "instance" => string(instance),
)

@testset "session lifecycle and edits" begin
    model = CompositeModel(
        Object(:leaf; name=:leaf, scale=:Leaf, status=Status(driver=1.0));
        applications=(
            ModelSpec(EditorSourceModel(); name=:source, on=One(name=:leaf)),
        ),
    )
    session = edit_graph(model; port=0, open_browser=false, autosave=false)
    try
        @test current_model(session) !== model
        @test occursin("Open in browser:", sprint(show, MIME"text/plain"(), session))
        @test occursin("Quit session: close(session)", sprint(show, MIME"text/plain"(), session))

        health = HTTP.get("http://$(session.host):$(session.port)/health")
        @test health.status == 200
        @test JSON.parse(String(health.body))["ok"]

        state = HTTP.get("http://$(session.host):$(session.port)/state?token=$(session.token)")
        payload = JSON.parse(String(state.body))
        @test payload["ok"]
        @test payload["graph"]["metadata"]["applicationCount"] == 1
        @test occursin("model = CompositeModel", payload["modelCode"])

        static_view = HTTP.get("http://$(session.host):$(session.port)/static?token=$(session.token)")
        @test static_view.status == 200
        @test occursin("pse-model-graph-data", String(static_view.body))

        consumer_spec = ModelSpec(EditorConsumerModel(); name=:consumer, on=One(name=:leaf))
        apply_edit!(session, AddModelApplication(consumer_spec))
        @test length(current_model(session).applications) == 2
        @test !isempty(session.history)

        undo!(session)
        @test length(current_model(session).applications) == 1
        redo!(session)
        @test length(current_model(session).applications) == 2
    finally
        close(session)
    end
end


@testset "template and environment catalogs drive transactional commands" begin
    editor_extension = Base.get_extension(PlantSimEngine, :PlantSimEngineGraphEditorExt)
    template = CompositeModelTemplate((
        ModelSpec(EditorSourceModel(); name=:source, on=Many(scale=:Leaf)),
    ); kind=:plant, species=:test_species)
    weather = EditorEnvironmentBackend(:weather)
    canopy = EditorEnvironmentBackend(:canopy)
    model = CompositeModel(
        Object(:plant_a; name=:plant_a, scale=:Plant),
        Object(:leaf_a; scale=:Leaf, parent=:plant_a, status=Status(driver=1.0)),
        Object(:plant_b; name=:plant_b, scale=:Plant),
        Object(:leaf_b; scale=:Leaf, parent=:plant_b, status=Status(driver=1.0)),
    )
    @test_throws "catalog names must be symbols" edit_graph(
        model;
        templates=Dict("plant" => template),
        port=0,
        open_browser=false,
        autosave=false,
    )
    @test_throws "must be a CompositeModelTemplate" edit_graph(
        model;
        templates=(invalid=EditorSourceModel(),),
        port=0,
        open_browser=false,
        autosave=false,
    )
    output_path = joinpath(mktempdir(), "catalog-model.jl")
    session = edit_graph(
        model;
        templates=(plant=template,),
        environments=(weather=weather, canopy=canopy),
        save_path=output_path,
        port=0,
        open_browser=false,
        autosave=false,
    )
    try
        preview = editor_extension._handle_command!(session, Dict(
            "action" => "preview_instance",
            "name" => "plant_a",
            "templateId" => "catalog:plant",
            "rootId" => "plant_a",
        ))
        @test preview["ok"]
        @test Set(preview["instancePreview"]["objectIds"]) == Set(["plant_a", "leaf_a"])
        @test only(preview["instancePreview"]["applications"])["targetIds"] == ["leaf_a"]
        @test isempty(session.history)

        for plant in ("plant_a", "plant_b")
            response = editor_extension._handle_command!(session, Dict(
                "action" => "edit",
                "kind" => "add_instance",
                "name" => plant,
                "templateId" => "catalog:plant",
                "rootId" => plant,
            ))
            response["ok"] || error(join(response["diagnostics"], "\n"))
        end
        @test length(current_model(session).instances) == 2
        mounted_state = editor_extension._state_payload(session)["graph"]
        @test Set(application["owner"]["applicationId"] for application in mounted_state["applications"]) == Set(["source"])
        @test length(mounted_state["templates"]) == 1
        @test only(mounted_state["templates"])["source"] == "catalog"

        shared_preview = editor_extension._handle_command!(session, Dict(
            "action" => "preview_application_targets",
            "applicationRef" => editor_template_ref(:plant_a, :source),
            "selector" => Dict(
                "multiplicity" => "many",
                "criteria" => Dict("selectors" => Any[], "scale" => "Leaf"),
            ),
        ))
        @test shared_preview["ok"]
        @test shared_preview["targetPreview"]["count"] == 2
        @test Set(group["instance"] for group in shared_preview["targetPreview"]["groups"]) ==
              Set(["plant_a", "plant_b"])

        shared_update = editor_extension._handle_command!(session, Dict(
            "action" => "edit",
            "kind" => "update_application",
            "applicationRef" => editor_template_ref(:plant_a, :source),
            "name" => "source",
            "modelType" => string(EditorSourceModel),
            "parameters" => Dict(),
            "selector" => Dict(
                "multiplicity" => "many",
                "criteria" => Dict("selectors" => Any[], "scale" => "Leaf"),
            ),
            "cadence" => Dict("mode" => "period", "value" => 2, "unit" => "Hour"),
        ))
        shared_update["ok"] || error(join(shared_update["diagnostics"], "\n"))
        @test all(application["cadence"]["value"] == 2 for application in shared_update["graph"]["applications"])
        @test Set(template["source"] for template in shared_update["graph"]["templates"]) == Set(["catalog", "model"])

        environment_response = editor_extension._handle_command!(session, Dict(
            "action" => "edit",
            "kind" => "set_model_environment",
            "environmentId" => "environment:weather",
        ))
        environment_response["ok"] || error(join(environment_response["diagnostics"], "\n"))
        @test current_model(session).environment === weather
        @test environment_response["graph"]["metadata"]["sceneEnvironmentId"] == "environment:weather"

        application_environment = editor_extension._handle_command!(session, Dict(
            "action" => "edit",
            "kind" => "set_application_environment",
            "applicationRef" => editor_template_ref(:plant_a, :source),
            "configuration" => Dict(
                "backendId" => "environment:canopy",
                "provider" => "canopy_cells",
                "sources" => Dict(),
                "sink" => "canopy_state",
                "extra" => Dict("layer" => Dict("type" => "integer", "value" => "2")),
            ),
        ))
        application_environment["ok"] || error(join(application_environment["diagnostics"], "\n"))
        @test all(
            application["environment"]["backendId"] == "environment:canopy"
            for application in application_environment["graph"]["applications"]
        )

        code = read(output_path, String)
        @test occursin("Requires `editor_environments`", code)
        @test occursin("editor_environments.weather", code)
        @test occursin("editor_environments.canopy", code)
        portable_template = CompositeModelTemplate((
            ModelSpec(PlantSimEngine.Examples.ToyPlantRmModel(); name=:maintenance, on=Many(scale=:Leaf)),
        ))
        portable_model = CompositeModel(
            ObjectInstance(
                :portable_plant,
                portable_template;
                root=Object(:portable_plant; name=:portable_plant, scale=:Plant),
                objects=(Object(:portable_leaf; scale=:Leaf, parent=:portable_plant),),
            );
            environment=weather,
        )
        portable_path = joinpath(mktempdir(), "portable-catalog-model.jl")
        portable_session = edit_graph(
            portable_model;
            environments=(weather=weather, canopy=canopy),
            save_path=portable_path,
            port=0,
            open_browser=false,
            autosave=false,
        )
        close(portable_session)
        @test_throws "requires environment catalog keys" edit_graph(
            ;
            recover_path=portable_path,
            port=0,
            open_browser=false,
            autosave=false,
        )
        reopened = edit_graph(
            ;
            environments=(weather=weather, canopy=canopy),
            recover_path=portable_path,
            port=0,
            open_browser=false,
            autosave=false,
        )
        try
            @test reopened.model.environment === weather
            @test length(reopened.model.instances) == 1
            @test only(reopened.model.instances).name == :portable_plant
        finally
            close(reopened)
        end

        remove_response = editor_extension._handle_command!(session, Dict(
            "action" => "edit",
            "kind" => "remove_instance",
            "name" => "plant_b",
        ))
        @test remove_response["ok"]
        @test ObjectId(:plant_b) in object_ids(current_model(session))
        @test ObjectId(:leaf_b) in object_ids(current_model(session))
        undo!(session)
        @test length(current_model(session).instances) == 2
        redo!(session)
        @test length(current_model(session).instances) == 1
    finally
        close(session)
    end
end

@testset "empty session and automatic save" begin
    output_path = joinpath(mktempdir(), "model.generated.jl")
    session = edit_graph(
        ;
        port=0,
        open_browser=false,
        autosave=true,
        save_path=output_path,
    )
    try
        @test isempty(current_model(session).applications)
        @test isfile(output_path)
        before = read(output_path, String)
        @test occursin("model = CompositeModel", before)

        apply_edit!(session, AddModelObject(Object(:plant; name=:plant, scale=:Plant)))
        after = read(output_path, String)
        @test after != before
        @test occursin("Object(:plant", after)
        @test !isnothing(session.autosave_path)
        @test isfile(session.autosave_path)
        @test output_path in session.recent_paths

        snapshot_path = joinpath(mktempdir(), "saved-model.jl")
        write(snapshot_path, Base.get_extension(PlantSimEngine, :PlantSimEngineGraphEditorExt)._model_to_julia(session))
        apply_edit!(session, AddModelObject(Object(:soil; name=:soil, scale=:Soil)))
        @test length(model_objects(current_model(session))) == 2
        response = Base.get_extension(PlantSimEngine, :PlantSimEngineGraphEditorExt)._handle_command!(session, Dict(
            "action" => "open_model_code",
            "path" => snapshot_path,
        ))
        response["ok"] || error(join(response["diagnostics"], "\n"))
        @test response["ok"]
        @test length(model_objects(current_model(session))) == 1
        @test session.save_path == snapshot_path
        @test first(session.recent_paths) == snapshot_path

        reopened = edit_graph(; port=0, open_browser=false, autosave=false)
        try
            @test snapshot_path in reopened.recent_paths
        finally
            close(reopened)
        end
        recovered = edit_graph(
            ;
            port=0,
            open_browser=false,
            autosave=false,
            recover_path=snapshot_path,
        )
        try
            @test length(model_objects(current_model(recovered))) == 1
        finally
            close(recovered)
        end
    finally
        close(session)
    end
end


@testset "JSON editor commands round-trip through Julia" begin
    editor_extension = Base.get_extension(PlantSimEngine, :PlantSimEngineGraphEditorExt)
    @test !isnothing(editor_extension)
    session = edit_graph(; port=0, open_browser=false, autosave=false)
    try
        object_response = editor_extension._handle_command!(session, Dict(
            "action" => "edit",
            "kind" => "add_object",
            "objectId" => "leaf",
            "configuration" => Dict(
                "scale" => "Leaf",
                "kind" => "organ",
                "species" => nothing,
                "name" => "leaf",
                "parent" => nothing,
            ),
        ))
        @test object_response["ok"]
        @test length(model_objects(current_model(session))) == 1

        target_history_length = length(session.history)
        target_preview = editor_extension._handle_command!(session, Dict(
            "action" => "preview_application_targets",
            "selector" => Dict(
                "multiplicity" => "many",
                "criteria" => Dict(
                    "selectors" => Any[],
                    "within" => Dict("type" => "SceneScope"),
                    "scale" => "Leaf",
                ),
            ),
        ))
        @test target_preview["ok"]
        @test target_preview["targetPreview"]["count"] == 1
        @test target_preview["targetPreview"]["objectIds"] == ["leaf"]
        @test length(session.history) == target_history_length

        source_response = editor_extension._handle_command!(session, Dict(
            "action" => "edit",
            "kind" => "add_application",
            "name" => "source",
            "modelType" => string(EditorSourceModel),
            "parameters" => Dict(),
            "selector" => Dict(
                "multiplicity" => "one",
                "criteria" => Dict(
                    "selectors" => Any[],
                    "scale" => "Leaf",
                ),
            ),
            "cadence" => Dict("mode" => "default"),
        ))
        @test source_response["ok"]

        environment_response = editor_extension._handle_command!(session, Dict(
            "action" => "edit",
            "kind" => "set_application_environment",
            "applicationRef" => editor_global_ref(:source),
            "configuration" => Dict(
                "backendId" => "scene",
                "provider" => "model",
                "sources" => Dict(),
                "sink" => nothing,
                "extra" => Dict(),
            ),
        ))
        @test environment_response["ok"]
        source_application = only(
            PlantSimEngine.as_model_spec(spec) for spec in current_model(session).applications
            if application_name(PlantSimEngine.as_model_spec(spec)) == :source
        )
        @test environment_config(source_application).config.provider == :model

        routing_response = editor_extension._handle_command!(session, Dict(
            "action" => "edit",
            "kind" => "set_output_routing",
            "applicationRef" => editor_global_ref(:source),
            "output" => "signal",
            "route" => "stream_only",
        ))
        @test routing_response["ok"]
        @test only(
            application for application in routing_response["graph"]["applications"]
            if application["applicationId"] == "source"
        )["outputRouting"]["signal"] == "stream_only"

        consumer_response = editor_extension._handle_command!(session, Dict(
            "action" => "edit",
            "kind" => "add_application",
            "name" => "consumer",
            "modelType" => string(EditorConsumerModel),
            "parameters" => Dict(),
            "selector" => Dict(
                "multiplicity" => "one",
                "criteria" => Dict("selectors" => Any[], "name" => "leaf"),
            ),
            "cadence" => Dict("mode" => "period", "value" => 2, "unit" => "Hour"),
        ))
        @test consumer_response["ok"]

        call_selector = Dict(
            "multiplicity" => "one",
            "criteria" => Dict(
                "selectors" => Any[],
                "within" => Dict("type" => "Self"),
                "application" => "source",
            ),
        )
        call_response = editor_extension._handle_command!(session, Dict(
            "action" => "edit",
            "kind" => "set_call_binding",
            "applicationRef" => editor_global_ref(:consumer),
            "call" => "source_call",
            "selector" => call_selector,
        ))
        @test call_response["ok"]
        @test call_response["graph"]["metadata"]["callCount"] == 1
        remove_call_response = editor_extension._handle_command!(session, Dict(
            "action" => "edit",
            "kind" => "remove_call_binding",
            "applicationRef" => editor_global_ref(:consumer),
            "call" => "source_call",
        ))
        @test remove_call_response["ok"]
        @test remove_call_response["graph"]["metadata"]["callCount"] == 0

        binding_command = Dict(
            "applicationRef" => editor_global_ref(:consumer),
            "input" => "signal",
            "selector" => Dict(
                "multiplicity" => "one",
                "criteria" => Dict(
                    "selectors" => Any[],
                    "within" => Dict("type" => "Self"),
                    "application" => "source",
                    "var" => "signal",
                    "policy" => Dict("type" => "HoldLast"),
                ),
            ),
        )
        history_length = length(session.history)
        preview_response = editor_extension._handle_command!(session, merge(
            binding_command,
            Dict("action" => "preview_input_binding"),
        ))
        @test preview_response["ok"]
        @test preview_response["selectorPreview"]["bindingCount"] == 1
        @test preview_response["selectorPreview"]["consumerObjectIds"] == ["leaf"]
        @test preview_response["selectorPreview"]["sourceObjectIds"] == ["leaf"]
        @test preview_response["selectorPreview"]["sourceApplicationIds"] == ["source"]
        @test length(session.history) == history_length
        consumer_before = only(
            PlantSimEngine.as_model_spec(spec) for spec in current_model(session).applications
            if application_name(PlantSimEngine.as_model_spec(spec)) == :consumer
        )
        @test isempty(consumer_before.inputs)

        binding_response = editor_extension._handle_command!(session, merge(
            binding_command,
            Dict("action" => "edit", "kind" => "set_input_binding"),
        ))
        @test binding_response["ok"]
        @test binding_response["graph"]["metadata"]["bindingCount"] == 1
        @test binding_response["graph"]["metadata"]["applicationCount"] == 2

        status_response = editor_extension._handle_command!(session, Dict(
            "action" => "edit",
            "kind" => "set_object_statuses",
            "objectIds" => ["leaf"],
            "variable" => "driver",
            "value" => Dict("type" => "float", "value" => "3.5"),
        ))
        @test status_response["ok"]
        @test only(model_objects(current_model(session))).status.driver == 3.5

        undo_response = editor_extension._handle_command!(session, Dict("action" => "undo"))
        @test undo_response["ok"]
        restored_status = only(model_objects(current_model(session))).status
        @test isnothing(restored_status) || !(:driver in propertynames(restored_status))
    finally
        close(session)
    end
end


@testset "generated Julia code reconstructs templates and overrides" begin
    editor_extension = Base.get_extension(PlantSimEngine, :PlantSimEngineGraphEditorExt)
    template = CompositeModelTemplate(
        (
            ModelSpec(EditorSourceModel(); name=:source, on=Many(scale=:Leaf), environment=Environment((provider=:model,)), output_routing=(signal=:stream_only,)),
        );
        kind=:plant,
        species=:test_species,
    )
    original = CompositeModel(
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
            overrides=(source=EditorSourceModel(),),
            object_overrides=(Override(object=:leaf_b, application=:source, model=EditorSourceModel()),),
        ),
    )
    session = edit_graph(original; port=0, open_browser=false, autosave=false)
    code = try
        editor_extension._model_to_julia(session)
    finally
        close(session)
    end
    @test occursin("defined in Main", code)
    @test occursin("template_1 = CompositeModelTemplate", code)
    @test occursin("instances = (", code)
    @test occursin("Override(", code)
    @test occursin("environment=Environment((provider = :model,))", code)
    @test occursin("output_routing=(signal = :stream_only,)", code)
    @test !occursin("ObjectModelOverrides", code)

    restored = Base.include_string(Main, code, "generated_model_editor_test.jl")
    original_view = model_graph_view(original)
    restored_view = model_graph_view(restored)
    @test restored_view.metadata["objectCount"] == original_view.metadata["objectCount"]
    @test restored_view.metadata["instanceCount"] == original_view.metadata["instanceCount"]
    @test Set(application["applicationId"] for application in restored_view.applications) ==
          Set(application["applicationId"] for application in original_view.applications)
    restored_source = PlantSimEngine.as_model_spec(first(first(restored.instances).template.applications))
    @test environment_config(restored_source).config == (provider=:model,)
    @test output_routing(restored_source) == (signal=:stream_only,)

    local_model = CompositeModel(Object(
        :local_leaf;
        name=:local_leaf,
        scale=:Leaf,
        status=Status(driver=1.0),
        applications=(
            ModelSpec(EditorSourceModel(); name=:local_source, on=One(name=:local_leaf)),
        ),
    ))
    local_session = edit_graph(local_model; port=0, open_browser=false, autosave=false)
    local_code = try
        editor_extension._model_to_julia(local_session)
    finally
        close(local_session)
    end
    @test occursin("applications=(ModelSpec", local_code)
    restored_local = Base.include_string(Main, local_code, "generated_local_model_editor_test.jl")
    restored_local_application = only(only(model_objects(restored_local)).applications)
    @test PlantSimEngine.application_name(
        PlantSimEngine.as_model_spec(restored_local_application),
    ) == :local_source
end
