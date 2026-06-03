function _model_specs_for_dependency_updates(vars::NamedTuple)
    return Dict(
        :Default => Dict{Symbol,ModelSpec}(
            process(model) => as_model_spec(model) for model in values(vars)
        )
    )
end

_model_specs_for_dependency_updates(mapping::AbstractDict{Symbol,T}) where {T} =
    Dict(scale => parse_model_specs(declarations) for (scale, declarations) in pairs(mapping))

function _update_variables_for_spec(spec::ModelSpec)
    vars = Set{Symbol}()
    for update in updates(spec)
        union!(vars, update.variables)
    end
    return vars
end

function _update_after_for_var(spec::ModelSpec, var::Symbol)
    after = Symbol[]
    for update in updates(spec)
        var in update.variables || continue
        append!(after, update.after)
    end
    return unique(after)
end

function _canonical_output_vars(spec::ModelSpec)
    vars = Symbol[]
    routing = output_routing(spec)
    for var in keys(outputs_(spec))
        mode = var in keys(routing) ? routing[var] : :canonical
        mode == :stream_only && continue
        push!(vars, var)
    end
    return vars
end

function _validate_updates_for_scale(scale::Symbol, specs_at_scale::Dict{Symbol,ModelSpec}, ignored_processes::Set{Symbol}=Set{Symbol}())
    canonical_writers = Dict{Symbol,Vector{Symbol}}()

    for (process, spec) in specs_at_scale
        model_outputs = Set(keys(outputs_(spec)))
        for update in updates(spec)
            isempty(update.after) && error(
                "Updates declaration for process `$(process)` at scale `$(scale)` must specify `after=...`. ",
                "Use for example `Updates(:var; after=:producer_process)`."
            )
            for var in update.variables
                var in model_outputs || error(
                    "Updates declaration for process `$(process)` at scale `$(scale)` mentions variable `$(var)`, ",
                    "but this model does not output `$(var)`."
                )
                for after_process in update.after
                    haskey(specs_at_scale, after_process) || error(
                        "Updates declaration for variable `$(var)` in process `$(process)` at scale `$(scale)` ",
                        "references unknown process `$(after_process)`."
                    )
                    var in keys(outputs_(specs_at_scale[after_process])) || error(
                        "Updates declaration `Updates(:$(var); after=:$(after_process))` in process `$(process)` ",
                        "at scale `$(scale)` requires `$(after_process)` to output `$(var)`."
                    )
                end
            end
        end

        process in ignored_processes && continue
        for var in _canonical_output_vars(spec)
            push!(get!(canonical_writers, var, Symbol[]), process)
        end
    end

    for (var, writers) in canonical_writers
        length(writers) <= 1 && continue
        updater_flags = Dict(process => (var in _update_variables_for_spec(specs_at_scale[process])) for process in writers)
        primary_writers = [process for process in writers if !updater_flags[process]]
        update_writers = [process for process in writers if updater_flags[process]]

        length(primary_writers) == 1 || error(
            "Ambiguous canonical writers for variable `$(var)` at scale `$(scale)`: ",
            join(writers, ", "),
            ". Keep one primary writer and declare additional writers with `Updates(:$(var); after=:primary_process)`."
        )

        primary = only(primary_writers)
        for updater in update_writers
            after = _update_after_for_var(specs_at_scale[updater], var)
            primary in after || error(
                "Update writer `$(updater)` for variable `$(var)` at scale `$(scale)` must declare its primary producer in `after`. ",
                "Use `Updates(:$(var); after=:$(primary))` or include `:$(primary)` in the `after` list."
            )
        end

        for i in eachindex(update_writers), j in (i+1):length(update_writers)
            left = update_writers[i]
            right = update_writers[j]
            left_after = _update_after_for_var(specs_at_scale[left], var)
            right_after = _update_after_for_var(specs_at_scale[right], var)
            (left in right_after || right in left_after) || error(
                "Update writers `$(left)` and `$(right)` both update variable `$(var)` at scale `$(scale)` ",
                "without an ordering relation. Declare one updater `after` the other."
            )
        end
    end

    return nothing
end

function validate_update_dependencies(
    model_specs::Dict{Symbol,Dict{Symbol,ModelSpec}};
    ignored_processes_by_scale::Dict{Symbol,Set{Symbol}}=Dict{Symbol,Set{Symbol}}()
)
    for (scale, specs_at_scale) in model_specs
        _validate_updates_for_scale(scale, specs_at_scale, get(ignored_processes_by_scale, scale, Set{Symbol}()))
    end
    return nothing
end

function _soft_nodes_by_scale_process(graph::DependencyGraph)
    nodes = Dict{Tuple{Symbol,Symbol},SoftDependencyNode}()
    for node in traverse_dependency_graph(graph, false)
        nodes[(node.scale, node.process)] = node
    end
    return nodes
end

function _delete_root_for_node!(graph::DependencyGraph, node::SoftDependencyNode)
    if haskey(graph.roots, node.process)
        delete!(graph.roots, node.process)
    end
    key = node.scale => node.process
    if haskey(graph.roots, key)
        delete!(graph.roots, key)
    end
    return nothing
end

function _add_update_edge!(graph::DependencyGraph, parent_node::SoftDependencyNode, child_node::SoftDependencyNode)
    parent_node === child_node && error(
        "Invalid Updates dependency: process `$(child_node.process)` cannot be ordered after itself."
    )

    child_node in parent_node.children || push!(parent_node.children, child_node)
    if child_node.parent === nothing
        child_node.parent = [parent_node]
    elseif !(parent_node in child_node.parent)
        push!(child_node.parent, parent_node)
    end
    _delete_root_for_node!(graph, child_node)
    return nothing
end

function apply_update_dependencies!(graph::DependencyGraph, model_specs::Dict{Symbol,Dict{Symbol,ModelSpec}})
    validate_hard_dependency_timestep_consistency(model_specs, graph)
    ignored_processes_by_scale = _hard_dependency_children(graph)
    validate_update_dependencies(model_specs; ignored_processes_by_scale=ignored_processes_by_scale)
    has_updates = any(!isempty(updates(spec)) for specs_at_scale in values(model_specs) for spec in values(specs_at_scale))
    has_updates || return graph

    nodes = _soft_nodes_by_scale_process(graph)

    for (scale, specs_at_scale) in model_specs
        ignored_processes = get(ignored_processes_by_scale, scale, Set{Symbol}())
        for (process, spec) in specs_at_scale
            process in ignored_processes && continue
            child_node = get(nodes, (scale, process), nothing)
            isnothing(child_node) && continue
            for update in updates(spec)
                for after_process in update.after
                    parent_node = get(nodes, (scale, after_process), nothing)
                    isnothing(parent_node) && error(
                        "Updates declaration for process `$(process)` at scale `$(scale)` references `$(after_process)`, ",
                        "but that process is not an executable dependency node. It may be nested as a hard dependency."
                    )
                    _add_update_edge!(graph, parent_node, child_node)
                end
            end
        end
    end

    iscyclic, cycle_vec = is_graph_cyclic(graph; warn=false)
    iscyclic && error(
        "Cyclic dependency detected after applying Updates declarations. Cycle: \n",
        print_cycle(cycle_vec)
    )

    return graph
end
