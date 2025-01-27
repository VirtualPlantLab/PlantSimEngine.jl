 
using BenchmarkTools
using Dates

PlantSimEngine.@process "sleep" verbose = false

struct ToySleepModel <: AbstractSleepModel   
end

PlantSimEngine.inputs_(::ToySleepModel) = (a = -Inf,)
PlantSimEngine.outputs_(::ToySleepModel) = NamedTuple()

function PlantSimEngine.run!(m::ToySleepModel, models, status, meteo, constants=nothing, extra=nothing)
    # sleep for 0.01 seconds (not going to be perfectly accurate)
    Base.sleep(0.001)
end

PlantSimEngine.TimeStepDependencyTrait(::Type{<:ToySleepModel}) = PlantSimEngine.IsTimeStepIndependent()

meteo_day = read_weather(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), duration=Day)
    nrows = nrow(meteo_day)
    
    vc = [0 for i in 1:nrows]

models1 = ModelList(process1=ToySleepModel(), status=(a=vc,))
models2 = ModelList(process1=ToySleepModel(), status=(a=vc,))

@testset begin "Check number of threads"
    nthr = Threads.nthreads()
    @test nthr == 4
    
    t_seq = @benchmark run!(models1, meteo_day; executor = SequentialEx())
    #t_seq = run!(models1, meteo_day; executor = SequentialEx())
    min_time_seq = minimum(t_seq).time 

    #time is in nanoseconds
    @test min_time_seq > nrows * 1000000

    t_mt = @benchmark run!(models2, meteo_day; executor = ThreadedEx())
    #t_mt = run!(models2, meteo_day; executor = ThreadedEx())
    min_time_mt = minimum(t_mt).time 

    @test min_time_mt > nrows * 1000000 / nthr

    # expecting mt to have some overhead
    @test nthr * min_time_mt > min_time_seq

    # todo DataFrame equals
    @test status(models1) == status(models2)
end