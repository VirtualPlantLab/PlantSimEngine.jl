# Stable-call kernels may throw. This gate checks the original cache lease and
# publication behavior after a failing invocation, including a second call in
# the same root invocation. Include after checks.jl; root executes via Kaimon.

PSE.@process "region_call_exception_worker" verbose=false
PSE.@process "region_call_exception_controller" verbose=false
struct CallExceptionWorker <: AbstractRegion_Call_Exception_WorkerModel end
struct CallExceptionController <: AbstractRegion_Call_Exception_ControllerModel
    publish::Bool
end
PSE.inputs_(::CallExceptionWorker) = NamedTuple()
PSE.outputs_(::CallExceptionWorker) = (value=0.0, visits=0)
PSE.inputs_(::CallExceptionController) = NamedTuple()
PSE.outputs_(::CallExceptionController) = (caught=false, observed=0.0)

function PSE.run!(::CallExceptionWorker, status, environment, constants, context)
    status.visits += 1
    status.value += 1.0
    status.visits == 1 && throw(ErrorException("expected call-cleanup probe"))
    return nothing
end

function PSE.run!(model::CallExceptionController, status, environment, constants,
    context)
    try
        PSE.run_call!(context, :worker; sampled_environment=environment,
            publish=model.publish)
    catch error
        error isa ErrorException && error.msg == "expected call-cleanup probe" || rethrow()
        status.caught = true
    end
    targets = PSE.run_call!(context, :worker; sampled_environment=environment,
        publish=model.publish)
    status.observed = only(targets).status.value
    return nothing
end
resolved_call_effects(::Type{CallExceptionWorker}) = :stable_calls
resolved_call_effects(::Type{CallExceptionController}) = :stable_calls

function call_exception_fixture(; publish=true)
    return PSE.CompositeModel(PSE.Object(:owner);
        applications=(
            PSE.ModelSpec(CallExceptionController(publish); name=:controller,
                on=PSE.One(id=:owner), every=Hour(1), calls=(
                    worker=PSE.One(within=PSE.Self(), application=:worker),)),
            PSE.ModelSpec(CallExceptionWorker(); name=:worker,
                on=PSE.One(id=:owner), every=Hour(1)),
        ), environment=(duration=Hour(1),))
end

function _call_exception_leases_released(context, seen=IdDict{Any,Nothing}())
    haskey(seen, context) && return true
    seen[context] = nothing
    context.calls isa Union{ResolvedCallTable,EpochCallTable} || return true
    for entry in values(context.calls.entries)
        entry isa ResolvedCallEntry{true} || continue
        for batch in entry.plans, target in batch.targets
            target.owner.call_context_cache.in_use && return false
            _call_exception_leases_released(target.context, seen) || return false
        end
    end
    return true
end

function run_call_exception_checks(; strategies=(:guarded, :epoch), regions_cases=(false,))
    reports = NamedTuple[]
    @testset "resolved-call failure cleanup and publication" begin
        for strategy in strategies, publish in (false, true), regions in regions_cases
            reference = PSE.run!(call_exception_fixture(; publish);
                steps=1, outputs=:all)
            simulation = PSE.run!(call_exception_fixture(; publish);
                steps=0, outputs=:all)
            program = compile_regions(simulation; regions,
                resolved_calls=true, compact=regions, call_strategy=strategy)
            advance_regions!(program; steps=1)
            @test isequal(downstream_fingerprint(simulation),
                downstream_fingerprint(reference))
            state = PSE.final_state(simulation, :owner)
            @test state.caught
            @test state.observed == state.value == 2.0
            @test state.visits == 2
            report = region_report(program)
            @test fast_call_count(report) == 2
            @test call_report_metric(report, :reentrant_fallbacks) == 0
            @test call_report_metric(report, :fallback_calls) == 0
            for node in program.plan.nodes, batch in node.batches
                batch isa RegionResolvedBatch || continue
                @test all(row -> _call_exception_leases_released(row.context),
                    batch.payload.rows)
            end
            # A later public continuation must use the same released caches.
            PSE.continue!(reference; steps=1)
            PSE.continue!(simulation; steps=1)
            @test isequal(downstream_fingerprint(simulation),
                downstream_fingerprint(reference))
            @test PSE.final_state(simulation, :owner).visits == 4
            push!(reports, (; strategy, publish, regions, report))
        end
    end
    return (; cases=length(reports), reports)
end
