using HTTP

@testset "HTTP extension loading and WebSocket edits" begin
    @test Base.get_extension(PlantSimEngine, :PlantSimEngineGraphEditorExt) !== nothing

    mapping = ModelMapping(
        :Leaf => (
            ToyLAIModel(),
            Beer(0.5),
            Status(TT_cu=1.0, LAI=2.0),
        ),
    )
    session = edit_graph(mapping; port=0)

    try
        @test session isa AbstractGraphEditorSession
        @test startswith(session.url, "http://127.0.0.1:")
        @test current_mapping(session) === mapping

        state_response = HTTP.get(string(session.url, "/state"))
        @test state_response.status == 200
        state = PlantSimEngine.JSON.parse(String(state_response.body))
        @test state["ok"]
        @test haskey(state, "graph")
        @test haskey(state, "models")

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
        end
    finally
        close(session)
    end
end
