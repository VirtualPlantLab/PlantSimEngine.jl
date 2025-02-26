#using Pkg
#Pkg.develop("PlantSimEngine")
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
        size_threshold=300000
    ),

    pages=[
        "Home" => "index.md",
        "Introduction" => [
            #"Organization of the documentation ?"
            "Why PlantSimEngine ?" => "./introduction/why_plantsimengine.md",
            "Why Julia ?" => "./introduction/why_julia.md",
            #"Overview ?"
            #"Feature list ? Companion packages ?"
        ],
        "Prerequisites" => [
            "Key Concepts" => "./prerequisites/key_concepts.md", # Key concepts vs terminology ?
            #"Setup" ?",
            "Julia language basics" => "./prerequisites/julia_basics.md",
            "Design" =>"./prerequisites/design.md", # Rework with key concepts
        ],
        "Step by step - Single Scale simulations" => [
        #"First Simulation" => ",
        "Coupling" => "./step_by_step/simple_model_coupling.md",
        "Model Switching" => "./step_by_step/model_switching.md",
        "Processes" => "./step_by_step/implement_a_process.md",
        "Implementing a model" => "./step_by_step/implement_a_model.md",
        "Parallelization" => "./step_by_step/parallelization.md",
        "Advanced coupling and hard dependencies" => "./step_by_step/advanced_coupling.md"
        ],
        "Execution" => "model_execution.md",
        "Working with data" => [
            # Quick and dirty examples
            "Reducing DoF" => "./working_with_data/reducing_dof.md",
            "Fitting" => "./working_with_data/fitting.md",
            "Input types" => "./working_with_data/inputs.md",
            "Visualizing outputs" => "./working_with_data/visualising_outputs.md"
        ],
        "Moving to multiscale" => [
            "Detailed example" => "./multiscale/multiscale.md",
            "Handling cyclic dependencies" => "./multiscale/multiscale_cyclic.md",
            "Multiscale coupling considerations" => "./multiscale/multiscale_coupling.md", # TODO expand upon this
            "Building a simple plant" => [
                "A rudimentary plant simulation" => "./multiscale/multiscale_example_1.md",
                "Expanding the plant simulation" => "./multiscale/multiscale_example_2.md",
            ],
        ],

        "Troubleshooting and testing" => [
        "Troubleshooting" => "./troubleshooting_and_testing/plantsimengine_and_julia_troubleshooting.md",
        "Automated testing" => "./troubleshooting_and_testing/downstream_tests.md",
        "Tips and Workarounds" => "./troubleshooting_and_testing/tips_and_workarounds.md",
        ],

        "API" => "API.md",
        "Credits" => "credits.md",
        "Planned features" => "planned_features.md",
        #"developer section ?"
    ]
)

deploydocs(;
    repo="github.com/VirtualPlantLab/PlantSimEngine.jl.git",
    devbranch="main"
)
