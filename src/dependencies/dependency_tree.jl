abstract type AbstractDependencyNode end

mutable struct HardDependencyNode{T} <: AbstractDependencyNode
    value::T
    process::Symbol
    inputs::NamedTuple
    outputs::NamedTuple
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
    parent_vars::Union{Nothing,Tuple{Vararg{Symbol}}}
    children::Vector{SoftDependencyNode}
end

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
    traverse_dependency_tree(tree::DependencyTree, f::Function)

Traverse the dependency `tree` and apply the function `f` to each node.
The first-level soft-dependencies are traversed first, then their
hard-dependencies, and then the children of the soft-dependencies.

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
    f::Function
)
    var = []
    for (p, root) in tree.roots
        traverse_dependency_tree!(root, f, var)
    end

    return var
end


"""
    traverse_dependency_tree(node::SoftDependencyNode, f::Function, var::Vector)

Traverse the soft-dependency `node` and apply the `f` to itself, to its hard 
dependencies if any, and then to its children.

Mutate the vector `var` by pushing a pair of the node and the result of the
function `f`.
"""
function traverse_dependency_tree!(
    node::SoftDependencyNode,
    f::Function,
    var::Vector
)
    push!(var, node.process => f(node))

    # Traverse the hard dependencies of the SoftDependencyNode if any:
    if node isa SoftDependencyNode
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

Traverse the hard-dependency `node` and apply the `f` to itself and then to its
children.

Mutate the vector `var` by pushing a pair of the node and the result of the
function `f`.
"""
function traverse_dependency_tree!(
    node::HardDependencyNode,
    f::Function,
    var::Vector
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
        # p = :process4; tree = trees.roots[p]
        # typeof(deps[:process4].children[1].hard_dependency.children[1])

        draw_dependency_tree(tree, node, dep_tree_guides=dep_tree_guides)
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
    draw_dependency_tree(
        tree, node;
        guides_style::String=TERM_THEME[].tree_guide_style,
        dep_tree_guides=(space=" ", vline="│", branch="├", leaf="└", hline="─")
    )

Draw the dependency tree.
"""
function draw_dependency_tree(
    tree, node;
    dep_tree_guides=(space=" ", vline="│", branch="├", leaf="└", hline="─")
)

    prefix = ""
    panel1 = draw_model_panel(tree; title="Main model")

    push!(node, prefix * panel1)

    draw_panel(node, tree, prefix, dep_tree_guides)
    return node
end

"""
    draw_panel(node, tree, prefix, dep_tree_guides)

Draw the panels for all dependencies
"""
function draw_panel(node, tree, prefix, dep_tree_guides; last_leaf=true)
    ch = AbstractTrees.children(tree)
    length(ch) == 0 && return # If no children, return

    is_leaf = [repeat([false], length(ch) - 1)..., last_leaf]

    for i in AbstractTrees.children(tree)
        panel_hright = string(prefix, repeat(" ", 8))

        panel = draw_model_panel(i)

        push!(
            node,
            draw_guide(
                panel.measure.h ÷ 2,
                3,
                panel_hright,
                popfirst!(is_leaf),
                dep_tree_guides
            ) * panel
        )

        # Draw the hard dependencies if any:
        if i isa SoftDependencyNode
            # draw a branching guide if there's more soft dependencies after this one:
            if length(i.children) > 0
                last_leaf = false
            end
            draw_panel(node, i.hard_dependency, panel_hright, dep_tree_guides, last_leaf=last_leaf)
        end

        if !last_leaf && i isa HardDependencyNode
            panel_hright = string(panel_hright, dep_tree_guides.vline)
        end
        # draw the other dependencies:
        draw_panel(node, i, panel_hright, dep_tree_guides)
    end
end


function draw_model_panel(i::SoftDependencyNode{T}; title="Soft-coupled model") where {T}
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


function draw_model_panel(i::HardDependencyNode{T}; title="Hard-coupled model") where {T}
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