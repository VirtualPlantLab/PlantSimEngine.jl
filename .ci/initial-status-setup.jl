using PlantSimEngine, Test, Statistics, TOML

@assert realpath(pkgdir(PlantSimEngine)) == realpath(ARGS[1])
include(joinpath(pkgdir(PlantSimEngine), "benchmark", "test-distributed-output-benchmark.jl"))

function measure_public_setup(n)
    GC.gc()
    measurement = @timed setup_distributed_output_public_assignment_benchmark(
        n; path=:ref_loop, ncolumns=2)
    simulation = measurement.value
    @assert current_step(simulation) == 1
    ids = sort!(collect(1:n); by=i -> string(:object_, i))
    for (position, index) in pairs(ids)
        status = model_status(simulation.model, Symbol(:object_, index))
        @assert status.incident_par === Float64(index)
        @assert status.rank === position
    end
    return Dict("size" => n, "seconds" => measurement.time,
        "bytes" => measurement.bytes, "compile_seconds" => measurement.compile_time)
end

rows = []
for n in (1_000, 10_000)
    measure_public_setup(n)
    for repeat in 1:3
        row = measure_public_setup(n)
        @assert iszero(row["compile_seconds"])
        @info "Prepared scene and first distributed write" repeat row
        push!(rows, row)
    end
end
open(ARGS[2], "w") do io
    TOML.print(io, Dict("rows" => rows))
end
