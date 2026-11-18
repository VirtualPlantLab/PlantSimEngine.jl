module StatusSemanticProjection
export project_core
function project_state(values::NamedTuple)
    names = Tuple(sort!(collect(keys(values)); by=String))
    # No field is removed here: frozen snapshot already excludes only :node.
    return NamedTuple{names}(map(name -> getproperty(values, name), names))
end
function project_core(core)
    keys(core) == (:step,:states,:topology,:histories,:rngs,:source_topology) ||
        error("The complete historical core is required.")
    # Any is a detached protocol record-list carrier only. Scientific values
    # and embedded arrays are passed through with all types/bits unchanged.
    states = Any[(id=row.id, state=project_state(row.state)) for row in core.states]
    return (step=core.step, states, topology=core.topology, histories=core.histories,
        rngs=core.rngs, source_topology=core.source_topology)
end
end
