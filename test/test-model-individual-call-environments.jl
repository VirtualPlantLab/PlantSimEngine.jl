using Dates
using PlantSimEngine
using Test

const INDIVIDUAL_ENV_API = PlantSimEngine.EnvironmentAPI

# Test-only roles and instrumentation. No production hypothesis is added.
PlantSimEngine.@process "individual_env_owner_probe" verbose=false
PlantSimEngine.@process "individual_env_middle_probe" verbose=false
PlantSimEngine.@process "individual_env_leaf_probe" verbose=false

struct IndividualEnvTrialA{T}
    cell_a::T
    cell_b::T
end
struct IndividualEnvTrialB{T}
    values::NTuple{2,T}
end
individual_env_value(state::IndividualEnvTrialA, cell) =
    cell === :cell_a ? state.cell_a : state.cell_b
individual_env_value(state::IndividualEnvTrialB, cell) =
    state.values[cell === :cell_a ? 1 : 2]

const IndividualEnvSample = NamedTuple{
    (:application,:cell,:variable,:time,:trial),
    Tuple{Symbol,Symbol,Symbol,Float64,Bool},
}
const IndividualEnvCommit = NamedTuple{
    (:application,:cell,:value,:time),Tuple{Symbol,Symbol,Float64,Float64},
}
mutable struct IndividualEnvBackend <: INDIVIDUAL_ENV_API.AbstractEnvironmentBackend
    values::Dict{Symbol,Float64}
    samples::Vector{IndividualEnvSample}
    writes::Vector{IndividualEnvCommit}
end
IndividualEnvBackend() = IndividualEnvBackend(
    Dict(:cell_a=>10.0,:cell_b=>20.0),IndividualEnvSample[],IndividualEnvCommit[])
INDIVIDUAL_ENV_API.base_step_seconds(::IndividualEnvBackend) = 3600.0
INDIVIDUAL_ENV_API.get_nsteps(::IndividualEnvBackend) = 8
INDIVIDUAL_ENV_API.environment_variables(::IndividualEnvBackend) =
    Set((:source_temperature,:clock_index))
function INDIVIDUAL_ENV_API.bind_environment(
    backend::IndividualEnvBackend, object::Object, context, config,
)
    location=geometry(object)
    cell=isnothing(location) ? :cell_a : location.cell
    sink=isnothing(config) ? nothing : get(config,:sink,nothing)
    return (;cell,application=context.application,sink)
end
function INDIVIDUAL_ENV_API.sample(backend::IndividualEnvBackend,handle,variable::Symbol,time)
    push!(backend.samples,(application=handle.application,cell=handle.cell,
        variable=variable,time=Float64(time),trial=false))
    variable === :clock_index && return float(time)
    variable === :source_temperature && return backend.values[handle.cell]
    error("Unexpected individual-environment source $variable")
end
function INDIVIDUAL_ENV_API.sample(backend::IndividualEnvBackend,handle,
    state::Union{IndividualEnvTrialA,IndividualEnvTrialB},variable::Symbol,time)
    push!(backend.samples,(application=handle.application,cell=handle.cell,
        variable=variable,time=Float64(time),trial=true))
    variable === :clock_index && return float(time)
    variable === :source_temperature && return individual_env_value(state,handle.cell)
    error("Unexpected individual trial source $variable")
end
function INDIVIDUAL_ENV_API.commit_environment!(backend::IndividualEnvBackend,handle,state,time)
    handle.sink === :individual_probe || error("Individual probe has no commit sink")
    backend.values[handle.cell]=state.Tl
    push!(backend.writes,(application=handle.application,cell=handle.cell,
        value=Float64(state.Tl),time=Float64(time)))
    return nothing
end

struct IndividualEnvOwner{C} <: AbstractIndividual_Env_Owner_ProbeModel
    capture::C
