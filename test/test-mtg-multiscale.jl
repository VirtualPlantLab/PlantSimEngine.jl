
# Example meteo:
meteo = Weather(
    [
    Atmosphere(T=20.0, Wind=1.0, Rh=0.65),
    Atmosphere(T=25.0, Wind=0.5, Rh=0.8)
]
)

# A mapping that actually works (same as before but with the init for TT):
mapping_1 = Dict(
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


@testset "inputs and outputs of a mapping" begin
    ins = inputs(mapping_1)

    @test collect(keys(ins)) == collect(keys(mapping_1))
    @test ins["Soil"] == (soil_water=(),)
    @test ins["Leaf"] == (photosynthesis=(:aPPFD, :soil_water_content), carbon_demand=(:TT,))

    outs = outputs(mapping_1)
    @test collect(keys(outs)) == collect(keys(mapping_1))
    @test outs["Soil"] == (soil_water=(:soil_water_content,),)
    @test outs["Leaf"] == (photosynthesis=(:A,), carbon_demand=(:carbon_demand,))
    @test outs["Plant"] == (carbon_allocation=(:carbon_offer, :carbon_allocation),)

    vars = variables(mapping_1)
    @test collect(keys(vars)) == collect(keys(mapping_1))
    @test vars["Soil"] == outs["Soil"]
    @test vars["Plant"] == (carbon_allocation=(:A, :carbon_demand, :carbon_offer, :carbon_allocation),)
    @test vars["Leaf"] == (photosynthesis=(:aPPFD, :soil_water_content, :A), carbon_demand=(:TT, :carbon_demand))
end

@testset "status_template" begin
    organs_statuses = PlantSimEngine.status_template(mapping_1, nothing)
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
    organs_statuses = PlantSimEngine.status_template(mapping_1, Dict(Float64 => Float32, Vector{Float64} => Vector{Float32}))

    @test isa(organs_statuses["Plant"][:A], PlantSimEngine.RefVector{Float32})
    @test isa(organs_statuses["Plant"][:carbon_allocation], PlantSimEngine.RefVector{Float32})
    @test isa(organs_statuses["Internode"][:carbon_allocation], Float32)
    @test isa(organs_statuses["Leaf"][:carbon_demand], Float32)
    @test isa(organs_statuses["Soil"][:soil_water_content], Base.RefValue{Float32})
end


@testset "Multiscale initialisations and outputs" begin
    outs = Dict(
        "Flowers" => (:A, :carbon_demand), # There are no flowers in this MTG
        "Leaf" => (:A, :carbon_demand, :non_existing_variable), # :non_existing_variable is not computed by any model
        "Soil" => (:soil_water_content,),
    )

    type_promotion = nothing
    nsteps = 2
    organs_statuses = PlantSimEngine.status_template(mapping_1, type_promotion)

    @test collect(keys(organs_statuses)) == ["Soil", "Internode", "Plant", "Leaf"]
    @test collect(keys(organs_statuses["Soil"])) == [:soil_water_content]
    @test collect(keys(organs_statuses["Leaf"])) == [:carbon_allocation, :A, :TT, :aPPFD, :soil_water_content, :carbon_demand]
    @test collect(keys(organs_statuses["Plant"])) == [:carbon_allocation, :A, :carbon_offer, :carbon_demand]
    @test organs_statuses["Soil"][:soil_water_content][] === -Inf
    @test organs_statuses["Leaf"][:carbon_allocation] === -Inf
    @test organs_statuses["Leaf"][:TT] === 10.0
    @test typeof(organs_statuses["Plant"][:carbon_allocation]) === PlantSimEngine.RefVector{Float64}

    @test PlantSimEngine.reverse_mapping(mapping_1, all=true) == Dict{String,Any}(
        "Soil" => Dict("Leaf" => [:soil_water_content]),
        "Internode" => Dict("Plant" => [:carbon_demand, :carbon_allocation]),
        "Leaf" => Dict("Plant" => [:A, :carbon_demand, :carbon_allocation])
    )

    var_refvector_1 = PlantSimEngine.reverse_mapping(mapping_1, all=false)
    @test var_refvector_1 == Dict{String,Any}(
        "Internode" => Dict("Plant" => [:carbon_demand, :carbon_allocation]),
        "Leaf" => Dict("Plant" => [:A, :carbon_demand, :carbon_allocation])
    )

    @test PlantSimEngine.reverse_mapping(filter(x -> x.first == "Soil", mapping_1)) == Dict{String,Any}()

    var_need_init = PlantSimEngine.to_initialize(mapping_1, mtg)
    @test var_need_init == Dict{String,Any}()

    statuses = PlantSimEngine.init_statuses(mtg, organs_statuses, var_refvector_1, var_need_init)
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

    outs_ = @test_logs (:info, "You requested outputs for organs Soil, Flowers, Leaf, but organs Flowers have no models.") (:info, "You requested outputs for variables A, carbon_demand, non_existing_variable, but variables non_existing_variable have no models.") PlantSimEngine.pre_allocate_outputs(statuses, outs, nsteps, check=false)

    @test outs_ == Dict(
        "Soil" => Dict(:node => [[], []], :soil_water_content => [[], []]),
        "Leaf" => Dict(:A => [[], []], :node => [[], []], :carbon_demand => [[], []])
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

    to_init = @test_nowarn to_initialize(mapping)

    @test to_init["Internode"].need_initialisation == [:TT]
    @test to_init["Internode"].need_models_from_scales == []
    @test to_init["Internode"].need_var_from_mtg == []
end

@testset "Mapping: missing organ in mapping (Soil)" begin
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
        @test_throws ErrorException to_initialize(mapping)
    else
        @test_throws "Nodes of type Leaf are mapping to variable `:soil_water_content` computed from nodes of type Soil, but there is no type Soil in the list of mapping." to_initialize(mapping)
    end
end

@testset "Mapping: missing model at other scale (soil_water_content) + missing init + var1 from MTG" begin
    mtg_var = let
        scene = Node(MultiScaleTreeGraph.NodeMTG("/", "Scene", 1, 0))
        soil = Node(scene, MultiScaleTreeGraph.NodeMTG("/", "Soil", 1, 1))
        plant = Node(scene, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1))
        internode1 = Node(plant, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
        leaf1 = Node(internode1, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))
        scene
    end

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

    soil_node = mtg_var[1]
    soil_node[:var1] = 1.0
    to_init = to_initialize(mapping, mtg_var)
    @test to_init["Soil"].need_initialisation == [:var2]# var1 would be here if not present in the MTG
    @test to_init["Soil"].need_models_from_scales == []
    @test to_init["Soil"].need_var_from_mtg == [PlantSimEngine.VarFromMTG(:var1, "Soil")]

    @test to_init["Leaf"].need_initialisation == []
    @test to_init["Leaf"].need_models_from_scales == [(var=:soil_water_content, scale="Leaf", need_scales="Soil")]
    @test to_init["Leaf"].need_var_from_mtg == []

    @test to_init["Internode"].need_initialisation == [:TT]
    @test to_init["Internode"].need_models_from_scales == []
    @test to_init["Internode"].need_var_from_mtg == []
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
    if VERSION < v"1.8" # We test differently depending on the julia version because the format of the error message changed
        @test_throws ErrorException run!(mtg, mapping_all, meteo)
    else
        @test_throws "Nodes of type Internode need variable(s) TT to be initialized or computed by a model." run!(mtg, mapping_all, meteo)
    end

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

    st_leaf1 = out.statuses["Leaf"][1]
    @test st_leaf1.TT == 10.0
    @test st_leaf1.carbon_demand == 0.5
    # This one depends on the soil, which is random, so we test using the computation directly:
    @test st_leaf1.A == st_leaf1.aPPFD * out.models["Leaf"].photosynthesis.LUE * st_leaf1.soil_water_content
    @test st_leaf1.carbon_allocation == 0.0
end

@testset "run! on MTG with complete mapping (with init)" begin
    out = @test_nowarn run!(mtg, mapping_1, meteo, executor=SequentialEx())

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
        @test_throws "Nodes of type Leaf need variable(s) var2 to be initialized or computed by a model." PlantSimEngine.init_simulation(mtg, mapping)
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

    out = @test_nowarn PlantSimEngine.run!(mtg, mapping, meteo, executor=SequentialEx())

    @test length(out.dependency_graph.roots) == 4
    @test out.statuses["Leaf"][1].var1 === 1.01
    @test out.statuses["Leaf"][1].var2 === 1.03
    @test out.statuses["Leaf"][1].var4 ≈ 8.1612000000000013 atol = 1e-6
    @test out.statuses["Leaf"][1].var5 == 32.4806
    @test out.statuses["Leaf"][1].var8 ≈ 1321.0700490800002 atol = 1e-6
end

@testset "MTG with dynamic output variables" begin
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

    out_vars = Dict(
        "Leaf" => (:A, :carbon_demand, :soil_water_content, :carbon_allocation),
        "Internode" => (:carbon_allocation,),
        "Plant" => (:carbon_allocation,),
        "Soil" => (:soil_water_content,),
    )
    out = @test_nowarn PlantSimEngine.run!(mtg, mapping, meteo, outputs=out_vars, executor=SequentialEx())

    @test length(out.dependency_graph.roots) == 4
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
    @test length(filter(x -> x !== nothing, outs.A)) == length(filter(x -> x, traverse(mtg, node -> node.MTG.scale == 2)))
    # a = status(out, TimeStepTable{Status})
    A = outputs(out, :A)
    @test A == outs.A

    A2 = outputs(out, 5)
    @test A == A2
end