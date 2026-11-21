module NativeFixtureApps
import PlantSimEngine as PSE
import TOML
export stage_native_fixture

"""Stage a self-contained test app from canonical source files.

Project.toml, src and an optional Manifest.toml are copied. Source paths resolve against the original
project. Direct PSE and MTG dependencies use the packages loaded by the integration test.
"""
function stage_native_fixture(template; fixture_sources=())
    template = abspath(template)
    directory = mktempdir(; prefix="pse-native-fixture-")
    app = joinpath(directory, "app")
    mkpath(app)
    cp(joinpath(template, "src"), joinpath(app, "src"))
    cp(joinpath(@__DIR__, "native_preparation.jl"),
        joinpath(app, "src", "native_preparation.jl"))
    for (source, name) in fixture_sources
        basename(name) == name || throw(ArgumentError("A staged fixture needs a source filename."))
        cp(source, joinpath(app, "src", name))
    end
    project = TOML.parsefile(joinpath(template, "Project.toml"))
    sources = get!(Dict{String,Any}, project, "sources")
    for source in values(sources)
        haskey(source, "path") || continue
        source["path"] = abspath(joinpath(template, source["path"]))
    end
    checkouts = Dict{String,String}()
    for package in (PSE, PSE.MultiScaleTreeGraph)
        name = string(nameof(package))
        haskey(project["deps"], name) || continue
        path = realpath(pkgdir(package))
        sources[name] = Dict("path" => path)
        checkouts[project["deps"][name]] = path
    end
    open(joinpath(app, "Project.toml"), "w") do io
        TOML.print(io, project)
    end
    manifest = joinpath(template, "Manifest.toml")
    if isfile(manifest)
        lock = TOML.parsefile(manifest)
        for entries in values(lock["deps"]), entry in entries
            if haskey(checkouts, entry["uuid"])
                entry["path"] = checkouts[entry["uuid"]]
                for key in ("git-tree-sha1", "registries", "repo-url", "repo-rev")
                    delete!(entry, key)
                end
            elseif haskey(entry, "path")
                entry["path"] = entry["uuid"] == project["uuid"] ? app :
                    abspath(joinpath(template, entry["path"]))
            end
        end
        open(joinpath(app, "Manifest.toml"), "w") do io
            TOML.print(io, lock)
        end
    end
    return app
end
end # module
