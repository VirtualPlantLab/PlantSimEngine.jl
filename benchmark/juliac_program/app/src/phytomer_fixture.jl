module PhytomerFixture

using Dates
using PlantSimEngine
using XPalm
import MultiScaleTreeGraph
const PSE = PlantSimEngine
const MTG = MultiScaleTreeGraph
const Models = XPalm.Models

"""Scene 1 → Plant 2 → Stem 3 → anchor Phytomer 4; no initial Internode or Leaf."""
function tree(factory=MTG.Node)
    scene = factory(1, MTG.NodeMTG(:/, :Scene, 1, 0), NamedTuple())
    plant = factory(2, scene, MTG.NodeMTG(:+, :Plant, 1, 1), NamedTuple())
    stem = factory(3, plant, MTG.NodeMTG(:+, :Stem, 1, 2), NamedTuple())
    factory(4, stem, MTG.NodeMTG(:/, :Phytomer, 1, 3), NamedTuple())
    return scene
end

# A fixed empty-attribute topology uses the original documented six-argument
# Node constructor and original addchild!; no columnar Any-valued store is needed.
function topology_node(id,encoding,attrs::NamedTuple{()})
    N=MTG.Node{typeof(encoding),typeof(attrs)}
    return N(id,nothing,N[],encoding,attrs,nothing)
end
function topology_node(id,parent::MTG.Node,encoding,attrs::NamedTuple{()})
    node=topology_node(id,encoding,attrs)
    MTG.addchild!(parent,node)
    return node
end
native_tree()=tree(topology_node)

# MTG nodes carry topology only. Scientific starting values are explicit typed
# inputs, rather than imported attributes. The ordinary reference retains
# XPalm's original status policy, then overlays those same inputs. add_organ!
# subsequently overlays the original emission kernel's newborn initial_status.
struct InitialStatus{B,A}
    biomass::B
    initiation_age::A
end
function (policy::InitialStatus)(node)
    values = NamedTuple(XPalm._xpalm_initial_status(node))
    scale = MTG.symbol(node)
    if scale === :Scene
        return Status(merge(values, (graph_node_count=length(node),)))
    elseif scale === :Phytomer
        return Status(merge(values, (initiation_age=policy.initiation_age,)))
    elseif scale in (:Internode, :Leaf)
        return Status(merge(values, (biomass=policy.biomass,)))
    end
    return Status(values)
end
status_policy(; biomass=1.0, initiation_age=0) = InitialStatus(biomass, initiation_age)

function _application(scale, model; inputs=NamedTuple())
    return ModelSpec(model; name=Symbol(scale, "__", PSE.process(model)),
        on=Many(scale=scale), inputs, every=Day(1))
end

function _initiation(scale, model)
    return _application(scale, model; inputs=(
        plant_age=One(scale=:Plant, within=SelfPlant(),
            application=:Plant__plant_age, var=:plant_age),
    ))
end

function _maintenance_model(scale, parameters)
    p = parameters["respiration"][String(scale)]
    return Models.RmQ10FixedN(p["Q10"], p["Mr"], p["T_ref"], p["P_alive"])
end

"""Original XPalm model instances, without ModelSpec or ordinary PSE preparation."""
function models(mtg; rate=0.05, initiation_age=0, parameters=XPalm.default_parameters())
    internode = parameters["dimensions"]["internode"]
    leaf = parameters["dimensions"]["leaf"]
    return (
        Models.DailyDegreeDays(),
        Models.DailyPlantAgeModel(; initiation_age),
        Models.PhyllochronModel(parameters["phyllochron"]["age_palm_maturity"], rate, rate),
        Models.PhytomerEmission(mtg),
        Models.InitiationAgeFromPlantAge(),
        Models.InitiationAgeFromPlantAge(),
        Models.FinalPotentialInternodeDimensionModel(
            internode["age_max_height"], internode["age_max_radius"],
            internode["min_height"], internode["min_radius"],
            internode["max_height"], internode["max_radius"]),
        Models.InitiationAgeFromPlantAge(),
        Models.FinalPotentialAreaModel(leaf["age_first_mature_leaf"],
            leaf["leaf_area_first_leaf"], leaf["leaf_area_mature_leaf"]),
        _maintenance_model(:Internode, parameters),
        _maintenance_model(:Leaf, parameters),
    )
end

"""External scalar seeds by scale; runtime scientific schemas derive from model contracts."""
function initial(; biomass=1.0, initiation_age=0, graph_node_count=4)
    return (
        Scene=(graph_node_count=graph_node_count,), Plant=NamedTuple(), Stem=NamedTuple(),
        Phytomer=(initiation_age=initiation_age,), Internode=(biomass=biomass,), Leaf=(biomass=biomass,),
    )
end

