# Alternative scalar-local lowering without an inner exception region. The
# eligibility contract already promises completion for validated inputs; this
# probe tests whether try/finally inhibited escape analysis in local_state.jl.

struct FastScalarLocalRegion{R,B}
    first_entry::Int
    last_entry::Int
    batches::B
    recipe::R
end

mutable struct FastScalarGeneratedProgram{G}
    base::G
end

program_simulation(program::FastScalarGeneratedProgram) = program_simulation(program.base)
strategy_report(program::FastScalarGeneratedProgram) = strategy_report(program.base)

@inline @generated function _program_run_fast_scalar_region!(
    node::FastScalarLocalRegion{R,B}, simulation, step,
) where {R<:LocalStateRecipe,B}
    names, aliases = R.parameters
    count = fieldcount(B)
    environments = [Symbol(:fast_environment_, i) for i in 1:count]
    setup = [:( $(environments[i]) = _program_direct_environment(
        getfield(node.batches, $i), simulation, step)) for i in 1:count]
    references = [Symbol(:fast_local_cell_, i) for i in eachindex(names)]
    loads = [:( $(references[i]) = Ref(getproperty(source, $(QuoteNode(names[i])))))
        for i in eachindex(names) if aliases[i] == i]
    cells = Expr(:tuple, (references[aliases[i]] for i in eachindex(names))...)
    constructor = :(PSE.Status(NamedTuple{$(QuoteNode(names))}($cells)))
    stores = [:(setproperty!(source, $(QuoteNode(names[i])),
        getproperty(local_status, $(QuoteNode(names[i])))))
        for i in eachindex(names) if aliases[i] == i]
    stages = Expr[]
    for i in 1:count
        push!(stages, quote
            batch = getfield(node.batches, $i)
            @inbounds target = batch.batch.targets[row]
            context = target.context
            context isa PSE.RunContext && (context.time = float(step))
            Base.@inline PSE.run!(target.model, local_status,
                $(environments[i]), simulation.constants, context)
            if batch.batch.output_publication.enabled
                @inbounds _publish_local_outputs!(batch.output_bindings[row], local_status, step)
            end
        end)
    end
    return quote
        $(setup...)
        for row in eachindex(getfield(node.batches, 1).statuses)
            @inbounds source = getfield(node.batches, 1).statuses[row]
            $(loads...)
            local_status = $constructor
            $(stages...)
            $(stores...)
        end
        nothing
    end
end

@noinline function _program_run_node!(node::FastScalarLocalRegion, simulation, step)
    _program_run_fast_scalar_region!(node, simulation, step)
    return nothing
end

@inline function _program_run_application!(node::FastScalarLocalRegion, simulation, step)
    Base.@inline _program_run_fast_scalar_region!(node, simulation, step)
    return nothing
end

function _compile_fast_scalar_plan(base)
    local_plan = _compile_local_program_plan(base)
    nodes = map(local_plan.nodes) do node
        node isa ScalarLocalRegion ? FastScalarLocalRegion(
            node.first_entry, node.last_entry, node.batches, node.recipe) : node
    end
    report = merge(local_plan.report, (
        scalar_fast_requested=true,
        scalar_fast_regions=count(node -> node isa FastScalarLocalRegion, nodes),
        scalar_exception_region=false,
    ))
    return ProgramPlan(nodes, local_plan.schedule, local_plan.packed_store,
        local_plan.runtime_revision, local_plan.fixed_local, report)
end

"""Probe nonescaping original Status cells without try/finally around each row."""
function compile_fast_scalar_program(simulation; strategy::Symbol=:fused,
    packed::Bool=false, block_size::Int=4)
    strategy in (:fused, :monolith) || throw(ArgumentError(
        "Fast scalar lowering requires :fused or :monolith.",
    ))
    base = compile_program(simulation; strategy, packed, block_size)
    base.plan = _compile_fast_scalar_plan(base)
    return FastScalarGeneratedProgram(base)
end

function _fast_scalar_refresh!(program::FastScalarGeneratedProgram)
    base = program.base
    _program_ensure_plan!(base)
    if !hasproperty(base.plan.report, :scalar_fast_requested)
        base.plan = _compile_fast_scalar_plan(base)
    end
    return base.plan
end

function advance_program!(program::FastScalarGeneratedProgram; steps::Integer=1)
    steps >= 0 || throw(ArgumentError("steps must be non-negative"))
    base = program.base
    plan = _fast_scalar_refresh!(program)
    if plan.fixed_local
        return advance_program!(base; steps)
    end
    for _ in 1:steps
        _fast_scalar_refresh!(program)
        advance_program!(base; steps=1)
    end
    _fast_scalar_refresh!(program)
    return base.simulation
end

# Include this extension after cadence_driver.jl to allow the independent
# schedule-specialization and scalarization experiments to be combined.
if isdefined(@__MODULE__, :RegularGeneratedProgram)
    _regular_underlying(program::FastScalarGeneratedProgram) = program.base
    _regular_refresh!(program::FastScalarGeneratedProgram) = _fast_scalar_refresh!(program)
end
