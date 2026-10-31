# A separate experiment over the generic generated driver: specialize away the
# root scheduler for proven local scenes whose compiled entries are always due.
# This file neither changes the ordinary executor nor weakens model effects.

mutable struct RegularGeneratedProgram{B}
    base::B
    selected::Bool
    reason::Symbol
    regular_steps::Int
    fallback_steps::Int
end

_regular_underlying(program::GeneratedProgram) = program
_regular_underlying(program::LocalGeneratedProgram) = program.base

program_simulation(program::RegularGeneratedProgram) = program_simulation(program.base)

function _regular_reason(plan)
    plan.fixed_local || return :requires_total_local_scene
    isempty(plan.schedule.periodic_entry_indices) || return :periodic_clock_requires_general_scheduler
    isempty(plan.schedule.generic_entry_indices) || return :generic_clock_requires_general_scheduler
    all(entry -> entry.kind === :always, plan.schedule.entries) || return :nonalways_schedule
    return :eligible
end

"""
    compile_regular_program(simulation; strategy=:typed, packed=false,
                            scalar=false, block_size=4)

Compile an always-due local program whose generated time loop has no per-step
schedule heap, due-vector construction, sorting, membership scan, or cadence
test. Runtime clock progression is restored at each advance boundary so the
same Simulation can subsequently use ordinary continue!/step!.

Other scenes retain the corresponding ordinary generated strategy. The same
explicit total/nonthrowing, nonescaping, status-disjoint effect promise applies.
"""
function compile_regular_program(simulation; strategy::Symbol=:typed,
    packed::Bool=false, scalar::Bool=false, block_size::Int=4)
    base = scalar ? compile_local_program(simulation; strategy, packed, block_size) :
        compile_program(simulation; strategy, packed, block_size)
    reason = _regular_reason(_regular_underlying(base).plan)
    return RegularGeneratedProgram(base, reason === :eligible, reason, 0, 0)
end

function strategy_report(program::RegularGeneratedProgram)
    return merge(strategy_report(program.base), (
        regular_requested=true,
        regular_selected=program.selected,
        regular_reason=program.reason,
        regular_steps=program.regular_steps,
        regular_fallback_steps=program.fallback_steps,
        regular_schedule=:compiled_always_due,
    ))
end

function _regular_refresh!(program::GeneratedProgram)
    return _program_ensure_plan!(program)
end

function _regular_refresh!(program::LocalGeneratedProgram)
    base = program.base
    _program_ensure_plan!(base)
    if !hasproperty(base.plan.report, :scalar_requested)
        base.plan = _compile_local_program_plan(base)
    end
    return base.plan
end

# Kept separate from the normal scheduler. An always-only clock has no heap or
# periodic cursor to advance. Keeping last_step and the reusable due buffer in
# the same boundary state is sufficient for normal continue! to pick up later.
function _regular_restore_schedule!(simulation, plan)
    schedule = simulation.execution_plan.schedule
    schedule.last_step = simulation.current_step
    due = schedule.due_entry_indices
    indices = plan.schedule.always_entry_indices
    resize!(due, length(indices))
    for i in eachindex(indices)
        due[i] = indices[i]
    end
    return nothing
end

@generated function _program_advance_regular!(simulation,
    plan::P, steps, ::Val{Strategy},
) where {P<:ProgramPlan,Strategy}
    N = fieldtype(P, :nodes)
    statements = Expr[]
    for i in 1:fieldcount(N)
        NT = fieldtype(N, i)
        if Strategy === :monolith && NT <: ProgramFusedRegion
            B = fieldtype(NT, :batches)
            count = fieldcount(B)
            environments = [Symbol(:regular_environment_, i, :_, j) for j in 1:count]
            setup = [:( $(environments[j]) = _program_direct_environment(
                getfield(node.batches, $j), simulation, step)) for j in 1:count]
            calls = [:(Base.@inline _program_run_direct_row!(
                getfield(node.batches, $j), row, $(environments[j]), simulation, step))
                for j in 1:count]
            body = quote
                $(setup...)
                for row in eachindex(getfield(node.batches, 1).batch.targets)
                    $(calls...)
                end
            end
        elseif Strategy === :monolith && NT <: ScalarLocalRegion
            body = :(Base.@inline _program_run_scalar_region!(node, simulation, step))
        elseif Strategy === :monolith
            # New compiled region kinds expose their own inline body through
            # this same entry, rather than forcing the bounded node boundary.
            body = :(Base.@inline _program_run_application!(node, simulation, step))
        else
            body = :(_program_run_node!(node, simulation, step))
        end
        push!(statements, quote
            node = getfield(plan.nodes, $i)
            $body
        end)
    end
    return quote
        first_step = simulation.current_step + 1
        final_step = simulation.current_step + steps
        for step in first_step:final_step
            simulation.compiled.execution_generation += UInt64(1)
            empty!(simulation.environment_bindings.sample_cache)
            $(statements...)
            simulation.current_step = step
        end
        simulation
    end
end

function advance_program!(program::RegularGeneratedProgram; steps::Integer=1)
    steps >= 0 || throw(ArgumentError("steps must be non-negative"))
    plan = _regular_refresh!(program.base)
    reason = _regular_reason(plan)
    program.selected = reason === :eligible
    program.reason = reason
    if !program.selected
        program.fallback_steps += steps
        return advance_program!(program.base; steps)
    end
    base = _regular_underlying(program.base)
    simulation = base.simulation
    runtime_schedule = simulation.execution_plan.schedule
    runtime_schedule.last_step == simulation.current_step || error(
        "Regular program expected clock step $(simulation.current_step), got $(runtime_schedule.last_step).",
    )
    isempty(runtime_schedule.heap) || error("Always-due schedule unexpectedly has periodic cursors.")
    isnothing(plan.packed_store) || pull_packed!(plan.packed_store)
    previous_step = simulation.current_step
    try
        _program_advance_regular!(simulation, plan, steps, Val(base.strategy))
    finally
        isnothing(plan.packed_store) || push_packed!(plan.packed_store)
        _regular_restore_schedule!(simulation, plan)
        program.regular_steps += simulation.current_step - previous_step
    end
    PSE._compiled_source_finalize!(simulation)
    return simulation
end
