abstract type AbstractDependencyNode end

mutable struct HardDependencyNode{T} <: AbstractDependencyNode
    value::T
    process::Symbol
    dependency::NamedTuple
    missing_dependency::Vector{Int}
    scale::String
    inputs
    outputs
    parent::Union{Nothing,<:AbstractDependencyNode}
    children::Vector{HardDependencyNode}
end

mutable struct SoftDependencyNode{T} <: AbstractDependencyNode
    value::T
    process::Symbol
    scale::String
    inputs
    outputs
    hard_dependency::Vector{HardDependencyNode}
    parent::Union{Nothing,Vector{SoftDependencyNode}}
    parent_vars::Union{Nothing,NamedTuple}
    children::Vector{SoftDependencyNode}
    simulation_id::Vector{Int} # id of the simulation
end

# Add methods to check if a node is parallelizable:
object_parallelizable(x::T) where {T<:AbstractDependencyNode} = x.value => object_parallelizable(x.value)
timestep_parallelizable(x::T) where {T<:AbstractDependencyNode} = x.value => timestep_parallelizable(x.value)

"""
    DependencyGraph{T}(roots::T, not_found::Dict{Symbol,DataType})

A graph of dependencies between models.

# Arguments

- `roots::T`: the root nodes of the graph.
- `not_found::Dict{Symbol,DataType}`: the models that were not found in the graph.
"""
struct DependencyGraph{T,N}
    roots::T
    not_found::Dict{Symbol,N}
end

# Add methods to check if a node is parallelizable:
function which_timestep_parallelizable(x::T) where {T<:DependencyGraph}
    return traverse_dependency_graph(x, timestep_parallelizable)
end

function which_object_parallelizable(x::T) where {T<:DependencyGraph}
    return traverse_dependency_graph(x, object_parallelizable)
end

object_parallelizable(x::T) where {T<:DependencyGraph} = all([i.second.second for i in which_object_parallelizable(x)])
timestep_parallelizable(x::T) where {T<:DependencyGraph} = all([i.second.second for i in which_timestep_parallelizable(x)])

AbstractTrees.children(t::AbstractDependencyNode) = t.children
AbstractTrees.nodevalue(t::AbstractDependencyNode) = t.value # needs recent AbstractTrees
AbstractTrees.ParentLinks(::Type{<:AbstractDependencyNode}) = AbstractTrees.StoredParents()
AbstractTrees.parent(t::AbstractDependencyNode) = t.parent
AbstractTrees.printnode(io::IO, node::HardDependencyNode{T}) where {T} = print(io, T)
AbstractTrees.printnode(io::IO, node::SoftDependencyNode{T}) where {T} = print(io, T)
Base.show(io::IO, t::AbstractDependencyNode) = AbstractTrees.print_tree(io, t)
Base.length(t::AbstractDependencyNode) = length(collect(AbstractTrees.PreOrderDFS(t)))
Base.length(t::DependencyGraph) = length(traverse_dependency_graph(t))
AbstractTrees.children(t::DependencyGraph) = collect(t.roots)

# Long form printing
function Base.show(io::IO, ::MIME"text/plain", t::DependencyGraph)
    # If the graph is cyclic, we print the cycle because we can't print indefinitely:
    iscyclic, cycle_vec = is_graph_cyclic(t; warn=false, full_stack=true)
    if iscyclic
        print(io, "⚠ Cyclic dependency graph: \n $(print_cycle(cycle_vec))")
        return nothing
    else
        draw_dependency_graph(io, t)
    end
end

"""
    variables_multiscale(node, organ, mapping, st=NamedTuple())

Get the variables of a HardDependencyNode, taking into account the multiscale mapping, *i.e.*
defining variables as `MappedVar` if they are mapped to another scale. The default values are 
taken from the model if not given by the user (`st`), and are marked as `UninitializedVar` if 
they are inputs of the node.

Return a NamedTuple with the variables and their default values.

# Arguments

- `node::HardDependencyNode`: the node to get the variables from.
- `organ::String`: the organ type, *e.g.* "Leaf".
- `vars_mapping::Dict{String,T}`: the mapping of the models (see details below).
- `st::NamedTuple`: an optional named tuple with default values for the variables.

# Details

The `vars_mapping` is a dictionary with the organ type as key and a dictionary as value. It is 
computed from the user mapping like so:
"""
function variables_multiscale(node, organ, vars_mapping, st=NamedTuple())
    node_vars = variables(node) # e.g. (inputs = (:var1=-Inf, :var2=-Inf), outputs = (:var3=-Inf,))
    ins = node_vars.inputs
    ins_variables = keys(ins)
    outs_variables = keys(node_vars.outputs)
    defaults = merge(node_vars...)
    map((inputs=ins_variables, outputs=outs_variables)) do vars # Map over vars from :inputs and vars from :outputs
        vars_ = Vector{Pair{Symbol,Any}}()
        for var in vars # e.g. var = :carbon_biomass
            if var in keys(st)
                #If the user has given a status, we use it as default value.
                default = st[var]
            elseif var in ins_variables
                # Otherwise, we use the default value given by the model:
                # If the variable is an input, we mark it as uninitialized:
                default = UninitializedVar(var, defaults[var])
            else
                # If the variable is an output, we use the default value given by the model:
                default = defaults[var]
            end

            if haskey(vars_mapping[organ], var)
                organ_mapped, organ_mapped_var = _node_mapping(vars_mapping[organ][var])
                push!(vars_, var => MappedVar(organ_mapped, var, organ_mapped_var, default))
                #* We still check if the variable also exists wrapped in PreviousTimeStep, because one model could use the current 
                #* values, and another one the previous values.
                if haskey(vars_mapping[organ], PreviousTimeStep(var, node.process))
                    organ_mapped, organ_mapped_var = _node_mapping(vars_mapping[organ][PreviousTimeStep(var, node.process)])
                    push!(vars_, var => MappedVar(organ_mapped, PreviousTimeStep(var, node.process), organ_mapped_var, default))
                end
            elseif haskey(vars_mapping[organ], PreviousTimeStep(var, node.process))
                # If not found in the current time step, we check if the variable is mapped to the previous time step:
                organ_mapped, organ_mapped_var = _node_mapping(vars_mapping[organ][PreviousTimeStep(var, node.process)])
                push!(vars_, var => MappedVar(organ_mapped, PreviousTimeStep(var, node.process), organ_mapped_var, default))
            else
                # Else we take the default value:
                push!(vars_, var => default)
            end
        end
        return (; vars_...,)
    end
end

function _node_mapping(var_mapping::Pair{String,Symbol})
    # One organ is mapped to the variable:
    return SingleNodeMapping(first(var_mapping)), last(var_mapping)
end

function _node_mapping(var_mapping)
    # Several organs are mapped to the variable:
    organ_mapped = MultiNodeMapping([first(i) for i in var_mapping])
    organ_mapped_var = [last(i) for i in var_mapping]

    return organ_mapped, organ_mapped_var
end