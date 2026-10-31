# Included after driver.jl and local_state.jl. This additional experiment makes
# scalar state local to an eligible fused row before invoking unchanged kernels.

mutable struct LocalGeneratedProgram{G}
    base::G
end

program_simulation(program::LocalGeneratedProgram) = program_simulation(program.base)

# Bounded scalar regions retain their own native function boundary. The static
# monolith generator in driver.jl uses _program_run_application!, whose overload
# below instead exposes the generated scalar row body to its caller.
@noinline function _program_run_node!(node::ScalarLocalRegion, simulation, step)
    _program_run_scalar_region!(node, simulation, step)
    return nothing
end

@inline function _program_run_application!(node::ScalarLocalRegion, simulation, step)
    Base.@inline _program_run_scalar_region!(node, simulation, step)
    return nothing
end

function _compile_local_program_plan(base)
    plan = base.plan
    nodes = Any[]
    reasons = NamedTuple[]
    regions = 0
    applications = 0
    for node in plan.nodes
        if node isa ProgramFusedRegion
            try
                converted = make_scalar_local_region(node)
                push!(nodes, converted)
                regions += 1
                applications += node.last_entry - node.first_entry + 1
                push!(reasons, (first_entry=node.first_entry,
                    last_entry=node.last_entry, reason=:eligible))
            catch error_
                error_ isa ArgumentError || rethrow()
                push!(nodes, node)
                push!(reasons, (first_entry=node.first_entry,
                    last_entry=node.last_entry, reason=:unsupported_scalar_schema_or_alias_pattern))
            end
        else
            push!(nodes, node)
        end
    end
    report = merge(plan.report, (
        scalar_requested=true,
        scalar_regions=regions,
        scalar_applications=applications,
        scalar_reasons=Tuple(reasons),
        scalar_storage=:per_row_local_refs,
    ))
    return ProgramPlan(Tuple(nodes), plan.schedule, plan.packed_store,
        plan.runtime_revision, plan.fixed_local, report)
end

"""
    compile_local_program(simulation; strategy=:fused, packed=false, block_size=4)

Additional local-state lowering experiment over the same original model methods.
The ordinary compiler determines legal regions first. A scalar recipe preserves
their field/ref alias pattern; required publications read each writer's live
local value, and canonical/packed row state is written back at the region end.
Unsupported regions retain the ordinary generated strategy.
"""
function compile_local_program(simulation; strategy::Symbol=:fused,
    packed::Bool=false, block_size::Int=4)
    strategy in (:fused, :monolith) || throw(ArgumentError(
        "Local scalar lowering requires :fused or :monolith.",
    ))
    base = compile_program(simulation; strategy, packed, block_size)
    base.plan = _compile_local_program_plan(base)
    return LocalGeneratedProgram(base)
end

strategy_report(program::LocalGeneratedProgram) = strategy_report(program.base)

function advance_program!(program::LocalGeneratedProgram; steps::Integer=1)
    steps >= 0 || throw(ArgumentError("steps must be non-negative"))
    base = program.base
    simulation = base.simulation
    PSE._compiled_source_finalize!(simulation)
    if base.plan.runtime_revision != simulation.runtime_revision
        base.plan = _compile_program_plan(simulation, base.strategy,
            base.packed, base.block_size)
        base.plan = _compile_local_program_plan(base)
        base.rebuilds += 1
    end
    # Dynamic regions can rebuild inside the general driver. Reapply scalar
    # lowering after each step, without deferring any lifecycle effect.
    if !base.plan.fixed_local
        for _ in 1:steps
            _program_ensure_plan!(base)
            if !hasproperty(base.plan.report, :scalar_requested)
                base.plan = _compile_local_program_plan(base)
            end
            advance_program!(base; steps=1)
        end
        _program_ensure_plan!(base)
        if !hasproperty(base.plan.report, :scalar_requested)
            base.plan = _compile_local_program_plan(base)
        end
        return simulation
    end
    return advance_program!(base; steps)
end
