mapping = ModelMapping(
    "Plant" => (
        MultiScaleModel(
            model=ToyCAllocationModel(),
            mapped_variables=[
                # inputs
                :carbon_assimilation => ["Leaf"],
                :carbon_demand => ["Leaf", "Internode"],
                # outputs
                :carbon_allocation => ["Leaf", "Internode"]
            ],
        ),
        MultiScaleModel(
            model=ToyPlantRmModel(),
            mapped_variables=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
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
            mapped_variables=[:soil_water_content => "Soil",],
            # Notice we provide "Soil", not ["Soil"], so a single value is expected here
        ),
        ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
        ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
        Status(aPPFD=1300.0, TT=10.0),
    ),
    "Soil" => (
        ToySoilWaterModel(),
    ),
)

dep_graph = dep(mapping)

# The C allocation depends on the C demand at the leaf and internode levels,
# the maintenance respiration at the plant level, and the maintenance respiration at the plant level,
# which depends on the maintenance respiration at the leaf and internode levels.

# Expected root dependency nodes:
root_models = Dict(
    ("Soil" => :soil_water) => mapping["Soil"][1], # The only model from the soil is completely independent  
    ("Internode" => :carbon_demand) => mapping["Internode"][1], # The c allocation models dependent on TT, that is given as input:
    ("Leaf" => :carbon_demand) => mapping["Leaf"][2], # Same for the leaf
    ("Internode" => :maintenance_respiration) => mapping["Internode"][2], # The maintenance respiration model for the internode is independant
    ("Leaf" => :maintenance_respiration) => mapping["Leaf"][3], # The maintenance respiration model for the leaf is independant
)

for (proc, node) in dep_graph.roots # proc = ("Soil" => :soil_water) ; node = dep_graph.roots[proc]
    @test root_models[proc] == node.value
end

