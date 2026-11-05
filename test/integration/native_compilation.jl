# Run from an environment containing PlantSimEngine and JuliaC on Julia 1.13.
using PlantSimEngine, JuliaC, Test

const compiled_scenario_app = joinpath(pkgdir(PlantSimEngine), "examples", "compiled_scenario")
Base.include(@__MODULE__, joinpath(compiled_scenario_app, "src", "PSECompiledScenario.jl"))

@testset "Standalone scenario matches ordinary PSE" begin
    ordinary = run!(PSECompiledScenario.make_model(); steps=4, outputs=:none)
    expected = string(current_step(ordinary), ',', final_state(ordinary).total, '\n')
    mktempdir() do directory
        destination = joinpath(directory, "bundle")
        artifact = Compilation.compile(compiled_scenario_app; destination)
        @test artifact.directory == destination
        @test isfile(artifact.executable)
        @test read(`$(artifact.executable) 4`, String) == expected
        @test read(`$(artifact.executable) 2 2`, String) == expected
        @test_throws ArgumentError Compilation.compile(compiled_scenario_app; destination)

        moved = joinpath(directory, "moved bundle")
        executable = joinpath(moved, relpath(artifact.executable, artifact.directory))
        mv(artifact.directory, moved)
        @test read(Cmd(`$executable 4`; dir=directory), String) == expected
    end
end
