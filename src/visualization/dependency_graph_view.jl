"""
    GraphPort

A display-oriented input or output port on a model node.
"""
struct GraphPort
    id::String
    name::Symbol
    role::Symbol
    mapping_mode::Union{Nothing,String}
    source_scale::Union{Nothing,Symbol}
    source_variable::Union{Nothing,Symbol}
    previous_timestep::Bool
    default_label::String
end

"""
    GraphNode

A display-oriented model node for dependency graph visualisation.
"""
struct GraphNode
    id::String
    process::Symbol
    scale::Symbol
    model_type::String
    role::Symbol
    rate::String
    inputs::Vector{GraphPort}
    outputs::Vector{GraphPort}
    parent::Union{Nothing,String}
    diagnostics::Vector{String}
end

"""
    GraphEdge

A display-oriented dependency edge between model variable ports.
"""
struct GraphEdge
    id::String
    source::String
    target::String
    source_port::Union{Nothing,String}
    target_port::Union{Nothing,String}
    source_variable::Union{Nothing,Symbol}
    target_variable::Union{Nothing,Symbol}
    kind::Symbol
    scale_relation::Symbol
    label::String
    diagnostics::Vector{String}
end

"""
    DependencyGraphView

Renderer-independent graph representation used by dependency graph visualisers.
"""
struct DependencyGraphView
    nodes::Vector{GraphNode}
    edges::Vector{GraphEdge}
    scales::Vector{Symbol}
    cyclic::Bool
    cycle_nodes::Vector{String}
    diagnostics::Vector{String}
end

abstract type AbstractGraphEdit end

"""
    MarkPreviousTimeStep(scale, process, variable)

Declarative graph edit used by future interactive editors to request that a
model input should be considered from the previous timestep.
"""
struct MarkPreviousTimeStep <: AbstractGraphEdit
    scale::Symbol
    process::Symbol
    variable::Symbol
end

"""
    graph_view(mapping)
    graph_view(sim::GraphSimulation)

Build a renderer-independent view of a dependency graph.
"""
function graph_view(mapping::ModelMapping; verbose::Bool=false)
    diagnostics = String[]
    graph = try
        dep(mapping; verbose=verbose)
    catch err
        msg = sprint(showerror, err)
        push!(diagnostics, msg)
        return _graph_view_from_mapping_only(mapping, diagnostics)
    end

    return graph_view(graph, mapping; diagnostics=diagnostics)
end

function graph_view(sim::GraphSimulation; diagnostics::Vector{String}=String[])
    return graph_view(sim.dependency_graph, sim; diagnostics=diagnostics)
end

function graph_view(graph::DependencyGraph, context=nothing; diagnostics::Vector{String}=String[])
    node_ids = IdDict{AbstractDependencyNode,String}()
    nodes = GraphNode[]
    edges = GraphEdge[]

    for node in traverse_dependency_graph(graph)
        id = _graph_node_id(node, node_ids)
        push!(nodes, _graph_node(node, id, context, node_ids))
    end

    for node in traverse_dependency_graph(graph, false)
        child_id = node_ids[node]
        if node.parent !== nothing
            for parent in node.parent
                parent_id = _graph_node_id(parent, node_ids)
                append!(edges, _soft_edges(parent, node, parent_id, child_id))
            end
        end

        for hard_child in node.hard_dependency
            parent_id = child_id
            child_hard_id = _graph_node_id(hard_child, node_ids)
            push!(edges, GraphEdge(
                "edge:hard:$(parent_id):$(child_hard_id)",
                parent_id,
                child_hard_id,
                nothing,
                nothing,
                nothing,
                nothing,
                :hard_dependency,
                node.scale == hard_child.scale ? :same_scale : :multiscale,
                "hard dependency",
                String[],
            ))
        end
    end

    cyclic, cycle_vec = is_graph_cyclic(graph; warn=false)
    cycle_nodes = cyclic ? [_model_node_id(last(pair), process(first(pair))) for pair in cycle_vec] : String[]
    scales = sort!(unique([node.scale for node in nodes]); by=string)
    return DependencyGraphView(nodes, edges, scales, cyclic, cycle_nodes, diagnostics)
end

