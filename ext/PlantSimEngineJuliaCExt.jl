module PlantSimEngineJuliaCExt

import JuliaC

function _application_project(path::AbstractString)
    isempty(path) && throw(ArgumentError("An application package directory is required."))
    project = abspath(path)
    metadata_path = joinpath(project, "Project.toml")
    isdir(project) && isfile(metadata_path) || throw(ArgumentError(
        "Expected a Julia application package directory containing `Project.toml`, got $(repr(path)).",
    ))
    metadata = Base.parsed_toml(metadata_path)
    name = get(metadata, "name", nothing)
    uuid = get(metadata, "uuid", nothing)
    name isa String && Base.isidentifier(name) &&
        uuid isa String && !isnothing(tryparse(Base.UUID, uuid)) || throw(ArgumentError(
        "The application `Project.toml` must declare a valid Julia package name and UUID.",
    ))
    source_path = joinpath(project, "src", "$name.jl")
    isfile(source_path) || throw(ArgumentError(
        "The application package entry file $(repr(source_path)) does not exist.",
    ))
    return project
end

function _require_new_destination(path::AbstractString)
    (ispath(path) || islink(path)) && throw(ArgumentError(
        "The bundle destination $(repr(path)) already exists. Choose a new path.",
    ))
    return nothing
end

function build_bundle(app_project::AbstractString, destination::AbstractString, name::AbstractString)
    project = _application_project(app_project)
    occursin(r"\A[A-Za-z0-9][A-Za-z0-9_-]*\z", name) || throw(ArgumentError(
        "The executable name must start with an ASCII letter or digit and use only letters, digits, underscores, or hyphens.",
    ))
    isempty(destination) && throw(ArgumentError("A bundle destination is required."))
    directory = joinpath(splitpath(abspath(destination)))
    _require_new_destination(directory)
    parent = dirname(directory)
    mkpath(parent)

    image = JuliaC.ImageRecipe(;
        file=project, output_type="--output-exe", trim_mode="safe", cpu_target="generic",
    )
    JuliaC.compile_products(image)

    # Publish a complete bundle with a same-filesystem move. The staged copy is
    # cleaned up if linking or bundling fails.
    return mktempdir(parent; prefix=".pse-build-") do work
        staged = joinpath(work, "bundle")
        link = JuliaC.LinkRecipe(; image_recipe=image, outname=joinpath(work, "link", name), rpath="@bundle")
        JuliaC.link_products(link)
        JuliaC.bundle_products(JuliaC.BundleRecipe(; link_recipe=link, output_dir=staged))
        relative_executable = relpath(link.outname, staged)
        isfile(link.outname) || error("JuliaC did not produce a bundled executable.")
        _require_new_destination(directory)
        mv(staged, directory)
        return (; directory, executable=joinpath(directory, relative_executable))
    end
end

end
