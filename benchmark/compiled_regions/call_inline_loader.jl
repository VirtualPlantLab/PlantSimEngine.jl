# Load the additive strategy into an already loaded experiment module without
# redefining its counter, factory, batch, or plan structs. Function definitions
# are extracted from the CURRENT backend source, not reconstructed old APIs.

function _inline_loader_definition_name(expression)
    expression isa Expr && expression.head === :function || return nothing
    signature = first(expression.args)
    while signature isa Expr && signature.head in (:where, :(::))
        signature = first(signature.args)
    end
    signature isa Expr && signature.head === :call || return nothing
    name = first(signature.args)
    return name isa Symbol ? name : nothing
end

function _inline_loader_collect!(definitions, expression, names)
    expression isa Expr || return definitions
    name = _inline_loader_definition_name(expression)
    if name in names
        haskey(definitions, name) && error("Duplicate backend definition: $(name)")
        definitions[name] = expression
    elseif expression.head in (:toplevel, :macrocall)
        for argument in expression.args
            _inline_loader_collect!(definitions, argument, names)
        end
    end
    return definitions
end

function load_inline_call_strategy!()
    names = (:_prepare_region_resolved_root, :compile_regions)
    backend_path = joinpath(@__DIR__, "region_backend.jl")
    syntax = Meta.parseall(read(backend_path, String); filename=backend_path)
    definitions = _inline_loader_collect!(Dict{Symbol,Expr}(), syntax, names)
    all(name -> haskey(definitions, name), names) ||
        error("Current backend does not define both inline-strategy entry points")
    Base.include(@__MODULE__, joinpath(@__DIR__, "call_status_abi.jl"))
    Base.include(@__MODULE__, joinpath(@__DIR__, "call_context_abi.jl"))
    if !isdefined(@__MODULE__, :InlineResolvedTargetPlan)
        Base.include(@__MODULE__, joinpath(@__DIR__, "inline_calls.jl"))
    end
    for name in names
        Core.eval(@__MODULE__, definitions[name])
    end
    return (; installed=names, backend_path,
        existing_backend_structs_preserved=true,
        intended_config=(refresh_strategy=:rebuild, state_strategy=:columns))
end
