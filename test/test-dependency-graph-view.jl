@testset "Dependency graph view" begin
    mapping = ModelMapping(
        ToyLAIModel(),
        Beer(0.5),
        ToyRUEGrowthModel(0.3);
        status=(TT_cu=[10.0, 20.0],)
    )

    view = graph_view(mapping)
    @test view isa DependencyGraphView
    @test length(view.nodes) == 3
    @test !isempty(view.edges)
    @test :Default in view.scales
    @test any(node -> node.process == :light_interception, view.nodes)
    @test any(edge -> edge.source_variable == :LAI && edge.target_variable == :LAI, view.edges)
    @test any(edge -> edge.source_variable == :aPPFD && edge.target_variable == :aPPFD, view.edges)

    json = graph_view_json(view)
    @test occursin("\"nodes\"", json)
    @test occursin("\"edges\"", json)
    @test occursin("ToyLAIModel", json)

    html_path = write_graph_view(joinpath(mktempdir(), "dependency_graph.html"), view)
    @test isfile(html_path)
    html = read(html_path, String)
    @test occursin("PlantSimEngine Dependency Graph", html)
    @test occursin("pse-graph-data", html)
    if isfile(joinpath(dirname(dirname(@__DIR__)), "frontend", "dist", ".vite", "manifest.json"))
        @test occursin("react-flow", html)
    end

    fallback_html_path = write_graph_view(joinpath(mktempdir(), "dependency_graph_fallback.html"), view; renderer=:standalone)
    @test isfile(fallback_html_path)
    fallback_html = read(fallback_html_path, String)
    @test occursin("PlantSimEngine Dependency Graph", fallback_html)
    @test occursin("canvas", fallback_html)

    multiscale_mapping = ModelMapping(
        :Plant => MultiScaleModel(
            model=ToyCAllocationModel(),
            mapped_variables=[
                :carbon_assimilation => [:Leaf],
                :carbon_demand => [:Leaf, :Internode],
                :carbon_allocation => [:Leaf, :Internode],
            ],
        ),
        :Internode => ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
        :Leaf => (
            MultiScaleModel(
                model=ToyAssimModel(),
                mapped_variables=[:soil_water_content => :Soil => :soil_water_content],
            ),
            ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            Status(aPPFD=1300.0, TT=10.0),
        ),
        :Soil => ToySoilWaterModel(),
    )

    multiscale_view = graph_view(multiscale_mapping)
    @test Set(multiscale_view.scales) == Set([:Plant, :Internode, :Leaf, :Soil])
    @test any(edge -> edge.scale_relation == :multiscale, multiscale_view.edges)
    @test any(edge -> edge.source_variable == :soil_water_content && edge.target_variable == :soil_water_content, multiscale_view.edges)

    edited_mapping = apply_graph_edit(
        multiscale_mapping,
        MarkPreviousTimeStep(:Leaf, :carbon_assimilation, :soil_water_content),
    )
    edited_view = graph_view(edited_mapping)
    @test !any(
        edge -> edge.source_variable == :soil_water_content &&
                edge.target_variable == :soil_water_content &&
                edge.source != edge.target,
        edited_view.edges,
    )
end