@testset "ModelMapping checks and normalization" begin
    mapping_struct = PlantSimEngine.ModelMapping(Dict(mapping))
    @test mapping_struct isa PlantSimEngine.ModelMapping
    @test Set(keys(mapping_struct)) == Set(keys(mapping))
    @test hasmethod(PlantSimEngine.dep, Tuple{PlantSimEngine.ModelMapping})
    @test hasmethod(PlantSimEngine.hard_dependencies, Tuple{PlantSimEngine.ModelMapping})
    @test hasmethod(PlantSimEngine.inputs, Tuple{PlantSimEngine.ModelMapping})
    @test hasmethod(PlantSimEngine.outputs, Tuple{PlantSimEngine.ModelMapping})
    @test hasmethod(PlantSimEngine.variables, Tuple{PlantSimEngine.ModelMapping})
    @test hasmethod(PlantSimEngine.to_initialize, Tuple{PlantSimEngine.ModelMapping})
    @test hasmethod(PlantSimEngine.reverse_mapping, Tuple{PlantSimEngine.ModelMapping})

    mapping_from_pairs = PlantSimEngine.ModelMapping(
        "Plant" => mapping["Plant"],
        "Internode" => mapping["Internode"],
        "Leaf" => mapping["Leaf"],
        "Soil" => mapping["Soil"],
    )
    @test Set(keys(mapping_from_pairs)) == Set(keys(mapping))

    mapping_with_specs = PlantSimEngine.ModelMapping(
        "Scene" => (ModelSpec(ToyDegreeDaysCumulModel()) |> TimeStepModel(ClockSpec(24.0, 1.0)),),
        "Soil" => (ModelSpec(ToySoilWaterModel()) |> TimeStepModel(ClockSpec(24.0, 1.0)),),
        "Leaf" => (
            ModelSpec(ToyAssimModel()) |>
            MultiScaleModel([:soil_water_content => "Soil"]) |>
            TimeStepModel(1.0),
        ),
    )
    @test mapping_with_specs isa PlantSimEngine.ModelMapping
    @test any(item -> item isa ModelSpec, mapping_with_specs["Soil"])
    @test mapping_with_specs.info.validated
    @test mapping_with_specs.info.is_valid
    @test mapping_with_specs.info.is_multirate
    @test Set(mapping_with_specs.info.scales) == Set(["Scene", "Soil", "Leaf"])
    @test mapping_with_specs.info.models_per_scale["Leaf"] == 1
    @test length(mapping_with_specs.info.processes_per_scale["Leaf"]) == 1
    @test haskey(mapping_with_specs.info.model_specs, "Leaf")

    io = IOBuffer()
    show(io, MIME("text/plain"), mapping_with_specs)
    summary_txt = String(take!(io))
    @test occursin("ModelMapping", summary_txt)
    @test occursin("multirate: true", summary_txt)
    @test occursin("scales (3)", summary_txt)

    dep_from_dict = dep(mapping)
    dep_from_struct = dep(mapping_struct)
    @test Set(keys(dep_from_dict.roots)) == Set(keys(dep_from_struct.roots))
    @test Set(keys(first(PlantSimEngine.hard_dependencies(mapping_struct)).roots)) == Set(keys(first(PlantSimEngine.hard_dependencies(Dict(mapping_struct))).roots))
    @test inputs(mapping_struct) == inputs(Dict(mapping_struct))
    @test outputs(mapping_struct) == outputs(Dict(mapping_struct))
    @test variables(mapping_struct) == variables(Dict(mapping_struct))

    ModelMapping_scale = ModelMapping(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        status=(var1=1.0, var2=2.0)
    )
    merged_mapping = PlantSimEngine.ModelMapping(Dict("Default" => ModelMapping_scale))
    @test length(PlantSimEngine.get_models(merged_mapping["Default"])) == 2
    @test !isnothing(PlantSimEngine.get_status(merged_mapping["Default"]))

    single_scale_from_models = PlantSimEngine.ModelMapping(
        Process1Model(1.0),
        Process2Model();
        scale="Default",
        status=(var1=1.0, var2=2.0),
    )
    @test Set(keys(single_scale_from_models)) == Set(["Default"])
    @test length(PlantSimEngine.get_models(single_scale_from_models["Default"])) == 2
    @test PlantSimEngine.get_status(single_scale_from_models["Default"]).var1 == 1.0

    single_scale_from_namedtuple = PlantSimEngine.ModelMapping(
        (process1=Process1Model(1.0), process2=Process2Model());
        status=(var1=1.0, var2=2.0),
    )
    @test Set(keys(single_scale_from_namedtuple)) == Set(["Default"])
    @test length(PlantSimEngine.get_models(single_scale_from_namedtuple["Default"])) == 2

    single_scale_from_kwargs = PlantSimEngine.ModelMapping(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        status=(var1=1.0, var2=2.0),
    )
    @test Set(keys(single_scale_from_kwargs)) == Set(["Default"])
    @test length(PlantSimEngine.get_models(single_scale_from_kwargs["Default"])) == 2

    @test_throws "Cannot mix scale-level pairs" PlantSimEngine.ModelMapping(
        "Leaf" => (Process1Model(1.0),),
        process2=Process2Model(),
    )

    missing_scale_mapping = Dict(
        "Leaf" => (
            MultiScaleModel(
                model=ToyAssimModel(),
                mapped_variables=[:soil_water_content => "Soil"],
            ),
        ),
    )
    @test_throws "missing scale `Soil`" PlantSimEngine.ModelMapping(missing_scale_mapping)

    missing_source_variable_mapping = Dict(
        "Leaf" => (
            MultiScaleModel(
                model=ToyAssimModel(),
                mapped_variables=[:soil_water_content => "Soil"],
            ),
        ),
        "Soil" => (
            Process1Model(1.0),
        ),
    )
    @test_throws "not available at scale `Soil`" PlantSimEngine.ModelMapping(missing_source_variable_mapping)

    no_model_mapping = Dict(
        "Soil" => (Status(soil_water_content=0.2),),
    )
    @test_throws "defines no model" PlantSimEngine.ModelMapping(no_model_mapping)

    duplicate_process_mapping = Dict(
        "Leaf" => (
            Process1Model(1.0),
            Process1Model(2.0),
        ),
    )
    @test_throws "duplicate process(es)" PlantSimEngine.ModelMapping(duplicate_process_mapping)

    meteo = Atmosphere(T=20.0, Wind=1.0, Rh=0.65)
    models_single_scale = ModelMapping(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model(),
        status=(var1=15.0, var2=0.3)
    )
    @test !models_single_scale.info.is_multirate
    @test models_single_scale.info.scales == ["Default"]
    @test models_single_scale.info.models_per_scale["Default"] == 3
    baseline_outputs = run!(models_single_scale, meteo)

    outputs_from_models_args = run!(
        PlantSimEngine.ModelMapping(
            Process1Model(1.0),
            Process2Model(),
            Process3Model();
            status=(var1=15.0, var2=0.3),
        ),
        meteo
    )
    @test outputs_from_models_args == baseline_outputs

    outputs_from_named_tuple = run!(
        PlantSimEngine.ModelMapping(
            (process1=Process1Model(1.0), process2=Process2Model(), process3=Process3Model());
            status=(var1=15.0, var2=0.3),
        ),
        meteo
    )
    @test outputs_from_named_tuple == baseline_outputs

    outputs_from_kwargs = run!(
        PlantSimEngine.ModelMapping(
            process1=Process1Model(1.0),
            process2=Process2Model(),
            process3=Process3Model(),
            status=(var1=15.0, var2=0.3),
        ),
        meteo
    )
    @test outputs_from_kwargs == baseline_outputs

    @test_throws "Use `run!(mtg, mapping, ...)` for multiscale mappings." run!(mapping, meteo)
end



###########################
### Single and multi-scale ModelMapping comparison
### and Mapping with custom models vs mapping with generated models for user-provided vector
###########################

# Currently untested in 'real' multi-scale modes, or with complex configs (hard dependencies). 
# Need to place the simple timestep models in PlantSimEngine, and probably provide more complex ones at some point

