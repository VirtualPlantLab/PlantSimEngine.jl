module IntegrationSourceConfig

using TOML

export configure_local_sources!

const DIRECT_DEPENDENCY_SECTIONS = ("deps", "extras")

function _source_identity(source_root::AbstractString)
    source_path = realpath(source_root)
    project_file = joinpath(source_path, "Project.toml")
    isfile(project_file) || error("Missing source project: $(project_file)")

    project = TOML.parsefile(project_file)
    name = get(project, "name", nothing)
    uuid = get(project, "uuid", nothing)
    name isa AbstractString || error("Missing package name in $(project_file)")
    uuid isa AbstractString || error("Missing package UUID in $(project_file)")

    return (; name=String(name), uuid=String(uuid), path=source_path)
end

function _declared_uuid(project, package_name::AbstractString)
    declared_uuid = nothing
    for section_name in DIRECT_DEPENDENCY_SECTIONS
        section = get(project, section_name, nothing)
        section isa AbstractDict || continue
        haskey(section, package_name) || continue

        uuid = String(section[package_name])
        if declared_uuid !== nothing && declared_uuid != uuid
            error("Conflicting UUIDs for $(package_name) in [deps] and [extras]")
        end
        declared_uuid = uuid
    end
    return declared_uuid
end

function _configured_project(project_file::AbstractString, source_identities)
    project_path = realpath(project_file)
    project = TOML.parsefile(project_path)
    sources = get!(project, "sources", Dict{String,Any}())
    matched = String[]
    changed = String[]

    for source in source_identities
        declared_uuid = _declared_uuid(project, source.name)
        declared_uuid === nothing && continue
        declared_uuid == source.uuid || error(
            "UUID mismatch for $(source.name) in $(project_path): " *
            "expected $(source.uuid), found $(declared_uuid)",
        )

        push!(matched, source.name)
        local_source = Dict{String,Any}("path" => source.path)
        get(sources, source.name, nothing) == local_source && continue
        sources[source.name] = local_source
        push!(changed, source.name)
    end

    return (; path=project_path, contents=project, matched, changed)
end

"""
    configure_local_sources!(project_files, source_roots)

Replace URL/revision source entries with absolute paths to exact local package
checkouts. A source is changed only when the target project declares the same
package UUID in `[deps]` or `[extras]`; weak dependencies are intentionally not
modified. Every requested source must match at least one target project.
"""
function configure_local_sources!(project_files, source_roots)
    source_identities = map(_source_identity, source_roots)
    source_names = getproperty.(source_identities, :name)
    allunique(source_names) || error("Each local source package must be unique")

    configured_projects = map(project_files) do project_file
        isfile(project_file) || error("Missing target project: $(abspath(project_file))")
        _configured_project(project_file, source_identities)
    end

    for source_name in source_names
        any(source_name in project.matched for project in configured_projects) || error(
            "Local source $(source_name) is not a direct dependency of any target project",
        )
    end

    for project in configured_projects
        isempty(project.changed) && continue
        open(project.path, "w") do io
            TOML.print(io, project.contents; sorted=true)
        end
    end

    return map(configured_projects) do project
        (; project=project.path, matched=project.matched, changed=project.changed)
    end
end

end
