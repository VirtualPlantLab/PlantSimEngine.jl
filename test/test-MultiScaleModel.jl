@testset "MultiScaleModel: case 1" begin
    models = MultiScaleModel(
        model=ToyLAIModel(),
        mapping=[:TT_cu => "Scene",],
    )

    @test models.model == ToyLAIModel()
    @test models.mapping == [:TT_cu => "Scene" => :TT_cu]
end;

@testset "MultiScaleModel: case 2" begin
    models = MultiScaleModel(
        model=ToyLAIModel(),
        mapping=[:TT_cu => ["Plant"],],
    )

    @test models.model == ToyLAIModel()
    @test models.mapping == [:TT_cu => ["Plant" => :TT_cu]]


    models = MultiScaleModel(
        model=ToyLAIModel(),
        mapping=[:TT_cu => ["Leaf", "Internode"],],
    )

    @test models.model == ToyLAIModel()
    @test models.mapping == [:TT_cu => ["Leaf" => :TT_cu, "Internode" => :TT_cu]]
end;


@testset "MultiScaleModel: case 2, several variables with different format" begin
    models = MultiScaleModel(
        model=ToyCAllocationModel(),
        mapping=[:carbon_assimilation => ["Leaf"], :carbon_demand => ["Leaf", "Internode"], :Rm => "Plant" => :Rm_plant],
    )

    @test models.model == ToyCAllocationModel()
    @test models.mapping == [:carbon_assimilation => ["Leaf" => :carbon_assimilation], :carbon_demand => ["Leaf" => :carbon_demand, "Internode" => :carbon_demand], :Rm => "Plant" => :Rm_plant]
end;