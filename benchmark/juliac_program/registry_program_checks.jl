isdefined(@__MODULE__, :RegistryPrograms) ||
    include(joinpath(@__DIR__, "app", "src", "registry_program.jl"))

module RegistryProgramChecks

using Test
import ..RegistryPrograms as Registry
const PSE = Registry.PSE

function run_checks()
    @testset "Registry publication preserves owned temporal history" begin
        retained = Tuple{Float64,Vector{Float64}}[]
        dependency = PSE.TemporalDependencyBuffer{Vector{Float64}}(8)
        live = [1.0]
        schema = Registry.TypedSeedCopies.schema(Registry.TypedSeedCopies.prepare(live))
        repeated_time = 2.0 + 1.0e-9

        for (time, value) in ((1.0, 1.0), (2.0, 2.0), (repeated_time, 3.0), (5.0, 4.0))
            live[1] = value
            Registry._publish_value!(retained, live, time, 1.0, schema)
            Registry._publish_value!(dependency, live, time, 1.0, schema)
        end
        live[1] = 99.0

        @test retained == [(1.0, [1.0]), (repeated_time, [3.0]), (5.0, [4.0])]
        @test collect(dependency) == [(repeated_time, [3.0]), (5.0, [4.0])]
        @test dependency[1][2] !== retained[2][2]
    end
end

end
