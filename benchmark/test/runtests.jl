using CSV
using DataFrames
using Dates
using MultiScaleTreeGraph
using PlantMeteo
using PlantSimEngine
using PlantSimEngine.Examples
using Statistics
using Test

@testset "PlantSimEngine benchmark API smoke" begin
    include(joinpath(@__DIR__, "..", "test-PSE-benchmark.jl"))
    model, requests, _ = setup_heavier_model_benchmark()
    simulation = benchmark_heavier_scene(model, requests, 1)
    @test current_step(simulation) == 1
    @test !isempty(collect_outputs(simulation; sink=nothing))
end

@testset "multirate benchmark API smoke" begin
    include(joinpath(@__DIR__, "..", "test-multirate-buffer-benchmark.jl"))
    model, requests, nsteps = setup_multirate_buffer_benchmark(; ndays=1, nleaves=4)
    simulation = benchmark_multirate_output_request_run(model, requests, nsteps)
    @test current_step(simulation) == nsteps
    @test !isempty(collect_outputs(simulation; sink=nothing))
end

@testset "PlantBiophysics benchmark API smoke" begin
    include(joinpath(@__DIR__, "..", "test-plantbiophysics.jl"))
    scenes = setup_benchmark_plantbiophysics_batch(; n=2)
    @test isnothing(benchmark_plantbiophysics_batch(scenes))
end

@testset "XPalm benchmark API smoke" begin
    include(joinpath(@__DIR__, "..", "test-xpalm.jl"))
    model, requests, _ = xpalm_default_param_create()
    simulation = PlantSimEngine.run!(model; steps=1, outputs=requests)
    @test current_step(simulation) == 1
    @test !isempty(xpalm_default_param_collect_outputs(simulation))
end