end
PlantSimEngine.inputs_(::IndividualEnvOwner)=NamedTuple()
PlantSimEngine.outputs_(::IndividualEnvOwner)=(visits=0,)
PlantSimEngine.environment_inputs_(::IndividualEnvOwner)=NamedTuple()
function PlantSimEngine.run!(model::IndividualEnvOwner,status,environment,constants,context)
    model.capture[]=context
    status.visits+=1
    return nothing
end

struct IndividualEnvLeaf <: AbstractIndividual_Env_Leaf_ProbeModel end
PlantSimEngine.inputs_(::IndividualEnvLeaf)=(fail_next=Default(false),)
PlantSimEngine.outputs_(::IndividualEnvLeaf)=(seen=0.0,seen_step=0.0,calls=0)
PlantSimEngine.environment_inputs_(::IndividualEnvLeaf)=(Tl=0.0,clock_index=0.0)
PlantSimEngine.environment_outputs_(::IndividualEnvLeaf)=(Tl=0.0,)
function PlantSimEngine.run!(::IndividualEnvLeaf,status,environment,constants,context)
    status.calls+=1
    status.seen=environment.Tl
    status.seen_step=environment.clock_index
    if status.fail_next
        status.fail_next=false
        error("intentional individual-environment failure")
    end
    commit_environment!(context,(Tl=environment.Tl,))
    return nothing
end

struct IndividualEnvMiddle{C,H} <: AbstractIndividual_Env_Middle_ProbeModel
    individual::Bool
    captured_leaf::C
    reentry_hook::H
end
PlantSimEngine.inputs_(::IndividualEnvMiddle)=NamedTuple()
PlantSimEngine.outputs_(::IndividualEnvMiddle)=(seen=0.0,seen_step=0.0,leaf_seen=0.0,calls=0)
PlantSimEngine.environment_inputs_(::IndividualEnvMiddle)=(Tm=0.0,clock_index=0.0)
function PlantSimEngine.run!(model::IndividualEnvMiddle,status,environment,constants,context)
    # Acquire the outer child view BEFORE same-target reentry. An inner call
    # must not corrupt that already-borrowed outer environment or permission.
    leaf=only(call_targets(context,:leaf))
    hook=model.reentry_hook[]
    if !isnothing(hook)
        model.reentry_hook[]=nothing
        hook()
    end
    if model.individual
        run_call!(leaf;publish=true)
    else
        leaf=only(run_call!(context,:leaf;publish=true))
    end
    model.captured_leaf[]=leaf
    status.seen=environment.Tm
    status.seen_step=environment.clock_index
    status.leaf_seen=leaf.status.seen
    status.calls+=1
    return nothing
end

function individual_env_scene(::Type{S};individual=false) where {S}
    capture=Ref{Any}()
    captured_leaf=Ref{Any}()
    reentry_hook=Ref{Any}(nothing)
    backend=IndividualEnvBackend()
    middle=IndividualEnvMiddle(individual,captured_leaf,reentry_hook)
    model=CompositeModel(
        Object(:individual_owner;scale=:Scene,geometry=(cell=:cell_a,)),
        Object(:individual_middle;scale=:Plant,parent=:individual_owner,geometry=(cell=:cell_a,)),
        Object(:individual_leaf;scale=:Leaf,parent=:individual_middle,geometry=(cell=:cell_b,));
        applications=(
            ModelSpec(IndividualEnvOwner(capture);name=:individual_owner,on=One(id=:individual_owner),
                calls=(middle=One(id=:individual_middle,application=:individual_middle),)),
            ModelSpec(middle;name=:individual_middle,on=One(id=:individual_middle),
                calls=(leaf=One(id=:individual_leaf,within=Subtree(),application=:individual_leaf),),
                environment=Environment(provider=:individual_probe,sources=(Tm=:source_temperature,))),
            ModelSpec(IndividualEnvLeaf();name=:individual_leaf,on=Many(scale=:Leaf),
                environment=Environment(provider=:individual_probe,sink=:individual_probe,
                    sources=(Tl=:source_temperature,))),
        ),environment=backend,type_promotion=Dict(Float64=>S))
    return (;model,backend,capture,captured_leaf,reentry_hook)
