using PlantSimEngine
using PlantMeteo, PlantBiophysics
using Documenter

DocMeta.setdocmeta!(PlantSimEngine, :DocTestSetup, :(using PlantSimEngine, PlantMeteo, PlantBiophysics); recursive=true)

makedocs(;
    modules=[PlantSimEngine],
    authors="Rémi Vezy <VEZY@users.noreply.github.com> and contributors",
    repo="https://github.com/VEZY/PlantSimEngine.jl/blob/{commit}{path}#{line}",
    sitename="PlantSimEngine.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://VEZY.github.io/PlantSimEngine.jl",
        edit_link="main",
        assets=String[]
    ),
    pages=[
        "Home" => "index.md",
        "Design" => "design.md",
        "Extending" => [
            "Processes" => "./extending/implement_a_process.md",
            "Models" => "./extending/implement_a_model.md",
        ],
        "Coupling" => [
            "Users" => "./model_coupling/model_coupling_user.md",
            "Modelers" => "./model_coupling/model_coupling_modeler.md",
        ],
        "API" => "API.md"
    ]
)

deploydocs(;
    repo="github.com/VEZY/PlantSimEngine.jl",
    devbranch="main"
)
