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

    updated = PlantSimEngine.apply_graph_edit(
        mapping_multiscale,
        PlantSimEngine.UpdateModel(:Default, :light_interception, :Default, Beer, (k=0.8,), ClockSpec(3.0, 1.0)),
    )
    updated_spec = PlantSimEngine.parse_model_specs(updated[:Default])[:light_interception]
    @test PlantSimEngine.model_(updated_spec).k == 0.8
    @test PlantSimEngine.timestep(updated_spec) == ClockSpec(3.0, 1.0)

    moved = PlantSimEngine.apply_graph_edit(
        updated,
        PlantSimEngine.UpdateModel(:Default, :light_interception, :Fruit, Beer, (k=0.9,), :default),
    )
    @test !haskey(PlantSimEngine.parse_model_specs(moved[:Default]), :light_interception)
    moved_spec = PlantSimEngine.parse_model_specs(moved[:Fruit])[:light_interception]
    @test PlantSimEngine.model_(moved_spec).k == 0.9
    @test isnothing(PlantSimEngine.timestep(moved_spec))

    rated = PlantSimEngine.apply_graph_edit(
        mapping_multiscale,
        PlantSimEngine.AddModel(:Fruit, ToyLAIModel, NamedTuple(), ClockSpec(2.0, 1.0)),
    )
    rated_spec = only(values(PlantSimEngine.parse_model_specs(rated[:Fruit])))
    @test PlantSimEngine.timestep(rated_spec) == ClockSpec(2.0, 1.0)
end

