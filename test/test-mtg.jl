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

    to_init = init_mtg_models!(mtg, models, length(meteo), attr_name=:models)
    @test to_init == Dict{String,Set{Symbol}}("Leaf" => Set(Symbol[:var2]))
    @test NamedTuple(get_node(mtg, 3)[:models][1]) == (var4=-Inf, var5=-Inf, var6=-Inf, var1=var1, var3=-Inf, var2=var2)

    # The following shouldn't work because var2 has only one value: 
    if VERSION < v"1.8" # We test differently depending on the julia version because the format of the error message changed
        @test_throws ErrorException init_mtg_models!(mtg, models, 10)
    else
        @test_throws ["The attribute", "in node 3"] init_mtg_models!(mtg, models, 10)
    end
    # Same with two time-steps:
    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Plant", 1, 1))
    internode = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
    leaf = Node(internode, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))
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
    to_init = init_mtg_models!(mtg, models, length(meteo), attr_name=:models)
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

    to_init = init_mtg_models!(mtg, models, length(meteo), attr_name=:models)

    nsteps = length(meteo)

    @test NamedTuple(status(get_node(mtg, 3)[:models])[1]) == (var4=-Inf, var5=-Inf, var6=-Inf, var1=15.0, var3=-Inf, var2=0.3)

    # If we change the value of var1 in the status...:
    status(get_node(mtg, 3)[:models])[1][:var1] = 16.0
    # ... the value in the attributes are too (because they are the same object):
    @test get_node(mtg, 3)[:var1][1] == 16.0
end


@testset "MTG simulation: Dict attributes" begin
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

    to_init = init_mtg_models!(mtg, models, length(meteo), attr_name=:models)

    attr_before_sim = deepcopy(leaf.attributes)

    @test attr_before_sim[:var1] == var1
    # :var2 was repeated for each time-step at init, so it should be a vector now:
    @test attr_before_sim[:var2] == [var2, var2]
    # :var3 was not initialized, so it should be a vector of -Inf:
    @test attr_before_sim[:var3] == [-Inf, -Inf]
    @test attr_before_sim[:var4] == [-Inf, -Inf]
    @test attr_before_sim[:var5] == [-Inf, -Inf]
    @test attr_before_sim[:var6] == [-Inf, -Inf]

    # Making the simulation:
    constants = PlantMeteo.Constants()
    MultiScaleTreeGraph.transform!(
        mtg,
        (node) -> run!(node[:models], meteo, constants, node),
        filter_fun=node -> node[:models] !== nothing
    )

    # The inputs should not have changed:
    @test attr_before_sim[:var1] == leaf.attributes[:var1]
    @test attr_before_sim[:var2] == leaf.attributes[:var2]
    # The outputs should have changed:
    @test attr_before_sim[:var3] != leaf.attributes[:var3]

    # And they should have changed according to the models:
    @test leaf.attributes[:var3] == models["Leaf"].models.process1.a .+ attr_before_sim[:var1] .* attr_before_sim[:var2]
    @test leaf.attributes[:var4] == leaf.attributes[:var3] .* 4.0
    @test leaf.attributes[:var5] == (leaf.attributes[:var4] ./ 2.0) .+ 1.0 .* meteo.T .+ 2.0 .* meteo.Wind .+ 3.0 .* meteo.Rh
    @test leaf.attributes[:var6] == leaf.attributes[:var5] .+ leaf.attributes[:var4]
end