"""
    graph_view_json(view)
    graph_view_json(mapping)

Return the graph view as JSON for browser renderers.
"""
graph_view_json(view::DependencyGraphView) = _json(_graph_view_dict(view))
graph_view_json(mapping::ModelMapping; kwargs...) = graph_view_json(graph_view(mapping; kwargs...))
graph_view_json(sim::GraphSimulation; kwargs...) = graph_view_json(graph_view(sim; kwargs...))

"""
    write_graph_view(path, view)
    write_graph_view(path, mapping)

Write a standalone HTML dependency graph visualisation.
"""
function write_graph_view(path::AbstractString, view::DependencyGraphView)
    mkpath(dirname(abspath(path)))
    open(path, "w") do io
        write(io, _graph_view_html(view))
    end
    return abspath(path)
end

write_graph_view(path::AbstractString, mapping::ModelMapping; kwargs...) =
    write_graph_view(path, graph_view(mapping; kwargs...))

write_graph_view(path::AbstractString, sim::GraphSimulation; kwargs...) =
    write_graph_view(path, graph_view(sim; kwargs...))

function apply_graph_edit(mapping::ModelMapping{MultiScale}, edit::MarkPreviousTimeStep)
    haskey(mapping, edit.scale) || error("Cannot mark `$(edit.variable)` as previous timestep: scale `$(edit.scale)` is not present in the `ModelMapping`.")

    found = Ref(false)
    data = Dict{Symbol,Any}()
    for (scale, entry) in pairs(mapping)
        data[scale] = scale == edit.scale ? _mark_previous_timestep_entry(entry, edit, found) : entry
    end

    found[] || error("Cannot mark `$(edit.variable)` as previous timestep: process `$(edit.process)` was not found at scale `$(edit.scale)`.")
    return ModelMapping(data; check=true, type_promotion=type_promotion(mapping))
end

function apply_graph_edit(mapping::ModelMapping, edit::AbstractGraphEdit)
    error("Graph edit `$(typeof(edit))` is not supported for `$(typeof(mapping))`.")
end

function _mark_previous_timestep_entry(entry::Tuple, edit::MarkPreviousTimeStep, found::Base.RefValue{Bool})
    return tuple((_mark_previous_timestep_item(item, edit, found) for item in entry)...)
end

function _mark_previous_timestep_entry(entry, edit::MarkPreviousTimeStep, found::Base.RefValue{Bool})
    return _mark_previous_timestep_item(entry, edit, found)
end

_mark_previous_timestep_item(item::Status, ::MarkPreviousTimeStep, ::Base.RefValue{Bool}) = item

function _mark_previous_timestep_item(item, edit::MarkPreviousTimeStep, found::Base.RefValue{Bool})
    spec = as_model_spec(item)
    process(model_(spec)) == edit.process || return item
    edit.variable in keys(variables(model_(spec))) || error(
        "Cannot mark `$(edit.variable)` as previous timestep for process `$(edit.process)` at scale `$(edit.scale)`: ",
        "the variable is not declared as an input or output of `$(typeof(model_(spec)))`."
    )

    found[] = true
    return ModelSpec(spec; multiscale=_mark_previous_timestep_mapping(spec.multiscale, edit.variable))
end

function _mark_previous_timestep_mapping(mapping, variable::Symbol)
    mapped = isnothing(mapping) ? Any[] : Any[collect(mapping)...]
    replaced = false
    for i in eachindex(mapped)
        item = mapped[i]
        if item isa Pair
            lhs = first(item)
            if lhs isa PreviousTimeStep && lhs.variable == variable
                replaced = true
                break
            elseif lhs == variable
                mapped[i] = PreviousTimeStep(variable) => last(item)
                replaced = true
                break
            end
        elseif item isa PreviousTimeStep && item.variable == variable
            replaced = true
            break
        end
    end
    replaced || push!(mapped, PreviousTimeStep(variable))
    return mapped
end