# And then need to insert it at the graph sim generation level, and modify tests to consistently do single <-> multiple scale conversions
# And then implement tests with proper output filtering

@testset "check_statuses_contain_no_remaining_vectors behaviour" begin
    meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)
    mapping_with_vector = ModelMapping(
        "Scale" =>
            (ToyAssimGrowthModel(0.0, 0.0, 0.0),
                ToyCAllocationModel(),
                Status(TT_cu=Vector(cumsum(meteo_day.TT))),
            ),
    )

    mtg = import_mtg_example()
    @test !last(PlantSimEngine.check_statuses_contain_no_remaining_vectors(mapping_with_vector))
    @test_throws "call the function generate_models_from_status_vectors" PlantSimEngine.GraphSimulation(mtg, mapping_with_vector)

    mapping_with_empty_status = ModelMapping(
        "Scale" =>
            (ToyAssimGrowthModel(0.0, 0.0, 0.0),
                ToyCAllocationModel(),
                Status(),
            ),
    )

    @test last(PlantSimEngine.check_statuses_contain_no_remaining_vectors(mapping_with_empty_status))
end

@testset "Vector in status in a multiscale context" begin
    meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)
    TT_v = Vector(meteo_day.TT)
    TT_cu_vec = Vector(cumsum(meteo_day.TT))
    nsteps = length(meteo_day.TT)

    mapping_with_vector = ModelMapping("Plant" => (
            MultiScaleModel(
                model=ToyCAllocationModel(),
                mapped_variables=[
                    # inputs
                    :carbon_assimilation => ["Leaf"],
                    :carbon_demand => ["Leaf", "Internode"],
                    # outputs
                    :carbon_allocation => ["Leaf", "Internode"]
                ],
            ),
            MultiScaleModel(
                model=ToyPlantRmModel(),
                mapped_variables=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
            ),
        ),
        "Internode" => (
            ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
            Status(TT=TT_v, carbon_biomass=1.0)
        ),
        "Leaf" => (
            MultiScaleModel(
                model=ToyAssimModel(),
                mapped_variables=[:soil_water_content => "Soil",],
                # Notice we provide "Soil", not ["Soil"], so a single value is expected here
            ),
            ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
            Status(aPPFD=1300.0, carbon_biomass=2.0, TT=10.0), # TODO try calling the generated TT output through a variable mapping
        ),
        "Soil" => (
            ToySoilWaterModel(),
        ),
    )

    out_multiscale = Dict("Plant" => (:Rm_organs,),)
    mtg = import_mtg_example()

    mapping_without_vectors = PlantSimEngine.replace_mapping_status_vectors_with_generated_models(mapping_with_vector, "Soil", nsteps)

    @test to_initialize(mapping_without_vectors) == Dict()

    graph_sim_multiscale = @test_nowarn PlantSimEngine.GraphSimulation(mtg, mapping_without_vectors, nsteps=nsteps, check=true, outputs=out_multiscale)

    sim_multiscale = run!(graph_sim_multiscale,
        meteo_day,
        PlantMeteo.Constants(),
        nothing;
        check=true,
        executor=SequentialEx()
    )

    #replace a value with a constant vector and ensure no changes happen in the simulation 
    carbon_biomass_vec = Vector{Float64}(undef, nsteps)
    for i in nsteps
        carbon_biomass_vec[i] = 2.0
    end
    mapping_with_two_vectors = ModelMapping("Plant" => (
            MultiScaleModel(
                model=ToyCAllocationModel(),
                mapped_variables=[
                    # inputs
                    :carbon_assimilation => ["Leaf"],
                    :carbon_demand => ["Leaf", "Internode"],
                    # outputs
                    :carbon_allocation => ["Leaf", "Internode"]
                ],
            ),
            MultiScaleModel(
                model=ToyPlantRmModel(),
                mapped_variables=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
            ),
        ),
        "Internode" => (
            ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
            Status(TT=TT_v, carbon_biomass=1.0)
        ),
        "Leaf" => (
            MultiScaleModel(
                model=ToyAssimModel(),
                mapped_variables=[:soil_water_content => "Soil",],
            ),
            ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
            Status(aPPFD=1300.0, carbon_biomass=carbon_biomass_vec, TT=10.0), # Replaced with vector here
        ),
        "Soil" => (
            ToySoilWaterModel(),
        ),
    )

    mtg = import_mtg_example()
    mapping_without_vectors_2 = PlantSimEngine.replace_mapping_status_vectors_with_generated_models(mapping_with_two_vectors, "Soil", nsteps)
    graph_sim_multiscale_2 = @test_nowarn PlantSimEngine.GraphSimulation(mtg, mapping_without_vectors_2, nsteps=nsteps, check=true, outputs=out_multiscale)

    @test to_initialize(mapping_without_vectors_2) == Dict()

    sim_multiscale_2 = run!(graph_sim_multiscale_2,
        meteo_day,
        PlantMeteo.Constants(),
        nothing;
        check=true,
        executor=SequentialEx()
    )

    @test compare_outputs_graphsim(graph_sim_multiscale, graph_sim_multiscale_2)
end
