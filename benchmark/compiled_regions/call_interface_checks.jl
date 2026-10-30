# Current-engine composition gate. The frozen original engine has no narrow
# execution-policy helper and intentionally does not run this experiment.

PSE.@process "region_call_interface_worker" verbose=false
PSE.@process "region_call_interface_controller" verbose=false
struct CallInterfaceWorker <: AbstractRegion_Call_Interface_WorkerModel
    factor::Float64
end
struct CallInterfaceController <: AbstractRegion_Call_Interface_ControllerModel end
PSE.inputs_(::CallInterfaceWorker) = (worker_input=PSE.Default(2.0),)
PSE.outputs_(::CallInterfaceWorker) = (worker_value=0.0, worker_fields=0)
PSE.outputs_(::CallInterfaceController) = (controller_value=0.0, controller_fields=0)
PSE.inputs_(::CallInterfaceController) = NamedTuple()

_call_interface_context_check(::PSE.RunContext) = true
function PSE.run!(model::CallInterfaceWorker, status, environment, constants, context)
    _call_interface_context_check(context) || error("RunContext dispatch lost")
    status.worker_value = status.worker_input * model.factor
    status.worker_fields = length(keys(getfield(status, :vars)))
    return nothing
end
function PSE.run!(::CallInterfaceController, status, environment, constants, context)
    _call_interface_context_check(context) || error("RunContext dispatch lost")
    worker = PSE.call_model(context, :worker)
    targets = PSE.run_call!(context, :worker; sampled_environment=environment, publish=true)
    status.controller_value = worker.factor + only(targets).status.worker_value
    status.controller_fields = length(keys(getfield(status, :vars)))
    return nothing
end
resolved_call_effects(::Type{CallInterfaceWorker}) = :stable_calls
resolved_call_effects(::Type{CallInterfaceController}) = :stable_calls

function call_interface_fixture()
    return PSE.CompositeModel(PSE.Object(:unit; status=PSE.Status(spare=13.0));
        applications=(
            PSE.ModelSpec(CallInterfaceController(); name=:controller,
                on=PSE.One(id=:unit), every=Hour(1), calls=(
                    worker=PSE.One(within=PSE.Self(), application=:worker),)),
            PSE.ModelSpec(CallInterfaceWorker(3.0); name=:worker,
                on=PSE.One(id=:unit), every=Hour(1)),
        ), environment=(duration=Hour(1),))
end

function _call_interface_contexts(context, seen=IdDict{Any,Nothing}())
    haskey(seen, context) && return ()
    seen[context] = nothing
    contexts = Any[context]
    for entry in values(context.calls.entries)
        entry isa ResolvedCallEntry{true} || continue
        for batch in entry.plans, target in batch.targets
            target.context.calls isa Union{ResolvedCallTable,EpochCallTable} || continue
            append!(contexts, _call_interface_contexts(target.context, seen))
        end
    end
    return contexts
end

function run_call_interface_checks(; strategies=(:guarded, :epoch), regions_cases=(false,))
    isdefined(PSE, :_with_execution_policy) || return (; skipped=:original_engine)
    reports = NamedTuple[]
    @testset "resolved-call source-interface composition" begin
        for narrow_status in (false, true), local_context in (false, true),
            strategy in strategies, regions in regions_cases
            build = () -> PSE._with_execution_policy(;
                narrow_status, local_context, shared_plans=false) do
                PSE.run!(call_interface_fixture(); steps=0, outputs=:all)
            end
            reference = build()
            simulation = build()
            program = compile_regions(simulation; regions,
                resolved_calls=true, compact=regions, call_strategy=strategy)
            advance_regions!(program; steps=2)
            PSE.continue!(reference; steps=2)
            @test isequal(downstream_fingerprint(simulation),
                downstream_fingerprint(reference))
            report = region_report(program)
            @test fast_call_count(report) > 0
            state = PSE.final_state(simulation, :unit)
            @test state.controller_value == 9.0
            if narrow_status
                @test state.controller_fields == 2
                @test state.worker_fields == 3
            else
                @test state.controller_fields > 3
                @test state.worker_fields == state.controller_fields
            end
            # The region wrapper is introspected cold, never from scientific
            # model code or an implicit type-parameter dispatch promise.
            contexts = Any[]
            for node in program.plan.nodes, batch in node.batches
                batch isa RegionResolvedBatch || continue
                for row in batch.payload.rows
                    append!(contexts, _call_interface_contexts(row.context))
                end
            end
            @test !isempty(contexts)
            @test all(ctx -> (fieldtype(typeof(ctx), :compiled) === Any) == local_context,
                contexts)
            @test all(ctx -> (fieldtype(typeof(ctx), :application) === Any) == local_context,
                contexts)
            @test all(ctx -> (fieldtype(typeof(ctx), :temporal_streams) === Any) == local_context,
                contexts)
            @test !_resolved_context_current(first(contexts).calls,
                (; compiled=nothing))
            push!(reports, (; narrow_status, local_context, strategy, regions, report))
        end
    end
    return (; cases=length(reports), reports)
end