function _graph_view_from_mapping_only(mapping::ModelMapping, diagnostics)
    nodes = GraphNode[]
    for (scale, entry) in pairs(mapping)
        specs = parse_model_specs(entry)
        for (process_name, spec) in specs
            model = model_(spec)
            id = _model_node_id(scale, process_name)
            push!(nodes, GraphNode(
                id,
                process_name,
                scale,
                _type_label(typeof(model)),
                :model,
                _rate_label(spec),
                _ports(id, :input, inputs_(model)),
                _ports(id, :output, outputs_(model)),
                nothing,
                String[],
            ))
        end
    end
    scales = sort!(unique([node.scale for node in nodes]); by=string)
    return DependencyGraphView(nodes, GraphEdge[], scales, any(occursin.("Cyclic", diagnostics)), String[], diagnostics)
end

function _graph_node(node::AbstractDependencyNode, id::String, context, node_ids)
    role = node isa SoftDependencyNode ? :model : :hard_dependency
    parent = node.parent isa AbstractDependencyNode ? _graph_node_id(node.parent, node_ids) : nothing
    spec = _model_spec(context, node.scale, node.process)
    rate = isnothing(spec) ? _rate_label(node.value) : _rate_label(spec)
    return GraphNode(
        id,
        node.process,
        node.scale,
        _type_label(typeof(node.value)),
        role,
        rate,
        _ports(id, :input, _flatten_node_vars(node.inputs)),
        _ports(id, :output, _flatten_node_vars(node.outputs)),
        parent,
        _node_diagnostics(node),
    )
end

function _model_spec(mapping::ModelMapping, scale::Symbol, process_name::Symbol)
    specs = get(mapping.info.model_specs, scale, nothing)
    isnothing(specs) && return nothing
    return get(specs, process_name, nothing)
end

function _model_spec(sim::GraphSimulation, scale::Symbol, process_name::Symbol)
    specs = get(sim.model_specs, scale, nothing)
    isnothing(specs) && return nothing
    return get(specs, process_name, nothing)
end

_model_spec(::Any, ::Symbol, ::Symbol) = nothing

function _node_diagnostics(node)
    diagnostics = String[]
    if node isa HardDependencyNode && !isempty(node.missing_dependency)
        missing = [string(node.dependency[j]) for j in node.missing_dependency]
        push!(diagnostics, "Missing hard dependencies: $(join(missing, ", "))")
    end
    return diagnostics
end

_flatten_node_vars(vars::NamedTuple) = vars
_flatten_node_vars(vars::AbstractVector{<:Pair}) = flatten_vars(vars)
_flatten_node_vars(vars) = NamedTuple()

function _ports(node_id::String, role::Symbol, vars::NamedTuple)
    ports = GraphPort[]
    for (name, value) in pairs(vars)
        previous = value isa MappedVar && mapped_variable(value) isa PreviousTimeStep
        previous |= name isa PreviousTimeStep
        source_scale = _port_source_scale(value)
        source_var = _port_source_variable(value)
        push!(ports, GraphPort(
            _port_id(node_id, role, name),
            Symbol(name),
            role,
            _mapping_mode(value),
            source_scale,
            source_var,
            previous,
            _default_label(value),
        ))
    end
    return ports
end

_ports(node_id::String, role::Symbol, vars) = _ports(node_id, role, _flatten_node_vars(vars))

function _soft_edges(parent::SoftDependencyNode, child::SoftDependencyNode, parent_id::String, child_id::String)
    parent_outputs = _flatten_node_vars(parent.outputs)
    child_inputs = _flatten_node_vars(child.inputs)
    edges = GraphEdge[]

    for (input_name, input_value) in pairs(child_inputs)
        source_var = _source_var_for_parent(input_name, input_value, parent)
        isnothing(source_var) && continue
        haskey(parent_outputs, source_var) || continue

        scale_relation = parent.scale == child.scale ? :same_scale : :multiscale
        kind = input_value isa MappedVar ? :mapped_variable : :soft_dependency
        label = source_var == input_name ? string(input_name) : string(source_var, " -> ", input_name)
        if scale_relation == :multiscale
            label = string(parent.scale, ".", label, " -> ", child.scale)
        end
        push!(edges, GraphEdge(
            "edge:soft:$(parent_id):$(_port_id(parent_id, :output, source_var)):$(child_id):$(_port_id(child_id, :input, input_name))",
            parent_id,
            child_id,
            _port_id(parent_id, :output, source_var),
            _port_id(child_id, :input, input_name),
            source_var,
            Symbol(input_name),
            kind,
            scale_relation,
            label,
            String[],
        ))
    end

    return edges
