using Test

const GUARD = joinpath(@__DIR__, "require_complete_jet.jl")

function guarded_case(packages, source)
    output, errors = IOBuffer(), IOBuffer()
    command = `$(Base.julia_cmd()) --startup-file=no --threads=2 --load=$GUARD -e $source`
    load_path = join((packages, "@stdlib"), Sys.iswindows() ? ';' : ':')
    process = run(pipeline(ignorestatus(addenv(command, "JULIA_LOAD_PATH" => load_path));
        stdout=output, stderr=errors))
    return (code=process.exitcode, output=String(take!(output)), errors=String(take!(errors)))
end

@testset "Pkg cache-flag probe with an empty LOAD_PATH" begin
    output, errors = IOBuffer(), IOBuffer()
    command = `$(Base.julia_cmd()) --code-coverage=none --color=yes --check-bounds=yes --warn-overwrite=yes --depwarn=yes --inline=yes --startup-file=no --track-allocation=none --load=$GUARD --eval 'show(ccall(:jl_cache_flags, UInt8, ()))'`
    process = run(pipeline(ignorestatus(addenv(command, "JULIA_LOAD_PATH" => ""));
        stdout=output, stderr=errors))
    cache_flags = (code=process.exitcode, output=String(take!(output)), errors=String(take!(errors)))
    @test cache_flags.code == 0
    @test cache_flags.output == sprint(show, parse(UInt8, cache_flags.output))
    @test isempty(cache_flags.errors)
end

@testset "incomplete JET analysis fails its test subprocess" begin
    mktempdir() do packages
        source_dir = mkpath(joinpath(packages, "JET", "src"))
        write(joinpath(source_dir, "JET.jl"), """
            module JET
            using Logging
            function analyze(; broken=false)
                if broken
                    try
                        error("deliberate analyzer failure")
                    catch exception
                        @error "Analyzer worker aborted" exception
                    end
                else
                    @info "Analysis completed"
                end
                return current_task()
            end
            module Workers
                using Logging
                fail() = @error "Another internal analyzer diagnostic"
            end
            end
            """)

        clean = guarded_case(packages, "using JET; JET.analyze()")
        @test clean.code == 0
        @test occursin("Analysis completed", clean.errors)
        @test !occursin("analysis incomplete", clean.errors)

        swallowed = guarded_case(packages, "using JET; JET.analyze(; broken=true)")
        @test swallowed.code == 1
        @test occursin("Analyzer worker aborted", swallowed.errors)
        @test occursin("JET analysis incomplete: 1 internal analyzer error(s).", swallowed.errors)

        worker = guarded_case(packages, """
            using JET
            parent = current_task()
            task = Threads.@spawn JET.analyze(; broken=true)
            @assert fetch(task) !== parent
            """)
        @test worker.code == 1
        @test occursin("JET analysis incomplete: 1 internal analyzer error(s).", worker.errors)

        concurrent = guarded_case(packages, """
            using JET
            @sync for _ in 1:32
                Threads.@spawn JET.Workers.fail()
            end
            """)
        @test concurrent.code == 1
        @test occursin("JET analysis incomplete: 32 internal analyzer error(s).", concurrent.errors)

        unrelated = guarded_case(packages, """
            using Test, Logging, JET
            @test_logs (:error, "expected unrelated error") @error "expected unrelated error"
            @error "unrelated module error remains visible"
            JET.analyze()
            """)
        @test unrelated.code == 0
        @test occursin("unrelated module error remains visible", unrelated.errors)
        @test !occursin("analysis incomplete", unrelated.errors)

        prior_failure = guarded_case(packages, "using JET; JET.analyze(; broken=true); exit(7)")
        @test prior_failure.code == 7
        @test occursin("JET analysis incomplete: 1 internal analyzer error(s).", prior_failure.errors)
    end
end
