abstract type AbstractGraphViewPlantAgeModel <: PlantSimEngine.AbstractModel end
abstract type AbstractGraphViewPhytomerEmissionModel <: PlantSimEngine.AbstractModel end
abstract type AbstractGraphViewInitiationAgeModel <: PlantSimEngine.AbstractModel end
abstract type AbstractGraphViewParamModel <: PlantSimEngine.AbstractModel end
abstract type AbstractGraphViewCyclePlantModel <: PlantSimEngine.AbstractModel end
abstract type AbstractGraphViewCycleLeafModel <: PlantSimEngine.AbstractModel end

PlantSimEngine.process_(::Type{AbstractGraphViewPlantAgeModel}) = :graph_view_plant_age
PlantSimEngine.process_(::Type{AbstractGraphViewPhytomerEmissionModel}) = :graph_view_phytomer_emission
PlantSimEngine.process_(::Type{AbstractGraphViewInitiationAgeModel}) = :graph_view_initiation_age
PlantSimEngine.process_(::Type{AbstractGraphViewParamModel}) = :graph_view_param
PlantSimEngine.process_(::Type{AbstractGraphViewCyclePlantModel}) = :graph_view_cycle_plant
PlantSimEngine.process_(::Type{AbstractGraphViewCycleLeafModel}) = :graph_view_cycle_leaf

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

struct GraphViewParamModel{T} <: AbstractGraphViewParamModel
    a::T
    b::T
end

PlantSimEngine.inputs_(::GraphViewParamModel) = (x=-Inf,)
PlantSimEngine.outputs_(::GraphViewParamModel) = (y=-Inf,)

struct GraphViewDefaultParamModel <: AbstractGraphViewParamModel
    alpha::Float64
    mode::Symbol
end

GraphViewDefaultParamModel() = GraphViewDefaultParamModel(1.5, :fast)
PlantSimEngine.inputs_(::GraphViewDefaultParamModel) = (x=-Inf,)
PlantSimEngine.outputs_(::GraphViewDefaultParamModel) = (z=-Inf,)

struct GraphViewCyclePlantModel <: AbstractGraphViewCyclePlantModel
end

PlantSimEngine.inputs_(::GraphViewCyclePlantModel) = (y=-Inf,)
PlantSimEngine.outputs_(::GraphViewCyclePlantModel) = (x=-Inf,)

struct GraphViewCycleLeafModel <: AbstractGraphViewCycleLeafModel
end

PlantSimEngine.inputs_(::GraphViewCycleLeafModel) = (x=-Inf,)
PlantSimEngine.outputs_(::GraphViewCycleLeafModel) = (y=-Inf,)

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

    @test AbstractGraphViewParamModel in available_processes()
    @test GraphViewParamModel in available_models(:graph_view_param)
    descriptor = model_constructor_descriptor(GraphViewParamModel)
    fields = descriptor["fields"]
    @test length(fields) == 2
    @test fields[1]["typeParameter"] == "T"
    @test fields[2]["typeParameter"] == "T"
    @test descriptor["parameterGroups"]["T"] == ["a", "b"]
    @test fields[1]["inferredChoice"] == "float"

    default_descriptor = model_constructor_descriptor(GraphViewDefaultParamModel)
    default_fields = default_descriptor["fields"]
    @test default_descriptor["hasZeroArgConstructor"]
    @test default_fields[1]["default"] == 1.5
    @test default_fields[1]["inferredChoice"] == "float"
    @test default_fields[2]["default"] == ":fast"
    @test default_fields[2]["inferredChoice"] == "symbol"

    add_mapping = ModelMapping(:Plant => (GraphViewPlantAgeModel(), Status(day=1.0)))
    added_mapping = apply_graph_edit(add_mapping, AddModel(:Plant, GraphViewPhytomerEmissionModel, NamedTuple()))
    @test any(m -> process(m) == :graph_view_phytomer_emission, PlantSimEngine.get_models(added_mapping[:Plant]))
    @test_throws "already exists" apply_graph_edit(added_mapping, AddModel(:Plant, GraphViewPhytomerEmissionModel, NamedTuple()))
    removed_mapping = apply_graph_edit(added_mapping, RemoveModel(:Plant, :graph_view_phytomer_emission))
    @test !any(m -> process(m) == :graph_view_phytomer_emission, PlantSimEngine.get_models(removed_mapping[:Plant]))
    replaced_mapping = apply_graph_edit(add_mapping, ReplaceModel(:Plant, :graph_view_plant_age, GraphViewPlantAgeModel, NamedTuple()))
    @test only(PlantSimEngine.get_models(replaced_mapping[:Plant])) isa GraphViewPlantAgeModel

    mapped_edit_mapping = apply_graph_edit(
        hard_mapped_mapping,
        SetMappedVariable(:Phytomer, :graph_view_initiation_age, :plant_age, :Plant, :plant_age, :single),
    )
    mapped_spec = PlantSimEngine.parse_model_specs(mapped_edit_mapping[:Phytomer])[:graph_view_initiation_age]
    @test first(PlantSimEngine.mapped_variables_(mapped_spec)) == (:plant_age => (:Plant => :plant_age))

    vector_mapping = ModelMapping(
        :Leaf => (ToyAssimModel(), Status(aPPFD=1300.0)),
        :Soil => ToySoilWaterModel(),
        :Internode => ToySoilWaterModel(),
    )
    vector_edit_mapping = apply_graph_edit(
        vector_mapping,
        SetMappedVariable(
            :Leaf,
            :carbon_assimilation,
            :soil_water_content,
            :Soil,
            :soil_water_content,
            :multi,
            [:Internode],
        ),
    )
    vector_spec = PlantSimEngine.parse_model_specs(vector_edit_mapping[:Leaf])[:carbon_assimilation]
    vector_mapped_variable = first(PlantSimEngine.mapped_variables_(vector_spec))
    @test first(vector_mapped_variable) == :soil_water_content
    @test last(vector_mapped_variable) == [:Soil => :soil_water_content, :Internode => :soil_water_content]

    unmarked_mapping = apply_graph_edit(edited_mapping, UnmarkPreviousTimeStep(:Leaf, :carbon_assimilation, :soil_water_content))
    unmarked_view = graph_view(unmarked_mapping)
    @test any(
        edge -> edge.source_variable == :soil_water_content &&
                edge.target_variable == :soil_water_content &&
                edge.source != edge.target,
        unmarked_view.edges,
    )

    cyclic_mapping = ModelMapping(
        :Plant => MultiScaleModel(GraphViewCyclePlantModel(), [:y => [:Leaf]]),
        :Leaf => MultiScaleModel(GraphViewCycleLeafModel(), [:x => :Plant]),
    )
    @test_throws "Cyclic dependency detected" dep(cyclic_mapping)
    cyclic_view = graph_view(cyclic_mapping)
    @test cyclic_view.cyclic
    @test !isempty(cyclic_view.cycle_nodes)
    @test occursin("Cyclic dependency detected", join(cyclic_view.diagnostics, "\n"))
end
