module PhytomerChecks
using Test
using PlantSimEngine
import MultiScaleTreeGraph as MTG
import ..ReusableProgram as RP
import ..PhytomerFixture as PF
function snapshot(state)
    rows=NamedTuple[]
    for cohort in state.cohorts, i in eachindex(cohort.ids)
        node=cohort.nodes[i]; parent=MTG.parent(node)
        push!(rows,PF.object_fingerprint(cohort.ids[i],RP._cohort_key(cohort),
            isnothing(parent) ? nothing : MTG.node_id(parent),cohort.rows[i];
            link=MTG.link(node),index=MTG.index(node)))
    end
    return sort!(rows;by=r->r.object_id)
end
function samples(state, specs)
    rows=NamedTuple[]
    for (i,spec) in enumerate(specs), sample in state.publications[i], var in keys(PlantSimEngine.outputs_(spec))
        push!(rows,(application=spec.name,object_id=sample.object_id,step=sample.step,
            variable=var,value=sample.values[var]))
    end
    return sort!(rows;by=r->(string(r.application),r.object_id,r.step,string(r.variable)))
end
function ordinary_samples(sim)
    rows=[(application=r.application_id,object_id=ObjectId(r.object_id).value,
        step=r.timestep,variable=r.variable,value=r.value)
        for r in PlantSimEngine.collect_outputs(sim;sink=nothing)]
    return sort!(rows;by=r->(string(r.application),r.object_id,r.step,string(r.variable)))
end
function compare_case(;days=4,rate=0.05,biomass=1.0,initiation_age=0)
    tree=PF.tree(); specs=PF.specs(tree;rate,initiation_age)
    initial=PF.initial(;biomass,initiation_age)
    program=RP.prepare(specs;initial)
    state=RP.instantiate(program,map(s->s.model,specs),tree;initial,retain=true)
    ordinary=PlantSimEngine.run!(PF.scene(PF.rows(days);rate,biomass,initiation_age);steps=0,outputs=:all)
    @test length(state.cohorts[5].ids)==length(state.cohorts[6].ids)==0
    @test isequal(snapshot(state),PF.fingerprint(PlantSimEngine.runtime_model(ordinary)))
    refs=[PlantSimEngine.refvalue(s,:plant_age) for s in state.cohorts[4].rows]
    for row in PF.rows(days)
        RP.step!(state,row;constants=PlantSimEngine.Constants())
        PlantSimEngine.step!(ordinary)
        @test isequal(snapshot(state),PF.fingerprint(PlantSimEngine.runtime_model(ordinary)))
        @test isequal(samples(state,specs),ordinary_samples(ordinary))
        @test all(c->c.committed==length(c.ids),state.cohorts)
        @test isempty(state.pending)
    end
    @test refs[1] === PlantSimEngine.refvalue(state.cohorts[4].rows[1],:plant_age)
    @test all(s->PlantSimEngine.refvalue(s,:plant_age)===PlantSimEngine.refvalue(only(state.cohorts[2].rows),:plant_age),state.cohorts[6].rows)
    return (nodes=length(tree),cohorts=map(c->length(c.ids),state.cohorts),steps=state.step)
end
function run_checks()
    cases=NamedTuple[]
    result=@testset "Original XPalm phytomer lifecycle" begin
        for settings in ((days=4,rate=0.05,biomass=1.0,initiation_age=0),
                         (days=6,rate=0.1,biomass=2.0,initiation_age=12),
                         (days=2,rate=0.001,biomass=1.0,initiation_age=0))
            push!(cases,compare_case(;settings...))
        end
    end
    counts=Test.get_test_counts(result)
    return (passes=counts.passes+counts.cumulative_passes,
        fails=counts.fails+counts.cumulative_fails,errors=counts.errors+counts.cumulative_errors,cases)
end
end
