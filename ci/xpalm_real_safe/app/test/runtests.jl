using Test
import CSV
using DataFrames
using Dates
import PlantSimEngine as PSE
import Tables
import XPalm
import XPalmLifecycleApp as App
include("oracle.jl")
using .OfficialXPalmOracle

@testset "Real XPalm application T0/T1: host controls before any native claim" begin
    meteo = OfficialXPalmOracle.official_meteo()
    meteo_t1 = meteo[1:1, :]
    reference = OfficialXPalmOracle.official_t1()
    @test App.OUTPUT_VARIABLES == OfficialXPalmOracle.REFERENCE_REGRESSION_VARIABLES
    @test App.DAILY_COLUMNS == Tuple(Symbol.(names(reference)))
    @test PSE.current_step(App.STATE.simulation) == 0
    @test length(App.STATE.date_labels) == 4160
    @test all(isempty, values(PSE.collect_outputs(App.STATE.simulation; sink=nothing)))

    # Independent existing public wrapper: a fresh default Palm in each control.
    dataframe_outputs = XPalm.xpalm(meteo_t1, DataFrame;
        vars=OfficialXPalmOracle.REFERENCE_REGRESSION_VARIABLES, architecture=false,
        palm=XPalm.Palm(initiation_age=0, parameters=XPalm.default_parameters()))
    rowtable_outputs = XPalm.xpalm(Tables.rowtable(meteo_t1), DataFrame;
        vars=OfficialXPalmOracle.REFERENCE_REGRESSION_VARIABLES, architecture=false,
        palm=XPalm.Palm(initiation_age=0, parameters=XPalm.default_parameters()))
    dataframe_daily = OfficialXPalmOracle.reference_regression_daily(dataframe_outputs, meteo_t1)
    rowtable_daily = OfficialXPalmOracle.reference_regression_daily(rowtable_outputs, meteo_t1)
    OfficialXPalmOracle.compare_daily(dataframe_daily, reference)
    OfficialXPalmOracle.compare_daily(rowtable_daily, dataframe_daily)

    # The application keeps the complete forcing, starts at T0, then runs the shared step!.
    PSE.step!(App.STATE.simulation)
    @test PSE.current_step(App.STATE.simulation) == 1
    actual_outputs = XPalm._collect_xpalm_outputs(App.STATE.simulation, DataFrame, App.OUTPUT_VARIABLES)
    actual_daily = OfficialXPalmOracle.reference_regression_daily(actual_outputs, meteo_t1)
    OfficialXPalmOracle.compare_daily(actual_daily, dataframe_daily)
    OfficialXPalmOracle.compare_daily(actual_daily, reference)

    # The fixed scalar report must agree with retained public output rows.
    buffer = IOBuffer()
    App.write_daily_header(buffer)
    App.write_daily_row(buffer, App.daily_snapshot())
    emitted = CSV.read(IOBuffer(take!(buffer)), DataFrame; types=Dict(:date => Date))
    OfficialXPalmOracle.compare_daily(emitted, actual_daily)
end
