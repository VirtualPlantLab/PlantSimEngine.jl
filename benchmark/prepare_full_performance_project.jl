using TOML

function prepare_full_performance_project!(project_path)
    project = TOML.parsefile(project_path)
    pop!(project, "sources", nothing)
    # Downstream packages are opt-in: AirspeedVelocity resolves the core project
    # before benchmarks.jl can inspect PSE_BENCHMARK_INCLUDE_DOWNSTREAM.
    project["deps"]["XPalm"] = "6b523e1e-d512-416c-8e51-a8fbef0064e7"
    project["deps"]["PlantBiophysics"] = "7ae8fcfa-76ad-4ec6-9ea7-5f8f5e2d6ec9"
    open(project_path, "w") do io
        TOML.print(io, project)
    end
    return project_path
end

function prepare_plantbiophysics_performance_project!(project_path)
    project = TOML.parsefile(project_path)
    pop!(project, "sources", nothing)
    pop!(project["deps"], "XPalm", nothing)
    project["deps"]["PlantBiophysics"] = "7ae8fcfa-76ad-4ec6-9ea7-5f8f5e2d6ec9"
    open(project_path, "w") do io
        TOML.print(io, project)
    end
    return project_path
end
