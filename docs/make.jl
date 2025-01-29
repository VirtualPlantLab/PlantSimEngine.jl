using PlantSimEngine
using PlantMeteo
using DataFrames, CSV
using Documenter, DocumenterVitepress
using CairoMakie

DocMeta.setdocmeta!(PlantSimEngine, :DocTestSetup, :(using PlantSimEngine, PlantMeteo, DataFrames, CSV, CairoMakie); recursive=true)

makedocs(;
    modules=[PlantSimEngine],
    authors="Rémi Vezy <VEZY@users.noreply.github.com> and contributors",
    repo=Documenter.Remotes.GitHub("VirtualPlantLab", "PlantSimEngine.jl"),
    sitename="PlantSimEngine.jl",
    format=DocumenterVitepress.MarkdownVitepress(;
        repo="https://github.com/VirtualPlantLab/PlantSimEngine.jl",
        # build_vitepress=false
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
            "Tips and Workarounds" => "./model_coupling/tips_and_workarounds.md",
        ],
        "FAQ" => ["Translate a model" => "./FAQ/translate_a_model.md"],
        "API" => "API.md",
    ]
)

deploydocs(;
    repo="github.com/VirtualPlantLab/PlantSimEngine.jl.git",
    devbranch="main",
    push_preview=true, # Visit https://VirtualPlantLab.github.io/PlantSimEngine.jl/previews/PR## to visualize the preview
)
