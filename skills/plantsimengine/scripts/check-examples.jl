using PlantSimEngine

const SKILL_ROOT = realpath(joinpath(@__DIR__, ".."))
const PACKAGE_ROOT = realpath(joinpath(SKILL_ROOT, "..", ".."))

@assert realpath(pkgdir(PlantSimEngine)) == PACKAGE_ROOT "The loaded PlantSimEngine does not come from the package that owns this skill."
@assert Base.pkgversion(PlantSimEngine) >= v"0.15.0"

const FORBIDDEN_API_NAMES = (
    "Model" * "Mapping",
    "Multi" * "ScaleModel",
    "Graph" * "Simulation",
    "Input" * "Bindings",
)

function skill_source_files()
    files = String[joinpath(SKILL_ROOT, "SKILL.md")]
    for directory in ("references", "assets", "evaluations")
        root = joinpath(SKILL_ROOT, directory)
        for (path, _, names) in walkdir(root)
            for name in names
                extension = splitext(name)[2]
                extension in (".md", ".jl") || continue
                push!(files, joinpath(path, name))
            end
        end
    end
    return sort!(files)
end

function validate_sources(files)
    for path in files
        source = read(path, String)
        for name in FORBIDDEN_API_NAMES
            @assert !occursin(name, source) "Removed API name $(name) found in $(path)."
        end
        @assert !occursin("AbstractSome", source) "Fictitious model type found in $(path)."
    end
    return nothing
end

function validate_markdown_links(files)
    markdown_files = filter(path -> endswith(path, ".md"), files)
    for path in markdown_files
        source = read(path, String)
        for match in eachmatch(r"\]\(([^)]+)\)", source)
            target = only(match.captures)
            startswith(target, "#") && continue
            occursin("://", target) && continue
            target_path = normpath(joinpath(dirname(path), target))
            @assert ispath(target_path) "Missing local skill link $(target) in $(path)."
        end
    end
    return nothing
end

const SOURCE_FILES = skill_source_files()
validate_sources(SOURCE_FILES)
validate_markdown_links(SOURCE_FILES)

include(joinpath(SKILL_ROOT, "evaluations", "harness.jl"))
const EVALUATION_REPORT =
    PlantSimEngineSkillEvaluations.validate_manifest(; skill_root=SKILL_ROOT)
const EVALUATION_ORACLE_RESULTS = Dict(
    case.id => PlantSimEngineSkillEvaluations.run_oracle(case.id)
    for case in PlantSimEngineSkillEvaluations.EVALUATION_CASES
)

include(joinpath(SKILL_ROOT, "assets", "model-tests.jl"))

(
    package_path=Base.pathof(PlantSimEngine),
    package_root=PACKAGE_ROOT,
    package_version=Base.pkgversion(PlantSimEngine),
    active_project=Base.active_project(),
    checked_files=length(SOURCE_FILES),
    evaluation_cases=EVALUATION_REPORT.case_count,
    executable_oracles=EVALUATION_REPORT.executable_oracles,
    workspace_oracles=EVALUATION_REPORT.workspace_oracles,
)
