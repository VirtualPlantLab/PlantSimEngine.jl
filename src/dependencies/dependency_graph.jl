abstract type AbstractDependencyNode end

mutable struct HardDependencyNode{T} <: AbstractDependencyNode
    value::T
    process::Symbol
    dependency::NamedTuple
    missing_dependency::Vector{Int}
    inputs
    outputs
    parent::Union{Nothing,HardDependencyNode}
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
struct DependencyGraph{T}
    roots::T
    not_found::Dict{Symbol,DataType}
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

function Base.show(io::IO, t::DependencyGraph)
    draw_dependency_graph(io, t)
end

"""
    traverse_dependency_graph(graph::DependencyGraph, f::Function, visit_hard_dep=true)

Traverse the dependency `graph` and apply the function `f` to each node.
The first-level soft-dependencies are traversed first, then their
hard-dependencies (if `visit_hard_dep=true`), and then the children of the soft-dependencies.

Return a vector of pairs of the node and the result of the function `f`.

# Example

```julia
using PlantSimEngine

# Including example processes and models:
using PlantSimEngine.Examples;

function f(node)
    node.value
end

vars = (
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
    process4=Process4Model(),
    process5=Process5Model(),
    process6=Process6Model(),
    process7=Process7Model(),
)

graph = dep(vars)
traverse_dependency_graph(graph, f)
```
"""
function traverse_dependency_graph(
    graph::DependencyGraph,
    f::Function;
    visit_hard_dep=true
)
    var = []
    for (p, root) in graph.roots
        traverse_dependency_graph!(root, f, var; visit_hard_dep=visit_hard_dep)
    end

    return var
end


function traverse_dependency_graph!(
    f::Function,
    node::SoftDependencyNode,
    visit_hard_dep=true
)

    f(node)
    # Traverse the hard dependencies of the SoftDependencyNode if any:
    if visit_hard_dep && node isa SoftDependencyNode
        # draw a branching guide if there's more soft dependencies after this one:
        for child in node.hard_dependency
            traverse_dependency_graph!(f, child)
        end
    end

    for child in node.children
        traverse_dependency_graph!(f, child)
    end
end


"""
    traverse_dependency_graph(node::SoftDependencyNode, f::Function, var::Vector; visit_hard_dep=true)

Apply function `f` to `node`, visit its hard dependency nodes (if `visit_hard_dep=true`), and 
then its soft dependency children.

Mutate the vector `var` by pushing a pair of the node process name and the result of the function `f`.
"""
function traverse_dependency_graph!(
    node::SoftDependencyNode,
    f::Function,
    var::Vector;
    visit_hard_dep=true
)
    push!(var, node.process => f(node))

    # Traverse the hard dependencies of the SoftDependencyNode if any:
    if visit_hard_dep && node isa SoftDependencyNode
        # draw a branching guide if there's more soft dependencies after this one:
        for child in node.hard_dependency
            traverse_dependency_graph!(child, f, var)
        end
    end

    for child in node.children
        traverse_dependency_graph!(child, f, var)
    end
end

"""
    traverse_dependency_graph(node::HardDependencyNode, f::Function, var::Vector)

Apply function `f` to `node`, and then its children (hard-dependency nodes).

Mutate the vector `var` by pushing a pair of the node process name and the result of the function `f`.
"""
function traverse_dependency_graph!(
    node::HardDependencyNode,
    f::Function,
    var::Vector;
    visit_hard_dep=true  # Just to be compatible with a call shared with SoftDependencyNode method
)
    push!(var, node.process => f(node))

    for child in node.children
        traverse_dependency_graph!(child, f, var)
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

