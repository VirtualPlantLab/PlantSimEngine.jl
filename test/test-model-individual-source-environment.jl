using Dates
using Test
using PlantSimEngine

PlantSimEngine.@process "individual_source_environment_leaf" verbose=false
struct SourceEnvironmentLeaf{T} <: AbstractIndividual_Source_Environment_LeafModel end
PlantSimEngine.inputs_(::SourceEnvironmentLeaf) = NamedTuple()
PlantSimEngine.outputs_(::SourceEnvironmentLeaf{T}) where {T} =
    (source_leaf_seen=zero(T),source_leaf_permission=false,source_leaf_calls=0)
PlantSimEngine.environment_inputs_(::SourceEnvironmentLeaf{T}) where {T} = (T=zero(T),)
PlantSimEngine.environment_outputs_(::SourceEnvironmentLeaf) = NamedTuple()
function PlantSimEngine.run!(::SourceEnvironmentLeaf,status,environment,constants,context)
    status.source_leaf_seen = environment.T
    status.source_leaf_permission = context.publication_allowed
    status.source_leaf_calls += 1
    return nothing
end

PlantSimEngine.@process "individual_source_environment_middle" verbose=false
struct SourceEnvironmentMiddle{T} <: AbstractIndividual_Source_Environment_MiddleModel end
PlantSimEngine.inputs_(::SourceEnvironmentMiddle) = NamedTuple()
PlantSimEngine.outputs_(::SourceEnvironmentMiddle{T}) where {T} =
    (source_middle_seen=zero(T),source_middle_leaf_seen=zero(T),
     source_middle_permission=false,source_middle_leaf_permission=false,source_middle_calls=0)
PlantSimEngine.environment_inputs_(::SourceEnvironmentMiddle{T}) where {T} = (T=zero(T),)
PlantSimEngine.environment_outputs_(::SourceEnvironmentMiddle) = NamedTuple()
function PlantSimEngine.run!(::SourceEnvironmentMiddle,status,environment,constants,context)
    leaf = only(call_targets(context,:leaf))
    run_call!(leaf;publish=true)
    status.source_middle_seen = environment.T
    status.source_middle_leaf_seen = leaf.status.source_leaf_seen
    status.source_middle_permission = context.publication_allowed
    status.source_middle_leaf_permission = leaf.status.source_leaf_permission
    status.source_middle_calls += 1
    return nothing
end

PlantSimEngine.@process "individual_source_environment_owner" verbose=false
struct SourceEnvironmentOwner{T,R} <: AbstractIndividual_Source_Environment_OwnerModel
    trial_temperature::T
    old_override_temperature::T
    # Probe instrumentation only, not physical model state.
    first_target::R
end
PlantSimEngine.inputs_(::SourceEnvironmentOwner) = NamedTuple()
PlantSimEngine.outputs_(::SourceEnvironmentOwner{T}) where {T} =
    (source_visits=0,source_trial_middle=zero(T),source_trial_leaf=zero(T),
     source_trial_permission=true,source_trial_leaf_permission=true,
     source_default_middle=zero(T),source_default_leaf=zero(T),
     source_rejected_dual=false,source_rejected_unchanged=false,
     source_target_default_unchanged=false,source_old_override_middle=zero(T),
     source_old_override_leaf=zero(T),source_old_default_middle=zero(T),
     source_old_default_leaf=zero(T),source_old_time_preserved=false)
PlantSimEngine.environment_inputs_(::SourceEnvironmentOwner) = NamedTuple()
PlantSimEngine.environment_outputs_(::SourceEnvironmentOwner) = NamedTuple()
function PlantSimEngine.run!(model::SourceEnvironmentOwner,status,environment,constants,context)
    status.source_visits += 1
    target = only(call_targets(context,:middle))
    original_environment = target.environment
    original_time = target.time
    previous_calls = target.status.source_middle_calls
    status.source_rejected_dual = false
    try
        run_call!(target;
            environment=(T=model.trial_temperature,duration=Hour(1)),
            sampled_environment=(T=model.old_override_temperature,),publish=true)
    catch error
        status.source_rejected_dual = error isa ArgumentError
    end
    status.source_rejected_unchanged = target.status.source_middle_calls == previous_calls

    run_call!(target;environment=(T=model.trial_temperature,duration=Hour(1)),publish=false)
    status.source_trial_middle = target.status.source_middle_seen
    status.source_trial_leaf = target.status.source_middle_leaf_seen
    status.source_trial_permission = target.status.source_middle_permission
    status.source_trial_leaf_permission = target.status.source_middle_leaf_permission
    status.source_target_default_unchanged =
        target.environment === original_environment && target.time === original_time

    if status.source_visits == 1
        model.first_target[] = target
    else
        retained = model.first_target[]
        retained_environment = retained.environment
        retained_time = retained.time
        run_call!(retained;
            environment=(T=model.old_override_temperature,duration=Hour(1)),publish=false)
        status.source_old_override_middle = retained.status.source_middle_seen
        status.source_old_override_leaf = retained.status.source_middle_leaf_seen
        run_call!(retained;publish=false)
        status.source_old_default_middle = retained.status.source_middle_seen
        status.source_old_default_leaf = retained.status.source_middle_leaf_seen
        status.source_old_time_preserved =
            retained.environment === retained_environment && retained.time === retained_time &&
            retained.time != target.time
    end

    run_call!(target;publish=true)
    status.source_default_middle = target.status.source_middle_seen
    status.source_default_leaf = target.status.source_middle_leaf_seen
    return nothing
