module TwoPlantAllocationTests

using Test, PlantSimEngine, Dates

include(joinpath(@__DIR__, "..", "examples", "two_plant_allocation.jl"))
using .TwoPlantAllocationExample

function allocation_status(offer, leaf_demand, wood_demand; initial=(0, 0, 0))
    Status(
        carbon_offer=offer,
        leaf_demand=leaf_demand,
        wood_demand=wood_demand,
        leaf_growth=zero(offer),
        wood_growth=zero(offer),
        reserve_change=zero(offer),
        leaf_carbon=oftype(offer, initial[1]),
        wood_carbon=oftype(offer, initial[2]),
        reserve_carbon=oftype(offer, initial[3]),
    )
end

allocation_amounts(status) =
    (status.leaf_growth, status.wood_growth, status.reserve_change)
carbon_stocks(status) =
    (status.leaf_carbon, status.wood_carbon, status.reserve_carbon)

function calculate!(model, status)
    PlantSimEngine.run!(model, status, NamedTuple(), nothing, nothing)
    return status
end

@testset "Allocation equations and carbon conservation" begin
    cases = (
        (name="balanced supply", offer=10.0, leaf=8.0, wood=2.0,
            fixed=(5.0, 2.0, 3.0), demand=(8.0, 2.0, 0.0)),
        (name="scarce supply", offer=4.0, leaf=8.0, wood=2.0,
            fixed=(2.0, 1.2, 0.8), demand=(3.2, 0.8, 0.0)),
        (name="supply exceeds both demands", offer=20.0, leaf=3.0, wood=2.0,
            fixed=(3.0, 2.0, 15.0), demand=(3.0, 2.0, 15.0)),
        (name="no supply", offer=0.0, leaf=8.0, wood=2.0,
            fixed=(0.0, 0.0, 0.0), demand=(0.0, 0.0, 0.0)),
        (name="no demand", offer=10.0, leaf=0.0, wood=0.0,
            fixed=(0.0, 0.0, 10.0), demand=(0.0, 0.0, 10.0)),
        (name="wood demand only", offer=10.0, leaf=0.0, wood=2.0,
            fixed=(0.0, 2.0, 8.0), demand=(0.0, 2.0, 8.0)),
    )

    for case in cases
        @testset "$(case.name)" begin
            for (model, expected) in (
                (FixedFractionAllocation(0.5, 0.3), case.fixed),
                (DemandAllocation(), case.demand),
            )
                initial = (11.0, 17.0, 23.0)
                status = allocation_status(case.offer, case.leaf, case.wood; initial)
                calculate!(model, status)

                @test all(isapprox.(allocation_amounts(status), expected))
                @test all(isapprox.(carbon_stocks(status), initial .+ expected))
                @test sum(allocation_amounts(status)) ≈ case.offer
                @test sum(carbon_stocks(status)) - sum(initial) ≈ case.offer
                @test 0 <= status.leaf_growth <= case.leaf
                @test 0 <= status.wood_growth <= case.wood
                @test status.reserve_change >= 0
            end
        end
    end
end

@testset "Allocation rejects invalid fractions and inputs" begin
    for fractions in ((-0.1, 0.3), (0.5, -0.1), (0.8, 0.3), (1.1, 0.0),
                      (NaN, 0.3), (0.5, NaN), (Inf, 0.3), (0.5, Inf))
        @test_throws ArgumentError FixedFractionAllocation(fractions...)
    end

    for model in (FixedFractionAllocation(0.5, 0.3), DemandAllocation())
        for input in (:carbon_offer, :leaf_demand, :wood_demand)
            for invalid in (-1.0, NaN, Inf, -Inf)
                status = allocation_status(10.0, 8.0, 2.0)
                calculate!(model, status)
                saved_amounts = allocation_amounts(status)
                saved_stocks = carbon_stocks(status)
                setproperty!(status, input, invalid)
                @test_throws ArgumentError calculate!(model, status)
                @test allocation_amounts(status) == saved_amounts
                @test carbon_stocks(status) == saved_stocks
            end
        end
    end

    overflow = allocation_status(10.0, floatmax(Float64), floatmax(Float64))
    @test_throws ArgumentError calculate!(DemandAllocation(), overflow)
    @test carbon_stocks(overflow) == (0.0, 0.0, 0.0)

    template = allocation_template(FixedFractionAllocation(0.5, 0.3))
    @test_throws ArgumentError allocation_plant(:invalid, template; carbon_offer=-1.0)
    @test_throws ArgumentError allocation_plant(:invalid, template; leaf_demand=NaN)
    @test_throws ArgumentError allocation_plant(:invalid, template; wood_demand=Inf)
end

@testset "Boundary allocation fractions remain valid" begin
    for (fractions, expected) in (
        ((0.0, 0.0), (0.0, 0.0, 10.0)),
        ((1.0, 0.0), (8.0, 0.0, 2.0)),
        ((0.0, 1.0), (0.0, 2.0, 8.0)),
    )
        status = allocation_status(10.0, 8.0, 2.0)
        calculate!(FixedFractionAllocation(fractions...), status)
        @test allocation_amounts(status) == expected
        @test sum(carbon_stocks(status)) == 10.0
    end
