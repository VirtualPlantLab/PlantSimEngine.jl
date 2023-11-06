#]add BenchmarkTools

using BenchmarkTools
using PlantSimEngine, PlantMeteo, DataFrames, CSV, Dates, Statistics
# include(joinpath(pkgdir(PlantSimEngine), "examples/ToyLAIModel.jl"))
# include(joinpath(pkgdir(PlantSimEngine), "examples/Beer.jl"))
# include(joinpath(pkgdir(PlantSimEngine), "examples/ToyAssimGrowthModel.jl"))
# include(joinpath(pkgdir(PlantSimEngine), "examples/ToyRUEGrowthModel.jl"))

meteo_day = read_weather(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), duration=Day)
models = ModelList(
    ToyLAIModel(),
    status=(TT_cu=cumsum(meteo_day.TT),),
)

# Match the warning on the executor, the default is ThreadedEx() but ToyRUEGrowthModel can't be run in parallel:
time_run = @benchmark run!($models, $meteo_day)

median_time_ns = median(time_run.times) / nrow(meteo_day)

# If we provide a serial executor, it works without a warning:
time_run_seq = @benchmark run!($models, $meteo_day, executor=$(SequentialEx()))
median_time_seq_ns = median(time_run_seq.times) / nrow(meteo_day)

# Coupled model: 
models_coupled = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    status=(TT_cu=cumsum(meteo_day.TT),),
)

# Match the warning on the executor, the default is ThreadedEx() but ToyRUEGrowthModel can't be run in parallel:
time_run_coupled = @benchmark run!($models_coupled, $meteo_day)
median_time_coupled_ns = median(time_run_coupled.times) / nrow(meteo_day)
