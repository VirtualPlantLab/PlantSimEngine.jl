@testset "MultiScaleModel: mapping formatting" begin
    std_mapping = :plant_surfaces => "Plant" => :plant_surfaces
    @test PlantSimEngine._get_var(:plant_surfaces => "Plant") == std_mapping # Case 1
    @test PlantSimEngine._get_var(:plant_surfaces => ["Plant"]) == (:plant_surfaces => ["Plant" => :plant_surfaces]) # Case 2
    @test PlantSimEngine._get_var(:plant_surfaces => ["Plant", "Leaf"]) == (:plant_surfaces => ["Plant" => :plant_surfaces, "Leaf" => :plant_surfaces]) # Case 3
    @test PlantSimEngine._get_var(:plant_surfaces => "Plant" => :plant_surfaces) == std_mapping # Similar to case 1
    @test PlantSimEngine._get_var(:plant_surfaces => "Plant" => :surface) == (:plant_surfaces => "Plant" => :surface) # Case 4
    @test PlantSimEngine._get_var(:plant_surfaces => ["Plant" => :surface, "Leaf" => :surface]) == (:plant_surfaces => ["Plant" => :surface, "Leaf" => :surface]) # Case 5
    @test PlantSimEngine._get_var(:plant_surfaces => ["Plant" => :surface_1, "Leaf" => :surface_2]) == (:plant_surfaces => ["Plant" => :surface_1, "Leaf" => :surface_2]) # Case 5
    @test PlantSimEngine._get_var(PreviousTimeStep(:plant_surfaces) => "Plant") == (PreviousTimeStep(:plant_surfaces, :unknown) => "Plant" => :plant_surfaces) # Case 6
    @test PlantSimEngine._get_var(PreviousTimeStep(:plant_surfaces) => "Plant" => :surface) == (PreviousTimeStep(:plant_surfaces, :unknown) => "Plant" => :surface) # Case 6
    @test PlantSimEngine._get_var(PreviousTimeStep(:plant_surfaces) => ["Plant" => :surface, "Leaf" => :surface]) == (PreviousTimeStep(:plant_surfaces, :unknown) => ["Plant" => :surface, "Leaf" => :surface]) # Case 6
    @test PlantSimEngine._get_var(PreviousTimeStep(:plant_surfaces)) == (PreviousTimeStep(:plant_surfaces, :unknown) => "" => :plant_surfaces) # Case 7
    @test PlantSimEngine._get_var(PreviousTimeStep(:plant_surfaces) => :surface) == (PreviousTimeStep(:plant_surfaces, :unknown) => "" => :surface)
    @test PlantSimEngine._get_var(PreviousTimeStep(:plant_surfaces) => :surface, :test) == (PreviousTimeStep(:plant_surfaces, :test) => "" => :surface)
end;

@testset "MultiScaleModel: case 1" begin
    models = MultiScaleModel(
        model=ToyLAIModel(),
        mapped_variables=[:TT_cu => "Scene",],
    )

    @test models.model == ToyLAIModel()
    @test models.mapped_variables == [:TT_cu => "Scene" => :TT_cu]
end;

@testset "MultiScaleModel: case 2" begin
    models = MultiScaleModel(
        model=ToyLAIModel(),
        mapped_variables=[:TT_cu => ["Plant"],],
    )

    @test models.model == ToyLAIModel()
    @test models.mapped_variables == [:TT_cu => ["Plant" => :TT_cu]]


    models = MultiScaleModel(
        model=ToyLAIModel(),
        mapped_variables=[:TT_cu => ["Leaf", "Internode"],],
    )

    @test models.model == ToyLAIModel()
    @test models.mapped_variables == [:TT_cu => ["Leaf" => :TT_cu, "Internode" => :TT_cu]]
end;


@testset "MultiScaleModel: case 2, several variables with different format" begin
    models = MultiScaleModel(
        model=ToyCAllocationModel(),
        mapped_variables=[:carbon_assimilation => ["Leaf"], :carbon_demand => ["Leaf", "Internode"], :Rm => "Plant" => :Rm_plant],
    )

    @test models.model == ToyCAllocationModel()
    @test models.mapped_variables == [:carbon_assimilation => ["Leaf" => :carbon_assimilation], :carbon_demand => ["Leaf" => :carbon_demand, "Internode" => :carbon_demand], :Rm => "Plant" => :Rm_plant]
end;


@testset "MultiScaleModel: case with PreviousTimeStep => ..." begin
    models = MultiScaleModel(
        model=ToyLAIfromLeafAreaModel(1.0),
        mapped_variables=[
            PreviousTimeStep(:plant_surfaces) => "Plant" => :surface,
        ],
    )

    @test models.model == ToyLAIfromLeafAreaModel(1.0)
    @test models.mapped_variables == [PreviousTimeStep(:plant_surfaces, :LAI_Dynamic) => ("Plant" => :surface)]
end;

@testset "MultiScaleModel: several types of mapping" begin
    models = MultiScaleModel(
        model=ToyLightPartitioningModel(),
        mapped_variables=[
            :aPPFD_larger_scale => "Scene" => :aPPFD,
            :total_surface => "Scene"
        ],
    )

    @test models.model == ToyLightPartitioningModel()
    @test models.mapped_variables == [:aPPFD_larger_scale => ("Scene" => :aPPFD), :total_surface => ("Scene" => :total_surface)]
end