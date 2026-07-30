using TOML

function prepare_full_performance_project!(project_path)
    project = TOML.parsefile(project_path)
    pop!(project, "sources", nothing)
    open(project_path, "w") do io
        TOML.print(io, project)
    end
    return project_path
end