end
function individual_env_rows(simulation,object;variable=:seen)
    return sort!(collect_outputs(simulation,object,variable;sink=nothing);by=row->row.timestep)
end
function individual_env_current(scene,::Type{S},middle,leaf,step) where {S}
    middle_status=model_status(scene.model,:individual_middle)
    leaf_status=model_status(scene.model,:individual_leaf)
    @test middle_status.seen === S(middle)
    @test middle_status.seen_step === S(step)
    @test middle_status.leaf_seen === S(leaf)
    @test leaf_status.seen === S(leaf)
    @test leaf_status.seen_step === S(step)
end
function individual_env_sample_signature(backend)
    return Set((sample.application,sample.cell,sample.variable,sample.time,sample.trial)
        for sample in backend.samples)
end

@testset "individual backend overrides preserve providers, snapshots and publication" begin
    for S in (Float32,Float64),individual in (false,true)
        @testset "storage=$S individual-descendant=$individual" begin
            scene=individual_env_scene(S;individual)
            simulation=run!(scene.model;steps=1,outputs=:all)
            target=only(call_targets(scene.capture[],:middle))
            captured_environment=target.environment
            captured_time=target.time
            captured_permission=target.publication_allowed
            @test isempty(individual_env_rows(simulation,:individual_middle))
            @test isempty(individual_env_rows(simulation,:individual_leaf))

            for trial in (IndividualEnvTrialA(30.0,40.0),IndividualEnvTrialA(31.0,41.0))
                empty!(scene.backend.samples)
                @test run_call!(target;environment=trial,publish=false) === target
                individual_env_current(scene,S,trial.cell_a,trial.cell_b,1)
                @test length(scene.backend.samples)==4
                @test individual_env_sample_signature(scene.backend)==Set((
                    (:individual_middle,:cell_a,:source_temperature,1.0,true),
                    (:individual_middle,:cell_a,:clock_index,1.0,true),
                    (:individual_leaf,:cell_b,:source_temperature,1.0,true),
                    (:individual_leaf,:cell_b,:clock_index,1.0,true),
                ))
                @test isempty(scene.backend.writes)
                @test isempty(individual_env_rows(simulation,:individual_leaf))
            end
            @test scene.backend.values==Dict(:cell_a=>10.0,:cell_b=>20.0)

            run_call!(target;environment=IndividualEnvTrialB((50.0f0,60.0f0)),publish=true)
            individual_env_current(scene,S,50,60,1)
            @test scene.backend.writes==[
                (application=:individual_leaf,cell=:cell_b,value=60.0,time=1.0)]
            accepted=deepcopy(individual_env_rows(simulation,:individual_leaf))
            @test getproperty.(accepted,:value)==S[60]

            run_call!(target;environment=IndividualEnvTrialA(32.0,42.0),publish=false)
            escaped_leaf=scene.captured_leaf[]
            escaped_environment=escaped_leaf.environment
            @test !escaped_leaf.publication_allowed
            @test run_call!(escaped_leaf;environment=IndividualEnvTrialB((55.0f0,66.0f0)),
                publish=true) === escaped_leaf
            @test escaped_leaf.status.seen === S(66)
            @test escaped_leaf.environment === escaped_environment
            # Even a later direct accepted request cannot escape an ancestor's
            # captured rejection. Omitting override restores captured trial A.
            run_call!(escaped_leaf;publish=true)
            @test escaped_leaf.status.seen === S(42)
            @test length(scene.backend.writes)==1
            @test isequal(individual_env_rows(simulation,:individual_leaf),accepted)

            run_call!(target;publish=false)
            individual_env_current(scene,S,10,60,1)
            @test target.environment === captured_environment
            @test target.time === captured_time
            @test target.publication_allowed === captured_permission
            empty!(scene.backend.samples)
            run_call!(target;sampled_environment=(Tm=91.0,clock_index=-91.0),publish=false)
            @test target.status.seen === S(91)
            @test target.status.seen_step === S(-91)
            @test target.status.leaf_seen === S(60)
            @test length(scene.backend.samples)==2
            @test all(sample->sample.application === :individual_leaf && !sample.trial,
                scene.backend.samples)

            before=(middle=NamedTuple(target.status),leaf=NamedTuple(escaped_leaf.status),
                samples=copy(scene.backend.samples),writes=copy(scene.backend.writes),
                rows=deepcopy(individual_env_rows(simulation,:individual_leaf)))
            @test_throws ArgumentError run_call!(target;
                environment=IndividualEnvTrialA(99.0,100.0),
                sampled_environment=(Tm=-1.0,clock_index=-1.0),publish=true)
            @test isequal(NamedTuple(target.status),before.middle)
            @test isequal(NamedTuple(escaped_leaf.status),before.leaf)
            @test scene.backend.samples==before.samples
            @test scene.backend.writes==before.writes
            @test isequal(individual_env_rows(simulation,:individual_leaf),before.rows)

            leaf=model_status(scene.model,:individual_leaf)
            calls_before=leaf.calls
            leaf.fail_next=true
            @test_throws "intentional individual-environment failure" run_call!(target;
                environment=IndividualEnvTrialA(33.0,43.0),publish=false)
            @test leaf.calls==calls_before+1
            @test !leaf.fail_next
            @test length(scene.backend.writes)==1
            # The very same target/cache must remain usable after the throw.
            run_call!(target;environment=IndividualEnvTrialB((51.0f0,61.0f0)),publish=false)
            individual_env_current(scene,S,51,61,1)

            step!(simulation)
            current=only(call_targets(scene.capture[],:middle))
            run_call!(current;environment=IndividualEnvTrialB((70.0f0,80.0f0)),publish=true)
            individual_env_current(scene,S,70,80,2)
            # Explicit new values on an old target still use the OLD clock.
            run_call!(target;environment=IndividualEnvTrialA(21.0,22.0),publish=false)
            individual_env_current(scene,S,21,22,1)
            run_call!(target;publish=false)
            individual_env_current(scene,S,10,80,1)
            @test target.environment === captured_environment
            @test target.time === captured_time
            for (id,expected) in ((:individual_middle,S[50,70]),(:individual_leaf,S[60,80]))
                rows=individual_env_rows(simulation,id)
                @test getproperty.(rows,:timestep)==[1,2]
                @test getproperty.(rows,:value)==expected
                @test all(row->row.value isa S,rows)
            end
            @test length(scene.backend.writes)==2
        end
    end
