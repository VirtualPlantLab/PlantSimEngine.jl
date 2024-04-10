function draw_dependency_graph(
    io,
    graphs::DependencyGraph{Dict{Pair{String,Symbol},PlantSimEngine.SoftDependencyNode}};
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
