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

mutable struct TimestepMapping
    variable_from::Symbol
    variable_to::Symbol
    timestep_to::Period
    mapping_function::Function
    mapping_data_template
    mapping_data::Dict{Int, Any} # TODO fix type stability : Int is the node id, Any is a vector of n elements of the variable's type, n being the # of required timesteps
end

# can hard dependency nodes also handle timestep mapped variables... ?
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
    timestep::Period
    timestep_mapping_data::Union{Nothing, Vector{TimestepMapping}} # TODO : this approach might not play too well with parallelisation over MTG nodes
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