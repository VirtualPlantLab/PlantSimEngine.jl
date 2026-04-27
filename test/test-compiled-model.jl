@testset "Merged model source compiler" begin
    mapping = ModelMapping(
        process4=Process4Model(),
        process3=Process3Model(),
        process2=Process2Model(),
        process1=Process1Model(1.0);
        status=(var0=1.0,)
    )

    script = compile_model(mapping; function_name=:compiled_dummy_model!)
    @test occursin("function compiled_dummy_model!(models, status, meteo, constants, extra)", script)
    @test occursin("using PlantSimEngine", script)
    @test occursin("using PlantSimEngine.Examples", script)
    @test occursin("model: Process4Model | process: process4 | scale: Default", script)
    @test occursin("source: " * joinpath(pkgdir(PlantSimEngine), "examples", "dummy.jl"), script)
    @test occursin("method: run!(::Process1Model", script)
    @test occursin("status.var1 = status.var0 + 0.01", script)
    @test occursin("status.var3 = models.process1.a + status.var1 * status.var2", script)
    @test !occursin("PlantSimEngine.run!(models.process", script)

    module_name = gensym(:CompiledModelTest)
    compiled_mod = Module(module_name)
    script_path = tempname() * ".jl"
    write(script_path, script)
    Base.include(compiled_mod, script_path)

    model_list = PlantSimEngine._modellist_from_model_mapping(mapping)
    compiled_status = deepcopy(status(model_list))
    meteo = Atmosphere(T=20.0, Wind=1.0, P=101.3, Rh=0.65)
    Core.eval(compiled_mod, :compiled_dummy_model!)(model_list.models, compiled_status, meteo, PlantMeteo.Constants(), nothing)

    normal_mapping = copy(mapping)
    run!(normal_mapping, meteo; executor=SequentialEx())
    normal_status = status(PlantSimEngine._modellist_from_model_mapping(normal_mapping))

    @test compiled_status.var1 == normal_status.var1
    @test compiled_status.var2 == normal_status.var2
    @test compiled_status.var3 == normal_status.var3
    @test compiled_status.var4 == normal_status.var4
    @test compiled_status.var5 == normal_status.var5
    @test compiled_status.var6 == normal_status.var6

    path = tempname() * ".jl"
    @test write_compiled_model(path, mapping; function_name=:compiled_dummy_model!) == path
    @test read(path, String) == script
end

function compiled_model_dynamic_fixture()
    mtg = import_mtg_example()
    meteo = Weather([
        Atmosphere(T=20.0, Wind=1.0, Rh=0.65),
        Atmosphere(T=25.0, Wind=0.5, Rh=0.8),
    ])

    mapping = ModelMapping(
        :Scene => ToyDegreeDaysCumulModel(),
        :Plant => (
            MultiScaleModel(
                model=ToyLAIModel(),
                mapped_variables=[:TT_cu => (:Scene => :TT_cu)],
            ),
            Beer(0.6),
            MultiScaleModel(
                model=ToyCAllocationModel(),
                mapped_variables=[
                    :carbon_assimilation => [:Leaf],
                    :carbon_demand => [:Leaf, :Internode],
                    :carbon_allocation => [:Leaf, :Internode],
                ],
            ),
            MultiScaleModel(
                model=ToyPlantRmModel(),
                mapped_variables=[:Rm_organs => [:Leaf => :Rm, :Internode => :Rm]],
            ),
        ),
        :Internode => (
            MultiScaleModel(
                model=ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
                mapped_variables=[:TT => (:Scene => :TT)],
            ),
            MultiScaleModel(
                model=ToyInternodeEmergence(TT_emergence=20.0),
                mapped_variables=[:TT_cu => (:Scene => :TT_cu)],
            ),
            ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
            Status(carbon_biomass=1.0),
        ),
        :Leaf => (
            MultiScaleModel(
                model=ToyAssimModel(),
                mapped_variables=[:soil_water_content => (:Soil => :soil_water_content), :aPPFD => (:Plant => :aPPFD)],
            ),
            MultiScaleModel(
                model=ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
                mapped_variables=[:TT => (:Scene => :TT)],
            ),
            ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
            Status(carbon_biomass=1.0),
        ),
        :Soil => (ToySoilWaterModel(),),
    )

    outputs = Dict(
        :Leaf => (:carbon_assimilation, :carbon_demand, :soil_water_content, :carbon_allocation),
        :Internode => (:carbon_allocation, :TT_cu_emergence),
        :Plant => (:carbon_allocation,),
        :Soil => (:soil_water_content,),
    )

    return mtg, meteo, mapping, outputs
