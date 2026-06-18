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
        size_threshold=700000
    ), pages=[
        "Home" => "index.md",
        "Introduction" => [
            "Why PlantSimEngine ?" => "./introduction/why_plantsimengine.md",
            "Why Julia ?" => "./introduction/why_julia.md",
        ],
        "Prerequisites" => [
            "Installing and running PlantSimEngine" => "./prerequisites/installing_plantsimengine.md",
            "Key Concepts" => "./prerequisites/key_concepts.md",
            "Julia language basics" => "./prerequisites/julia_basics.md",
        ],
        "Scene/Object simulations" => [
            "Quickstart" => "./scene_object/quickstart.md",
            "Migrating from mappings" => "migration_scene_object.md",
        ],
        "Step by step - Single-scale simulations" => [
            "Detailed first simulation" => "./step_by_step/detailed_first_example.md",
            "Coupling" => "./step_by_step/simple_model_coupling.md",
            "Model Switching" => "./step_by_step/model_switching.md",
            "Quick examples" => "./step_by_step/quick_and_dirty_examples.md",
            "Implementing a process" => "./step_by_step/implement_a_process.md",
            "Implementing a model" => "./step_by_step/implement_a_model.md",
            "Advanced coupling and hard dependencies" => "./step_by_step/advanced_coupling.md",
            "Implementing a model : additional notes" => "./step_by_step/implement_a_model_additional.md",
        ],
        "Model execution" => "model_execution.md",
        "Model traits" => "model_traits.md",
        "AI agent skill" => "agent_skill.md",
        "Parameter fitting" => "./working_with_data/fitting.md",
        "Troubleshooting and testing" => [
            "Automated testing" => "./troubleshooting_and_testing/downstream_tests.md",
        ], "API" => [
            "Public API" => "./API/API_public.md",
            "Example models" => "./API/API_examples.md",
            "Internal API" => "./API/API_private.md",],
        "Development designs" => [
            "Unified scene/object design" => "./dev/unified_scene_object_design.md",
            "Unified scene/object implementation plan" => "./dev/unified_scene_object_implementation_plan.md",
            "Unified scene/object completion audit" => "./dev/unified_scene_object_completion_audit.md",
            "MAESPA-style scene example handoff" => "./dev/maespa_scene_handoff.md",
            "Code cleanup audit" => "./dev/code_cleanup_audit.md",
            "Release notes handoff" => "./dev/release_notes_handoff.md",
        ],
        "Developer guidelines" => "developers.md",
        "Roadmap" => "planned_features.md",
    ]
)

deploydocs(;
    repo="github.com/VirtualPlantLab/PlantSimEngine.jl.git",
    devbranch="main",
    push_preview=true, # Visit https://VirtualPlantLab.github.io/PlantSimEngine.jl/previews/PR128 to visualize the preview of the PR #128
)
