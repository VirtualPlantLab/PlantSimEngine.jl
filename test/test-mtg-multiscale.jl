# Example meteo:
meteo = Weather(
    [
    Atmosphere(T=20.0, Wind=1.0, Rh=0.65),
    Atmosphere(T=25.0, Wind=0.5, Rh=0.8)
]
)

@testset "MTG initialisation" begin
    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Plant", 1, 1))
    internode = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
    leaf = Node(mtg, MultiScaleTreeGraph.NodeMTG("<", "Leaf", 1, 2))
    var1 = 15.0
    var2 = 0.3
    leaf[:var2] = var2

    mapping = Dict(
        "Leaf" => (
            Process1Model(1.0),
            Process2Model(),
            Process3Model(),
            Status(var1=var1,)
        )
    )

    @test descendants(mtg, :var1) == [nothing, nothing]
    @test descendants(mtg, :var2) == [nothing, var2]

    to_init = to_initialize(mapping)
    @test to_initialize(mapping) == Dict("Leaf" => [:var4, :var2])
    @test to_initialize(mapping, mtg) == Dict("Leaf" => [:var4])
end

# A mapping that actually works (same as before but with the init for TT):
mapping_1 = Dict(
    "Plant" => (
        MultiScaleModel(
            model=ToyCAllocationModel(),
            mapping=[
                # inputs
                :carbon_assimilation => ["Leaf"],
                :carbon_demand => ["Leaf", "Internode"],
                # outputs
                :carbon_allocation => ["Leaf", "Internode"]
            ],
        ),
        MultiScaleModel(
            model=ToyPlantRmModel(),
            mapping=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
        ),
    ),
    "Internode" => (
        ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
        ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
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
        ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
    ),
    "Soil" => (
        ToySoilWaterModel(),
    ),
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

# Another MTG with initialisation values for biomass:
mtg_init = deepcopy(mtg)
transform!(mtg_init, (x -> 1.0) => :biomass, symbol=["Internode", "Leaf"])


@testset "inputs and outputs of a mapping" begin
    ins = inputs(mapping_1)

    @test collect(keys(ins)) == collect(keys(mapping_1))
    @test ins["Soil"] == (soil_water=(),)
    @test ins["Leaf"] == (carbon_assimilation=(:aPPFD, :soil_water_content), carbon_demand=(:TT,), maintenance_respiration=(:biomass,))

    outs = outputs(mapping_1)
    @test collect(keys(outs)) == collect(keys(mapping_1))
    @test outs["Soil"] == (soil_water=(:soil_water_content,),)
    @test outs["Leaf"] == (carbon_assimilation=(:carbon_assimilation,), carbon_demand=(:carbon_demand,), maintenance_respiration=(:Rm,))
    @test outs["Plant"] == (carbon_allocation=(:carbon_offer, :carbon_allocation), maintenance_respiration=(:Rm,))

    vars = variables(mapping_1)
    @test collect(keys(vars)) == collect(keys(mapping_1))
    @test vars["Soil"] == outs["Soil"]
    @test vars["Plant"] == (carbon_allocation=(:carbon_assimilation, :Rm, :carbon_demand, :carbon_offer, :carbon_allocation), maintenance_respiration=(:Rm_organs, :Rm),)
    @test vars["Leaf"] == (carbon_assimilation=(:aPPFD, :soil_water_content, :carbon_assimilation), carbon_demand=(:TT, :carbon_demand), maintenance_respiration=(:biomass, :Rm))
end

@testset "Status initialisation" begin
    @test_throws "Variable `biomass` is not computed by any model, not initialised by the user in the status, and not found in the MTG at scale Internode (checked for MTG node 4)." PlantSimEngine.init_statuses(mtg, mapping_1)
    organs_statuses, others = PlantSimEngine.init_statuses(mtg_init, mapping_1)

    @test collect(keys(organs_statuses)) == ["Soil", "Internode", "Plant", "Leaf"]
    # Check that the soil_water_content is linked between the soil and the leaves:
    @test length(organs_statuses["Soil"]) == length(organs_statuses["Plant"]) == 1
    @test length(organs_statuses["Leaf"]) == length(organs_statuses["Internode"]) == 2
    @test organs_statuses["Soil"][1][:soil_water_content] === -Inf
    @test organs_statuses["Leaf"][1][:soil_water_content] === -Inf
    @test organs_statuses["Leaf"][2][:soil_water_content] === -Inf
    @test organs_statuses["Leaf"][2][:soil_water_content] === organs_statuses["Soil"][1][:soil_water_content]

    organs_statuses["Soil"][1][:soil_water_content] = 1.0
    @test organs_statuses["Leaf"][1][:soil_water_content][] == 1.0

    @test organs_statuses["Plant"][1][:carbon_assimilation] == PlantSimEngine.RefVector{Float64}[]
    @test organs_statuses["Plant"][1][:carbon_allocation] == PlantSimEngine.RefVector{Float64}[]
    @test organs_statuses["Internode"][1][:carbon_allocation] == -Inf
    @test organs_statuses["Leaf"][1][:carbon_demand] == -Inf

    # Testing with a different type:
    organs_statuses, others = PlantSimEngine.init_statuses(mtg_init, mapping_1, type_promotion=Dict(Float64 => Float32, Vector{Float64} => Vector{Float32}))

    @test isa(organs_statuses["Plant"][1][:carbon_assimilation], PlantSimEngine.RefVector{Float32})
    @test isa(organs_statuses["Plant"][1][:carbon_allocation], PlantSimEngine.RefVector{Float32})
    @test isa(organs_statuses["Internode"][1][:carbon_allocation], Float32)
    @test isa(organs_statuses["Leaf"][1][:carbon_demand], Float32)
    @test isa(organs_statuses["Soil"][1][:soil_water_content], Float32)
end


@testset "Multiscale initialisations and outputs" begin
    outs = Dict(
        "Flowers" => (:carbon_assimilation, :carbon_demand), # There are no flowers in this MTG
        "Leaf" => (:carbon_assimilation, :carbon_demand, :non_existing_variable), # :non_existing_variable is not computed by any model
        "Soil" => (:soil_water_content,),
    )

    type_promotion = nothing
    nsteps = 2
    dependency_graph = dep(mapping_1)
    organs_statuses, others = PlantSimEngine.init_statuses(mtg_init, mapping_1, dependency_graph; type_promotion=type_promotion)

    @test collect(keys(organs_statuses)) == ["Soil", "Internode", "Plant", "Leaf"]
    @test collect(keys(organs_statuses["Soil"][1])) == [:node, :soil_water_content]
    @test collect(keys(organs_statuses["Leaf"][1])) == [:carbon_allocation, :carbon_assimilation, :TT, :node, :aPPFD, :biomass, :Rm, :soil_water_content, :carbon_demand]
    @test collect(keys(organs_statuses["Plant"][1])) == [:Rm_organs, :carbon_allocation, :carbon_assimilation, :node, :carbon_offer, :Rm, :carbon_demand]
    @test organs_statuses["Soil"][1][:soil_water_content][] === -Inf
    @test organs_statuses["Leaf"][1][:carbon_allocation] === -Inf
    @test organs_statuses["Leaf"][1][:TT] === 10.0
    @test typeof(organs_statuses["Plant"][1][:carbon_allocation]) === PlantSimEngine.RefVector{Float64}

    @test PlantSimEngine.reverse_mapping(mapping_1, all=true) == Dict{String,Dict{String,Dict{Symbol,Any}}}(
        "Soil" => Dict("Leaf" => Dict(:soil_water_content => :soil_water_content)),
        "Internode" => Dict("Plant" => Dict(:carbon_allocation => :carbon_allocation, :Rm => :Rm_organs, :carbon_demand => :carbon_demand)),
        "Leaf" => Dict("Plant" => Dict(:carbon_allocation => :carbon_allocation, :carbon_assimilation => :carbon_assimilation, :Rm => :Rm_organs, :carbon_demand => :carbon_demand))
    )

    @test PlantSimEngine.reverse_mapping(mapping_1, all=false) == Dict{String,Dict{String,Dict{Symbol,Any}}}(
        "Internode" => Dict("Plant" => Dict(:carbon_allocation => :carbon_allocation, :Rm => :Rm_organs, :carbon_demand => :carbon_demand)),
        "Leaf" => Dict("Plant" => Dict(:carbon_allocation => :carbon_allocation, :carbon_assimilation => :carbon_assimilation, :Rm => :Rm_organs, :carbon_demand => :carbon_demand))
    )

    @test PlantSimEngine.reverse_mapping(filter(x -> x.first == "Soil", mapping_1)) == Dict{String,Dict{String,Dict{Symbol,Any}}}()


    @test PlantSimEngine.to_initialize(mapping_1, mtg) == Dict("Internode" => [:biomass], "Leaf" => [:biomass])
    @test PlantSimEngine.to_initialize(mapping_1, mtg_init) == Dict{String,Symbol}()

    statuses, other = PlantSimEngine.init_statuses(mtg_init, mapping_1)
    @test collect(keys(statuses)) == ["Soil", "Internode", "Plant", "Leaf"]

    @test length(statuses["Internode"]) == length(statuses["Leaf"]) == 2
    @test length(statuses["Soil"]) == length(statuses["Plant"]) == 1

    e_1 = "You requested outputs for organs Soil, Flowers, Leaf, but organs Flowers have no models."
    e_2 = "You requested outputs for variables A, carbon_demand, non_existing_variable, but variables non_existing_variable have no models."

    # If check is true, this should return an error (some outputs are not computed):
    if VERSION < v"1.8" # We test differently depending on the julia version because the format of the error message changed
        @test_throws ErrorException PlantSimEngine.pre_allocate_outputs(statuses, outs, nsteps)
    else
        @test_throws e_1 PlantSimEngine.pre_allocate_outputs(statuses, outs, nsteps)
    end

    outs_ = @test_logs (:info, "You requested outputs for organs Soil, Flowers, Leaf, but organs Flowers have no models.") (:info, "You requested outputs for variables carbon_assimilation, carbon_demand, non_existing_variable, but variables non_existing_variable have no models.") PlantSimEngine.pre_allocate_outputs(statuses, outs, nsteps, check=false)

    @test outs_ == Dict(
        "Soil" => Dict(:node => [[], []], :soil_water_content => [[], []]),
        "Leaf" => Dict(:carbon_assimilation => [[], []], :node => [[], []], :carbon_demand => [[], []])
    )
end

# Testing the mappings:
@testset "Mapping: missing initialisation" begin
    mapping = Dict(
        "Plant" =>
            MultiScaleModel(
                model=ToyCAllocationModel(),
                mapping=[
                    # inputs
                    :carbon_assimilation => ["Leaf"],
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

    to_init = @test_nowarn to_initialize(mapping)

    @test to_init["Internode"] == [:TT]

    mapped_vars = PlantSimEngine.mapped_variables(mapping)
    @test collect(keys(mapped_vars["Plant"])) == [:carbon_allocation, :carbon_assimilation, :carbon_offer, :Rm, :carbon_demand]
    @test [PlantSimEngine.mapped_default(i) for i in values(mapped_vars["Plant"])] == [-Inf, -Inf, -Inf, PlantSimEngine.UninitializedVar{Float64}(:Rm, -Inf), -Inf]
    @test collect(keys(mapped_vars["Leaf"])) == [:carbon_allocation, :carbon_assimilation, :TT, :aPPFD, :soil_water_content, :carbon_demand]
    @test [PlantSimEngine.mapped_default(i) for i in values(mapped_vars["Leaf"])] == [-Inf, -Inf, 10.0, 1300.0, -Inf, -Inf]
    @test collect(keys(mapped_vars["Soil"])) == [:soil_water_content]
    @test [PlantSimEngine.mapped_default(i) for i in values(mapped_vars["Soil"])] == [-Inf]
end

@testset "Mapping: missing organ in mapping (Soil)" begin
    mapping = Dict(
        "Plant" =>
            MultiScaleModel(
                model=ToyCAllocationModel(),
                mapping=[
                    # inputs
                    :carbon_assimilation => ["Leaf"],
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
        )
    )

    if VERSION < v"1.8" # We test differently depending on the julia version because the format of the error message changed
        @test_throws AssertionError to_initialize(mapping)
        @test_throws AssertionError PlantSimEngine.find_var_mapped_default(mapping, "Plant")
    else
        @test_throws "Scale Soil not found in the mapping, but mapped to the Leaf scale." to_initialize(mapping)
    end
end

mtg_var = let
    scene = Node(MultiScaleTreeGraph.NodeMTG("/", "Scene", 1, 0))
    soil = Node(scene, MultiScaleTreeGraph.NodeMTG("/", "Soil", 1, 1))
    plant = Node(scene, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1))
    internode1 = Node(plant, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
    leaf1 = Node(internode1, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))
    scene
end

@testset "Mapping: missing model at other scale (soil_water_content) + missing init + var1 from MTG" begin
    mapping = Dict(
        "Plant" =>
            MultiScaleModel(
                model=ToyCAllocationModel(),
                mapping=[
                    # inputs
                    :carbon_assimilation => ["Leaf"],
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
            Process1Model(1.0),
        ),
    )

    @test_throws "The variable `soil_water_content` is mapped from scale `Soil` to scale `Leaf`, but is not computed by any model at `Soil` scale." to_initialize(mapping, mtg_var)
end

@testset "Mapping: missing init + var1 from MTG" begin
    mapping = Dict(
        "Plant" =>
            MultiScaleModel(
                model=ToyCAllocationModel(),
                mapping=[
                    # inputs
                    :carbon_assimilation => ["Leaf"],
                    :carbon_demand => ["Leaf", "Internode"],
                    # outputs
                    :carbon_allocation => ["Leaf", "Internode"]
                ],
            ),
        "Internode" => ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
        "Leaf" => (
            MultiScaleModel(
                model=ToyAssimModel(),
                mapping=[:soil_water_content => "Soil" => :var3,],
                # Notice we provide "Soil", not ["Soil"], so a single value is expected here
            ),
            ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            Status(aPPFD=1300.0, TT=10.0),
        ),
        "Soil" => (
            Process1Model(1.0),
        ),
    )

    to_init = to_initialize(mapping, mtg_var)

    @test to_init["Soil"] == [:var1, :var2]# var1 would be here if not present in the MTG

    soil_node = mtg_var[1]
    soil_node[:var1] = 1.0
    to_init = to_initialize(mapping, mtg_var)
    @test to_init["Soil"] == [:var2]# var1 would be here if not present in the MTG
    @test !haskey(to_init, "Leaf")
    @test to_init["Internode"] == [:TT]
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
                    :carbon_assimilation => ["Leaf"],
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
    if VERSION < v"1.8" # We test differently depending on the julia version because the format of the error message changed
        @test_throws ErrorException run!(mtg, mapping_all, meteo)
    else
        @test_throws "Variable `Rm` is not computed by any model, not initialised by the user in the status, and not found in the MTG at scale Plant (checked for MTG node 3)." run!(mtg, mapping_all, meteo)
    end

    # It should work if we don't check the mapping though:
    out = @test_nowarn run!(mtg, mapping_all, meteo, check=false)
    # Note that the outputs are garbage because the TT is not initialized.

    @test out.models == Dict{String,NamedTuple}(
        "Soil" => (soil_water=ToySoilWaterModel(0.1:0.1:1.0),),
        "Internode" => (carbon_demand=ToyCDemandModel{Float64}(10.0, 200.0),),
        "Plant" => (carbon_allocation=ToyCAllocationModel(),),
        "Leaf" => (carbon_assimilation=ToyAssimModel{Float64}(0.2), carbon_demand=ToyCDemandModel{Float64}(10.0, 200.0))
    )

    @test length(out.dependency_graph.roots) == 3 # 3 because the plant is not a root (its model has dependencies)
    @test out.statuses["Internode"][1].TT === -Inf
    @test out.statuses["Internode"][1].carbon_demand === -Inf

    st_leaf1 = out.statuses["Leaf"][1]
    @test st_leaf1.TT == 10.0
    @test st_leaf1.carbon_demand == 0.5
    # This one depends on the soil, which is random, so we test using the computation directly:
    @test st_leaf1.carbon_assimilation == st_leaf1.aPPFD * out.models["Leaf"].carbon_assimilation.LUE * st_leaf1.soil_water_content
    @test st_leaf1.carbon_allocation == -Inf # Default is taken from the source model at plant scale
end

@testset "run! on MTG with complete mapping (with init)" begin
    out = @test_nowarn run!(mtg_init, mapping_1, meteo, executor=SequentialEx())

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
    @test leaf1_status.carbon_assimilation == leaf1_status.aPPFD * out.models["Leaf"].carbon_assimilation.LUE * leaf1_status.soil_water_content

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
    if VERSION < v"1.8" # We test differently depending on the julia version because the format of the error message changed
        @test_throws ErrorException PlantSimEngine.init_simulation(mtg, mapping)
    else
        @test_throws "Variable `var2` is not computed by any model, not initialised by the user in the status, and not found in the MTG at scale Leaf (checked for MTG node 5)." PlantSimEngine.init_simulation(mtg, mapping)
    end

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
            "Plant" => (
                MultiScaleModel(
                    model=ToyCAllocationModel(),
                    mapping=[
                        # inputs
                        :carbon_assimilation => ["Leaf"],
                        :carbon_demand => ["Leaf", "Internode"],
                        # outputs
                        :carbon_allocation => ["Leaf", "Internode"]
                    ]
                ),
                MultiScaleModel(
                    model=ToyPlantRmModel(),
                    mapping=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
                ),
            ),
            "Internode" => (
                ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
                ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
                Status(TT=10.0, biomass=1.0)
            ),
            "Leaf" => (
                MultiScaleModel(
                    model=ToyAssimModel(),
                    mapping=[:soil_water_content => "Soil",],
                    # Notice we provide "Soil", not ["Soil"], so a single value is expected here
                ),
                ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
                ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
                Process1Model(1.0),
                Process2Model(),
                Process3Model(),
                Process4Model(),
                Process5Model(),
                Process6Model(),
                Status(aPPFD=1300.0, TT=10.0, var0=1.0, var9=1.0, biomass=1.0),
            ),
            "Soil" => (
                ToySoilWaterModel(),
            ),
        )

    out = @test_nowarn PlantSimEngine.run!(mtg, mapping, meteo, executor=SequentialEx())

    @test length(out.dependency_graph.roots) == 6
    @test out.statuses["Leaf"][1].var1 === 1.01
    @test out.statuses["Leaf"][1].var2 === 1.03
    @test out.statuses["Leaf"][1].var4 ≈ 8.1612000000000013 atol = 1e-6
    @test out.statuses["Leaf"][1].var5 == 32.4806
    @test out.statuses["Leaf"][1].var8 ≈ 1321.0700490800002 atol = 1e-6
end

@testset "MTG with dynamic output variables" begin
    mapping =
        Dict(
            "Plant" => (
                MultiScaleModel(
                    model=ToyCAllocationModel(),
                    mapping=[
                        # inputs
                        :carbon_assimilation => ["Leaf"],
                        :carbon_demand => ["Leaf", "Internode"],
                        # outputs
                        :carbon_allocation => ["Leaf", "Internode"]
                    ],
                ),
                MultiScaleModel(
                    model=ToyPlantRmModel(),
                    mapping=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
                ),
            ),
            "Internode" => (
                ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
                ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
                Status(TT=10.0, biomass=1.0)
            ),
            "Leaf" => (
                MultiScaleModel(
                    model=ToyAssimModel(),
                    mapping=[:soil_water_content => "Soil",],
                    # Notice we provide "Soil", not ["Soil"], so a single value is expected here
                ),
                ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
                ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
                Process1Model(1.0),
                Process2Model(),
                Process3Model(),
                Process4Model(),
                Process5Model(),
                Process6Model(),
                Status(aPPFD=1300.0, TT=10.0, var0=1.0, var9=1.0, biomass=1.0),
            ),
            "Soil" => (
                ToySoilWaterModel(),
            ),
        )

    out_vars = Dict(
        "Leaf" => (:carbon_assimilation, :carbon_demand, :soil_water_content, :carbon_allocation),
        "Internode" => (:carbon_allocation,),
        "Plant" => (:carbon_allocation,),
        "Soil" => (:soil_water_content,),
    )
    out = @test_nowarn PlantSimEngine.run!(mtg, mapping, meteo, outputs=out_vars, executor=SequentialEx())

    @test length(out.dependency_graph.roots) == 6
    @test out.statuses["Leaf"][1].var1 === 1.01
    @test out.statuses["Leaf"][1].var2 === 1.03
    @test out.statuses["Leaf"][1].var4 ≈ 8.1612000000000013 atol = 1e-6
    @test out.statuses["Leaf"][1].var5 == 32.4806
    @test out.statuses["Leaf"][1].var8 ≈ 1321.0700490800002 atol = 1e-6

    @test out.outputs["Leaf"][:carbon_demand] == [[0.5, 0.5], [0.5, 0.5]]
    @test out.outputs["Leaf"][:soil_water_content][1] == fill(out.outputs["Soil"][:soil_water_content][1][1], 2)
    @test out.outputs["Leaf"][:soil_water_content][2] == fill(out.outputs["Soil"][:soil_water_content][2][1], 2)

    @test out.outputs["Leaf"][:carbon_allocation] == out.outputs["Internode"][:carbon_allocation]
    @test out.outputs["Plant"][:carbon_allocation][1][1][1] === out.outputs["Internode"][:carbon_allocation][1][1]

    # Testing the outputs if transformed into a DataFrame:
    outs = outputs(out, DataFrame)

    @test isa(outs, DataFrame)
    @test size(outs) == (12, 7)

    @test unique(outs.timestep) == [1, 2]
    @test sort(unique(outs.organ)) == sort(collect(keys(out_vars)))
    @test length(filter(x -> x !== nothing, outs.carbon_assimilation)) == length(filter(x -> x, traverse(mtg, node -> MultiScaleTreeGraph.scale(node) == 2)))
    # a = status(out, TimeStepTable{Status})
    A = outputs(out, :carbon_assimilation)
    @test A == outs.carbon_assimilation

    A2 = outputs(out, 5)
    @test A == A2
end