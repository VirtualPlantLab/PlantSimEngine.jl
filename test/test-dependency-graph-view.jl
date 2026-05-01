abstract type AbstractGraphViewPlantAgeModel <: PlantSimEngine.AbstractModel end
abstract type AbstractGraphViewPhytomerEmissionModel <: PlantSimEngine.AbstractModel end
abstract type AbstractGraphViewInitiationAgeModel <: PlantSimEngine.AbstractModel end

PlantSimEngine.process_(::Type{AbstractGraphViewPlantAgeModel}) = :graph_view_plant_age
PlantSimEngine.process_(::Type{AbstractGraphViewPhytomerEmissionModel}) = :graph_view_phytomer_emission
PlantSimEngine.process_(::Type{AbstractGraphViewInitiationAgeModel}) = :graph_view_initiation_age

struct GraphViewPlantAgeModel <: AbstractGraphViewPlantAgeModel
end

PlantSimEngine.inputs_(::GraphViewPlantAgeModel) = (day=-Inf,)
PlantSimEngine.outputs_(::GraphViewPlantAgeModel) = (plant_age=-Inf,)

struct GraphViewPhytomerEmissionModel <: AbstractGraphViewPhytomerEmissionModel
end

PlantSimEngine.inputs_(::GraphViewPhytomerEmissionModel) = NamedTuple()
PlantSimEngine.outputs_(::GraphViewPhytomerEmissionModel) = (last_phytomer=-Inf,)
PlantSimEngine.dep(::GraphViewPhytomerEmissionModel) = (graph_view_initiation_age=AbstractGraphViewInitiationAgeModel => (:Phytomer,),)

struct GraphViewInitiationAgeModel <: AbstractGraphViewInitiationAgeModel
end

PlantSimEngine.inputs_(::GraphViewInitiationAgeModel) = (plant_age=-Inf,)
PlantSimEngine.outputs_(::GraphViewInitiationAgeModel) = (initiation_age=-Inf,)

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

    hard_mapped_mapping = ModelMapping(
        :Plant => (
            GraphViewPlantAgeModel(),
            GraphViewPhytomerEmissionModel(),
            Status(day=1.0),
        ),
        :Phytomer => MultiScaleModel(
            model=GraphViewInitiationAgeModel(),
            mapped_variables=[:plant_age => :Plant],
        ),
    )
    hard_mapped_view = graph_view(hard_mapped_mapping)
    initiation_node = only(node for node in hard_mapped_view.nodes if node.process == :graph_view_initiation_age && node.scale == :Phytomer)
    plant_age_input = only(port for port in initiation_node.inputs if port.name == :plant_age)
    plant_age_edges = [edge for edge in hard_mapped_view.edges if edge.target_port == plant_age_input.id]
    @test any(edge -> edge.kind == :mapped_variable && edge.source_variable == :plant_age && edge.target_variable == :plant_age, plant_age_edges)
    @test !any(edge -> edge.source_variable == :last_phytomer, plant_age_edges)
    @test any(edge -> edge.kind == :hard_dependency && isnothing(edge.source_port) && isnothing(edge.target_port), hard_mapped_view.edges)
end
