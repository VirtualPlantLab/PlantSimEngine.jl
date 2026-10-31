# Optional untimed coverage diagnostics. A caller owns the log; no global table
# retains programs, numerical batches, statuses or their contexts. The ordinary
# numerical function remains unchanged and untraced performance is unaffected.

mutable struct RegionCoverageLog
    batch_executions::Dict{Symbol,Int}
    row_executions::Dict{Symbol,Int}
end
RegionCoverageLog() = RegionCoverageLog(Dict{Symbol,Int}(), Dict{Symbol,Int}())

struct RegionTraceCounters{C}
    base::C
    log::RegionCoverageLog
    application::Symbol
end

function Base.getproperty(counters::RegionTraceCounters, name::Symbol)
    name in (:base, :log, :application) && return getfield(counters, name)
    return getproperty(getfield(counters, :base), name)
end

function Base.setproperty!(counters::RegionTraceCounters, name::Symbol, value)
    base = getfield(counters, :base)
    previous = getproperty(base, name)
    setproperty!(base, name, value)
    if name === :column_batches || name === :column_rows
        log = getfield(counters, :log)
        counts = name === :column_batches ? log.batch_executions : log.row_executions
        application = getfield(counters, :application)
        counts[application] = get(counts, application, 0) + value - previous
    end
    return value
end

_region_trace_base(counters) = counters
_region_trace_base(counters::RegionTraceCounters) = _region_trace_base(counters.base)

function _region_traced_batch(batch::RegionColumnBatch, log::RegionCoverageLog)
    counters = batch.counters
    counters isa RegionTraceCounters && counters.log === log && return batch
    traced = RegionTraceCounters(_region_trace_base(counters), log, batch.application.id)
    return RegionColumnBatch(batch.application, batch.targets, batch.environment_provider,
        batch.output_publication, batch.kernel, batch.state, traced)
end

"""
    enable_region_trace!(program, log)

Install optional per-application actual-execution counters in every owner of
the current numerical batches. Call before each one-step advance when lifecycle
events can rebuild the plan. The log retains only Symbols and integer counts;
it never retains an old batch or compiled context. This diagnostic changes hot
counter dispatch and must not be used for performance comparisons.
"""
function enable_region_trace!(program::CompiledRegionProgram, log::RegionCoverageLog)
    plan = _ensure_regions!(program)
    replacements = IdDict{Any,Any}()
    nodes = map(plan.nodes) do node
        batches = map(node.batches) do batch
            batch isa RegionColumnBatch || return batch
            replacement = _region_traced_batch(batch, log)
            # Object-ID vectors are mutable, stable identities. IdDict keys
            # must not rely on temporary boxes around immutable batch records.
            replacements[batch.targets.object_ids] = replacement
            replacement
        end
        RegionApplication(node.entry, node.application_slot, batches)
    end
    program.plan = RegionPlan(nodes, plan.schedule, plan.runtime_revision,
        plan.environment_revision, plan.report)

    simulation = program.simulation
    previous = simulation.execution_plan
    groups = PSE.CompiledApplicationExecutionGroup[]
    flat_batches = PSE.AbstractExecutionBatch[]
    for group in previous.groups
        updated = PSE.AbstractExecutionBatch[]
        changed = false
        for batch in group.batches
            replacement = batch isa RegionColumnBatch ?
                get(replacements, batch.targets.object_ids, batch) : batch
            push!(updated, replacement)
            changed |= replacement !== batch
        end
        # Rebind group, flat batch vector and slot-owner vector together. No
        # owner retains a superseded traced/untraced numerical batch.
        owner = changed ? PSE.CompiledApplicationExecutionGroup(group.application,
            RegionBatchCollection(updated)) : group
        push!(groups, owner)
        append!(flat_batches, owner.batches)
    end
    simulation.execution_plan = _region_execution_plan_record(previous, groups, flat_batches,
        PSE._execution_groups_by_application_slot(groups,
            length(simulation.compiled.scenario_plan.applications)),
        previous.schedule, previous.model_revision, previous.environment_revision)
    return log
end

function advance_traced_regions!(program::CompiledRegionProgram, log::RegionCoverageLog;
    steps::Integer=1)
    steps >= 0 || throw(ArgumentError("steps must be non-negative"))
    for _ in 1:steps
        enable_region_trace!(program, log)
        advance_regions!(program; steps=1)
    end
    return program.simulation
end

function region_coverage_report(log::RegionCoverageLog)
    applications = sort!(collect(union(keys(log.batch_executions), keys(log.row_executions))))
    return (actual_column_applications=length(applications),
        column_batch_executions=sum(values(log.batch_executions); init=0),
        column_row_executions=sum(values(log.row_executions); init=0),
        applications=Tuple((application=application,
            batch_executions=get(log.batch_executions, application, 0),
            row_executions=get(log.row_executions, application, 0))
            for application in applications))
end

function region_trace_checks()
    @testset "Optional actual region coverage survives plan rebuilding" begin
        reference = PSE.run!(GP.growth_fixture(); steps=3, outputs=:all)
        simulation = PSE.run!(GP.growth_fixture(); steps=0, outputs=:all)
        program = compile_regions(simulation; resolved_calls=false)
        log = RegionCoverageLog()
        advance_traced_regions!(program, log; steps=3)
        @test isequal(GP.fingerprint(simulation), GP.fingerprint(reference))
        report = region_coverage_report(log)
        @test report.column_batch_executions > 0
        @test report.column_batch_executions == program.counters.column_batches
        @test report.column_row_executions == program.counters.column_rows
        @test all(row -> row.batch_executions > 0 && row.row_executions > 0,
            report.applications)
        # Re-enabling uses the same log without resetting counts or retaining
        # an old plan; ordinary continuation shares the newly installed owners.
        enable_region_trace!(program, log)
        PSE.continue!(reference; steps=1)
        PSE.continue!(simulation; steps=1)
        @test isequal(GP.fingerprint(simulation), GP.fingerprint(reference))
        final = region_coverage_report(log)
        @test final.column_batch_executions == program.counters.column_batches
        @test final.column_row_executions == program.counters.column_rows
        return (; passed=true, final)
    end
end
