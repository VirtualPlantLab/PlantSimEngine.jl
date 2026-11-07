module NestedSelectionEvaluationAliasChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine
PSE.@process "selection_alias_child" verbose=false
PSE.@process "selection_alias_middle" verbose=false
PSE.@process "selection_alias_creator" verbose=false

struct Child <: AbstractSelection_Alias_ChildModel end
PSE.inputs_(::Child) = NamedTuple()
PSE.outputs_(::Child) = (calls=0, value=0.0)
function PSE.run!(::Child, status, environment, constants, context)
    status.calls += 1
    status.value = Float64(status.calls)
    return nothing
end

struct Middle <: AbstractSelection_Alias_MiddleModel
    call_child::Bool
end
PSE.inputs_(::Middle) = NamedTuple()
PSE.outputs_(::Middle) = (calls=0, value=0.0)
function PSE.run!(model::Middle, status, environment, constants, context)
    status.calls += 1
    status.value = Float64(status.calls)
    # Declared calls are parent-controlled and may be conditional. Both cases
    # use the same declared graph and the same real newborn registration path.
    model.call_child && run_call!(context, :child; publish=true)
    return nothing
end

struct Creator{C} <: AbstractSelection_Alias_CreatorModel
    capture::C
end
PSE.inputs_(::Creator) = NamedTuple()
PSE.outputs_(::Creator) = (created=false,)
function PSE.run!(model::Creator, status, environment, constants, context)
    status.created && return nothing
    runtime = runtime_model(context)
    middle = register_object!(runtime, Object(:middle; scale=:Middle, parent=:owner,
        status=Status(calls=0, value=0.0)))
    register_object!(runtime, Object(:child; scale=:Leaf, parent=:middle,
        status=Status(calls=0, value=0.0)))
    first = only(call_targets(context, :middle; objects=middle))
    second = only(call_targets(context, :middle; objects=middle))
    shared_status = first.status === second.status === model_status(runtime, :middle)
    shared_parent_cache = first.context_cache === second.context_cache
    evaluation = evaluate_call!(first)
    stamp_count = length(evaluation.frame.executions)
    first_revision = first.context_cache.execution_stamp[]
    run_call!(second; publish=false)
    first_stamp_changed = first.context_cache.execution_stamp[] != first_revision
    model_guard_valid = try
        PSE._validate_call_model_state(evaluation.frame, evaluation.frame.compiled)
        true
    catch
        false
    end
    stale_rejected, rejection = false, ""
    try
        accept_call!(evaluation)
    catch error
        rejection = error isa ArgumentError ? sprint(showerror, error) : string(typeof(error))
        stale_rejected = error isa ArgumentError && occursin("stale", rejection)
    end
    model.capture[] = (; shared_status, shared_parent_cache, stamp_count,
        first_stamp_changed, model_guard_valid, stale_rejected, rejection)
    status.created = true
    return nothing
end

function run_alias_case(call_child::Bool)
    capture = Ref{Any}()
    model = CompositeModel(Object(:owner; scale=:Scene);
        applications=(
            ModelSpec(Creator(capture); name=:creator, on=One(id=:owner),
                calls=(middle=Many(Subtree(); scale=:Middle, application=:middle),)),
            ModelSpec(Middle(call_child); name=:middle, on=Many(scale=:Middle),
                calls=(child=One(Subtree(); scale=:Leaf, application=:child),)),
            ModelSpec(Child(); name=:child, on=Many(scale=:Leaf)),
        ))
    simulation = run!(model; steps=1, outputs=:all)
    return (; data=capture[], middle_calls=model_status(model, :middle).calls,
        middle_value=model_status(model, :middle).value,
        child_calls=model_status(model, :child).calls,
        middle_history=get(outputs(simulation), (:middle, ObjectId(:middle), :calls), []),
        child_history=get(outputs(simulation), (:child, ObjectId(:child), :calls), []))
end

@testset "rerunning another selection of the same canonical status invalidates its evaluation" begin
    for call_child in (true, false)
        result = run_alias_case(call_child)
        @info "selection evaluation alias diagnostic" call_child diagnostic=result.data
        @test result.data.shared_status
        @test result.data.model_guard_valid # no timeline/topology/model mutation between the two runs
        @test result.middle_calls == 2
        @test result.middle_value == 2.0
        @test result.child_calls == (call_child ? 2 : 0)
        @test result.data.stale_rejected
        @test isempty(result.middle_history)
        @test isempty(result.child_history)
    end
end

end

module StableCallExecutionIdentityChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine
PSE.@process "stable_execution_leaf" verbose=false
PSE.@process "stable_execution_controller" verbose=false
PSE.@process "stable_execution_creator" verbose=false

struct Leaf <: AbstractStable_Execution_LeafModel end
PSE.inputs_(::Leaf) = NamedTuple()
PSE.outputs_(::Leaf) = (calls=0,)
PSE.run!(::Leaf, status, environment, constants, context) = (status.calls += 1; nothing)

function evaluate_then_rerun(first, second)
    shared_status = first.status === second.status
    shared_view = first.execution_target.status_view === second.execution_target.status_view
    shared_cache = first.context_cache === second.context_cache
    evaluation = evaluate_call!(first)
    run_call!(second; publish=false)
    model_guard_valid = try
        PSE._validate_call_model_state(evaluation.frame, evaluation.frame.compiled)
        true
    catch
        false
    end
    rejected, message = false, ""
    try
        accept_call!(evaluation)
    catch error
        message = error isa ArgumentError ? sprint(showerror, error) : string(typeof(error))
        rejected = error isa ArgumentError && occursin("stale", message)
    end
    return (; shared_status, shared_view, shared_cache, model_guard_valid, rejected, message)
