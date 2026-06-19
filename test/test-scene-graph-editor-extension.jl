abstract type AbstractEditorSourceModel <: PlantSimEngine.AbstractModel end
abstract type AbstractEditorConsumerModel <: PlantSimEngine.AbstractModel end
PlantSimEngine.process_(::Type{AbstractEditorSourceModel}) = :editor_source
PlantSimEngine.process_(::Type{AbstractEditorConsumerModel}) = :editor_consumer

struct EditorSourceModel <: AbstractEditorSourceModel end
PlantSimEngine.inputs_(::EditorSourceModel) = (driver=-Inf,)
PlantSimEngine.outputs_(::EditorSourceModel) = (signal=-Inf,)

struct EditorConsumerModel <: AbstractEditorConsumerModel end
PlantSimEngine.inputs_(::EditorConsumerModel) = (signal=-Inf,)
PlantSimEngine.outputs_(::EditorConsumerModel) = (result=-Inf,)

@testset "session lifecycle and edits" begin
    scene = Scene(
        Object(:leaf; name=:leaf, scale=:Leaf, status=Status(driver=1.0));
        applications=(
            ModelSpec(EditorSourceModel(); name=:source) |>
                AppliesTo(One(name=:leaf)),
        ),
    )
    session = edit_graph(scene; port=0, open_browser=false, autosave=false)
    try
        @test current_scene(session) !== scene
        @test occursin("Open in browser:", sprint(show, MIME"text/plain"(), session))
        @test occursin("Quit session: close(session)", sprint(show, MIME"text/plain"(), session))

        health = HTTP.get("http://$(session.host):$(session.port)/health")
        @test health.status == 200
        @test JSON.parse(String(health.body))["ok"]

        state = HTTP.get("http://$(session.host):$(session.port)/state?token=$(session.token)")
        payload = JSON.parse(String(state.body))
        @test payload["ok"]
        @test payload["graph"]["metadata"]["applicationCount"] == 1
        @test occursin("scene = Scene", payload["sceneCode"])

        consumer_spec = ModelSpec(EditorConsumerModel(); name=:consumer) |>
                        AppliesTo(One(name=:leaf))
        apply_edit!(session, AddSceneApplication(consumer_spec))
        @test length(current_scene(session).applications) == 2
        @test !isempty(session.history)

        undo!(session)
        @test length(current_scene(session).applications) == 1
        redo!(session)
        @test length(current_scene(session).applications) == 2
    finally
        close(session)
    end
end

@testset "empty session and automatic save" begin
    output_path = joinpath(mktempdir(), "scene.generated.jl")
    session = edit_graph(
        ;
        port=0,
        open_browser=false,
        autosave=true,
        save_path=output_path,
    )
    try
        @test isempty(current_scene(session).applications)
        @test isfile(output_path)
        before = read(output_path, String)
        @test occursin("scene = Scene", before)

        apply_edit!(session, AddSceneObject(Object(:plant; name=:plant, scale=:Plant)))
        after = read(output_path, String)
        @test after != before
        @test occursin("Object(:plant", after)
        @test !isnothing(session.autosave_path)
        @test isfile(session.autosave_path)
        @test output_path in session.recent_paths

        snapshot_path = joinpath(mktempdir(), "saved-scene.jl")
        write(snapshot_path, Base.get_extension(PlantSimEngine, :PlantSimEngineGraphEditorExt)._scene_to_julia(current_scene(session)))
        apply_edit!(session, AddSceneObject(Object(:soil; name=:soil, scale=:Soil)))
        @test length(scene_objects(current_scene(session))) == 2
        response = Base.get_extension(PlantSimEngine, :PlantSimEngineGraphEditorExt)._handle_command!(session, Dict(
            "action" => "open_scene_code",
            "path" => snapshot_path,
        ))
        @test response["ok"]
        @test length(scene_objects(current_scene(session))) == 1
        @test session.save_path == snapshot_path
        @test first(session.recent_paths) == snapshot_path
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
        @test length(scene_objects(current_scene(session))) == 1

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

        binding_response = editor_extension._handle_command!(session, Dict(
            "action" => "edit",
            "kind" => "set_input_binding",
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
        @test only(scene_objects(current_scene(session))).status.driver == 3.5

        undo_response = editor_extension._handle_command!(session, Dict("action" => "undo"))
        @test undo_response["ok"]
        restored_status = only(scene_objects(current_scene(session))).status
        @test isnothing(restored_status) || !(:driver in propertynames(restored_status))
    finally
        close(session)
    end
end


@testset "generated Julia code reconstructs templates and overrides" begin
    editor_extension = Base.get_extension(PlantSimEngine, :PlantSimEngineGraphEditorExt)
    template = ObjectTemplate(
        (
            ModelSpec(EditorSourceModel(); name=:source) |>
                AppliesTo(Many(scale=:Leaf)),
        );
        kind=:plant,
        species=:test_species,
    )
    original = Scene(
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
    code = editor_extension._scene_to_julia(original)
    @test occursin("template_1 = ObjectTemplate", code)
    @test occursin("instances = (", code)
    @test occursin("Override(", code)
    @test !occursin("ObjectModelOverrides", code)

    restored = Base.include_string(Main, code, "generated_scene_editor_test.jl")
    original_view = scene_graph_view(original)
    restored_view = scene_graph_view(restored)
    @test restored_view.metadata["objectCount"] == original_view.metadata["objectCount"]
    @test restored_view.metadata["instanceCount"] == original_view.metadata["instanceCount"]
    @test Set(application["applicationId"] for application in restored_view.applications) ==
          Set(application["applicationId"] for application in original_view.applications)
end
