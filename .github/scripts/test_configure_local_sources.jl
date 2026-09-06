using Test
using TOML

include(joinpath(@__DIR__, "configure_local_sources.jl"))

function write_project(path, project)
    mkpath(dirname(path))
    open(path, "w") do io
        TOML.print(io, project; sorted=true)
    end
end

function source_project(root, name, uuid)
    write_project(
        joinpath(root, "Project.toml"),
        Dict{String,Any}("name" => name, "uuid" => uuid, "version" => "1.0.0"),
    )
end

@testset "Configure local integration sources" begin
    mktempdir() do tmp
        pse_uuid = "9a576370-710b-4269-adf9-4f603a9c6423"
        plantgeom_uuid = "5edaa67e-25db-4eb9-bf81-05d793b2238d"
        xpalm_uuid = "6b523e1e-d512-416c-8e51-a8fbef0064e7"

        pse_root = joinpath(tmp, "PlantSimEngine")
        plantgeom_root = joinpath(tmp, "PlantGeom")
        source_project(pse_root, "PlantSimEngine", pse_uuid)
        source_project(plantgeom_root, "PlantGeom", plantgeom_uuid)

        xpalm_root = joinpath(tmp, "XPalm")
        root_project = joinpath(xpalm_root, "Project.toml")
        test_project = joinpath(xpalm_root, "test", "Project.toml")
        write_project(
            root_project,
            Dict{String,Any}(
                "name" => "XPalm",
                "uuid" => xpalm_uuid,
                "deps" => Dict(
                    "PlantSimEngine" => pse_uuid,
                    "PlantGeom" => plantgeom_uuid,
                ),
                "sources" => Dict(
                    "PlantSimEngine" => Dict("url" => "https://example.test/pse", "rev" => "old"),
                    "PlantGeom" => Dict("url" => "https://example.test/plantgeom", "rev" => "old"),
                    "Unrelated" => Dict("path" => "../Unrelated"),
                ),
            ),
        )
        write_project(
            test_project,
            Dict{String,Any}(
                "deps" => Dict(
                    "XPalm" => xpalm_uuid,
                    "PlantSimEngine" => pse_uuid,
                    "PlantGeom" => plantgeom_uuid,
                ),
                "sources" => Dict(
                    "XPalm" => Dict("path" => ".."),
                    "PlantSimEngine" => Dict("url" => "https://example.test/pse", "rev" => "old"),
                    "PlantGeom" => Dict("url" => "https://example.test/plantgeom", "rev" => "old"),
                ),
            ),
        )

        summaries = IntegrationSourceConfig.configure_local_sources!(
            (root_project, test_project),
            (pse_root, plantgeom_root),
        )
        @test all(summary.changed == ["PlantSimEngine", "PlantGeom"] for summary in summaries)

        configured_root = TOML.parsefile(root_project)
        configured_test = TOML.parsefile(test_project)
        @test configured_root["sources"]["PlantSimEngine"] == Dict("path" => realpath(pse_root))
        @test configured_root["sources"]["PlantGeom"] == Dict("path" => realpath(plantgeom_root))
        @test configured_root["sources"]["Unrelated"] == Dict("path" => "../Unrelated")
        @test configured_test["sources"]["XPalm"] == Dict("path" => "..")

        repeated = IntegrationSourceConfig.configure_local_sources!(
            (root_project, test_project),
            (pse_root, plantgeom_root),
        )
        @test all(isempty(summary.changed) for summary in repeated)

        weakdep_root = joinpath(plantgeom_root, "Project.toml")
        weakdep_test = joinpath(plantgeom_root, "test", "Project.toml")
        write_project(
            weakdep_root,
            Dict{String,Any}(
                "name" => "PlantGeom",
                "uuid" => plantgeom_uuid,
                "weakdeps" => Dict("PlantSimEngine" => pse_uuid),
            ),
        )
        write_project(
            weakdep_test,
            Dict{String,Any}(
                "deps" => Dict(
                    "PlantGeom" => plantgeom_uuid,
                    "PlantSimEngine" => pse_uuid,
                ),
                "sources" => Dict("PlantGeom" => Dict("path" => "..")),
            ),
        )

        weakdep_summaries = IntegrationSourceConfig.configure_local_sources!(
            (weakdep_root, weakdep_test),
            (pse_root,),
        )
        @test isempty(weakdep_summaries[1].matched)
        @test weakdep_summaries[2].changed == ["PlantSimEngine"]
        @test !haskey(TOML.parsefile(weakdep_root), "sources")
        @test TOML.parsefile(weakdep_test)["sources"]["PlantSimEngine"] ==
              Dict("path" => realpath(pse_root))

        extras_project = joinpath(tmp, "Extras", "Project.toml")
        write_project(
            extras_project,
            Dict{String,Any}("extras" => Dict("PlantSimEngine" => pse_uuid)),
        )
        extras_summary = only(IntegrationSourceConfig.configure_local_sources!(
            (extras_project,),
            (pse_root,),
        ))
        @test extras_summary.changed == ["PlantSimEngine"]
        @test TOML.parsefile(extras_project)["sources"]["PlantSimEngine"] ==
              Dict("path" => realpath(pse_root))

        mismatched_project = joinpath(tmp, "Mismatch", "Project.toml")
        write_project(
            mismatched_project,
            Dict{String,Any}(
                "deps" => Dict("PlantSimEngine" => "00000000-0000-0000-0000-000000000000"),
            ),
        )
        transaction_project = joinpath(tmp, "Transaction", "Project.toml")
        write_project(
            transaction_project,
            Dict{String,Any}(
                "deps" => Dict("PlantSimEngine" => pse_uuid),
                "sources" => Dict(
                    "PlantSimEngine" => Dict("url" => "https://example.test/pse", "rev" => "old"),
                ),
            ),
        )
        @test_throws ErrorException IntegrationSourceConfig.configure_local_sources!(
            (transaction_project, mismatched_project),
            (pse_root,),
        )
        @test haskey(
            TOML.parsefile(transaction_project)["sources"]["PlantSimEngine"],
            "url",
        )
    end
end