end

@testset "Roundoff preserves nonnegative allocation and demand caps" begin
    cases = (
        (FixedFractionAllocation(0.01f0, 0.99f0), 0.7f0, 10.0f0, 10.0f0),
        (DemandAllocation{Float32}(), 0.3f0, 0.1f0, 0.2f0),
        (DemandAllocation(), 1.0, 0.2, 0.1),
    )
    for (model, offer, leaf_demand, wood_demand) in cases
        status = allocation_status(offer, leaf_demand, wood_demand)
        calculate!(model, status)
        # Exact inequalities catch a negative reserve or an allocation just
        # above demand; approximate equality alone would hide these defects.
        @test 0 <= status.leaf_growth <= leaf_demand
        @test 0 <= status.wood_growth <= wood_demand
        @test status.reserve_change >= 0
        @test sum(allocation_amounts(status)) ≈ offer
        @test sum(carbon_stocks(status)) ≈ offer
    end
end

@testset "Repeated calculations replace step outputs and preserve stocks" begin
    for model in (FixedFractionAllocation(0.5, 0.3), DemandAllocation())
        status = allocation_status(10.0, 8.0, 2.0)
        calculate!(model, status)
        saved_stocks = carbon_stocks(status)

        status.carbon_offer = 0.0
        calculate!(model, status)
        @test allocation_amounts(status) == (0.0, 0.0, 0.0)
        @test carbon_stocks(status) == saved_stocks

        status.carbon_offer = 4.0
        status.leaf_demand = 0.0
        status.wood_demand = 0.0
        calculate!(model, status)
        @test allocation_amounts(status) == (0.0, 0.0, 4.0)
        @test carbon_stocks(status) == saved_stocks .+ (0.0, 0.0, 4.0)
        @test sum(carbon_stocks(status)) ≈ 14.0
    end
end

@testset "Float32 allocation and alternative-model declarations" begin
    fixed = FixedFractionAllocation(0.5f0, 0.3f0)
    demand = DemandAllocation{Float32}()
    @test fixed isa PlantSimEngine.Examples.AbstractCarbon_AllocationModel
    @test demand isa PlantSimEngine.Examples.AbstractCarbon_AllocationModel
    @test typeof(fixed) != typeof(demand)
    @test process(fixed) == process(demand) == :carbon_allocation

    comparison = Authoring.compare_models(fixed, demand)
    @test comparison.same_process
    @test comparison.override_compatible
    @test !comparison.requires_binding_changes

    for (model, expected) in ((fixed, (5.0f0, 2.0f0, 3.0f0)),
                              (demand, (8.0f0, 2.0f0, 0.0f0)))
        status = allocation_status(10.0f0, 8.0f0, 2.0f0)
        calculate!(model, status)
        @test allocation_amounts(status) == expected
        @test all(value -> value isa Float32, allocation_amounts(status))
        @test all(value -> value isa Float32, carbon_stocks(status))
        @test Authoring.validate_model(model; strict=true).valid
    end
end

@testset "Daily carbon offers cannot be reapplied every hour" begin
    for model in (FixedFractionAllocation(0.5, 0.3), DemandAllocation())
        hourly = CompositeModel(model;
            status=(carbon_offer=10.0, leaf_demand=8.0, wood_demand=2.0),
            environment=(duration=Hour(1),))
        @test_throws "timestep_hint.required=1 day" run!(hourly; steps=1)
    end
end