end

@testset "same-target backend reentry keeps the already acquired outer child view" begin
    for S in (Float32,Float64),individual in (false,true)
        scene=individual_env_scene(S;individual)
        simulation=run!(scene.model;steps=1,outputs=:all)
        target=only(call_targets(scene.capture[],:middle))
        scene.reentry_hook[]=()->run_call!(target;
            environment=IndividualEnvTrialB((31.0f0,41.0f0)),publish=false)
        run_call!(target;environment=IndividualEnvTrialA(11.0,21.0),publish=true)
        individual_env_current(scene,S,11,21,1)
        @test model_status(scene.model,:individual_leaf).calls==2
        @test scene.backend.writes==[
            (application=:individual_leaf,cell=:cell_b,value=21.0,time=1.0)]
        @test getproperty.(individual_env_rows(simulation,:individual_middle),:value)==S[11]
        @test getproperty.(individual_env_rows(simulation,:individual_leaf),:value)==S[21]
        # Normal reuse immediately after reentry must also release the lease.
        run_call!(target;environment=IndividualEnvTrialB((12.0f0,22.0f0)),publish=false)
        individual_env_current(scene,S,12,22,1)
        @test length(scene.backend.writes)==1
    end
end

struct IndividualEnvNewbornOwner{T,C} <: AbstractIndividual_Env_Owner_ProbeModel
    trials::T
    capture::C
