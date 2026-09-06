using Test

include(
    joinpath(
        @__DIR__,
        "..",
        "skills",
        "plantsimengine",
        "scripts",
        "check-examples.jl",
    ),
)

@test EVALUATION_REPORT.valid
@test EVALUATION_REPORT.schema_version == 1
@test EVALUATION_REPORT.executable_oracles == 10
@test EVALUATION_REPORT.workspace_oracles == 5
@test length(EVALUATION_ORACLE_RESULTS) == 15
@test all(result.passed for result in values(EVALUATION_ORACLE_RESULTS))
@test EVALUATION_REPORT.ids == (
    :direct_trigger,
    :indirect_dependency_trigger,
    :incomplete_process_request,
    :non_trigger_generic_julia,
    :wrong_environment_old_documentation,
    :existing_process_model,
    :drop_in_alternative,
    :same_process_binding_changes,
    :many_subtree_coupling,
    :contract_adapter,
    :missing_environment_input,
    :hard_call_publication,
    :dynamic_organ_initializer,
    :generic_numeric_types,
    :two_process_package_layout,
)

const AGENT_SKILL_EVALUATION_CASES =
    PlantSimEngineSkillEvaluations.EVALUATION_CASES
const AGENT_SKILL_TRIGGER_EXPECTATIONS = Dict(
    case.id => (:plantsimengine in case.required_skills)
    for case in AGENT_SKILL_EVALUATION_CASES
)
@test length(AGENT_SKILL_TRIGGER_EXPECTATIONS) == 15
@test !AGENT_SKILL_TRIGGER_EXPECTATIONS[:non_trigger_generic_julia]
@test all(
    expectation
    for (id, expectation) in AGENT_SKILL_TRIGGER_EXPECTATIONS
    if id !== :non_trigger_generic_julia
)

for case in AGENT_SKILL_EVALUATION_CASES
    ideal_trace = (
        triggered_skills=case.required_skills,
        read_references=case.required_references,
        actions=case.required_actions,
    )
    @test PlantSimEngineSkillEvaluations.assess_trace(case.id, ideal_trace).passed
end

missing_verification = PlantSimEngineSkillEvaluations.assess_trace(
    :direct_trigger,
    (
        triggered_skills=(:kaimon_julia, :plantsimengine),
        read_references=(
            "references/model-authoring.md",
            "references/scenario-coupling.md",
        ),
        actions=(
            :inspect_available_processes,
            :validate_model,
            :validate_scenario,
            :use_public_diagnostics,
        ),
    ),
)
@test !missing_verification.passed
@test missing_verification.missing_actions == [:verify_loaded_package]

skill_source = read(
    joinpath(@__DIR__, "..", "skills", "plantsimengine", "SKILL.md"),
    String,
)
@test occursin("13. Document the hypothesis", skill_source)
@test occursin("model_metadata", skill_source)
@test occursin("parameter_metadata", skill_source)

alternative_source = read(
    joinpath(
        @__DIR__,
        "..",
        "skills",
        "plantsimengine",
        "assets",
        "alternative-model.jl",
    ),
    String,
)
@test length(findall("maturity=:pedagogical_non_calibrated", alternative_source)) == 3
@test length(findall("reference=nothing", alternative_source)) == 3
@test length(findall("parameter_metadata", alternative_source)) == 3
