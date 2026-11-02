isdefined(@__MODULE__,:DownstreamMAESPAPSESources) || include(joinpath(@__DIR__,"downstream_maespa_pse_sources.jl"))

module DownstreamMAESPAPSESourcesChecks
using Test
import ..DownstreamMAESPAPSESources as Sources

function run_checks()
    actual=Sources.snapshot()
    @testset "Native PSE dependency inventory" begin
        @test length(actual.files)>30
        @test isequal(Sources.verify_unchanged(actual),actual)
        mktempdir() do root
            mkpath(joinpath(root,"src")); mkpath(joinpath(root,"ext"))
            write(joinpath(root,"Project.toml"),"name = \"InventoryProbe\"\n")
            write(joinpath(root,"src","a.jl"),"a=1\n")
            write(joinpath(root,"ext","b.jl"),"b=2\n")
            before=Sources.snapshot(;root)
            path=joinpath(root,"inventory.json")
            Sources.write_snapshot(path,before)
            @test Sources.verify_archived(path;current=before)["aggregate_sha256"]==before.aggregate_sha256
            @test_throws ErrorException Sources.verify_unchanged(merge(before,(aggregate_sha256="bad",)),before)
            write(joinpath(root,"src","a.jl"),"a=2\n")
            @test_throws ErrorException Sources.verify_unchanged(before,Sources.snapshot(;root))
            write(joinpath(root,"src","a.jl"),"a=1\n")
            write(joinpath(root,"ext","extra.jl"),"extra=1\n")
            @test_throws ErrorException Sources.verify_unchanged(before,Sources.snapshot(;root))
            rm(joinpath(root,"ext","extra.jl"))
            symlink(joinpath(root,"src","a.jl"),joinpath(root,"src","linked.jl"))
            @test_throws ErrorException Sources.snapshot(;root)
        end
    end
    return (assertions=7,files=length(actual.files),aggregate_sha256=actual.aggregate_sha256)
end

end
