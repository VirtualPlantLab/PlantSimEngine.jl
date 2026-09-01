module PlantSimEngineSkillEvaluations

export EVALUATION_SCHEMA_VERSION, EVALUATION_CASES
export evaluation_case, validate_manifest, assess_trace, run_oracle

include("manifest.jl")
include("oracles.jl")

function evaluation_case(id::Symbol)
    index = findfirst(case -> case.id === id, EVALUATION_CASES)
    isnothing(index) && throw(ArgumentError("Unknown evaluation case: $(id)"))
    return EVALUATION_CASES[index]
end

function validate_manifest(; skill_root=realpath(joinpath(@__DIR__, "..")))
    ids = map(case -> case.id, EVALUATION_CASES)
    length(unique(ids)) == length(ids) || error("Evaluation case ids must be unique.")

    for case in EVALUATION_CASES
        isempty(strip(case.prompt)) && error("Evaluation prompt $(case.id) is empty.")
        isempty(case.required_skills) && error(
            "Evaluation case $(case.id) must declare at least its Julia execution skill.",
        )
        isempty(intersect(case.required_skills, case.forbidden_skills)) || error(
            "Evaluation case $(case.id) both requires and forbids one skill.",
        )
        isempty(intersect(case.required_actions, case.forbidden_actions)) || error(
            "Evaluation case $(case.id) both requires and forbids one action.",
        )
        for reference in case.required_references
            isfile(joinpath(skill_root, reference)) || error(
                "Evaluation case $(case.id) references missing file $(reference).",
            )
        end
        fixture = joinpath(skill_root, case.workspace_fixture)
        ispath(fixture) || error(
            "Evaluation case $(case.id) references missing workspace fixture " *
            "$(case.workspace_fixture).",
        )
        case.oracle_level in (:workspace_precondition, :executable_model) || error(
            "Evaluation case $(case.id) has invalid oracle level $(case.oracle_level).",
        )
        haskey(ORACLE_RUNNERS, case.oracle) || error(
            "Evaluation case $(case.id) has no registered oracle $(case.oracle).",
        )
    end

    executable_count = count(
        case -> case.oracle_level === :executable_model,
        EVALUATION_CASES,
    )
    workspace_count = count(
        case -> case.oracle_level === :workspace_precondition,
        EVALUATION_CASES,
    )

    return (
        valid=true,
        schema_version=EVALUATION_SCHEMA_VERSION,
        case_count=length(EVALUATION_CASES),
        executable_oracles=executable_count,
        workspace_oracles=workspace_count,
        ids=ids,
    )
end

"""
    assess_trace(id, trace)

Assess one fresh-agent trace against the manifest. `trace` is a `NamedTuple`
with `triggered_skills`, `read_references`, and `actions` collections. This
harness scores captured behavior; it does not claim that static tests ran an
agent.
"""
function assess_trace(id::Symbol, trace::NamedTuple)
    case = evaluation_case(id)
    triggered_skills = Set(Symbol.(trace.triggered_skills))
    read_references = Set(String.(trace.read_references))
    actions = Set(Symbol.(trace.actions))

    missing_skills = setdiff(Set(case.required_skills), triggered_skills)
    forbidden_skills = intersect(Set(case.forbidden_skills), triggered_skills)
    missing_references = setdiff(Set(case.required_references), read_references)
    missing_actions = setdiff(Set(case.required_actions), actions)
    forbidden_actions = intersect(Set(case.forbidden_actions), actions)

    passed = all(isempty, (
        missing_skills,
        forbidden_skills,
        missing_references,
        missing_actions,
        forbidden_actions,
    ))
    return (
        passed=passed,
        case_id=id,
        missing_skills=sort!(collect(missing_skills); by=string),
        forbidden_skills=sort!(collect(forbidden_skills); by=string),
        missing_references=sort!(collect(missing_references)),
        missing_actions=sort!(collect(missing_actions); by=string),
        forbidden_actions=sort!(collect(forbidden_actions); by=string),
    )
end

end # module PlantSimEngineSkillEvaluations