```julia
full_vars_mapping = Dict(first(mod) => Dict(get_mapping(last(mod))) for mod in mapping)
```
"""
function variables_multiscale(node, organ, vars_mapping, st=NamedTuple())
    ins = inputs_(node.value)
    ins_variables = keys(ins)
    defaults = merge(ins, outputs_(node.value))
    map(variables(node)) do vars
        vars_ = Vector{Pair{Symbol,Any}}()
        for var in vars # e.g. var = :soil_water_content
            if var in keys(st)
                #If the user has given a status, we use it as default value:
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
                if isa(vars_mapping[organ][var], Pair{String,Symbol})
                    # One organ is mapped to the variable:
                    organ_mapped, organ_mapped_var = vars_mapping[organ][var]
                    organ_mapped = SingleNodeMapping(organ_mapped)
                else
                    # Several organs are mapped to the variable:
                    organ_mapped = MultiNodeMapping([first(i) for i in vars_mapping[organ][var]])
                    organ_mapped_var = [last(i) for i in vars_mapping[organ][var]]
                end
                push!(vars_, var => MappedVar(organ_mapped, var, organ_mapped_var, default))
            else
                push!(vars_, var => default)
            end
        end
        return (; vars_...,)
    end
end

function draw_dependency_graph(
    io,
    graphs::DependencyGraph;
    title="Dependency graph",
    title_style::String="#FFA726 italic",
    guides_style::String="#42A5F5",
    dep_graph_guides=(space=" ", vline="│", branch="├", leaf="└", hline="─")
)

    dep_graph_guides = map((g) -> Term.apply_style("{$guides_style}$g{/$guides_style}"), dep_graph_guides)

    graph_panel = []
    for (p, graph) in graphs.roots
        node = []
        # p = :process2; graph = graphs.roots[p]
        # typeof(deps[:process4].children[1].hard_dependency.children[1])
        draw_panel(node, graph, "", dep_graph_guides, graph; title="Main model")
        push!(graph_panel, Term.Panel(node...; fit=true, title=string(p), style="green dim"))
    end

    print(
        io,
        Term.Panel(
            graph_panel...;
            fit=true,
            title="{$(title_style)}$(title){/$(title_style)}",
            style="$(title_style) dim"
        )
    )
end

"""
    draw_panel(node, graph, prefix, dep_graph_guides, parent; title="Soft-coupled model")

Draw the panels for all dependencies
"""
function draw_panel(node, graph, prefix, dep_graph_guides, parent; title="Soft-coupled model")

    # If the node has a sibling, draw a branching guide + a horizontal line:
    if length(parent.children) <= 1
        is_leaf = true
    else
        is_leaf = false
    end

    panel_hright = string(prefix, repeat(" ", 8))
    panel = draw_model_panel(graph; title=title)

    if graph.parent === nothing && parent == graph
        # The current node is the root of the graph:
        push!(node, prefix * panel)
    else
        push!(
            node,
            draw_guide(
                panel.measure.h ÷ 2,
                3,
                panel_hright,
                is_leaf,
                dep_graph_guides
            ) * panel
        )
    end
    # Draw the hard dependencies if any:
    if graph isa SoftDependencyNode
        # draw a branching guide if there's more soft dependencies after this one:
        for child in graph.hard_dependency
            draw_panel(node, child, panel_hright, dep_graph_guides, graph; title="Hard-coupled model")
        end
    elseif isa(parent, SoftDependencyNode) && length(parent.children) > 0
        # The current node is a hard dependency of a soft dependency.
        # If the parent has more soft dependency children, draw a vline also:
        panel_hright = string(prefix, repeat(" ", 8), dep_graph_guides.vline)
    end

    # Recursive call:
    for child in AbstractTrees.children(graph)
        draw_panel(node, child, panel_hright, dep_graph_guides, graph; title=title_panel(child))
    end
end

title_panel(i::SoftDependencyNode) = "Soft-coupled model"
title_panel(i::HardDependencyNode) = "Hard-coupled model"

function draw_model_panel(i::SoftDependencyNode{T}; title=nothing) where {T}
    Term.Panel(
        title=title,
        string(
            "Process: $(i.process)\n",
            "Model: $(T)\n",
            "Dep: $(i.parent_vars)"
        );
        fit=true,
        style="blue dim"
    )
end


function draw_model_panel(i::HardDependencyNode{T}; title=nothing) where {T}
    Term.Panel(
        title=title,
        string(
            "Process: $(i.process)\n",
            "Model: $(T)",
            length(i.missing_dependency) == 0 ? "" : string(
                "\n{red underline}Missing dependencies: ",
                join([i.dependency[j] for j in i.missing_dependency], ", "),
                "{/red underline}"
            )
        );
        fit=true,
        style="red dim"
    )
end


"""
    draw_guide(h, w, prefix, isleaf, guides)

Draw the line guide for one node of the dependency graph.
"""
function draw_guide(h, w, prefix, isleaf, guides)
    header_width = string(prefix, guides.vline, repeat(guides.space, w - 1), "\n")
    header = h > 1 ? repeat(header_width, h) : ""
    if isleaf
        return header * prefix * guides.leaf * repeat(guides.hline, w - 1)
    else
        footer = h > 1 ? header_width[1:end-1] : "" # NB: we remove the last \n
        return header * prefix * guides.branch * repeat(guides.hline, w - 1) * "\n" * footer
    end
end