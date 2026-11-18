module OfficialXPalmOracle
using Test
import CSV
using DataFrames
using Dates
import SHA
import XPalm

const XPALM_ROOT = dirname(dirname(pathof(XPalm)))
include(joinpath(XPALM_ROOT, "test", "reference_regression_helpers.jl"))
const BASELINE = joinpath(XPALM_ROOT, "test", "references", "regression", REFERENCE_REGRESSION_CANDIDATE_BASELINE)
const METEO_SHA256 = "3406fa2cc253c40d84610aacebe7e537fe9d2205882e1dc040c58cf169c7c653"
const TRAJECTORY_SHA256 = "f742f74f7db90cc7b6f119f2301cc47638be7604b3aeaeffcba994cd03ad06f7"

function official_meteo()
    path = joinpath(XPALM_ROOT, "0-data", "meteo.csv")
    @test bytes2hex(SHA.sha256(read(path))) == METEO_SHA256
    meteo = CSV.read(path, DataFrame)
    :duration in propertynames(meteo) || (meteo.duration = fill(Day(1), nrow(meteo)))
    @test nrow(meteo) == 4160
    return meteo
end

function official_t1()
    path = joinpath(BASELINE, "trajectory_checkpoints.csv")
    @test bytes2hex(SHA.sha256(read(path))) == TRAJECTORY_SHA256
    row = first(CSV.read(path, DataFrame; types=Dict(:date => Date)), 1)
    @test only(row.timestep) == 1
    return row
end

function compare_daily(actual, expected)
    @test names(actual) == names(expected)
    @test nrow(actual) == nrow(expected)
    for name in REFERENCE_REGRESSION_EXACT_COLUMNS
        @test isequal(actual[!, name], expected[!, name])
    end
    for name in REFERENCE_REGRESSION_FLOAT_COLUMNS
        @test all(isapprox.(actual[!, name], expected[!, name]; rtol=1e-8, atol=1e-8, nans=true))
    end
    return nothing
end
end
