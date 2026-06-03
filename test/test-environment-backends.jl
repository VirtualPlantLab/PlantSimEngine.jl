using Dates

PlantSimEngine.@process "environment_probe" verbose = false
PlantSimEngine.@process "environment_temperature_update" verbose = false
PlantSimEngine.@process "environment_bad_output" verbose = false
PlantSimEngine.@process "environment_graph_leaf_probe" verbose = false
PlantSimEngine.@process "environment_graph_temperature_update" verbose = false
PlantSimEngine.@process "environment_scene_hard_graph_update" verbose = false

struct EnvironmentProbeModel <: AbstractEnvironment_ProbeModel end
struct EnvironmentTemperatureUpdateModel <: AbstractEnvironment_Temperature_UpdateModel end
struct EnvironmentBadOutputModel <: AbstractEnvironment_Bad_OutputModel end
struct EnvironmentGraphLeafProbeModel <: AbstractEnvironment_Graph_Leaf_ProbeModel end
struct EnvironmentGraphTemperatureUpdateModel <: AbstractEnvironment_Graph_Temperature_UpdateModel end
struct EnvironmentSceneHardGraphUpdateModel <: AbstractEnvironment_Scene_Hard_Graph_UpdateModel end

PlantSimEngine.inputs_(::EnvironmentProbeModel) = NamedTuple()
PlantSimEngine.outputs_(::EnvironmentProbeModel) = (meteo_seen=0.0,)
PlantSimEngine.meteo_inputs_(::EnvironmentProbeModel) = (T=0.0, CO2=400.0)

function PlantSimEngine.run!(::EnvironmentProbeModel, models, status, meteo, constants=nothing, extra=nothing)
    status.meteo_seen = meteo.T + 0.001 * meteo.CO2
    return nothing
end

PlantSimEngine.inputs_(::EnvironmentTemperatureUpdateModel) = NamedTuple()
PlantSimEngine.outputs_(::EnvironmentTemperatureUpdateModel) = (T=0.0,)
PlantSimEngine.meteo_inputs_(::EnvironmentTemperatureUpdateModel) = (T=0.0,)
PlantSimEngine.meteo_outputs_(::EnvironmentTemperatureUpdateModel) = (T=0.0,)

function PlantSimEngine.run!(::EnvironmentTemperatureUpdateModel, models, status, meteo, constants=nothing, extra=nothing)
    status.T = meteo.T + 1.0
    return nothing
end

PlantSimEngine.inputs_(::EnvironmentBadOutputModel) = NamedTuple()
PlantSimEngine.outputs_(::EnvironmentBadOutputModel) = NamedTuple()
PlantSimEngine.meteo_inputs_(::EnvironmentBadOutputModel) = (T=0.0,)
PlantSimEngine.meteo_outputs_(::EnvironmentBadOutputModel) = (T=0.0,)

function PlantSimEngine.run!(::EnvironmentBadOutputModel, models, status, meteo, constants=nothing, extra=nothing)
    return nothing
end

PlantSimEngine.inputs_(::EnvironmentGraphLeafProbeModel) = NamedTuple()
PlantSimEngine.outputs_(::EnvironmentGraphLeafProbeModel) = (meteo_seen=0.0,)
PlantSimEngine.meteo_inputs_(::EnvironmentGraphLeafProbeModel) = (T=0.0, CO2=400.0)

function PlantSimEngine.run!(::EnvironmentGraphLeafProbeModel, models, status, meteo, constants=nothing, extra=nothing)
    status.meteo_seen = meteo.T + 0.001 * meteo.CO2
    return nothing
end

PlantSimEngine.inputs_(::EnvironmentGraphTemperatureUpdateModel) = NamedTuple()
PlantSimEngine.outputs_(::EnvironmentGraphTemperatureUpdateModel) = (T=0.0,)
PlantSimEngine.meteo_inputs_(::EnvironmentGraphTemperatureUpdateModel) = (T=0.0,)
PlantSimEngine.meteo_outputs_(::EnvironmentGraphTemperatureUpdateModel) = (T=0.0,)

function PlantSimEngine.run!(::EnvironmentGraphTemperatureUpdateModel, models, status, meteo, constants=nothing, extra=nothing)
    status.T = meteo.T + 2.0
    return nothing
end

