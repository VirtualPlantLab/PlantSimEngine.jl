using SHA, Test
import PlantSimEngine as PSE
const RECIPE = normpath(joinpath(@__DIR__, "..", "xpalm-matched"))
include(joinpath(RECIPE, "harness/benchmark/regular_execution/xpalm.jl"))
include(joinpath(RECIPE, "strict-snapshot-observations.jl"))
include(joinpath(RECIPE, "finite-values.jl"))
include(joinpath(RECIPE, "status-semantic-projection.jl"))
include(joinpath(RECIPE, "full_science_observer.jl"))
const R = RegularXPalmExecution
const S = StrictSnapshotObservations
const Projection = StatusSemanticProjection
const F = FullXPalmScientificObservation
const REF = PSE.JSON.parsefile(joinpath(RECIPE, "reference.json"))
const COUNTS = Int.(REF["object_counts"])
const DAYS = 4160
const ENVIRONMENT = dirname(Base.active_project())
object_count(sim) = length(PSE.runtime_model(sim).registry.objects)
model_rngs(source) = [R._raw_digest(copy(getfield(spec.model, name))) for spec in source.applications
    for name in fieldnames(typeof(spec.model)) if getfield(spec.model, name) isa R.Random.AbstractRNG]
function science(sim, source)
    state = Projection.project_core(R.snapshot(sim))
    setup = (; palm=source.palm, parameters=source.palm.parameters, weather=PSE.runtime_model(sim).environment)
    companion = F.companion_snapshot(sim, setup; constants=sim.constants)
    @test S.content_sha256(Projection.project_core(R.snapshot(sim))) == S.content_sha256(state)
    @test state.step == DAYS
    @test length(state.states) == REF["objects"]
    @test sum(length(h.samples) for h in state.histories; init=0) == REF["retained_samples"]
    return (; core=S.content_sha256(state), components=Dict(String(k) => S.content_sha256(state[k]) for k in keys(state)),
        companion_digest=S.content_sha256(companion), objects=length(state.states),
        retained_samples=sum(length(h.samples) for h in state.histories; init=0))
end