end
PlantSimEngine.inputs_(::IndividualEnvNewbornOwner)=NamedTuple()
PlantSimEngine.outputs_(::IndividualEnvNewbornOwner)=(visits=0,seen=0.0)
PlantSimEngine.environment_inputs_(::IndividualEnvNewbornOwner)=NamedTuple()
function PlantSimEngine.run!(model::IndividualEnvNewbornOwner,status,environment,constants,context)
    status.visits+=1
    runtime=runtime_model(context)
    if status.visits==1
        register_object!(runtime,Object(:individual_newborn;scale=:Leaf,parent=:individual_owner,
            geometry=(cell=:cell_b,)))
    end
    target=only(call_targets(context,:newborn;objects=(:individual_newborn,)))
    run_call!(target;environment=model.trials[status.visits],publish=true)
    model.capture[]=target
    status.seen=target.status.seen
    return nothing
end
function individual_env_newborn_scene(::Type{S}) where {S}
    capture=Ref{Any}()
    backend=IndividualEnvBackend()
    trials=(IndividualEnvTrialA(61.0,62.0),IndividualEnvTrialB((81.0f0,82.0f0)))
    # Keep an existing leaf so this API probe starts with both environment
    # binding schemas compiled. Initially empty spatial applications have a
    # separate pre-existing binding-cache widening failure, not an override
    # execution failure; the unseeded case is retained in local diagnostics.
    model=CompositeModel(Object(:individual_owner;scale=:Scene),
        Object(:individual_existing;scale=:Leaf,parent=:individual_owner,
            geometry=(cell=:cell_b,));
        applications=(
            ModelSpec(IndividualEnvNewbornOwner(trials,capture);name=:individual_owner,
                on=One(id=:individual_owner),
                calls=(newborn=Many(scale=:Leaf,within=Subtree(),application=:individual_leaf),)),
            ModelSpec(IndividualEnvLeaf();name=:individual_leaf,on=Many(scale=:Leaf),
                environment=Environment(provider=:individual_probe,sink=:individual_probe,
                    sources=(Tl=:source_temperature,))),
        ),environment=backend,type_promotion=Dict(Float64=>S))
    return (;model,backend,capture)
end
@testset "targeted newborn individual calls receive backend trial states" begin
    for S in (Float32,Float64)
        scene=individual_env_newborn_scene(S)
        simulation=run!(scene.model;steps=1,outputs=:all)
        @test current_step(simulation)==1
        @test scene.capture[].object_id==ObjectId(:individual_newborn)
        @test model_status(scene.model,:individual_newborn).seen === S(62)
        step!(simulation)
        @test model_status(scene.model,:individual_newborn).seen === S(82)
        @test model_status(scene.model,:individual_newborn).calls==2
        @test model_status(scene.model,:individual_existing).calls==0
        @test isempty(individual_env_rows(simulation,:individual_existing))
        rows=individual_env_rows(simulation,:individual_newborn)
        @test getproperty.(rows,:timestep)==[1,2]
        @test getproperty.(rows,:value)==S[62,82]
        @test scene.backend.writes==[
            (application=:individual_leaf,cell=:cell_b,value=62.0,time=1.0),
            (application=:individual_leaf,cell=:cell_b,value=82.0,time=2.0),
        ]
    end
end

struct IndividualEnvScriptOwner <: AbstractIndividual_Env_Owner_ProbeModel
    trials::Tuple{IndividualEnvTrialA{Float64},IndividualEnvTrialB{Float32}}
