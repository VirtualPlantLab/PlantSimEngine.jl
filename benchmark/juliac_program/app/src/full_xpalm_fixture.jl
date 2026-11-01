module FullXPalmFixture

using Dates
using PlantSimEngine
using XPalm
import MultiScaleTreeGraph as MTG
const PSE = PlantSimEngine

"""
    parameters(; rate=0.05, reproductive=false, sex_seed=1, abortion_seed=1,
                 flowering=30.0, abortion_duration=6.0, sex_duration=12.0)

Original XPalm defaults with explicit fixture parameter changes. Both
phyllochron endpoints use `rate`. The reproductive case shortens only the
inflorescence timing parameters so original sex-determination/emission kernels
can be exercised in a short run. It does not preassign sex, bypass RNG, force an
emission pulse, or change the model graph. These are test inputs, not calibration.
"""
function parameters(; rate=0.05, reproductive=false, sex_seed=1, abortion_seed=1,
                    flowering=30.0, abortion_duration=6.0, sex_duration=12.0)
    values = XPalm.default_parameters()
    values["phyllochron"]["production_speed_initial"] = rate
    values["phyllochron"]["production_speed_mature"] = rate
    values["reproduction"]["sex_ratio"]["random_seed"] = sex_seed
    values["reproduction"]["abortion"]["random_seed"] = abortion_seed
    if reproductive
        values["phenology"]["inflorescence"]["TT_flowering"] = flowering
        values["phenology"]["inflorescence"]["duration_abortion"] = abortion_duration
        values["phenology"]["inflorescence"]["duration_sex_determination"] = sex_duration
    end
    return values
end

"""The original Palm constructor and complete eight-node initial graph."""
function palm(; initiation_age=0, kwargs...)
    return XPalm.Palm(; initiation_age, parameters=parameters(; kwargs...), architecture=false)
end

"""All original architecture=false applications, in the original authored order."""
specs(value::XPalm.Palm) = XPalm.model_applications(value; architecture=false)
models(applications::Tuple) = map(application -> application.model, applications)
models(applications::AbstractVector) = Tuple(application.spec.model for application in applications)

function _categories(value, applications)
    categories = Symbol[PSE.criteria(application.applies_to).scale for application in applications]
    MTG.traverse!(value.mtg) do node
        push!(categories, MTG.symbol(node))
    end
    return Tuple(sort!(unique!(categories)))
end

"""Derive status ports, including distributed outputs on their destination scale."""
function variables_by_category(value, applications=specs(value))
    categories = _categories(value, applications)
    ports = Dict(category => Set{Symbol}() for category in categories)
    for category in (:Phytomer, :Internode, :Leaf, :Male, :Female)
        # These original import-policy fields also belong to newborn overlays;
        # some are accessed by original kernels without being declared ports.
        union!(ports[category], (:plant_age, :initiation_age, :TT_since_init, :state, :sex))
    end
    for application in applications
        category = PSE.criteria(application.applies_to).scale
        union!(ports[category], keys(PSE.inputs_(application)))
        output = PSE.outputs_(application)
        distributed = Symbol[]
        for (name, declaration) in pairs(output)
            if declaration isa PSE.Distributed
                push!(distributed, name)
            else
                push!(ports[category], name)
            end
        end
        for destination in application.outputs_to
            target = PSE.criteria(destination.selector).scale
            names = isnothing(destination.vars) ? distributed : destination.vars
            for category in (target isa Tuple ? target : (target,))
                union!(ports[category], names)
            end
        end
    end
    names = map(category -> Tuple(sort!(collect(ports[category]))), categories)
    return NamedTuple{categories}(names)
end

function _policy_values(node, variables)
    # Inspect the original import boundary; model defaults remain the job of the
    # original model contracts. Do not fabricate missing input/default values.
    status = XPalm._xpalm_initial_status(node)
    names = Tuple(name for name in variables if name !== :node && haskey(NamedTuple(status), name))
    return NamedTuple{names}(map(name -> deepcopy(status[name]), names))
end

"""
    initial_data(palm, applications=specs(palm))

Separate the original status policy's scientific inputs from MTG attributes.
`templates` contains per-category policy defaults for future nodes; `objects`
contains vectors of `(object_id, values)` for actual initial nodes. Values are
NamedTuples carrying their real types. The raw `:node` and unrelated attributes
such as the Plant's parameter dictionary are excluded; the original graph is
left intact. Both initial and future scientific values still come from
`XPalm._xpalm_initial_status`, with emission-kernel newborn overlays applied at
runtime by the backend.
"""
function initial_data(value, applications=specs(value))
    variables = variables_by_category(value, applications)
    categories = keys(variables)
    nodes = typeof(value.mtg)[]
    MTG.traverse!(value.mtg) do node
        push!(nodes, node)
    end
    templates = map(categories) do category
        example = findfirst(node -> MTG.symbol(node) === category, nodes)
        scale = isnothing(example) ? 4 : MTG.scale(nodes[example])
        # A detached, empty node asks the original policy for that category's
        # default scientific fields. It is never inserted into the Palm graph.
        node = MTG.Node(1, MTG.NodeMTG(:/, category, 1, scale), NamedTuple())
        _policy_values(node, variables[category])
    end
    objects = map(categories, templates) do category, template
        entries = [(object_id=ObjectId(MTG.node_id(node)), values=_policy_values(node, variables[category]))
            for node in nodes if MTG.symbol(node) === category]
        prototype = isempty(entries) ? (object_id=ObjectId(1), values=template) : first(entries)
        all(entry -> typeof(entry) === typeof(prototype), entries) ||
            throw(ArgumentError("initial objects in a category need one concrete policy schema"))
        Vector{typeof(prototype)}(entries)
    end
    return (templates=NamedTuple{categories}(templates), objects=NamedTuple{categories}(objects))