@testset "HTTP extension loading and WebSocket edits" begin
    @test Base.get_extension(PlantSimEngine, :PlantSimEngineGraphEditorExt) !== nothing

    blank_session = edit_graph(; port=0, open_browser=false, autosave=false)
    try
        blank_mapping = current_mapping(blank_session)
        @test blank_mapping isa ModelMapping{PlantSimEngine.MultiScale}
        @test isempty(keys(blank_mapping))

        blank_state_response = HTTP.get(string(blank_session.url, "/state"))
        @test blank_state_response.status == 200
        blank_state = PlantSimEngine.JSON.parse(String(blank_state_response.body))
        @test blank_state["ok"]
        @test blank_state["graph"]["nodes"] == Any[]
        @test blank_state["graph"]["edges"] == Any[]
        @test blank_state["graph"]["scales"] == Any["Default"]
        @test occursin("Add at least one model", blank_state["mappingCode"])

        apply_edit!(blank_session, PlantSimEngine.AddModel(:Default, ToyLAIModel, NamedTuple()))
        @test :Default in keys(current_mapping(blank_session))
        @test only(PlantSimEngine.get_models(current_mapping(blank_session)[:Default])) isa ToyLAIModel
    finally
        close(blank_session)
    end

    mapping = ModelMapping(
        :Leaf => (
            ToyLAIModel(),
            Beer(0.5),
            Status(TT_cu=1.0, LAI=2.0),
        ),
    )
    autosave_path = tempname() * ".jl"
    recent_file_path = tempname() * ".json"
    session = edit_graph(mapping; port=0, open_browser=false, autosave_path=autosave_path, recent_file_path=recent_file_path)

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
        @test state["autosavePath"] == autosave_path
        @test state["lastAutosavedPath"] == autosave_path
        @test isfile(autosave_path)
        @test state["recentMappings"] == Any[]
        @test startswith(state["mappingCode"], "using PlantSimEngine\n")
        @test occursin("using PlantSimEngine.Examples", state["mappingCode"])
        @test occursin("ModelMapping", state["mappingCode"])
        @test occursin("Status(TT_cu = 1.0)", state["mappingCode"])
        @test !occursin("LAI = 2.0", state["mappingCode"])
        @test haskey(state, "initializations")
        initial_tt = only(item for item in state["initializations"] if item["scale"] == "Leaf" && item["name"] == "TT_cu")
        @test initial_tt["provided"]
        @test initial_tt["value"] == "1.0"

        websocket_url = replace(session.url, "http://" => "ws://") * "/ws"
        HTTP.WebSockets.open(websocket_url) do ws
            initial = PlantSimEngine.JSON.parse(String(HTTP.WebSockets.receive(ws)))
            @test initial["ok"]
            @test haskey(initial, "graph")
            node = only(item for item in initial["graph"]["nodes"] if item["process"] == "light_interception")
            @test node["modelParameters"]["k"]["value"] == "0.5"

            init_command = PlantSimEngine.JSON.json(Dict(
                "action" => "edit",
                "kind" => "set_initialization",
                "scale" => "Leaf",
                "variable" => "TT_cu",
                "value" => Dict("type" => "float", "value" => "2.5"),
            ))
            HTTP.WebSockets.send(ws, init_command)
            initialized = PlantSimEngine.JSON.parse(String(HTTP.WebSockets.receive(ws)))
            @test initialized["ok"]
            leaf_status = only(item for item in current_mapping(session)[:Leaf] if item isa Status)
            @test leaf_status[:TT_cu] == 2.5
            @test occursin("Status(TT_cu = 2.5)", initialized["mappingCode"])

            update_command = PlantSimEngine.JSON.json(Dict(
                "action" => "edit",
                "kind" => "update_model",
                "scale" => "Leaf",
                "process" => "light_interception",
                "targetScale" => "Leaf",
                "modelType" => string(Beer),
                "parameters" => Dict("k" => Dict("type" => "float", "value" => "0.8")),
                "timestep" => Dict("mode" => "clock", "dt" => "3.0", "phase" => "1.0"),
            ))
            HTTP.WebSockets.send(ws, update_command)
            updated = PlantSimEngine.JSON.parse(String(HTTP.WebSockets.receive(ws)))
            @test updated["ok"]
            updated_spec = PlantSimEngine.parse_model_specs(current_mapping(session)[:Leaf])[:light_interception]
            @test PlantSimEngine.model_(updated_spec).k == 0.8
            @test PlantSimEngine.timestep(updated_spec) == ClockSpec(3.0, 1.0)

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

            add_degree_days = PlantSimEngine.JSON.json(Dict(
                "action" => "edit",
                "kind" => "add_model",
                "scale" => "Plant",
                "modelType" => string(ToyDegreeDaysCumulModel),
                "parameters" => Dict{String,Any}(),
            ))
            HTTP.WebSockets.send(ws, add_degree_days)
            degree_days_added = PlantSimEngine.JSON.parse(String(HTTP.WebSockets.receive(ws)))
            @test degree_days_added["ok"]

            set_mapped_tt = PlantSimEngine.JSON.json(Dict(
                "action" => "edit",
                "kind" => "set_mapped_variable",
                "scale" => "Leaf",
                "process" => "LAI_Dynamic",
                "variable" => "TT_cu",
                "sourceScale" => "Plant",
                "sourceVariable" => "TT_cu",
                "mode" => "single",
            ))
            HTTP.WebSockets.send(ws, set_mapped_tt)
            mapped_tt = PlantSimEngine.JSON.parse(String(HTTP.WebSockets.receive(ws)))
            @test mapped_tt["ok"]
            @test !occursin("TT_cu = 1.0", mapped_tt["mappingCode"])
            lai_spec = PlantSimEngine.parse_model_specs(current_mapping(session)[:Leaf])[:LAI_Dynamic]
            @test first(PlantSimEngine.mapped_variables_(lai_spec)) == (:TT_cu => (:Plant => :TT_cu))
            @test any(
                edge -> edge["kind"] == "mapped_variable" &&
                        edge["sourceVariable"] == "TT_cu" &&
                        edge["targetVariable"] == "TT_cu" &&
                        edge["scaleRelation"] == "multiscale",
                mapped_tt["graph"]["edges"],
            )

            output_path = tempname() * ".jl"
            save_code = PlantSimEngine.JSON.json(Dict(
                "action" => "write_mapping_code",
                "path" => output_path,
            ))
            HTTP.WebSockets.send(ws, save_code)
            saved = PlantSimEngine.JSON.parse(String(HTTP.WebSockets.receive(ws)))
            @test saved["ok"]
            @test saved["lastSavedPath"] == output_path
            @test saved["saveTargetPath"] == output_path
            @test output_path in saved["recentMappings"]
            @test isfile(recent_file_path)
            @test isfile(output_path)
            saved_code = read(output_path, String)
            @test startswith(saved_code, "using PlantSimEngine\n")
            @test occursin("using PlantSimEngine.Examples", saved_code)
            @test occursin("mapping = ModelMapping", saved_code)
            @test !occursin("LAI = 2.0", saved_code)
            @test !occursin("TT_cu = 1.0", saved_code)

            update_degree_days = PlantSimEngine.JSON.json(Dict(
                "action" => "edit",
                "kind" => "update_model",
                "scale" => "Plant",
                "process" => "Degreedays",
                "targetScale" => "Plant",
                "modelType" => string(ToyDegreeDaysCumulModel),
                "parameters" => Dict(
                    "init_TT" => Dict("type" => "float", "value" => "5.0"),
                    "T_base" => Dict("type" => "float", "value" => "1.0"),
                    "T_max" => Dict("type" => "float", "value" => "20.0"),
                ),
            ))
            HTTP.WebSockets.send(ws, update_degree_days)
            autosaved = PlantSimEngine.JSON.parse(String(HTTP.WebSockets.receive(ws)))
            @test autosaved["ok"]
            @test occursin("ToyDegreeDaysCumulModel(5.0, 1.0, 20.0)", read(output_path, String))
            @test occursin("ToyDegreeDaysCumulModel(5.0, 1.0, 20.0)", read(autosave_path, String))

            open_saved = PlantSimEngine.JSON.json(Dict(
                "action" => "open_mapping_code",
                "path" => output_path,
            ))
            HTTP.WebSockets.send(ws, open_saved)
            loaded = PlantSimEngine.JSON.parse(String(HTTP.WebSockets.receive(ws)))
            @test loaded["ok"]
            @test loaded["saveTargetPath"] == output_path
            @test current_mapping(session) isa ModelMapping{PlantSimEngine.MultiScale}
        end
    finally
        close(session)
    end
end
