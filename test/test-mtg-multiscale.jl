
# Example meteo:
meteo = Weather(
    [
    Atmosphere(T=20.0, Wind=1.0, Rh=0.65),
    Atmosphere(T=25.0, Wind=0.5, Rh=0.8)
]
)


# Example MTG:

mtg = begin
    scene = Node(MultiScaleTreeGraph.NodeMTG("/", "Scene", 1, 0))
    soil = Node(scene, MultiScaleTreeGraph.NodeMTG("/", "Soil", 1, 1))
    plant = Node(scene, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1))
    internode1 = Node(plant, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
    leaf1 = Node(internode1, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))
    internode2 = Node(internode1, MultiScaleTreeGraph.NodeMTG("<", "Internode", 1, 2))
    leaf2 = Node(internode2, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))
    scene
end

# Testing with a simple mapping (just the soil model, no multiscale mapping):

@testset "run! on MTG: simple mapping" begin
    out = @test_nowarn run!(mtg, Dict("Soil" => (ToySoilWaterModel(),)), meteo)
    @test out.statuses["Soil"][1].node == soil
    @test out.models == Dict("Soil" => (soil_water=ToySoilWaterModel(0.1:0.1:1.0),))
    @test length(out.dependency_graph.roots) == 1
    @test collect(keys(out.dependency_graph.roots))[1] == Pair("Soil", :soil_water)
    @test out.graph == mtg

    leaf_mapping = Dict("Leaf" => (ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0), Status(TT=10.0)))
    out = run!(mtg, leaf_mapping, meteo)
    @test collect(keys(out.statuses)) == ["Leaf"]
    @test length(out.statuses["Leaf"]) == 2
    @test out.statuses["Leaf"][1].TT == 10.0 # As initialized in the mapping
    @test out.statuses["Leaf"][1].carbon_demand == 0.5

    @test out.statuses["Leaf"][1].node == leaf1
    @test out.statuses["Leaf"][2].node == leaf2
end

# A mapping with all different types of mapping (single, multi-scale, model as is, or tuple of):
@testset "run! on MTG with complete mapping (missing init)" begin
    mapping_all = Dict(
        "Plant" =>
            MultiScaleModel(
                model=ToyCAllocationModel(),
                mapping=[
                    # inputs
                    :A => ["Leaf"],
                    :carbon_demand => ["Leaf", "Internode"],
                    # outputs
                    :carbon_allocation => ["Leaf", "Internode"]
                ],
            ),
        "Internode" => ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
        "Leaf" => (
            MultiScaleModel(
                model=ToyAssimModel(),
                mapping=[:soil_water_content => "Soil",],
                # Notice we provide "Soil", not ["Soil"], so a single value is expected here
            ),
            ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            Status(aPPFD=1300.0, TT=10.0),
        ),
        "Soil" => (
            ToySoilWaterModel(),
        ),
    )
    # The mapping above should throw an error because TT is not initialized for the Internode:
    @test_throws "Nodes of type Internode need variable(s) TT to be initialized or computed by a model." run!(mtg, mapping_all, meteo)
    # It should work if we don't check the mapping though:
    out = @test_nowarn run!(mtg, mapping_all, meteo, check=false)
    # Note that the outputs are garbage because the TT is not initialized.

    @test out.models == Dict{String,NamedTuple}(
        "Soil" => (soil_water=ToySoilWaterModel(0.1:0.1:1.0),),
        "Internode" => (carbon_demand=ToyCDemandModel{Float64}(10.0, 200.0),),
        "Plant" => (carbon_allocation=ToyCAllocationModel(),),
        "Leaf" => (photosynthesis=ToyAssimModel{Float64}(0.2), carbon_demand=ToyCDemandModel{Float64}(10.0, 200.0))
    )

    @test length(out.dependency_graph.roots) == 3 # 3 because the plant is not a root (its model has dependencies)
    @test out.statuses["Internode"][1].TT === -Inf
    @test out.statuses["Internode"][1].carbon_demand === -Inf

    @test out.statuses["Leaf"][1].TT == 10.0
    @test out.statuses["Leaf"][1].carbon_demand == 0.5
    @test out.statuses["Leaf"][1].A == 260.0
    @test out.statuses["Leaf"][1].carbon_allocation == 0.0
