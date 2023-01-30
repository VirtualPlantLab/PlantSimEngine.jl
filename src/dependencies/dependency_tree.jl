abstract type AbstractDependencyNode end

mutable struct HardDependencyNode{T} <: AbstractDependencyNode
    value::T
    process::Symbol
    dependency::NamedTuple
    missing_dependency::Vector{Int}
    parent::Union{Nothing,HardDependencyNode}
    children::Vector{HardDependencyNode}
end


mutable struct SoftDependencyNode{T} <: AbstractDependencyNode
    value::T
    process::Symbol
    hard_dependency::Union{Vector{HardDependencyNode}}
    parent::Union{Nothing,Vector{SoftDependencyNode}}
    parent_vars::Union{Nothing,NamedTuple}
    children::Vector{SoftDependencyNode}
    simulation_id::Int # id of the simulation
end

"""
    DependencyTree{T}(roots::T, not_found::Dict{Symbol,DataType})

A tree of dependencies between models.

# Arguments

- `roots::T`: the root nodes of the tree.
- `not_found::Dict{Symbol,DataType}`: the models that were not found in the tree.
"""
struct DependencyTree{T}
    roots::T
    not_found::Dict{Symbol,DataType}
end

AbstractTrees.children(t::AbstractDependencyNode) = t.children
AbstractTrees.nodevalue(t::AbstractDependencyNode) = t.value # needs recent AbstractTrees
AbstractTrees.ParentLinks(::Type{<:AbstractDependencyNode}) = AbstractTrees.StoredParents()
AbstractTrees.parent(t::AbstractDependencyNode) = t.parent
AbstractTrees.printnode(io::IO, node::HardDependencyNode{T}) where {T} = print(io, T)
AbstractTrees.printnode(io::IO, node::SoftDependencyNode{T}) where {T} = print(io, T)
Base.show(io::IO, t::AbstractDependencyNode) = AbstractTrees.print_tree(io, t)
Base.length(t::AbstractDependencyNode) = length(collect(AbstractTrees.PreOrderDFS(t)))

function Base.show(io::IO, t::DependencyTree)
    draw_dependency_trees(io, t)
end

"""
    traverse_dependency_tree(tree::DependencyTree, f::Function, visit_hard_dep=true)

Traverse the dependency `tree` and apply the function `f` to each node.
The first-level soft-dependencies are traversed first, then their
hard-dependencies (if `visit_hard_dep=true`), and then the children of the soft-dependencies.

Return a vector of pairs of the node and the result of the function `f`.

# Example

```julia
using PlantSimEngine

function f(node)
    node.value
end

include(joinpath(pkgdir(PlantSimEngine), "examples/dummy.jl"))

vars = (
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
    process4=Process4Model(),
    process5=Process5Model(),
    process6=Process6Model(),
    process7=Process7Model(),
)

tree = dep(vars)

traverse_dependency_tree(tree, f)
```
"""
function traverse_dependency_tree(
    tree::DependencyTree,
    f::Function;
    visit_hard_dep=true
)
    var = []
    for (p, root) in tree.roots
        traverse_dependency_tree!(root, f, var; visit_hard_dep=visit_hard_dep)
    end

    return var
end


"""
    traverse_dependency_tree(node::SoftDependencyNode, f::Function, var::Vector; visit_hard_dep=true)

Apply function `f` to `node`, visit its hard dependency nodes (if `visit_hard_dep=true`), and 
then its soft dependency children.

Mutate the vector `var` by pushing a pair of the node process name and the result of the function `f`.
"""
function traverse_dependency_tree!(
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
            traverse_dependency_tree!(child, f, var)
        end
    end

    for child in node.children
        traverse_dependency_tree!(child, f, var)
    end
end

"""
    traverse_dependency_tree(node::HardDependencyNode, f::Function, var::Vector)

Apply function `f` to `node`, and then its children (hard-dependency nodes).

Mutate the vector `var` by pushing a pair of the node process name and the result of the function `f`.
"""
function traverse_dependency_tree!(
    node::HardDependencyNode,
    f::Function,
    var::Vector;
    visit_hard_dep=true  # Just to be compatible with a call shared with SoftDependencyNode method
)
    push!(var, node.process => f(node))

    for child in node.children
        traverse_dependency_tree!(child, f, var)
    end
end

function draw_dependency_trees(
    io,
    trees::DependencyTree;
    title="Dependency tree",
    title_style::String="#FFA726 italic",
    guides_style::String="#42A5F5",
    dep_tree_guides=(space=" ", vline="│", branch="├", leaf="└", hline="─")
)

    dep_tree_guides = map((g) -> Term.apply_style("{$guides_style}$g{/$guides_style}"), dep_tree_guides)

    tree_panel = []
    for (p, tree) in trees.roots
        node = []
        # p = :process2; tree = trees.roots[p]
        # typeof(deps[:process4].children[1].hard_dependency.children[1])
        draw_panel(node, tree, "", dep_tree_guides, tree; title="Main model")
        push!(tree_panel, Term.Panel(node...; fit=true, title=string(p), style="green dim"))
    end

    print(
        io,
        Term.Panel(
            tree_panel...;
            fit=true,
            title="{$(title_style)}$(title){/$(title_style)}",
            style="$(title_style) dim"
        )
    )
end

"""
    draw_panel(node, tree, prefix, dep_tree_guides, parent; title="Soft-coupled model")

Draw the panels for all dependencies
"""
function draw_panel(node, tree, prefix, dep_tree_guides, parent; title="Soft-coupled model")

    # If the node has a sibling, draw a branching guide + a horizontal line:
    if length(parent.children) <= 1
        is_leaf = true
    else
        is_leaf = false
    end

    panel_hright = string(prefix, repeat(" ", 8))
    panel = draw_model_panel(tree; title=title)

    if tree.parent === nothing && parent == tree
        # The current node is the root of the tree:
        push!(node, prefix * panel)
    else
        push!(
            node,
            draw_guide(
                panel.measure.h ÷ 2,
                3,
                panel_hright,
                is_leaf,
                dep_tree_guides
            ) * panel
        )
    end
    # Draw the hard dependencies if any:
    if tree isa SoftDependencyNode
        # draw a branching guide if there's more soft dependencies after this one:
        for child in tree.hard_dependency
            draw_panel(node, child, panel_hright, dep_tree_guides, tree; title="Hard-coupled model")
        end
    elseif isa(parent, SoftDependencyNode) && length(parent.children) > 0
        # The current node is a hard dependency of a soft dependency.
        # If the parent has more soft dependency children, draw a vline also:
        panel_hright = string(prefix, repeat(" ", 8), dep_tree_guides.vline)
    end

    # Recursive call:
    for child in AbstractTrees.children(tree)
        draw_panel(node, child, panel_hright, dep_tree_guides, tree; title=title_panel(child))
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

Draw the line guide for one node of the dependency tree.
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