end

function _source_var_for_parent(input_name, input_value, parent::SoftDependencyNode)
    if input_value isa MappedVar
        mapped_org = mapped_organ(input_value)
        if mapped_org isa Symbol
            mapped_org == parent.scale || return nothing
        elseif mapped_org isa AbstractVector
            parent.scale in mapped_org || return nothing
        else
            return nothing
        end
        mapped_variable(input_value) isa PreviousTimeStep && return nothing
        return Symbol(source_variable(input_value, parent.scale))
    end
    return Symbol(input_name)
end

function _graph_node_id(node::AbstractDependencyNode, node_ids::IdDict{AbstractDependencyNode,String})
    haskey(node_ids, node) && return node_ids[node]
    id = node isa SoftDependencyNode ? _model_node_id(node.scale, node.process) : _hard_node_id(node)
    node_ids[node] = id
    return id
end

function _graph_node_id(parent::Union{Nothing,AbstractDependencyNode}, node_ids)
    isnothing(parent) && return nothing
    return _graph_node_id(parent, node_ids)
end

_model_node_id(scale::Symbol, process_name::Symbol) = string("model:", scale, ":", process_name)
_hard_node_id(node::HardDependencyNode) = string("hard:", node.scale, ":", node.process, ":", objectid(node))
_port_id(node_id::String, role::Symbol, name) = string(node_id, ":", role, ":", Symbol(name))

_type_label(type) = string(nameof(type))

function _rate_label(spec::ModelSpec)
    if !isnothing(timestep(spec))
        return string("ModelSpec timestep: ", timestep(spec))
    end
    ts = timespec(model_(spec))
    return ts == ClockSpec(1.0, 0.0) ? "default rate" : string("model timespec: ", ts)
end

function _rate_label(model::AbstractModel)
    ts = timespec(model)
    return ts == ClockSpec(1.0, 0.0) ? "default rate" : string("model timespec: ", ts)
end

_mapping_mode(value) = nothing
_mapping_mode(value::MappedVar{SingleNodeMapping}) = "single-node"
_mapping_mode(value::MappedVar{MultiNodeMapping}) = "multi-node"
_mapping_mode(value::MappedVar{SelfNodeMapping}) = "self-node"
_mapping_mode(value::RefVariable) = "same-scale-alias"

_port_source_scale(value) = nothing
_port_source_scale(value::MappedVar{SingleNodeMapping}) = mapped_organ(value)
_port_source_scale(value::MappedVar{SelfNodeMapping}) = nothing
function _port_source_scale(value::MappedVar{MultiNodeMapping})
    scales = mapped_organ(value)
    isempty(scales) && return nothing
    return first(scales)
end

_port_source_variable(value) = nothing
_port_source_variable(value::MappedVar) = source_variable(value) isa Symbol ? source_variable(value) : nothing
_port_source_variable(value::RefVariable) = value.reference_variable
_port_source_variable(value::UninitializedVar) = value.variable

_default_label(value) = _short_value(value)
_default_label(value::MappedVar) = _short_value(mapped_default(value))
_default_label(value::UninitializedVar) = string("uninitialized, default ", _short_value(value.value))
_default_label(value::RefVariable) = string("alias of ", value.reference_variable)

function _short_value(value)
    value === nothing && return "nothing"
    value isa Number && return string(value)
    value isa AbstractString && return value
    value isa AbstractArray && return string(typeof(value), " length ", length(value))
    return string(typeof(value))
end

function _graph_view_dict(view::DependencyGraphView)
    return Dict(
        "nodes" => [_node_dict(node) for node in view.nodes],
        "edges" => [_edge_dict(edge) for edge in view.edges],
        "scales" => string.(view.scales),
        "cyclic" => view.cyclic,
        "cycleNodes" => view.cycle_nodes,
        "diagnostics" => view.diagnostics,
    )
end

function _node_dict(node::GraphNode)
    return Dict(
        "id" => node.id,
        "process" => string(node.process),
        "scale" => string(node.scale),
        "modelType" => node.model_type,
        "role" => string(node.role),
        "rate" => node.rate,
        "inputs" => [_port_dict(port) for port in node.inputs],
        "outputs" => [_port_dict(port) for port in node.outputs],
        "parent" => node.parent,
        "diagnostics" => node.diagnostics,
    )
