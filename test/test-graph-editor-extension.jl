using HTTP

@testset "Graph edits after normalization to multiscale" begin
    # Single-scale mappings are normalized to multiscale at :Default when passed to edit_graph
    mapping_single = ModelMapping(
        ToyLAIModel(),
        Beer(0.5);
        status=(TT_cu=1.0:2.0, LAI=2.0, aPPFD=3.0),
    )

    # Simulate what edit_graph does: normalize single-scale to multiscale
    mapping_multiscale = PlantSimEngine.ModelMapping(:Default => mapping_single[:Default]; check=true)

    # Now test edits on the normalized multiscale mapping
    added = PlantSimEngine.apply_graph_edit(
        mapping_multiscale,
        PlantSimEngine.AddModel(:Default, ToyDegreeDaysCumulModel, (init_TT=0.0, T_base=0.0, T_max=40.0)),
    )
    models_at_default = PlantSimEngine.get_models(added[:Default])
    @test any(m -> PlantSimEngine.process(m) == :Degreedays, models_at_default)

    removed = PlantSimEngine.apply_graph_edit(
        added,
        PlantSimEngine.RemoveModel(:Default, :Degreedays),
    )
    models_after_remove = PlantSimEngine.get_models(removed[:Default])
    @test !any(m -> PlantSimEngine.process(m) == :Degreedays, models_after_remove)

    replaced = PlantSimEngine.apply_graph_edit(
        mapping_multiscale,
        PlantSimEngine.ReplaceModel(:Default, :light_interception, Beer, (k=0.7,)),
    )
    models_after_replace = PlantSimEngine.get_models(replaced[:Default])
    beer_model = first(m for m in models_after_replace if PlantSimEngine.process(m) == :light_interception)
    @test beer_model.k == 0.7

    rated = PlantSimEngine.apply_graph_edit(
        mapping_multiscale,
        PlantSimEngine.AddModel(:Fruit, ToyLAIModel, NamedTuple(), ClockSpec(2.0, 1.0)),
    )
    rated_spec = only(values(PlantSimEngine.parse_model_specs(rated[:Fruit])))
    @test PlantSimEngine.timestep(rated_spec) == ClockSpec(2.0, 1.0)
end

@testset "HTTP extension loading and WebSocket edits" begin
    @test Base.get_extension(PlantSimEngine, :PlantSimEngineGraphEditorExt) !== nothing

    mapping = ModelMapping(
        :Leaf => (
            ToyLAIModel(),
            Beer(0.5),
            Status(TT_cu=1.0, LAI=2.0),
        ),
    )
    session = edit_graph(mapping; port=0, open_browser=false)

    try
        @test session isa AbstractGraphEditorSession
        @test startswith(session.url, "http://127.0.0.1:")
        @test current_mapping(session) isa ModelMapping{PlantSimEngine.MultiScale}
        @test current_mapping(session)[:Leaf][1] == mapping[:Leaf][1]

        state_response = HTTP.get(string(session.url, "/state"))
        @test state_response.status == 200
        state = PlantSimEngine.JSON.parse(String(state_response.body))
        @test state["ok"]
        @test haskey(state, "graph")
        @test haskey(state, "models")
        @test haskey(state, "mappingCode")
        @test occursin("ModelMapping", state["mappingCode"])

        websocket_url = replace(session.url, "http://" => "ws://") * "/ws"
        HTTP.WebSockets.open(websocket_url) do ws
            initial = PlantSimEngine.JSON.parse(String(HTTP.WebSockets.receive(ws)))
            @test initial["ok"]
            @test haskey(initial, "graph")

            command = PlantSimEngine.JSON.json(Dict(
                "action" => "edit",
                "kind" => "remove_model",
                "scale" => "Leaf",
                "process" => "light_interception",
            ))
            HTTP.WebSockets.send(ws, command)

            response = PlantSimEngine.JSON.parse(String(HTTP.WebSockets.receive(ws)))
            @test response["ok"]
            @test response["canUndo"]
            @test !any(
                model -> process(model) == :light_interception,
                PlantSimEngine.get_models(current_mapping(session)[:Leaf]),
            )

            add_new_scale = PlantSimEngine.JSON.json(Dict(
                "action" => "edit",
                "kind" => "add_model",
                "scale" => "Fruit",
                "modelType" => string(ToyLAIModel),
                "parameters" => Dict{String,Any}(),
                "timestep" => Dict("mode" => "clock", "dt" => "2.0", "phase" => "1.0"),
            ))
            HTTP.WebSockets.send(ws, add_new_scale)
            added = PlantSimEngine.JSON.parse(String(HTTP.WebSockets.receive(ws)))
            @test added["ok"]
            @test :Fruit in keys(current_mapping(session))
            rated_spec = only(values(PlantSimEngine.parse_model_specs(current_mapping(session)[:Fruit])))
            @test PlantSimEngine.timestep(rated_spec) == ClockSpec(2.0, 1.0)
            @test occursin("TimeStepModel", added["mappingCode"])

            output_path = tempname() * ".jl"
            save_code = PlantSimEngine.JSON.json(Dict(
                "action" => "write_mapping_code",
                "path" => output_path,
            ))
            HTTP.WebSockets.send(ws, save_code)
            saved = PlantSimEngine.JSON.parse(String(HTTP.WebSockets.receive(ws)))
            @test saved["ok"]
            @test saved["lastSavedPath"] == output_path
            @test isfile(output_path)
            @test occursin("mapping = ModelMapping", read(output_path, String))
        end
    finally
        close(session)
    end
end