end

function source_environment_scene(::Type{S}) where {S}
    capture = Ref{Any}(nothing)
    model = CompositeModel(Object(:scene;scale=:Scene);
        applications=(
            ModelSpec(SourceEnvironmentOwner(S(7),S(44),capture);name=:owner,on=One(id=:scene),
                calls=(middle=One(id=:scene,application=:middle),)),
            ModelSpec(SourceEnvironmentMiddle{S}();name=:middle,on=One(id=:scene),
                calls=(leaf=One(id=:scene,application=:leaf),)),
            ModelSpec(SourceEnvironmentLeaf{S}();name=:leaf,on=One(id=:scene)),
        ),
        environment=[(date=DateTime(2026,1,1)+Hour(i-1),duration=Hour(1),T=S(10+10i)) for i in 1:2],
        type_promotion=Dict(Float64=>S))
    return (;model,capture)
end

@testset "Generated individual backend overrides preserve descendants and snapshots" begin
    for S in (Float32,Float64)
        generated_case = source_environment_scene(S)
        normal_case = source_environment_scene(S)
        source = PlantSimEngine.Authoring.compiled_model_source(generated_case.model;
            function_name=:individual_environment_source!)
        @test occursin("PlantSimEngine._compiled_source_run_call!",source)
        @test occursin("environment =",source)
        path = tempname()*".jl"
        write(path,source)
        generated_module = Module(gensym(:IndividualEnvironmentSource))
        Base.include(generated_module,path)
        generated_run = Core.eval(generated_module,:individual_environment_source!)
        generated = Base.invokelatest(generated_run,generated_case.model;steps=1,outputs=:all)
        normal = PlantSimEngine.run!(normal_case.model;steps=1,outputs=:all)
        for sim in (generated,normal)
            state=final_state(sim,:scene)
            @test state.source_visits == 1
            @test state.source_trial_middle === S(7)
            @test state.source_trial_leaf === S(7)
            @test !state.source_trial_permission
            @test !state.source_trial_leaf_permission
            @test state.source_default_middle === S(20)
            @test state.source_default_leaf === S(20)
            @test state.source_rejected_dual
            @test state.source_rejected_unchanged
            @test state.source_target_default_unchanged
            @test only(collect_outputs(sim,:scene,:source_leaf_seen;sink=nothing)).value === S(20)
        end
        @test isequal(PlantSimEngine.final_state(generated,Many()),PlantSimEngine.final_state(normal,Many()))
        @test isequal(collect_outputs(generated;sink=nothing),collect_outputs(normal;sink=nothing))

        Base.invokelatest(generated_run,generated;steps=1)
        PlantSimEngine.continue!(normal;steps=1)
        for sim in (generated,normal)
            state=final_state(sim,:scene)
            @test state.source_visits == 2
            @test state.source_old_override_middle === S(44)
            @test state.source_old_override_leaf === S(44)
            @test state.source_old_default_middle === S(20)
            @test state.source_old_default_leaf === S(20)
            @test state.source_old_time_preserved
            @test state.source_default_middle === S(30)
            @test state.source_default_leaf === S(30)
            @test state.source_rejected_dual
            @test state.source_rejected_unchanged
            rows=sort!(collect_outputs(sim,:scene,:source_leaf_seen;sink=nothing);by=row->row.timestep)
            @test getproperty.(rows,:timestep) == [1,2]
            @test getproperty.(rows,:value) == S[20,30]
        end
        @test isequal(PlantSimEngine.final_state(generated,Many()),PlantSimEngine.final_state(normal,Many()))
        @test isequal(collect_outputs(generated;sink=nothing),collect_outputs(normal;sink=nothing))
    end
end