end

@testset "Merged multiscale model source compiler" begin
    mtg, meteo, mapping, outputs = compiled_model_dynamic_fixture()
    sim = PlantSimEngine.GraphSimulation(mtg, mapping, nsteps=PlantSimEngine.get_nsteps(meteo), check=true, outputs=outputs)
    script = compile_model(sim; function_name=:compiled_mtg_model!)

    @test occursin("function compiled_mtg_model!(sim, meteo, constants)", script)
    @test occursin("Mode: same-rate multiscale MTG", script)
    @test occursin("variables are scale-scoped through each Status", script)
    @test occursin("PlantSimEngine._assert_compiled_sim_compatible", script)
    @test occursin("Model compatibility signature", script)
    @test occursin("while idx <= length(statuses[:Leaf])", script)
    @test occursin("scale: Leaf | initial_statuses: 2", script)
    @test occursin("model: ToyCAllocationModel | process: carbon_allocation | scale: Plant", script)

    compiled_mod = Module(gensym(:CompiledMTGModelTest))
    script_path = tempname() * ".jl"
    write(script_path, script)
    Base.include(compiled_mod, script_path)
    compiled_outputs = Core.eval(compiled_mod, :compiled_mtg_model!)(sim, meteo, PlantMeteo.Constants())

    mtg_normal, meteo_normal, mapping_normal, outputs_normal = compiled_model_dynamic_fixture()
    sim_normal = PlantSimEngine.GraphSimulation(mtg_normal, mapping_normal, nsteps=PlantSimEngine.get_nsteps(meteo_normal), check=true, outputs=outputs_normal)
    normal_outputs = run!(sim_normal, meteo_normal; executor=SequentialEx())

    @test length(mtg) == length(mtg_normal) == 9
    @test length(sim.statuses[:Scene]) == length(sim_normal.statuses[:Scene]) == 1
    @test length(sim.statuses[:Soil]) == length(sim_normal.statuses[:Soil]) == 1
    @test length(sim.statuses[:Plant]) == length(sim_normal.statuses[:Plant]) == 1
    @test length(sim.statuses[:Internode]) == length(sim_normal.statuses[:Internode]) == 3
    @test length(sim.statuses[:Leaf]) == length(sim_normal.statuses[:Leaf]) == 3

    @test sim.statuses[:Leaf][1].carbon_assimilation == sim_normal.statuses[:Leaf][1].carbon_assimilation
    @test sim.statuses[:Leaf][2].carbon_assimilation == sim_normal.statuses[:Leaf][2].carbon_assimilation
    @test sim.statuses[:Plant][1].carbon_assimilation == sim_normal.statuses[:Plant][1].carbon_assimilation
    @test sim.statuses[:Plant][1].carbon_assimilation isa PlantSimEngine.RefVector
    @test getfield(sim.statuses[:Plant][1].carbon_assimilation, :v)[1] === PlantSimEngine.refvalue(sim.statuses[:Leaf][1], :carbon_assimilation)

    @test convert_outputs(compiled_outputs, DataFrames.DataFrame) == convert_outputs(normal_outputs, DataFrames.DataFrame)

    mtg_wrong = import_mtg_example()
    meteo_wrong = Atmosphere(T=20.0, Wind=1.0, Rh=0.65)
    mapping_wrong = ModelMapping(:Soil => (ToySoilWaterModel(),))
    sim_wrong = PlantSimEngine.GraphSimulation(mtg_wrong, mapping_wrong, nsteps=1, check=true, outputs=Dict(:Soil => (:soil_water_content,)))
    @test_throws "Compiled model was generated for a different model mapping" Core.eval(compiled_mod, :compiled_mtg_model!)(
        sim_wrong,
        meteo_wrong,
        PlantMeteo.Constants(),
    )
end

