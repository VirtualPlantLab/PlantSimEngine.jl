# Read-only inference diagnosis for the resolved-call experiment. Included
# after call_allocation_probes.jl. No model methods or executor are changed.

function _call_probe_typed_summary(function_, arguments; ir_path=nothing)
    typed = Base.code_typed(function_, arguments; optimize=true)
    if ir_path !== nothing
        open(ir_path, "w") do io
            show(io, MIME("text/plain"), typed)
        end
    end
    return map(typed) do result
        code, result_type = result
        values = code.ssavaluetypes
        any_values = values isa AbstractVector ? count(==(Any), values) : missing
        direct = dynamic = run_invokes = run_generic_calls = 0
        dynamic_names = Dict{String,Int}()
        for statement in code.code
            statement isa Expr || continue
            if statement.head === :invoke
                direct += 1
                callee = first(statement.args)
                if callee isa Core.MethodInstance && callee.def isa Method &&
                    callee.def.name === :run!
                    run_invokes += 1
                end
            elseif statement.head === :call
                dynamic += 1
                function_name = first(statement.args)
                if function_name isa GlobalRef && function_name.name === :run!
                    run_generic_calls += 1
                end
                # Avoid huge concrete-context types in a human-facing report.
                label = function_name isa GlobalRef ? string(function_name.name) :
                    string(nameof(typeof(function_name)))
                dynamic_names[label] = get(dynamic_names, label, 0) + 1
            end
        end
        (; return_type=string(result_type), any_values, direct_calls=direct,
            dynamic_calls=dynamic, run_invokes, run_generic_calls, dynamic_names)
    end
end

"""Inspect one real scientific callee and its singular model lookups, without executing it."""
function probe_call_inference(payload::ResolvedRootBatch, environment;
    depth=1, ir_prefix=nothing)
    context = first(payload.rows).context
    target = nothing
    for _ in 1:depth
        entries = [entry for entry in values(context.calls.entries)
            if entry isa ResolvedCallEntry{true} && _resolved_target_count(entry.plans) > 0]
        isempty(entries) && error("No nonempty resolved call at requested depth")
        target = first(first(first(entries).plans).targets)
        context = target.context
    end
    owner = target.owner
    status = _resolved_kernel_status(owner)
    kernel_arguments = Tuple{typeof(owner.model),typeof(status),
        typeof(environment),typeof(context.constants),typeof(context)}
    kernel = _call_probe_typed_summary(PSE.run!, kernel_arguments;
        ir_path=isnothing(ir_prefix) ? nothing : string(ir_prefix, "-kernel.txt"))
    # The scientific method can infer perfectly in isolation while its caller
    # still reaches it through generic dispatch and boxes immutable arguments.
    # Inspect the actual measured invocation boundary as well as the method.
    parent = first(payload.rows).context
    if depth > 1
        for _ in 1:(depth - 1)
            entry = first(filter(e -> e isa ResolvedCallEntry{true} &&
                _resolved_target_count(e.plans) > 0, values(parent.calls.entries)))
            parent = first(first(entry.plans).targets).context
        end
    end
    caller_arguments = Tuple{typeof(target),typeof(parent),typeof(environment),Int}
    caller = _call_probe_typed_summary(_probe_resolved_kernel!, caller_arguments;
        ir_path=isnothing(ir_prefix) ? nothing : string(ir_prefix, "-caller.txt"))
    lookups = Any[]
    if context.calls isa ResolvedCallTable
        for (name, entry) in pairs(context.calls.entries)
            entry isa ResolvedCallEntry{true} || continue
            _resolved_target_count(entry.plans) == 1 || continue
            original = context.calls.fallback_context
            arguments = Tuple{typeof(context),Val{name}}
            original_arguments = Tuple{typeof(original),Val{name}}
            resolved = _call_probe_typed_summary(PSE._call_model, arguments;
                ir_path=isnothing(ir_prefix) ? nothing : string(ir_prefix, "-", name, "-lookup.txt"))
            normal = _call_probe_typed_summary(PSE._call_model, original_arguments)
            push!(lookups, (; name, expected_model_type=string(typeof(_resolved_single_model(entry.plans))),
                resolved, normal))
        end
    end
    return (; depth, scientific_model=string(typeof(owner.model)),
        selected_status_matches_full=status === owner.status, kernel, caller, lookups,
        note=:inference_only_no_scientific_kernel_execution)
end