end

function _port_dict(port::GraphPort)
    return Dict(
        "id" => port.id,
        "name" => string(port.name),
        "role" => string(port.role),
        "mappingMode" => port.mapping_mode,
        "sourceScale" => isnothing(port.source_scale) ? nothing : string(port.source_scale),
        "sourceVariable" => isnothing(port.source_variable) ? nothing : string(port.source_variable),
        "previousTimeStep" => port.previous_timestep,
        "default" => port.default_label,
    )
end

function _edge_dict(edge::GraphEdge)
    return Dict(
        "id" => edge.id,
        "source" => edge.source,
        "target" => edge.target,
        "sourcePort" => edge.source_port,
        "targetPort" => edge.target_port,
        "sourceVariable" => isnothing(edge.source_variable) ? nothing : string(edge.source_variable),
        "targetVariable" => isnothing(edge.target_variable) ? nothing : string(edge.target_variable),
        "kind" => string(edge.kind),
        "scaleRelation" => string(edge.scale_relation),
        "label" => edge.label,
        "diagnostics" => edge.diagnostics,
    )
end

function _json(value)
    io = IOBuffer()
    _write_json(io, value)
    return String(take!(io))
end

function _write_json(io, value::AbstractDict)
    print(io, "{")
    first_item = true
    for (key, val) in value
        first_item || print(io, ",")
        first_item = false
        _write_json(io, string(key))
        print(io, ":")
        _write_json(io, val)
    end
    print(io, "}")
end

function _write_json(io, value::AbstractVector)
    print(io, "[")
    for (i, val) in pairs(value)
        i == firstindex(value) || print(io, ",")
        _write_json(io, val)
    end
    print(io, "]")
end

_write_json(io, value::Nothing) = print(io, "null")
_write_json(io, value::Bool) = print(io, value ? "true" : "false")
_write_json(io, value::Real) = isfinite(value) ? print(io, value) : _write_json(io, string(value))
_write_json(io, value::Symbol) = _write_json(io, string(value))
_write_json(io, value::AbstractString) = print(io, "\"", _escape_json(value), "\"")
_write_json(io, value) = _write_json(io, string(value))

function _escape_json(s::AbstractString)
    escaped = replace(s, "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t")
    return replace(escaped, "</" => "<\\/")
end

function _graph_view_html(view::DependencyGraphView)
    json = graph_view_json(view)
    html = raw"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PlantSimEngine Dependency Graph</title>
<style>
:root {
  --bg: #f7f3ea;
  --ink: #1f2933;
  --muted: #667085;
  --line: #c8d0d9;
  --leaf: #216e5f;
  --plant: #295d9b;
  --soil: #7a5831;
  --warn: #ba3b46;
  --panel: rgba(255,255,255,.82);
  --shadow: 0 18px 44px rgba(26, 35, 48, .14);
}
* { box-sizing: border-box; }
body {
  margin: 0;
  color: var(--ink);
  background:
    linear-gradient(135deg, rgba(33,110,95,.12), transparent 34%),
    radial-gradient(circle at 100% 0%, rgba(41,93,155,.12), transparent 30%),
    var(--bg);
  font: 14px/1.35 ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}