function compiled_model_multirate_fixture()
    mtg = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    plant = MultiScaleTreeGraph.Node(mtg, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    MultiScaleTreeGraph.Node(mtg, MultiScaleTreeGraph.NodeMTG("+", :Soil, 1, 1))
    internode = MultiScaleTreeGraph.Node(plant, MultiScaleTreeGraph.NodeMTG("/", :Internode, 1, 2))
    MultiScaleTreeGraph.Node(internode, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 2))
    MultiScaleTreeGraph.Node(internode, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 2))

    daily = ClockSpec(24.0, 1.0)
    hourly = 1.0
    mapping = ModelMapping(
        :Scene => (
            ModelSpec(ToyDegreeDaysCumulModel()) |> TimeStepModel(daily),
        ),
        :Plant => (
            ModelSpec(ToyLAIModel()) |>
            MultiScaleModel([:TT_cu => (:Scene => :TT_cu)]) |>
            TimeStepModel(daily),
            ModelSpec(Beer(0.6)) |> TimeStepModel(hourly),
            ModelSpec(ToyCAllocationModel()) |>
            MultiScaleModel([
                :carbon_assimilation => [:Leaf],
                :carbon_demand => [:Leaf, :Internode],
                :carbon_allocation => [:Leaf, :Internode],
            ]) |>
            InputBindings(; carbon_assimilation=(process=process(ToyAssimModel()), var=:carbon_assimilation, scale=:Leaf, policy=Integrate())) |>
            TimeStepModel(daily),
            ModelSpec(ToyPlantRmModel()) |>
            MultiScaleModel([:Rm_organs => [:Leaf => :Rm, :Internode => :Rm]]) |>
            TimeStepModel(daily),
        ),
        :Internode => (
            ModelSpec(ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0)) |>
            MultiScaleModel([:TT => (:Scene => :TT)]) |>
            TimeStepModel(daily),
            ModelSpec(ToyInternodeEmergence(TT_emergence=1.0e6)) |>
            MultiScaleModel([:TT_cu => (:Scene => :TT_cu)]) |>
            TimeStepModel(daily),
            ModelSpec(ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004)) |> TimeStepModel(daily),
            Status(carbon_biomass=1.0),
        ),
        :Leaf => (
            ModelSpec(ToyAssimModel()) |>
            MultiScaleModel([:soil_water_content => (:Soil => :soil_water_content), :aPPFD => (:Plant => :aPPFD)]) |>
            TimeStepModel(hourly),
            ModelSpec(ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0)) |>
            MultiScaleModel([:TT => (:Scene => :TT)]) |>
            TimeStepModel(daily),
            ModelSpec(ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025)) |> TimeStepModel(daily),
            Status(carbon_biomass=1.0),
        ),
        :Soil => (
            ModelSpec(ToySoilWaterModel()) |> TimeStepModel(daily),
        ),
    )

    outputs = Dict(
        :Leaf => (:carbon_assimilation, :aPPFD, :carbon_demand),
        :Plant => (:LAI, :carbon_offer, :Rm),
        :Scene => (:TT, :TT_cu),
        :Soil => (:soil_water_content,),
        :Internode => (:carbon_demand, :TT_cu_emergence),
    )
    meteo = Weather(repeat([Atmosphere(T=20.0, Wind=1.0, Rh=0.65, Ri_PAR_f=300.0)], 26))

    return mtg, meteo, mapping, outputs
end

