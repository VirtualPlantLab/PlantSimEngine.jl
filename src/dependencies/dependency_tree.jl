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


mutable struct SoftDependencyNode <: AbstractDependencyNode
    value::DataType
    process::Symbol
    hard_dependency::HardDependencyNode
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
AbstractTrees.printnode(io::IO, node::AbstractDependencyNode) = print(io, node.value)
Base.show(io::IO, t::AbstractDependencyNode) = AbstractTrees.print_tree(io, t)
Base.length(t::AbstractDependencyNode) = length(collect(AbstractTrees.PreOrderDFS(t)))

function Base.show(io::IO, t::DependencyTree)
    draw_dependency_trees(io, t)
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
    panel1 = Term.Panel(
        title="Main model",
        string(
            "Process: $(tree.process)\n",
            "Model: $(tree.value)",
            length(tree.hard_dependency.missing_dependency) == 0 ? "" : string(
                "\n{red underline}Missing dependencies: ",
                join([tree.hard_dependency.dependency[j] for j in tree.hard_dependency.missing_dependency], ", "),
                "{/red underline}"
            )
        );
        fit=true,
        style="blue dim"
    )

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


function draw_model_panel(i::SoftDependencyNode)
    Term.Panel(
        title="Soft-coupled model",
        string(
            "Process: $(i.process)\n",
            "Model: $(i.value)\n",
            "Dep: $(i.parent_vars)"
        );
        fit=true,
        style="blue dim"
    )
end


function draw_model_panel(i::HardDependencyNode)
    Term.Panel(
        title="Hard-coupled model",
        string(
            "Process: $(i.process)\n",
            "Model: $(i.value)",
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