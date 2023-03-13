meteo = Weather(
    [
    Atmosphere(T=20.0, Wind=1.0, Rh=0.65),
    Atmosphere(T=25.0, Wind=0.5, Rh=0.8)
]
)
# Here we initialise var1 to a constant value:
@testset "MTG initialisation" begin
    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Plant", 1, 1))
    internode = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
    leaf = Node(mtg, MultiScaleTreeGraph.NodeMTG("<", "Leaf", 1, 2))
    var1 = 15.0
    var2 = 0.3
    leaf[:var2] = var2

    models = Dict(
        "Leaf" => ModelList(
            process1=Process1Model(1.0),
            process2=Process2Model(),
            process3=Process3Model(),
            status=(var1=var1,)
        )
    )

    @test descendants(mtg, :var1) == [nothing, nothing]
    @test descendants(mtg, :var2) == [nothing, var2]

    to_init = init_mtg_models!(mtg, models, length(meteo))
    @test to_init == Dict{String,Set{Symbol}}("Leaf" => Set(Symbol[:var2]))
    @test NamedTuple(get_node(mtg, 3)[:models][1]) == (var4=-Inf, var5=-Inf, var6=-Inf, var1=var1, var3=-Inf, var2=var2)

    # The following shouldn't work because var2 has only one value: 
    @test_throws ["Issue in function", "for node #3"] init_mtg_models!(mtg, models, 10)

    # Same with two time-steps:
    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Plant", 1, 1))
    internode = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
    leaf = Node(mtg, MultiScaleTreeGraph.NodeMTG("<", "Leaf", 1, 2))
    var1 = [15.0, 16.0]
    var2 = [0.3, 0.4]
    leaf[:var2] = var2

    models = Dict(
        "Leaf" => ModelList(
            process1=Process1Model(1.0),
            process2=Process2Model(),
            process3=Process3Model(),
            status=(var1=var1,)
        )
    )
    to_init = init_mtg_models!(mtg, models, length(meteo))
    @test NamedTuple(status(get_node(mtg, 3)[:models])[2]) == (var4=-Inf, var5=-Inf, var6=-Inf, var1=16.0, var3=-Inf, var2=0.4)
end

@testset "MTG status update" begin
    # After initialization, the output variables for computation are pre-allocated:
    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Plant", 1, 1))
    internode = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
    leaf = Node(mtg, MultiScaleTreeGraph.NodeMTG("<", "Leaf", 1, 2))
    var1 = [15.0, 16.0]
    var2 = 0.3
    leaf[:var1] = var1
    leaf[:var2] = var2

    models = Dict(
        "Leaf" => ModelList(
            process1=Process1Model(1.0),
            process2=Process2Model(),
            process3=Process3Model()
        )
    )

    to_init = init_mtg_models!(mtg, models, length(meteo))

    nsteps = length(meteo)

    @test NamedTuple(status(get_node(mtg, 3)[:models])[1]) == (var4=-Inf, var5=-Inf, var6=-Inf, var1=15.0, var3=-Inf, var2=0.3)

    # If we change the value of var1 in the status...:
    status(get_node(mtg, 3)[:models])[1][:var1] = 16.0
    # ... the value in the attributes are too (because they are the same object):
    @test get_node(mtg, 3)[:var1][1] == 16.0
end

#! make another way for the simulation: we compute all needed variables when parsing the MTG
#! with the right amount of steps also. To do that, we need to pass the models and the meteo
#! to the read_MTG function. This way we use a TimeStepTable to store the attributes, which 
#! will make the simulation faster.