@testset "Merged multiscale model compiler supports multirate" begin
    mtg, meteo, mapping, outputs = compiled_model_multirate_fixture()
    sim = PlantSimEngine.GraphSimulation(mtg, mapping, nsteps=PlantSimEngine.get_nsteps(meteo), check=true, outputs=outputs)
    script = compile_model(sim; function_name=:compiled_multirate_mtg_model!)

    @test occursin("Mode: multi-rate multiscale MTG", script)
    @test occursin("tracked_outputs = nothing", script)
    @test occursin("PlantSimEngine.resolve_inputs_from_temporal_state!", script)
    @test occursin("PlantSimEngine.update_temporal_state_outputs!", script)
    @test occursin("PlantSimEngine.update_requested_outputs!", script)
    @test occursin("_mr_Leaf_carbon_assimilation_model = (models_by_scale[:Leaf]).carbon_assimilation", script)
    @test occursin("_mr_Leaf_carbon_assimilation_model_clock = PlantSimEngine._model_clock", script)
    @test occursin("while idx <= length(statuses[:Leaf])", script)

    compiled_mod = Module(gensym(:CompiledMultirateMTGModelTest))
    script_path = tempname() * ".jl"
    write(script_path, script)
    Base.include(compiled_mod, script_path)
    tracked = OutputRequest(:Leaf, :carbon_assimilation; name=:leaf_assimilation, process=process(ToyAssimModel()))
    compiled_outputs, compiled_requested = Core.eval(compiled_mod, :compiled_multirate_mtg_model!)(
        sim,
        meteo,
        PlantMeteo.Constants();
        tracked_outputs=tracked,
        return_requested_outputs=true,
        requested_outputs_sink=DataFrames.DataFrame,
    )

    mtg_normal, meteo_normal, mapping_normal, outputs_normal = compiled_model_multirate_fixture()
    sim_normal = PlantSimEngine.GraphSimulation(mtg_normal, mapping_normal, nsteps=PlantSimEngine.get_nsteps(meteo_normal), check=true, outputs=outputs_normal)
    normal_outputs, normal_requested = run!(
        sim_normal,
        meteo_normal;
        executor=SequentialEx(),
        tracked_outputs=tracked,
        return_requested_outputs=true,
        requested_outputs_sink=DataFrames.DataFrame,
    )

    @test sim.temporal_state.last_run == sim_normal.temporal_state.last_run
    @test convert_outputs(compiled_outputs, DataFrames.DataFrame) == convert_outputs(normal_outputs, DataFrames.DataFrame)
    @test compiled_requested[:leaf_assimilation] == normal_requested[:leaf_assimilation]
end

PlantSimEngine.@process "compiled_child" verbose = false
struct CompiledChildModel <: AbstractCompiled_ChildModel end
PlantSimEngine.inputs_(::CompiledChildModel) = (x=-Inf,)
PlantSimEngine.outputs_(::CompiledChildModel) = (y=-Inf,)
function PlantSimEngine.run!(::CompiledChildModel, models, status, meteo, constants=nothing, extra=nothing)
    status.y = status.x + 1.0
end

PlantSimEngine.@process "compiled_parent" verbose = false
struct CompiledParentModel <: AbstractCompiled_ParentModel end
PlantSimEngine.inputs_(::CompiledParentModel) = (x=-Inf,)
PlantSimEngine.outputs_(::CompiledParentModel) = (total=-Inf,)
PlantSimEngine.dep(::CompiledParentModel) = (compiled_child=AbstractCompiled_ChildModel => (:CompiledChildScale,),)
function PlantSimEngine.run!(::CompiledParentModel, models, status, meteo, constants=nothing, sim_object=nothing)
    child_status = sim_object.statuses[:CompiledChildScale][1]
    run!(sim_object.models[:CompiledChildScale].compiled_child, models, child_status, meteo, constants)
    status.total = status.x + child_status.y
end

@testset "Merged multiscale compiler inlines cross-scale hard dependencies" begin
    mtg = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", :CompiledParentScale, 1, 0))
    MultiScaleTreeGraph.Node(mtg, MultiScaleTreeGraph.NodeMTG("/", :CompiledChildScale, 1, 1))
    mapping = ModelMapping(
        :CompiledParentScale => (CompiledParentModel(), Status(x=10.0)),
        :CompiledChildScale => (CompiledChildModel(), Status(x=2.0)),
    )
    sim = PlantSimEngine.GraphSimulation(
        mtg,
        mapping,
        nsteps=1,
        check=true,
        outputs=Dict(:CompiledParentScale => (:total,), :CompiledChildScale => (:y,))
    )

    script = compile_model(sim; function_name=:compiled_cross_scale_hard_dep!)
    @test occursin("sim.models[:CompiledChildScale]", script)
    @test !occursin("run!(sim.models[:CompiledChildScale].compiled_child", script)

    compiled_mod = Module(gensym(:CompiledCrossScaleHardDepTest))
    script_path = tempname() * ".jl"
    write(script_path, script)
    Base.include(compiled_mod, script_path)
    Core.eval(compiled_mod, :compiled_cross_scale_hard_dep!)(sim, Atmosphere(T=20.0, Wind=1.0, Rh=0.65), PlantMeteo.Constants())

    @test sim.statuses[:CompiledChildScale][1].y == 3.0
    @test sim.statuses[:CompiledParentScale][1].total == 13.0
end