end

const TopologyRow = NamedTuple{
    (:id, :parent, :link, :scale, :index, :level),
    Tuple{Int,Union{Nothing,Int},Symbol,Symbol,Int,Int},
}

"""
    topology_descriptor(palm)

Typed topology data from the original graph, without MTG attributes or scientific
status values. Rows retain parent-first traversal and sibling order, allowing a
backend to reconstruct empty-attribute MTG nodes without changing child indexing.
`scale` is the category symbol; `level` is the numeric MTG scale.
"""
function topology_descriptor(value::XPalm.Palm)
    rows = TopologyRow[]
    MTG.traverse!(value.mtg) do node
        parent = MTG.parent(node)
        push!(rows, (
            id=MTG.node_id(node), parent=isnothing(parent) ? nothing : MTG.node_id(parent),
            link=MTG.link(node), scale=MTG.symbol(node), index=MTG.index(node), level=MTG.scale(node),
        ))
    end
    return rows
end

"""One coherent authoring snapshot; models refer to the actual original specifications."""
function authoring(; kwargs...)
    value = palm(; kwargs...)
    applications = specs(value)
    return (palm=value, applications=applications, models=models(applications),
        topology=topology_descriptor(value), variables=variables_by_category(value, applications),
        initial=initial_data(value, applications))
end

"""Complete plain daily environment rows required by the original model graph."""
function rows(n::Integer; start=Date(2025, 1, 1), Tmin=22.0, Tmax=31.0,
              T=26.5, Rh=0.7, Rh_min=60.0, Rh_max=95.0, Wind=1.0,
              P=100.0, Rg=16.0, Ri_SW_f=16.0, Ri_PAR_f=8.0,
              rain=3.0, rain_increment=0.5)
    n >= 0 || throw(ArgumentError("negative forcing length"))
    return [
        (date=start + Day(i - 1), duration=Day(1), T=T, Tmin=Tmin, Tmax=Tmax,
         Rh=Rh, Rh_min=Rh_min, Rh_max=Rh_max, Wind=Wind, P=P, Rg=Rg,
         Ri_SW_f=Ri_SW_f, Ri_PAR_f=Ri_PAR_f,
         Precipitations=rain + rain_increment * (i - 1))
        for i in 1:n
    ]
end

function weather(forcing)
    isempty(forcing) && throw(ArgumentError("ordinary fixture needs at least one forcing row"))
    return Weather([Atmosphere(; row...) for row in forcing])
end

"""Original CompositeModel import policy and entire unmodified application graph."""
function scene(value::XPalm.Palm, forcing; applications=specs(value))
    return CompositeModel(value.mtg; applications, environment=weather(forcing),
        status=XPalm._xpalm_initial_status)
end

"""Run the full original architecture=false XPalm graph with all outputs retained."""
function ordinary(forcing=rows(4); constants=Constants(), kwargs...)
    setup = authoring(; kwargs...)
    model = scene(setup.palm, forcing; applications=setup.applications)
    return PSE.run!(model; steps=length(forcing), outputs=:all, constants)
end

_plain(value::AbstractArray) = map(_plain, collect(value))
_plain(value) = deepcopy(value)
function _state_values(status, variables)
    names = Tuple(name for name in variables if name !== :node && name in keys(status))
    return NamedTuple{names}(map(name -> _plain(status[name]), names))
end

"""Declared scientific status, stable identities and actual topology for every live object."""
function fingerprint(model::PSE.CompositeModel, variables)
    objects = sort!(PSE.model_objects(model); by=object -> object.id.value)
    return [
        let node = PSE.source_node(model, object.id)
            (object_id=object.id, parent_id=object.parent, scale=object.scale,
             link=MTG.link(node), index=MTG.index(node),
             status=_state_values(object.status, variables[object.scale]))
        end
        for object in objects
    ]
end

function fingerprint(simulation::PSE.Simulation, variables)
    output = [
        (step=row.timestep, application=row.application_id, object_id=ObjectId(row.object_id),
         variable=row.variable, value=_plain(row.value))
        for row in PSE.collect_outputs(simulation; sink=nothing)
    ]
    return (objects=fingerprint(PSE.runtime_model(simulation), variables), outputs=output)
end

"""Non-mutating RNG evidence: next four UInt64 draws from copies of original RNG fields."""
function rng_fingerprint(kernels::Tuple)
    return map(kernels) do model
        names = Tuple(name for name in (:rng, :random_generator) if hasfield(typeof(model), name))
        NamedTuple{names}(map(name -> XPalm.Random.rand(copy(getfield(model, name)), UInt64, 4), names))
    end
end

end # module FullXPalmFixture
