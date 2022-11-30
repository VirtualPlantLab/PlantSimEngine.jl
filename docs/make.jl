using PlantSimEngine
using Documenter

DocMeta.setdocmeta!(PlantSimEngine, :DocTestSetup, :(using PlantSimEngine); recursive=true)

makedocs(;
    modules=[XPalm],
    authors="Rémi Vezy <VEZY@users.noreply.github.com> and contributors",
    repo="https://github.com/VEZY/PlantSimEngine.jl/blob/{commit}{path}#{line}",
    sitename="XPalm.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://VEZY.github.io/PlantSimEngine.jl",
        edit_link="main",
        assets=String[]
    ),
    pages=[
        "Home" => "index.md",
        "Getting started" => [
            "TL;DR" => "./getting_started/get_started.md",
            "Parameter fitting" => "./getting_started/first_fit.md",
        ],
        "API" => "API.md"
    ]
)

deploydocs(;
    repo="github.com/VEZY/PlantSimEngine.jl",
    devbranch="main"
)
