 
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
    @test nthr > 1
    
    t_seq = @benchmark run!(models1, meteo_day; executor = SequentialEx())
    #t_seq = run!(models1, meteo_day; executor = SequentialEx())
    med_time_seq = median(t_seq).time 

    #time is in nanoseconds
    @test med_time_seq > nrows * 1000000

    t_mt = @benchmark run!(models2, meteo_day; executor = ThreadedEx())
    #t_mt = run!(models2, meteo_day; executor = ThreadedEx())
    med_time_mt = median(t_mt).time 

    @test med_time_mt > nrows * 1000000 / nthr

    # Threads sleep/wakeup scheduling overhead causing inconsistencies ?
    # In any case, sometimes MT beats ST on CI runners, and the mac runner seems to return puzzling false positives
    # Deactivating it for now
    # TODO there is a thread discussing unreliability of the sleep() function, need to check it

    #if !Sys.isapple()
    #    @test abs(nthr * med_time_mt - med_time_seq) < 0.2 * med_time_seq
    #end

    # unsure how to recover outputs in benchmarked expressions to compare them, rerun the functions as a workaround for now
    @test run!(models1, meteo_day; executor = SequentialEx()) == run!(models2, meteo_day; executor = ThreadedEx())
end

# TODO make sure a mt test with nthreads == 1 also is tested and is correct
@testset "Single and multi-threaded output consistency" begin
    nthr = Threads.nthreads()
    @test nthr == 4

    using Dates
    meteo_day = read_weather(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), duration=Day)

    models = ModelList(
        ToyLAIModel(),
        Beer(0.5),
        status=(TT_cu=cumsum(meteo_day.TT),),
    )

    tracked_outputs = (:LAI,)
    
    out_seq, out_mt = run_single_and_multi_thread_modellist(models, tracked_outputs, meteo_day)
    @test compare_outputs_modellists(out_seq, out_mt)

    modellists, status_tuples, outs_vectors = get_modellist_bank()
    meteos_all = get_simple_meteo_bank()
    
    # First meteo only has one timestep
    meteos = meteos_all[2:length(meteos_all)]

    for i in 1:length(modellists)
    #i = 1
        modellist = modellists[i]
        status_tuple = status_tuples[i]
        outs_vector = outs_vectors[i]
        all_vars = init_variables(modellist)
        for j in 1:length(meteos)
            meteo = meteos[j]
            for k in 1:length(outs_vector)
            #k = 1
            out_tuple  = outs_vector[k]
                
                try out_st, out_mt = run_single_and_multi_thread_modellist(modellist, out_tuple, meteo)
                    @test compare_outputs_modellists(out_st, out_mt)
                catch e
                    #print(i," ", j, " ", k)
                    #println()
                    if isa(e, DimensionMismatch)
                        continue
                    elseif isa(e, ErrorException)
                        showerror(stdout, e)
                        @test false
                    else
                        showerror(stdout, e)
                        @test false
                    end
                end
            end
        end
    end
end