.shell {
  display: grid;
  grid-template-columns: 1fr 320px;
  height: 100vh;
}
.toolbar {
  position: fixed;
  z-index: 5;
  top: 18px;
  left: 18px;
  right: 338px;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 10px 12px;
  background: rgba(255,255,255,.78);
  border: 1px solid rgba(102,112,133,.18);
  box-shadow: 0 10px 30px rgba(31,41,51,.10);
  backdrop-filter: blur(12px);
}
.title {
  font-weight: 760;
  letter-spacing: .01em;
  margin-right: auto;
}
.pill {
  border: 1px solid rgba(102,112,133,.22);
  padding: 5px 8px;
  background: #fff;
  font-size: 12px;
}
.pill.warn { color: var(--warn); border-color: rgba(186,59,70,.35); }
.canvas-wrap {
  position: relative;
  overflow: auto;
  height: 100vh;
  padding: 88px 36px 42px;
}
.canvas {
  position: relative;
  min-width: 1100px;
  min-height: 720px;
}
.edges {
  position: absolute;
  inset: 0;
  overflow: visible;
  pointer-events: none;
}
.edge-path {
  fill: none;
  stroke: rgba(82, 96, 111, .42);
  stroke-width: 2.1;
}
.edge-path.multiscale {
  stroke: #295d9b;
  stroke-dasharray: 8 6;
}
.edge-path.hard {
  stroke: #8b3f3f;
  stroke-width: 2.4;
}
.edge-path.active {
  stroke: #111827;
  stroke-width: 3.4;
}
.edge-label {
  font-size: 11px;
  fill: #344054;
  paint-order: stroke;
  stroke: rgba(255,255,255,.9);
  stroke-width: 4px;
}
.node {
  position: absolute;
  width: 270px;
  background: var(--panel);
  border: 1px solid rgba(102,112,133,.22);
  box-shadow: var(--shadow);
  backdrop-filter: blur(14px);
  transition: transform .12s ease, border-color .12s ease, opacity .12s ease;
}
.node:hover, .node.active {
  transform: translateY(-2px);
  border-color: rgba(31,41,51,.42);
}
.node.dim { opacity: .34; }
.node.hard_dependency {
  border-style: dashed;
}
.node-head {
  display: grid;
  gap: 4px;
  padding: 11px 12px;
  color: #fff;
  background: linear-gradient(90deg, #216e5f, #295d9b);
}
.node[data-scale="Soil"] .node-head { background: linear-gradient(90deg, #7a5831, #a06b39); }
.process { font-weight: 760; }
.model { font-size: 12px; opacity: .9; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.meta {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  padding: 9px 12px 0;
}
.badge {
  font-size: 11px;
  border: 1px solid rgba(102,112,133,.2);
  color: #475467;
  background: #fff;
  padding: 3px 6px;
}
.ports {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 8px;
  padding: 10px 10px 12px;
}
.port-group-title {
  font-size: 10px;
  color: var(--muted);
  text-transform: uppercase;
  margin-bottom: 5px;
  letter-spacing: .08em;
}
.port {
  position: relative;
  margin: 3px 0;
  padding: 4px 6px;
  background: rgba(255,255,255,.72);
  border: 1px solid rgba(102,112,133,.14);
  font-size: 12px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.port.input { padding-left: 12px; }
.port.output { padding-right: 12px; text-align: right; }
.port::before, .port::after {
  content: "";
  position: absolute;
  top: 50%;
  width: 8px;
  height: 8px;
  margin-top: -4px;
  border-radius: 50%;
  background: #667085;
}
.port.input::before { left: -4px; }
.port.output::after { right: -4px; }
.port.mapped::before, .port.mapped::after { background: #295d9b; }
.port.previous { color: var(--warn); }
.side {
  height: 100vh;
  overflow: auto;
  border-left: 1px solid rgba(102,112,133,.2);
  background: rgba(255,255,255,.58);
  backdrop-filter: blur(14px);
  padding: 18px;
}
.side h2 {
  font-size: 16px;
  margin: 0 0 10px;
}
.side h3 {
  font-size: 12px;
  margin: 18px 0 7px;
  color: var(--muted);
  text-transform: uppercase;
  letter-spacing: .08em;
}
.detail {
  border-top: 1px solid rgba(102,112,133,.18);
  padding-top: 12px;
}
.kv {
  display: grid;
  grid-template-columns: 88px 1fr;
  gap: 6px;
  margin: 6px 0;
}
.kv span:first-child { color: var(--muted); }
.diag {
  color: var(--warn);
  background: rgba(186,59,70,.08);
  border: 1px solid rgba(186,59,70,.18);
  padding: 8px;
  margin-top: 8px;
}
@media (max-width: 900px) {
  .shell { grid-template-columns: 1fr; }
  .toolbar { right: 18px; }
  .side { display: none; }
}
</style>
</head>
<body>
<script type="application/json" id="pse-graph-data">__PSE_GRAPH_JSON__</script>
<div class="shell">
  <main class="canvas-wrap">
    <div class="toolbar">
      <div class="title">PlantSimEngine Dependency Graph</div>
      <div class="pill" id="node-count"></div>
      <div class="pill" id="edge-count"></div>
      <div class="pill warn" id="cycle-pill" hidden>cycle detected</div>
    </div>
    <div class="canvas" id="canvas">
      <svg class="edges" id="edges"></svg>
    </div>
  </main>
  <aside class="side">
    <h2>Inspector</h2>
    <div id="inspector">Select a model or hover a variable.</div>
    <h3>Diagnostics</h3>
    <div id="diagnostics"></div>
  </aside>
</div>
<script>
const graph = JSON.parse(document.getElementById("pse-graph-data").textContent);
const canvas = document.getElementById("canvas");
const svg = document.getElementById("edges");
const inspector = document.getElementById("inspector");
document.getElementById("node-count").textContent = `${graph.nodes.length} models`;
document.getElementById("edge-count").textContent = `${graph.edges.length} links`;
document.getElementById("cycle-pill").hidden = !graph.cyclic;
document.getElementById("diagnostics").innerHTML = graph.diagnostics.length
  ? graph.diagnostics.map(d => `<div class="diag">${escapeHtml(d)}</div>`).join("")
  : `<div class="kv"><span>Status</span><span>No diagnostics</span></div>`;

const byId = new Map(graph.nodes.map(n => [n.id, n]));
const incoming = new Map(graph.nodes.map(n => [n.id, 0]));
const outgoing = new Map(graph.nodes.map(n => [n.id, []]));
graph.edges.filter(e => e.kind !== "hard_dependency").forEach(e => {
  incoming.set(e.target, (incoming.get(e.target) || 0) + 1);
  outgoing.get(e.source)?.push(e.target);
});

const levels = new Map();
const queue = graph.nodes.filter(n => (incoming.get(n.id) || 0) === 0).map(n => n.id);
queue.forEach(id => levels.set(id, 0));
while (queue.length) {
  const id = queue.shift();
  const level = levels.get(id) || 0;
  for (const child of outgoing.get(id) || []) {
    incoming.set(child, incoming.get(child) - 1);
    levels.set(child, Math.max(levels.get(child) || 0, level + 1));
    if (incoming.get(child) === 0) queue.push(child);
  }
}
graph.nodes.forEach((n, i) => { if (!levels.has(n.id)) levels.set(n.id, Math.floor(i / 4)); });
const columns = new Map();
graph.nodes.forEach(n => {
  const level = levels.get(n.id);
  if (!columns.has(level)) columns.set(level, []);
  columns.get(level).push(n);
});
for (const nodes of columns.values()) nodes.sort((a, b) => a.scale.localeCompare(b.scale) || a.process.localeCompare(b.process));

const positions = new Map();
for (const [level, nodes] of columns) {
  nodes.forEach((node, row) => positions.set(node.id, { x: 40 + level * 360, y: 40 + row * 245 }));
}

graph.nodes.forEach(node => renderNode(node, positions.get(node.id)));
requestAnimationFrame(drawEdges);
window.addEventListener("resize", drawEdges);

function renderNode(node, pos) {
  const el = document.createElement("section");
  el.className = `node ${node.role}`;
  el.dataset.nodeId = node.id;
  el.dataset.scale = node.scale;
  el.style.left = `${pos.x}px`;
  el.style.top = `${pos.y}px`;
  el.innerHTML = `
    <div class="node-head">
      <div class="process">${escapeHtml(node.process)}</div>
      <div class="model">${escapeHtml(node.modelType)}</div>
    </div>
    <div class="meta">
      <span class="badge">${escapeHtml(node.scale)}</span>
      <span class="badge">${escapeHtml(node.rate)}</span>
      ${node.role === "hard_dependency" ? `<span class="badge">hard</span>` : ""}
    </div>
    <div class="ports">
      <div><div class="port-group-title">Inputs</div>${node.inputs.map(p => portHtml(p)).join("")}</div>
      <div><div class="port-group-title">Outputs</div>${node.outputs.map(p => portHtml(p)).join("")}</div>
    </div>`;
  el.addEventListener("click", () => inspectNode(node));
  el.addEventListener("mouseenter", () => highlightNeighborhood(node.id));
  el.addEventListener("mouseleave", clearHighlight);
  canvas.appendChild(el);
}

function portHtml(port) {
  const classes = ["port", port.role, port.mappingMode ? "mapped" : "", port.previousTimeStep ? "previous" : ""].join(" ");
  return `<div class="${classes}" data-port-id="${escapeAttr(port.id)}" title="${escapeAttr(port.default || "")}">${escapeHtml(port.name)}</div>`;
}

function drawEdges() {
  const rect = canvas.getBoundingClientRect();
  svg.setAttribute("width", canvas.scrollWidth);
  svg.setAttribute("height", canvas.scrollHeight);
  svg.innerHTML = "";
  graph.edges.forEach(edge => {
    const source = portCenter(edge.sourcePort, edge.source, "output", rect);
    const target = portCenter(edge.targetPort, edge.target, "input", rect);
    if (!source || !target) return;
    const dx = Math.max(80, Math.abs(target.x - source.x) * .5);
    const path = `M ${source.x} ${source.y} C ${source.x + dx} ${source.y}, ${target.x - dx} ${target.y}, ${target.x} ${target.y}`;
    const p = document.createElementNS("http://www.w3.org/2000/svg", "path");
    p.setAttribute("d", path);
    p.dataset.edgeId = edge.id;
    p.classList.add("edge-path");
    if (edge.scaleRelation === "multiscale") p.classList.add("multiscale");
    if (edge.kind === "hard_dependency") p.classList.add("hard");
    svg.appendChild(p);
    if (edge.kind !== "hard_dependency") {
      const label = document.createElementNS("http://www.w3.org/2000/svg", "text");
      label.classList.add("edge-label");
      label.setAttribute("x", (source.x + target.x) / 2);
      label.setAttribute("y", (source.y + target.y) / 2 - 5);
      label.textContent = edge.label;
      svg.appendChild(label);
    }
  });
}

function portCenter(portId, nodeId, fallbackRole, canvasRect) {
  const selector = portId ? `[data-port-id="${cssEscape(portId)}"]` : `[data-node-id="${cssEscape(nodeId)}"] .port.${fallbackRole}`;
  const el = document.querySelector(selector);
  if (!el) return null;
  const r = el.getBoundingClientRect();
  return { x: r.left - canvasRect.left + (fallbackRole === "input" ? 0 : r.width), y: r.top - canvasRect.top + r.height / 2 };
}

function inspectNode(node) {
  inspector.innerHTML = `
    <div class="detail">
      <div class="kv"><span>Process</span><span>${escapeHtml(node.process)}</span></div>
      <div class="kv"><span>Model</span><span>${escapeHtml(node.modelType)}</span></div>
      <div class="kv"><span>Scale</span><span>${escapeHtml(node.scale)}</span></div>
      <div class="kv"><span>Rate</span><span>${escapeHtml(node.rate)}</span></div>
      <div class="kv"><span>Inputs</span><span>${node.inputs.map(p => escapeHtml(p.name)).join(", ") || "none"}</span></div>
      <div class="kv"><span>Outputs</span><span>${node.outputs.map(p => escapeHtml(p.name)).join(", ") || "none"}</span></div>
      ${node.diagnostics.map(d => `<div class="diag">${escapeHtml(d)}</div>`).join("")}
    </div>`;
}

function highlightNeighborhood(id) {
  const related = new Set([id]);
  graph.edges.forEach(e => { if (e.source === id) related.add(e.target); if (e.target === id) related.add(e.source); });
  document.querySelectorAll(".node").forEach(el => el.classList.toggle("dim", !related.has(el.dataset.nodeId)));
  document.querySelectorAll(".edge-path").forEach(el => {
    const edge = graph.edges.find(e => e.id === el.dataset.edgeId);
    el.classList.toggle("active", edge && (edge.source === id || edge.target === id));
  });
}
function clearHighlight() {
  document.querySelectorAll(".node").forEach(el => el.classList.remove("dim"));
  document.querySelectorAll(".edge-path").forEach(el => el.classList.remove("active"));
}
function escapeHtml(x) { return String(x).replace(/[&<>"']/g, c => ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c])); }
function escapeAttr(x) { return escapeHtml(x); }
function cssEscape(x) { return String(x).replace(/["\\\\]/g, "\\\\$&"); }
</script>
</body>
</html>
"""
    return replace(html, "__PSE_GRAPH_JSON__" => json)
end
