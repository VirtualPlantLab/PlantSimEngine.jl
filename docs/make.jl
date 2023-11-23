using PlantSimEngine
using PlantMeteo
using DataFrames, CSV
using Documenter
using CairoMakie

DocMeta.setdocmeta!(PlantSimEngine, :DocTestSetup, :(using PlantSimEngine, PlantMeteo, DataFrames, CSV, CairoMakie); recursive=true)

makedocs(;
    modules=[PlantSimEngine],
    authors="Rémi Vezy <VEZY@users.noreply.github.com> and contributors",
    repo=Documenter.Remotes.GitHub("VirtualPlantLab", "PlantSimEngine.jl"),
    sitename="PlantSimEngine.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://VirtualPlantLab.github.io/PlantSimEngine.jl",
        edit_link="main",
        assets=String[],
        size_threshold=250000
    ),
    pages=[
        "Home" => "index.md",
        "Design" => "design.md",
        "Model Switching" => "model_switching.md",
        "Reducing DoF" => "reducing_dof.md",
        "Execution" => "model_execution.md",
        "Fitting" => "fitting.md",
        "Extending" => [
            "Processes" => "./extending/implement_a_process.md",
            "Models" => "./extending/implement_a_model.md",
            "Input types" => "./extending/inputs.md",
        ],
        "Coupling" => [
            "Users" => [
                "Simple case" => "./model_coupling/model_coupling_user.md",
                "Multi-scale modelling" => "./model_coupling/multiscale.md",
            ],
            "Modelers" => "./model_coupling/model_coupling_modeler.md",
        ],
        "FAQ" => ["./FAQ/translate_a_model.md"],
        "API" => "API.md",
    ]
)

deploydocs(;
    repo="github.com/VirtualPlantLab/PlantSimEngine.jl.git",
    devbranch="main"
)
