using Pkg
Pkg.develop("PlantSimEngine")
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
        size_threshold=500000
    ), pages=[
        "Home" => "index.md",
        "Introduction" => [
            #"Organization of the documentation ?"
            "Why PlantSimEngine ?" => "./introduction/why_plantsimengine.md",
            "Why Julia ?" => "./introduction/why_julia.md",
            #"Overview ?"
            #"Feature list ? Companion packages ?"
        ],
        "Prerequisites" => [
            "Installing and running PlantSimEngine" => "./prerequisites/installing_plantsimengine.md",
            "Key Concepts" => "./prerequisites/key_concepts.md", # Key concepts vs terminology ?
            #"Setup" ?",
            "Julia language basics" => "./prerequisites/julia_basics.md",
        ],
        "Step by step - Single-scale simulations" => [
            "Detailed first simulation" => "./step_by_step/detailed_first_example.md",
            "Coupling" => "./step_by_step/simple_model_coupling.md",
            "Model Switching" => "./step_by_step/model_switching.md",
            "Quick examples" => "./step_by_step/quick_and_dirty_examples.md",
            "Implementing a process" => "./step_by_step/implement_a_process.md",
            "Implementing a model" => "./step_by_step/implement_a_model.md",
            "Parallelization" => "./step_by_step/parallelization.md",
            "Advanced coupling and hard dependencies" => "./step_by_step/advanced_coupling.md",
            "Implementing a model : additional notes" => "./step_by_step/implement_a_model_additional.md",           
        ],
        "Execution" => "model_execution.md",
        "Working with data" => [
            "Reducing DoF" => "./working_with_data/reducing_dof.md",
            "Fitting" => "./working_with_data/fitting.md",
            "Input types" => "./working_with_data/inputs.md",
            "Visualizing outputs and data" => "./working_with_data/visualising_outputs.md",
            "Floating-point considerations" => "./working_with_data/floating_point_accumulation_error.md",
        ],
        "Moving to multiscale" => [
            "Multiscale considerations" => "./multiscale/multiscale_considerations.md",
            "Converting a simulation to multi-scale" => "./multiscale/single_to_multiscale.md",
            "More variable mapping examples" => "./multiscale/multiscale.md",
            "Handling cyclic dependencies" => "./multiscale/multiscale_cyclic.md",
            "Multiscale coupling considerations" => "./multiscale/multiscale_coupling.md",
            "Building a simple plant" => [
                "A rudimentary plant simulation" => "./multiscale/multiscale_example_1.md",
                "Expanding the plant simulation" => "./multiscale/multiscale_example_2.md",
                "Fixing bugs in the plant simulation"=> "./multiscale/multiscale_example_3.md", # TODO illustrate outputs filtering to find the bug
            ],
            "Visualizing our toy plant with PlantGeom"=> "./multiscale/multiscale_example_4.md",
        ], "Troubleshooting and testing" => [
            "Troubleshooting" => "./troubleshooting_and_testing/plantsimengine_and_julia_troubleshooting.md",
            "Automated testing" => "./troubleshooting_and_testing/downstream_tests.md",
            "Tips and Workarounds" => "./troubleshooting_and_testing/tips_and_workarounds.md",
            "Implicit contracts" => "./troubleshooting_and_testing/implicit_contracts.md",
        ], "API" => [
            "Public API" => "./API/API_public.md",
            "Example models" => "./API/API_examples.md",
            "Internal API" => "./API/API_private.md",],
        "Credits" => "credits.md",
        "Improving our documentation" => "documentation_improvement.md",
        "Planned features" => "planned_features.md",
        #"developer section TODO"
    ]
)
# move repeated examples listing to a specific page ?

deploydocs(;
    repo="github.com/VirtualPlantLab/PlantSimEngine.jl.git",
    devbranch="main",
    push_preview=true, # Visit https://VirtualPlantLab.github.io/PlantSimEngine.jl/previews/PR128 to visualize the preview of the PR #128
)
