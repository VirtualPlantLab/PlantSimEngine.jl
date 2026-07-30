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

@testset "session lifecycle and edits" begin
    model = CompositeModel(
        Object(:leaf; name=:leaf, scale=:Leaf, status=Status(driver=1.0));
        applications=(
            ModelSpec(EditorSourceModel(); name=:source) |>
                AppliesTo(One(name=:leaf)),
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

        consumer_spec = ModelSpec(EditorConsumerModel(); name=:consumer) |>
                        AppliesTo(One(name=:leaf))
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
        write(snapshot_path, Base.get_extension(PlantSimEngine, :PlantSimEngineGraphEditorExt)._model_to_julia(current_model(session)))
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
                    "selectors" => [Dict("type" => "Scale", "scale" => "Leaf")],
                ),
            ),
            "timestep" => Dict("mode" => "default"),
        ))
        @test source_response["ok"]

        environment_response = editor_extension._handle_command!(session, Dict(
            "action" => "edit",
            "kind" => "set_environment_provider",
            "applicationId" => "source",
            "provider" => "model",
        ))
        @test environment_response["ok"]
        source_application = only(
            PlantSimEngine.as_model_spec(spec) for spec in current_model(session).applications
            if application_name(PlantSimEngine.as_model_spec(spec)) == :source
        )
        @test environment_config(source_application).provider == :model

        routing_response = editor_extension._handle_command!(session, Dict(
            "action" => "edit",
            "kind" => "set_output_routing",
            "applicationId" => "source",
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
            "timestep" => Dict("mode" => "clock", "dt" => "2.0", "phase" => "0.0"),
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
            "applicationId" => "consumer",
            "call" => "source_call",
            "selector" => call_selector,
        ))
        @test call_response["ok"]
        @test call_response["graph"]["metadata"]["callCount"] == 1
        remove_call_response = editor_extension._handle_command!(session, Dict(
            "action" => "edit",
            "kind" => "remove_call_binding",
            "applicationId" => "consumer",
            "call" => "source_call",
        ))
        @test remove_call_response["ok"]
        @test remove_call_response["graph"]["metadata"]["callCount"] == 0

        binding_command = Dict(
            "applicationId" => "consumer",
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
            ModelSpec(EditorSourceModel(); name=:source) |>
                AppliesTo(Many(scale=:Leaf)) |>
                Environment((provider=:model,)) |>
                OutputRouting((signal=:stream_only,)),
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
    code = editor_extension._model_to_julia(original)
    @test occursin("defined in Main", code)
    @test occursin("template_1 = CompositeModelTemplate", code)
    @test occursin("instances = (", code)
    @test occursin("Override(", code)
    @test occursin("Environment((provider = :model,))", code)
    @test occursin("OutputRouting((signal = :stream_only,))", code)
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
            ModelSpec(EditorSourceModel(); name=:local_source) |>
                AppliesTo(One(name=:local_leaf)),
        ),
    ))
    local_code = editor_extension._model_to_julia(local_model)
    @test occursin("applications=(ModelSpec", local_code)
    restored_local = Base.include_string(Main, local_code, "generated_local_model_editor_test.jl")
    restored_local_application = only(only(model_objects(restored_local)).applications)
    @test PlantSimEngine.application_name(
        PlantSimEngine.as_model_spec(restored_local_application),
    ) == :local_source
end