end

struct Controller{C} <: AbstractStable_Execution_ControllerModel
    capture::C
    use_other_binding::Bool
end
PSE.inputs_(::Controller) = NamedTuple()
PSE.outputs_(::Controller) = (done=false,)
function PSE.run!(model::Controller, status, environment, constants, context)
    first = only(call_targets(context, :a))
    second = only(call_targets(context, model.use_other_binding ? :b : :a))
    model.capture[] = evaluate_then_rerun(first, second)
    status.done = true
    return nothing
end

@testset "different bindings to one application/object share scientific execution identity" begin
    for use_other_binding in (false, true)
        capture = Ref{Any}()
        model = CompositeModel(Object(:owner; scale=:Scene),
            Object(:leaf; scale=:Leaf, parent=:owner, status=Status(calls=0));
            applications=(
                ModelSpec(Controller(capture, use_other_binding); name=:controller, on=One(id=:owner),
                    calls=(a=One(id=:leaf, application=:leaf), b=One(id=:leaf, application=:leaf))),
                ModelSpec(Leaf(); name=:leaf, on=Many(scale=:Leaf)),
            ))
        simulation = run!(model; outputs=:all)
        data = capture[]
        @info "two-binding evaluation identity diagnostic" use_other_binding diagnostic=data
        @test data.shared_status
        @test data.shared_view
        @test data.model_guard_valid
        @test data.rejected
        @test model_status(model, :leaf).calls == 2
        @test isempty(get(outputs(simulation), (:leaf, ObjectId(:leaf), :calls), []))
    end
end

struct Creator{C} <: AbstractStable_Execution_CreatorModel
    capture::C
    reparent_before_barrier::Bool
end
PSE.inputs_(::Creator) = NamedTuple()
PSE.outputs_(::Creator) = (created=false,)
function PSE.run!(model::Creator, status, environment, constants, context)
    status.created && return nothing
    object = register_object!(runtime_model(context),
        Object(:leaf; scale=:Leaf, parent=:owner, status=Status(calls=0)))
    first = only(call_targets(context, :leaf; objects=object))
    second = only(call_targets(context, :leaf; objects=object))
    before_barrier = evaluate_then_rerun(first, second)
    model.capture[] = (; before_barrier, context, retained=first)
    model.reparent_before_barrier && reparent_object!(runtime_model(context), :leaf, :axis)
    status.created = true
    return nothing
end

@testset "targeted prebarrier and retained views keep their logical execution stamp" begin
    for reparent_before_barrier in (false, true)
        capture = Ref{Any}()
        model = CompositeModel(Object(:owner; scale=:Scene),
            Object(:axis; scale=:Axis, parent=:owner);
            applications=(
                ModelSpec(Creator(capture, reparent_before_barrier); name=:creator, on=One(id=:owner),
                    calls=(leaf=Many(Subtree(); scale=:Leaf, application=:leaf),)),
                ModelSpec(Leaf(); name=:leaf, on=Many(scale=:Leaf)),
            ))
        simulation = run!(model; outputs=:all)
        data = capture[]
        @info "targeted prebarrier evaluation identity diagnostic" reparent_before_barrier diagnostic=data.before_barrier
        @test data.before_barrier.shared_status
        @test data.before_barrier.model_guard_valid
        @test data.before_barrier.rejected
        @test model_status(model, :leaf).calls == 2
        @test isempty(get(outputs(simulation), (:leaf, ObjectId(:leaf), :calls), []))

        # Materialize the canonical owner before starting a candidate. No
        # binding observation/change may accidentally provide the stale guard.
        current = only(call_targets(data.context, :leaf))
        after_barrier = evaluate_then_rerun(data.retained, current)
        @info "retained postbarrier evaluation identity diagnostic" reparent_before_barrier diagnostic=after_barrier
        @test after_barrier.shared_status
        @test after_barrier.model_guard_valid
        @test after_barrier.rejected
        @test model_status(model, :leaf).calls == 4
        @test isempty(get(outputs(simulation), (:leaf, ObjectId(:leaf), :calls), []))

        # A full metadata refresh also keeps the logical stamp, including when
        # the token is evaluated through a retained pre-refresh view afterward.
        PSE.Advanced.refresh_bindings!(model; force=true)
        refreshed = only(call_targets(data.context, :leaf))
        after_force = evaluate_then_rerun(data.retained, refreshed)
        @info "retained full-refresh evaluation identity diagnostic" reparent_before_barrier diagnostic=after_force
        @test after_force.shared_status
        @test after_force.model_guard_valid
        @test after_force.rejected
        @test model_status(model, :leaf).calls == 6
        @test isempty(get(outputs(simulation), (:leaf, ObjectId(:leaf), :calls), []))
    end
end

function record_without_evaluation!(cache, count)
    for _ in 1:count
        PSE._record_call_execution!(cache, nothing)
    end
    return nothing
end

@testset "ordinary execution stamp updates allocate no per-call bookkeeping" begin
    stamp = Ref(UInt64(0))
    cache = PSE.CallContextCache(nothing, stamp)
    record_without_evaluation!(cache, 1000)
    @test (@allocated record_without_evaluation!(cache, 1000)) == 0
    @test stamp[] == UInt64(2000)
end

end