end

# A mapping that actually works (same as before but with the init for TT):
mapping = Dict(
    "Plant" =>
        MultiScaleModel(
            model=ToyCAllocationModel(),
            mapping=[
                # inputs
                :A => ["Leaf"],
                :carbon_demand => ["Leaf", "Internode"],
                # outputs
                :carbon_allocation => ["Leaf", "Internode"]
            ],
        ),
    "Internode" => (
        ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
        Status(TT=10.0)
    ),
    "Leaf" => (
        MultiScaleModel(
            model=ToyAssimModel(),
            mapping=[:soil_water_content => "Soil",],
            # Notice we provide "Soil", not ["Soil"], so a single value is expected here
        ),
        ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
        Status(aPPFD=1300.0, TT=10.0),
    ),
    "Soil" => (
        ToySoilWaterModel(),
    ),
)

@testset "run! on MTG with complete mapping (with init)" begin
    out = @test_nowarn run!(mtg, mapping, meteo, executor=ThreadedEx())

    @test typeof(out.statuses) == Dict{String,Vector{Status}}
    @test length(out.statuses["Plant"]) == 1
    @test length(out.statuses["Leaf"]) == 2
    @test length(out.statuses["Internode"]) == 2
    @test length(out.statuses["Soil"]) == 1
    @test out.statuses["Soil"][1].node == soil
    @test out.statuses["Soil"][1].soil_water_content !== -Inf

    # Testing if the value in the status of the leaves is the same as the one in the status of the soil:
    @test out.statuses["Soil"][1].soil_water_content === out.statuses["Leaf"][1].soil_water_content
    @test out.statuses["Soil"][1].soil_water_content === out.statuses["Leaf"][2].soil_water_content

    leaf1_status = out.statuses["Leaf"][1]

    # This is the model that computes the assimilation (testing manually that we get the right result here):
    @test leaf1_status.A == leaf1_status.aPPFD * out.models["Leaf"].photosynthesis.LUE * leaf1_status.soil_water_content

    @test out.statuses["Plant"][1].carbon_demand[[1, 3]] == [i.carbon_demand for i in out.statuses["Internode"]]
    @test out.statuses["Plant"][1].carbon_demand[[2, 4]] == [i.carbon_demand for i in out.statuses["Leaf"]]

    # Testing the reference directly:
    ref_values_cdemand = getfield(out.statuses["Plant"][1].carbon_demand, :v)

    for (j, i) in enumerate([1, 3])
        @test ref_values_cdemand[i] === PlantSimEngine.refvalue(out.statuses["Internode"][j], :carbon_demand)
    end

    for (j, i) in enumerate([2, 4])
        @test ref_values_cdemand[i] === PlantSimEngine.refvalue(out.statuses["Leaf"][j], :carbon_demand)
    end

    # Testing that carbon allocation in Leaf and Internode was added as a variable from the model at the Plant scale:

    @test hasproperty(out.statuses["Internode"][1], :carbon_allocation)
    @test hasproperty(out.statuses["Leaf"][1], :carbon_allocation)

    @test out.statuses["Internode"][1].carbon_allocation == 0.5
    @test out.statuses["Leaf"][1].carbon_allocation == 0.5

    # Testing the reference directly:
    ref_values_callocation = getfield(out.statuses["Plant"][1].carbon_allocation, :v)

    for (j, i) in enumerate([1, 3])
        @test ref_values_callocation[i] === PlantSimEngine.refvalue(out.statuses["Internode"][j], :carbon_allocation)
    end

    for (j, i) in enumerate([2, 4])
        @test ref_values_callocation[i] === PlantSimEngine.refvalue(out.statuses["Leaf"][j], :carbon_allocation)
    end
end