@testset "Two plants compare different allocation models in one simulation" begin
    scenario = build_allocation_comparison()
    @test scenario isa CompositeModel
    @test Set(object_ids(scenario)) == Set((ObjectId(:plant_a), ObjectId(:plant_b)))
    @test Authoring.validate_scenario(scenario; strict=true).valid

    applications = Diagnostics.explain_applications(scenario)
    application_a = only(row for row in applications if row.application_id == :plant_a__allocation)
    application_b = only(row for row in applications if row.application_id == :plant_b__allocation)
    @test length(applications) == 2
    @test application_a.process == application_b.process
    @test application_a.model_type <: FixedFractionAllocation
    @test application_b.model_type <: DemandAllocation
    @test application_a.target_ids == [:plant_a]
    @test application_b.target_ids == [:plant_b]

    simulation = run!(scenario; outputs=:all)
    state_a = final_state(simulation, :plant_a)
    state_b = final_state(simulation, :plant_b)
    @test current_step(simulation) == 1
    @test allocation_amounts(state_a) == (5.0, 2.0, 3.0)
    @test allocation_amounts(state_b) == (8.0, 2.0, 0.0)
    @test carbon_stocks(state_a) == (5.0, 2.0, 3.0)
    @test carbon_stocks(state_b) == (8.0, 2.0, 0.0)
    @test sum(carbon_stocks(state_a)) + sum(carbon_stocks(state_b)) == 20.0

    continue!(simulation; steps=2)
    @test current_step(simulation) == 3
    @test carbon_stocks(final_state(simulation, :plant_a)) == (15.0, 6.0, 9.0)
    @test carbon_stocks(final_state(simulation, :plant_b)) == (24.0, 6.0, 0.0)

    # With no new carbon, plant A must stop growing without reusing yesterday's
    # outputs. Plant B still receives its own unchanged supply and demands.
    status_a = model_status(scenario, :plant_a)
    status_b = model_status(scenario, :plant_b)
    status_a.carbon_offer = 0.0
    @test (status_b.carbon_offer, status_b.leaf_demand, status_b.wood_demand) == (10.0, 8.0, 2.0)
    step!(simulation)
    @test current_step(simulation) == 4
    @test allocation_amounts(final_state(simulation, :plant_a)) == (0.0, 0.0, 0.0)
    @test carbon_stocks(final_state(simulation, :plant_a)) == (15.0, 6.0, 9.0)
    @test carbon_stocks(final_state(simulation, :plant_b)) == (32.0, 8.0, 0.0)

    # Carbon offered to a plant with no growth demand goes entirely to reserve.
    status_a.carbon_offer = 4.0
    status_a.leaf_demand = 0.0
    status_a.wood_demand = 0.0
    continue!(simulation; steps=2)
    @test current_step(simulation) == 6
    @test allocation_amounts(final_state(simulation, :plant_a)) == (0.0, 0.0, 4.0)
    @test allocation_amounts(final_state(simulation, :plant_b)) == (8.0, 2.0, 0.0)
    @test carbon_stocks(final_state(simulation, :plant_a)) == (15.0, 6.0, 17.0)
    @test carbon_stocks(final_state(simulation, :plant_b)) == (48.0, 12.0, 0.0)
    @test (status_b.carbon_offer, status_b.leaf_demand, status_b.wood_demand) == (10.0, 8.0, 2.0)

    rows = collect_outputs(simulation; sink=nothing)
    expected = (
        plant_a=(
            leaf_growth=[5.0, 5.0, 5.0, 0.0, 0.0, 0.0],
            wood_growth=[2.0, 2.0, 2.0, 0.0, 0.0, 0.0],
            reserve_change=[3.0, 3.0, 3.0, 0.0, 4.0, 4.0],
            leaf_carbon=[5.0, 10.0, 15.0, 15.0, 15.0, 15.0],
            wood_carbon=[2.0, 4.0, 6.0, 6.0, 6.0, 6.0],
            reserve_carbon=[3.0, 6.0, 9.0, 9.0, 13.0, 17.0],
        ),
        plant_b=(
            leaf_growth=fill(8.0, 6),
            wood_growth=fill(2.0, 6),
            reserve_change=zeros(6),
            leaf_carbon=[8.0, 16.0, 24.0, 32.0, 40.0, 48.0],
            wood_carbon=[2.0, 4.0, 6.0, 8.0, 10.0, 12.0],
            reserve_carbon=zeros(6),
        ),
    )
    @test length(rows) == 2 * 6 * 6
    for (plant_id, plant_expected) in pairs(expected)
        application_id = Symbol(plant_id, "__allocation")
        for (variable, expected_values) in pairs(plant_expected)
            stream = filter(row -> row.object_id == plant_id && row.variable == variable, rows)
            @test getproperty.(stream, :application_id) == fill(application_id, 6)
            @test getproperty.(stream, :timestep) == collect(1:6)
            @test getproperty.(stream, :value) ≈ expected_values
        end
    end

    cumulative_offers = (
        plant_a=[10.0, 20.0, 30.0, 30.0, 34.0, 38.0],
        plant_b=[10.0, 20.0, 30.0, 40.0, 50.0, 60.0],
    )
    stock_variables = (:leaf_carbon, :wood_carbon, :reserve_carbon)
    for timestep in 1:6
        scene_carbon = 0.0
        for (plant_id, supplied) in pairs(cumulative_offers)
            stored_carbon = sum(
                row.value for row in rows
                if row.object_id == plant_id && row.timestep == timestep &&
                   row.variable in stock_variables
            )
            @test stored_carbon ≈ supplied[timestep]
            scene_carbon += stored_carbon
        end
        @test scene_carbon ≈ cumulative_offers.plant_a[timestep] + cumulative_offers.plant_b[timestep]
    end
end

@testset "Float32 survives plant templates and model replacement" begin
    daily_inputs = (carbon_offer=10.0f0, leaf_demand=8.0f0, wood_demand=2.0f0)
    scenario = build_allocation_comparison(
        fixed_model=FixedFractionAllocation(0.5f0, 0.3f0),
        demand_model=DemandAllocation{Float32}(),
        plant_a=daily_inputs,
        plant_b=daily_inputs,
    )
    simulation = run!(scenario; steps=2, outputs=:all)
    @test carbon_stocks(final_state(simulation, :plant_a)) == (10.0f0, 4.0f0, 6.0f0)
    @test carbon_stocks(final_state(simulation, :plant_b)) == (16.0f0, 4.0f0, 0.0f0)
    @test all(row -> row.value isa Float32, collect_outputs(simulation; sink=nothing))
end

end # module TwoPlantAllocationTests
