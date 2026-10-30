# Reload only top-level method definitions after a test-harness correction.
# Existing process/fixture types are deliberately retained in the Kaimon module.

function _call_check_method_assignment(expression)
    expression isa Expr && expression.head === :(=) || return false
    signature = first(expression.args)
    while signature isa Expr && signature.head in (:where, :(::))
        signature = first(signature.args)
    end
    return signature isa Expr && signature.head === :call
end

function _call_check_collect_methods!(definitions, expression)
    expression isa Expr || return definitions
    if expression.head === :function || _call_check_method_assignment(expression)
        push!(definitions, expression)
    elseif expression.head in (:toplevel, :macrocall)
        for argument in expression.args
            _call_check_collect_methods!(definitions, argument)
        end
    end
    return definitions
end

function reload_call_check_methods!(;
    files=("inline_call_checks.jl", "call_distributed_checks.jl"))
    counts = NamedTuple[]
    for file in files
        path = joinpath(@__DIR__, file)
        syntax = Meta.parseall(read(path, String); filename=path)
        definitions = _call_check_collect_methods!(Expr[], syntax)
        isempty(definitions) && error("No call-check methods in $(file)")
        for definition in definitions
            Core.eval(@__MODULE__, definition)
        end
        push!(counts, (; file, methods=length(definitions)))
    end
    return (; files=counts, existing_fixture_types_preserved=true)
end
