using PlantSimEngine
using PlantMeteo
using DataFrames, CSV
using Documenter
using CairoMakie

DocMeta.setdocmeta!(PlantSimEngine, :DocTestSetup, :(using PlantSimEngine, PlantMeteo, DataFrames, CSV, CairoMakie); recursive=true)

makedocs(;
    modules=[PlantSimEngine],
    authors="Rémi Vezy <VEZY@users.noreply.github.com> and contributors",
    repo="https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/{commit}{path}#{line}",
    sitename="PlantSimEngine.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://VirtualPlantLab.github.io/PlantSimEngine.jl",
        edit_link="main",
        assets=String[]
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
            "Users" => "./model_coupling/model_coupling_user.md",
            "Modelers" => "./model_coupling/model_coupling_modeler.md",
        ],
        "FAQ" => ["./FAQ/translate_a_model.md"],
        "API" => "API.md",
    ]
)

deploydocs(;
    repo="github.com/VirtualPlantLab/PlantSimEngine.jl",
    devbranch="main"
)