end
PlantSimEngine.inputs_(::IndividualEnvScriptOwner)=NamedTuple()
PlantSimEngine.outputs_(::IndividualEnvScriptOwner)=(visits=0,seen=0.0,leaf_seen=0.0)
PlantSimEngine.environment_inputs_(::IndividualEnvScriptOwner)=NamedTuple()
function PlantSimEngine.run!(model::IndividualEnvScriptOwner,status,environment,constants,context)
    status.visits+=1
    target=only(call_targets(context,:middle))
    run_call!(target;environment=model.trials[status.visits],publish=true)
    status.seen=target.status.seen
    status.leaf_seen=target.status.leaf_seen
    return nothing
end
function individual_env_script_scene(::Type{S};individual=false) where {S}
    backend=IndividualEnvBackend()
    middle=IndividualEnvMiddle(individual,Ref{Any}(),Ref{Any}(nothing))
    trials=(IndividualEnvTrialA(30.0,40.0),IndividualEnvTrialB((50.0f0,60.0f0)))
    model=CompositeModel(
        Object(:individual_owner;scale=:Scene,geometry=(cell=:cell_a,)),
        Object(:individual_middle;scale=:Plant,parent=:individual_owner,geometry=(cell=:cell_a,)),
        Object(:individual_leaf;scale=:Leaf,parent=:individual_middle,geometry=(cell=:cell_b,));
        applications=(
            ModelSpec(IndividualEnvScriptOwner(trials);name=:individual_owner,on=One(id=:individual_owner),
                calls=(middle=One(id=:individual_middle,application=:individual_middle),)),
            ModelSpec(middle;name=:individual_middle,on=One(id=:individual_middle),
                calls=(leaf=One(id=:individual_leaf,within=Subtree(),application=:individual_leaf),),
                environment=Environment(provider=:individual_probe,sources=(Tm=:source_temperature,))),
            ModelSpec(IndividualEnvLeaf();name=:individual_leaf,on=Many(scale=:Leaf),
                environment=Environment(provider=:individual_probe,sink=:individual_probe,
                    sources=(Tl=:source_temperature,))),
        ),environment=backend,type_promotion=Dict(Float64=>S))
    return (;model,backend)
end
@testset "readable source executes individual backend overrides through descendants" begin
    for S in (Float32,Float64),individual in (false,true)
        source_scene=individual_env_script_scene(S;individual)
        source=PlantSimEngine.Authoring.compiled_model_source(source_scene.model;
            function_name=:individual_environment_source!)
        @test occursin("PlantSimEngine._compiled_source_run_call!",source)
        path=tempname()*".jl"
        PlantSimEngine.Authoring.write_compiled_model_source(path,source_scene.model;
            function_name=:individual_environment_source!)
        generated_module=Module(gensym(:IndividualEnvironmentSource))
        Base.include(generated_module,path)
        generated_run=Core.eval(generated_module,:individual_environment_source!)
        generated_scene=individual_env_script_scene(S;individual)
        normal_scene=individual_env_script_scene(S;individual)
        generated=Base.invokelatest(generated_run,generated_scene.model;steps=2,outputs=:all)
        normal=run!(normal_scene.model;steps=2,outputs=:all)
        @test current_step(generated)==current_step(normal)==2
        @test isequal(final_state(generated,Many()),final_state(normal,Many()))
        @test isequal(collect_outputs(generated;sink=nothing),collect_outputs(normal;sink=nothing))
        @test generated_scene.backend.writes==normal_scene.backend.writes==[
            (application=:individual_leaf,cell=:cell_b,value=40.0,time=1.0),
            (application=:individual_leaf,cell=:cell_b,value=60.0,time=2.0),
        ]
    end
end

# Coverage is behavioral, not a performance/whole-suite/scientific verdict.
# No rollback is promised after a throwing numerical kernel. The dual-override
# error, by contrast, must occur before any observed mutation or sampling.