PlantSimEngine.dep(::EnvironmentSceneHardGraphUpdateModel) = (
    leaf_temperature=HardDomains(kind=:plant, scale=:Leaf, process=:environment_graph_temperature_update),
)
PlantSimEngine.inputs_(::EnvironmentSceneHardGraphUpdateModel) = NamedTuple()
PlantSimEngine.outputs_(::EnvironmentSceneHardGraphUpdateModel) = (hard_temperature_sum=0.0,)

function PlantSimEngine.run!(::EnvironmentSceneHardGraphUpdateModel, models, status, meteo, constants=nothing, extra=nothing)
    targets = dependency_targets(extra, :leaf_temperature)
    for target in targets
        run_target!(target; publish=true)
    end
    status.hard_temperature_sum = sum(target.status.T for target in targets)
    return nothing
end

struct ProbeEnvironmentBackend <: AbstractEnvironmentBackend
    nsteps::Int
    base_seconds::Float64
end

PlantSimEngine.get_nsteps(backend::ProbeEnvironmentBackend) = backend.nsteps
PlantSimEngine.base_step_seconds(backend::ProbeEnvironmentBackend) = backend.base_seconds
PlantSimEngine.environment_variables(::ProbeEnvironmentBackend) = Set([:T, :CO2, :Ca])

function PlantSimEngine.sample(
    ::ProbeEnvironmentBackend,
    variable::Symbol,
    support::EnvironmentSupport,
    time
)
    variable == :CO2 && return 410.0
    variable == :Ca && return 420.0
    variable == :T || error("Unexpected variable `$(variable)`.")
    offset = support.domain == :plant_b ? 100.0 : 0.0
    return offset + 10.0 + float(time)
end

struct MissingCO2EnvironmentBackend <: AbstractEnvironmentBackend end

PlantSimEngine.get_nsteps(::MissingCO2EnvironmentBackend) = 1
PlantSimEngine.base_step_seconds(::MissingCO2EnvironmentBackend) = 3600.0
PlantSimEngine.environment_variables(::MissingCO2EnvironmentBackend) = Set([:T])
PlantSimEngine.sample(::MissingCO2EnvironmentBackend, variable::Symbol, support::EnvironmentSupport, time) = 20.0

mutable struct ScatteringEnvironmentBackend <: AbstractEnvironmentBackend
    nsteps::Int
    base_seconds::Float64
    writes::Vector{NamedTuple}
    index_updates::Vector{Any}
end

PlantSimEngine.get_nsteps(backend::ScatteringEnvironmentBackend) = backend.nsteps
PlantSimEngine.base_step_seconds(backend::ScatteringEnvironmentBackend) = backend.base_seconds
PlantSimEngine.environment_variables(::ScatteringEnvironmentBackend) = Set([:T])
PlantSimEngine.sample(::ScatteringEnvironmentBackend, variable::Symbol, support::EnvironmentSupport, time) = 20.0 + float(time)

function PlantSimEngine.scatter!(
    backend::ScatteringEnvironmentBackend,
    variable::Symbol,
    support::EnvironmentSupport,
    value,
    time
)
    push!(backend.writes, (domain=support.domain, process=support.process, variable=variable, value=value, time=time))
    return nothing
end

function PlantSimEngine.update_index!(backend::ScatteringEnvironmentBackend, entities)
    push!(
        backend.index_updates,
        [
            (domain=entity.domain, kind=entity.kind, scale=entity.scale, nstatuses=length(entity.statuses))
            for entity in entities
        ],
    )
    return nothing
end

mutable struct GraphEnvironmentBackend <: AbstractEnvironmentBackend
    nsteps::Int
    base_seconds::Float64
    writes::Vector{NamedTuple}
    index_updates::Vector{Any}
end

PlantSimEngine.get_nsteps(backend::GraphEnvironmentBackend) = backend.nsteps
PlantSimEngine.base_step_seconds(backend::GraphEnvironmentBackend) = backend.base_seconds
PlantSimEngine.environment_variables(::GraphEnvironmentBackend) = Set([:T, :CO2])

function PlantSimEngine.sample(
    ::GraphEnvironmentBackend,
    variable::Symbol,
    support::EnvironmentSupport,
    time
)
    variable == :CO2 && return 410.0
    variable == :T || error("Unexpected variable `$(variable)`.")
    return 20.0 + float(time) + 0.1 * node_id(support.status.node)
end

function PlantSimEngine.scatter!(
    backend::GraphEnvironmentBackend,
    variable::Symbol,
    support::EnvironmentSupport,
    value,
    time
)
    push!(
        backend.writes,
        (
            domain=support.domain,
            scale=support.scale,
            process=support.process,
            node_id=node_id(support.status.node),
            variable=variable,
            value=value,
            time=time,
        ),
    )
    return nothing