"""
    specs(mtg; rate=0.05, initiation_age=0, parameters=XPalm.default_parameters())

Eleven applications using original XPalm scientific methods. `rate` accelerates
both phyllochron endpoints for a short structural proof. All other parameter
values come from the pinned XPalm package's defaults. The original emission
application supplies its cross-object inputs, five targeted manual calls and
two newborn initializers; those contracts are not duplicated here.
"""
function specs(mtg; rate=0.05, initiation_age=0, parameters=XPalm.default_parameters())
    kernels = models(mtg; rate, initiation_age, parameters)
    # The original helper is used only in host-side scenario authoring. Its
    # original contracts feed ModelSpec; distributed state uses models directly.
    original_emission = XPalm._phytomer_emission_application(mtg)
    emission = ModelSpec(kernels[4];
        name=original_emission.name, on=original_emission.applies_to,
        inputs=original_emission.inputs, calls=original_emission.calls, every=Day(1))
    return (
        _application(:Plant, kernels[1]),
        _application(:Plant, kernels[2]),
        _application(:Plant, kernels[3]),
        emission,
        _initiation(:Phytomer, kernels[5]),
        _initiation(:Internode, kernels[6]),
        _application(:Internode, kernels[7]),
        _initiation(:Leaf, kernels[8]),
        _application(:Leaf, kernels[9]),
        _application(:Internode, kernels[10]),
        _application(:Leaf, kernels[11]),
    )
end

function rows(n::Integer; Tmin=22.0, Tmax=31.0)
    n >= 0 || throw(ArgumentError("negative forcing length"))
    return [(Tmin=Tmin, Tmax=Tmax) for _ in 1:n]
end
function _weather(forcing)
    isempty(forcing) && throw(ArgumentError("ordinary fixture needs at least one forcing row"))
    return Weather([
        Atmosphere(; date=DateTime(2025, 1, 1) + Day(i - 1), duration=Day(1),
            T=(row.Tmin + row.Tmax) / 2, Wind=1.0, Rh=0.6, P=100.0, row...)
        for (i, row) in enumerate(forcing)
    ])
end

"""Build the ordinary MTG-backed model without preparing or advancing its timeline."""
function scene(forcing; rate=0.05, initiation_age=0, mtg=tree(),
               biomass=1.0, parameters=XPalm.default_parameters())
    return CompositeModel(mtg;
        applications=specs(mtg; rate, initiation_age, parameters),
        environment=_weather(forcing), status=status_policy(; biomass, initiation_age))
end

"""Run original XPalm phytomer emission, targeted calls and newborn initializers."""
function ordinary(forcing=rows(4); rate=0.05, initiation_age=0, biomass=1.0,
                  parameters=XPalm.default_parameters(), constants=Constants())
    mtg = tree()
    model = scene(forcing; mtg, rate, initiation_age, biomass, parameters)
    return PSE.run!(model; steps=length(forcing), outputs=:all, constants)
end

function _declared_variables(applications, scale)
    names = Symbol[]
    for application in applications
        PSE.criteria(application.applies_to).scale === scale || continue
        append!(names, keys(PSE.inputs_(application)))
        append!(names, keys(PSE.outputs_(application)))
    end
    return Tuple(sort!(unique!(names)))
end

# Derive each status projection from original model contracts. Node references,
# caches and unrelated imported attributes are deliberately absent from evidence.
const STATUS_VARIABLES = let
    applications = specs(tree())
    (Scene=(:graph_node_count,), Plant=_declared_variables(applications, :Plant),
     Stem=(), Phytomer=_declared_variables(applications, :Phytomer),
     Internode=_declared_variables(applications, :Internode),
     Leaf=_declared_variables(applications, :Leaf))
end

"""One identity/topology/status evidence row, also usable by a separate backend."""
function object_fingerprint(id, scale::Symbol, parent_id, status; link, index)
    names = getproperty(STATUS_VARIABLES, scale)
    values = NamedTuple{names}(map(name -> status[name], names))
    return (object_id=id isa ObjectId ? id.value : id,
        parent_id=parent_id isa ObjectId ? parent_id.value : parent_id,
        scale=scale, link=link, index=index, status=values)
end

function fingerprint(model::PSE.CompositeModel)
    objects = sort!(PSE.model_objects(model); by=object -> object.id.value)
    return [
        object_fingerprint(object.id, object.scale, object.parent, object.status;
            link=MTG.link(PSE.source_node(model, object.id)),
            index=MTG.index(PSE.source_node(model, object.id)))
        for object in objects
    ]
end
function fingerprint(simulation::PSE.Simulation)
    samples = PSE.collect_outputs(simulation; sink=nothing)
    outputs = [
        (step=row.timestep, application=row.application_id,
            object_id=row.object_id, variable=row.variable, value=row.value)
        for row in samples
    ]
    return (objects=fingerprint(PSE.runtime_model(simulation)), outputs=outputs)
end

end # module PhytomerFixture