@testset "status_template" begin
    organs_statuses = PlantSimEngine.status_template(mapping, nothing)
    @test collect(keys(organs_statuses)) == ["Soil", "Internode", "Plant", "Leaf"]
    # Check that the soil_water_content is linked between the soil and the leaves:
    @test organs_statuses["Soil"][:soil_water_content][] === -Inf
    @test organs_statuses["Leaf"][:soil_water_content][] === -Inf

    @test organs_statuses["Soil"][:soil_water_content][] === organs_statuses["Leaf"][:soil_water_content][]

    organs_statuses["Soil"][:soil_water_content][] = 1.0
    @test organs_statuses["Leaf"][:soil_water_content][] == 1.0

    @test organs_statuses["Plant"][:A] == PlantSimEngine.RefVector{Float64}[]
    @test organs_statuses["Plant"][:carbon_allocation] == PlantSimEngine.RefVector{Float64}[]
    @test organs_statuses["Internode"][:carbon_allocation] == -Inf
    @test organs_statuses["Leaf"][:carbon_demand] == -Inf

    # Testing with a different type:
    organs_statuses = PlantSimEngine.status_template(mapping, Dict(Float64 => Float32, Vector{Float64} => Vector{Float32}))

    @test isa(organs_statuses["Plant"][:A], PlantSimEngine.RefVector{Float32})
    @test isa(organs_statuses["Plant"][:carbon_allocation], PlantSimEngine.RefVector{Float32})
    @test isa(organs_statuses["Internode"][:carbon_allocation], Float32)
    @test isa(organs_statuses["Leaf"][:carbon_demand], Float32)
    @test isa(organs_statuses["Soil"][:soil_water_content], Base.RefValue{Float32})
end

# Here we initialise var1 to a constant value:
@testset "MTG initialisation" begin
    var1 = 1.0
    mapping = Dict(
        "Leaf" => (
            Process1Model(1.0),
            Process2Model(),
            Process3Model(),
            Status(var1=var1,)
        )
    )

    # Need init for var2, so it returns an error:
    @test_throws "Nodes of type Leaf need variable(s) var2 to be initialized or computed by a model." PlantSimEngine.init_simulation(mtg, mapping)

    mapping = Dict(
        "Leaf" => (
            Process1Model(1.0),
            Process2Model(),
            Process3Model(),
            Status(var1=var1, var2=1.0)
        )
    )

    out = @test_nowarn PlantSimEngine.run!(mtg, mapping, meteo)

    @test out.statuses["Leaf"][1].var1 === var1
    @test out.statuses["Leaf"][1].var2 === 1.0
    @test out.statuses["Leaf"][1].var3 === 2.0
    @test out.statuses["Leaf"][1].var6 === 40.4
end

@testset "MTG with complex mapping" begin
    mapping =
        Dict(
            "Plant" =>
                MultiScaleModel(
                    model=ToyCAllocationModel(),
                    mapping=[
                        # inputs
                        :A => ["Leaf"],
                        :carbon_demand => ["Leaf", "Internode"],
                        # outputs
                        :carbon_allocation => ["Leaf", "Internode"]
                    ],
                ),
            "Internode" => (
                ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
                Status(TT=10.0)
            ),
            "Leaf" => (
                MultiScaleModel(
                    model=ToyAssimModel(),
                    mapping=[:soil_water_content => "Soil",],
                    # Notice we provide "Soil", not ["Soil"], so a single value is expected here
                ),
                ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
                Process1Model(1.0),
                Process2Model(),
                Process3Model(),
                Process4Model(),
                Process5Model(),
                Process6Model(),
                Status(aPPFD=1300.0, TT=10.0, var0=1.0, var9=1.0),
            ),
            "Soil" => (
                ToySoilWaterModel(),
            ),
        )
    out = @test_nowarn PlantSimEngine.run!(mtg, mapping, meteo)

    @test length(out.dependency_graph.roots) == 4
    @test out.statuses["Leaf"][1].var1 === 1.01
    @test out.statuses["Leaf"][1].var2 === 1.03
    @test out.statuses["Leaf"][1].var8 ≈ 1015.47786908 atol = 1e-6
end