end

function PlantSimEngine.update_index!(backend::GraphEnvironmentBackend, entities)
    push!(
        backend.index_updates,
        [
            (domain=entity.domain, kind=entity.kind, scale=entity.scale, nstatuses=length(entity.statuses))
            for entity in entities
        ],
    )
    return nothing
end

@testset "Environment backends" begin
    support = EnvironmentSupport(:plant_a, :Default, :environment_probe, nothing)
    global_backend = GlobalConstant(Atmosphere(T=20.0, Rh=0.65, Wind=1.0, CO2=410.0, duration=Dates.Hour(1)))
    @test sample(global_backend, :T, support, 1.0) == 20.0
    @test PlantSimEngine.get_nsteps(global_backend) == 1
    @test base_step_seconds(global_backend) == 3600.0
    @test environment_variables(GlobalConstant(nothing)) == Set{Symbol}()

    mapping = ModelMapping(
        ModelSpec(EnvironmentProbeModel()) |> TimeStepModel(Dates.Hour(1)),
        status=(meteo_seen=0.0,),
    )
    simulation_mapping = SimulationMapping(
        Domain(:plant_a, mapping; kind=:plant),
        Domain(:plant_b, mapping; kind=:plant),
    )

    sim = run!(simulation_mapping, ProbeEnvironmentBackend(3, 3600.0), check=true)
    @test status(sim, :plant_a).meteo_seen ≈ 13.41
    @test status(sim, :plant_b).meteo_seen ≈ 113.41

    environment = explain_environment(sim)
    @test environment.backend == ProbeEnvironmentBackend
    @test environment.nsteps == 3
    @test environment.base_step_seconds == 3600.0
    @test :CO2 in environment.variables

    bound_mapping = ModelMapping(
        ModelSpec(EnvironmentProbeModel()) |>
            TimeStepModel(Dates.Hour(1)) |>
            MeteoBindings(; CO2=(source=:Ca, reducer=MeanReducer())),
        status=(meteo_seen=0.0,),
    )
    bound_sim = run!(
        SimulationMapping(Domain(:plant_a, bound_mapping; kind=:plant)),
        ProbeEnvironmentBackend(1, 3600.0),
        check=true,
    )
    @test status(bound_sim, :plant_a).meteo_seen ≈ 11.42

    @test_throws "CO2" run!(
        SimulationMapping(Domain(:plant_a, mapping; kind=:plant)),
        MissingCO2EnvironmentBackend(),
        check=true,
    )
    @test_throws "CO2" run!(
        SimulationMapping(Domain(:plant_a, mapping; kind=:plant)),
        nothing,
        check=true,
    )

    update_mapping = ModelMapping(
        ModelSpec(EnvironmentTemperatureUpdateModel()) |> TimeStepModel(Dates.Hour(1)),
        status=(T=0.0,),
    )
    scattering_backend = ScatteringEnvironmentBackend(2, 3600.0, NamedTuple[], Any[])
    scatter_sim = run!(
        SimulationMapping(Domain(:plant_a, update_mapping; kind=:plant)),
        scattering_backend,
        check=true,
    )
    @test status(scatter_sim, :plant_a).T == 23.0
    @test scattering_backend.writes == [
        (domain=:plant_a, process=:environment_temperature_update, variable=:T, value=22.0, time=1.0),
        (domain=:plant_a, process=:environment_temperature_update, variable=:T, value=23.0, time=2.0),
    ]
    @test scattering_backend.index_updates == [
        [(domain=:plant_a, kind=:plant, scale=:Default, nstatuses=1)],
        [(domain=:plant_a, kind=:plant, scale=:Default, nstatuses=1)],
    ]

    @test_throws "GlobalConstant is immutable" run!(
        SimulationMapping(Domain(:plant_a, update_mapping; kind=:plant)),
        Atmosphere(T=20.0, Rh=0.65, Wind=1.0, duration=Dates.Hour(1)),
        check=true,
    )

    bad_mapping = ModelMapping(
        ModelSpec(EnvironmentBadOutputModel()) |> TimeStepModel(Dates.Hour(1)),
        status=NamedTuple(),
    )
    @test_throws "status does not contain" run!(
        SimulationMapping(Domain(:plant_a, bad_mapping; kind=:plant)),
        ScatteringEnvironmentBackend(1, 3600.0, NamedTuple[], Any[]),
        check=true,
    )

    scene = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    plant = Node(scene, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    leaf_1 = Node(plant, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 2))
    leaf_2 = Node(plant, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 2, 2))
    leaf_ids = sort([node_id(leaf_1), node_id(leaf_2)])
    graph_mapping = ModelMapping(
        :Leaf => (
            ModelSpec(EnvironmentGraphLeafProbeModel()) |> TimeStepModel(Dates.Hour(1)),
        ),
    )
    graph_backend = GraphEnvironmentBackend(2, 3600.0, NamedTuple[], Any[])
    graph_sim = run!(
        scene,
        SimulationMapping(Domain(:plant_a, graph_mapping; kind=:plant, selector=plant)),
        graph_backend,
        check=true,
    )
    graph_values = graph_sim.outputs[(DomainModelKey(:plant_a, :Leaf, :environment_graph_leaf_probe), :meteo_seen)]
    @test graph_values == [
        [20.0 + 1.0 + 0.1 * leaf_ids[1] + 0.410, 20.0 + 1.0 + 0.1 * leaf_ids[2] + 0.410],
        [20.0 + 2.0 + 0.1 * leaf_ids[1] + 0.410, 20.0 + 2.0 + 0.1 * leaf_ids[2] + 0.410],
    ]
    @test graph_backend.index_updates == [
        [(domain=:plant_a, kind=:plant, scale=:Leaf, nstatuses=2)],
        [(domain=:plant_a, kind=:plant, scale=:Leaf, nstatuses=2)],
    ]

    scatter_scene = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    scatter_plant = Node(scatter_scene, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    scatter_leaf = Node(scatter_plant, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 2))
    scatter_mapping = ModelMapping(
        :Leaf => (
            ModelSpec(EnvironmentGraphTemperatureUpdateModel()) |> TimeStepModel(Dates.Hour(1)),
        ),
    )
    graph_scatter_backend = GraphEnvironmentBackend(1, 3600.0, NamedTuple[], Any[])
    graph_scatter_sim = run!(
        scatter_scene,
        SimulationMapping(Domain(:plant_a, scatter_mapping; kind=:plant, selector=scatter_plant)),
        graph_scatter_backend,
        check=true,
    )
    @test only(status(graph_scatter_sim, :plant_a, :Leaf)).T ≈ 20.0 + 1.0 + 0.1 * node_id(scatter_leaf) + 2.0
    @test graph_scatter_backend.writes == [
        (
            domain=:plant_a,
            scale=:Leaf,
            process=:environment_graph_temperature_update,
            node_id=node_id(scatter_leaf),
            variable=:T,
            value=20.0 + 1.0 + 0.1 * node_id(scatter_leaf) + 2.0,
            time=1.0,
        ),
    ]

    hard_scatter_scene = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    hard_scatter_plant = Node(hard_scatter_scene, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    hard_scatter_leaf = Node(hard_scatter_plant, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 2))
    hard_scatter_mapping = ModelMapping(
        :Leaf => (
            ModelSpec(EnvironmentGraphTemperatureUpdateModel()) |> TimeStepModel(Dates.Hour(1)),
        ),
    )
    hard_scatter_scene_mapping = ModelMapping(
        ModelSpec(EnvironmentSceneHardGraphUpdateModel()) |> TimeStepModel(Dates.Hour(1)),
        status=(hard_temperature_sum=0.0,),
    )
    hard_graph_scatter_backend = GraphEnvironmentBackend(1, 3600.0, NamedTuple[], Any[])
    hard_graph_scatter_sim = run!(
        hard_scatter_scene,
        SimulationMapping(
            Domain(:plant_a, hard_scatter_mapping; kind=:plant, selector=hard_scatter_plant),
            Domain(:scene, hard_scatter_scene_mapping; kind=:scene),
        ),
        hard_graph_scatter_backend,
        check=true,
    )
    expected_hard_T = 20.0 + 1.0 + 0.1 * node_id(hard_scatter_leaf) + 2.0
    @test only(status(hard_graph_scatter_sim, :plant_a, :Leaf)).T ≈ expected_hard_T
    @test status(hard_graph_scatter_sim, :scene).hard_temperature_sum ≈ expected_hard_T
    @test hard_graph_scatter_backend.writes == [
        (
            domain=:plant_a,
            scale=:Leaf,
            process=:environment_graph_temperature_update,
            node_id=node_id(hard_scatter_leaf),
            variable=:T,
            value=expected_hard_T,
            time=1.0,
        ),
    ]
end
