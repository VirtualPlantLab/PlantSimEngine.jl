module NativeFixtureApps
import PlantSimEngine as PSE
import TOML
export stage_native_fixture

"""Stage a self-contained test app from canonical source files.

Project.toml, src and an optional Manifest.toml are copied. Source paths resolve against the original
project, and PSE is the package actually loaded by this integration test.
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
    sources["PlantSimEngine"] = Dict("path" => realpath(pkgdir(PSE)))
    open(joinpath(app, "Project.toml"), "w") do io
        TOML.print(io, project)
    end
    manifest = joinpath(template, "Manifest.toml")
    if isfile(manifest)
        lock = TOML.parsefile(manifest)
        for entries in values(lock["deps"]), entry in entries
            if entry["uuid"] == project["deps"]["PlantSimEngine"]
                entry["path"] = realpath(pkgdir(PSE))
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
