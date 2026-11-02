module ObjectPrograms

import PlantSimEngine as PSE

abstract type AbstractRegistryOwner end
const PlantId = PSE.ObjectId{Symbol}
const OrganId = PSE.ObjectId{Tuple{Symbol,Symbol,Int}}
const IN_GROUP = :amap_internode
const Id = Union{PlantId,OrganId}

# An adapter registers its original model families and state-construction hook.
# This file contains no AMAP botanical, event, random or geometry equations.
model_role(model) = :unsupported
admit_native_state(state) = throw(ArgumentError("unregistered native state family"))
clone_native_state(state) = throw(ArgumentError("unregistered native state factory"))
native_geometry_type(state) = throw(ArgumentError("unregistered native geometry schema"))

struct Instruction
    role::Symbol
    index::Int
end
struct Sample{I,T}
    id::I
    step::Int
    value::T
end
struct RegistryProgram{A,P,L,C,PI,OI,G,K}
    architecture::A
    publishers::Vector{P}
    length_model::L
    count_model::C
    plant_initials::Vector{PI}
    organ_initial::OI
    geometry_type::Type{G}
    scene_id::PlantId
    scene_children::Vector{PlantId}
    plant_ids::Vector{PlantId}
    publisher_names::Vector{Symbol}
    publisher_plants::Vector{Int}
    plant_publishers::Vector{Int}
    architecture_name::Symbol
    length_name::Symbol
    count_name::Symbol
    order::Vector{Instruction}
    plant_order::Vector{Int}
    constants::K
end
struct RegistryRecord{I,P,C,S,G}
    id::I
    parent::P
    children::C
    status::S
    geometry::G
    name::Nothing
    kind::Symbol
    scale::Symbol
    species::Nothing
end
mutable struct RegistryState{P,SP,SI,G,TL,TR,TO,TC} <: AbstractRegistryOwner
    program::P
    scene_status::typeof(PSE.Status())
    plant_statuses::Vector{SP}
    plant_children::Vector{Vector{OrganId}}
    plant_lookup::Dict{PlantId,Int}
    organ_ids::Vector{OrganId}
    organ_parents::Vector{PlantId}
    organ_statuses::Vector{SI}
    organ_geometry::Vector{G}
    organ_active::BitVector
    organ_lookup::Dict{OrganId,Int}
    owned_rows::Vector{Vector{Int}}
    committed_rows::Vector{Int}
    dirty_plants::BitVector
    membership_dirty::Bool
    output_ids::Vector{Vector{OrganId}}
    output_columns::Vector{PSE.RefVector{TL}}
    architecture_samples::Vector{Sample{PlantId,TR}}
    publisher_samples::Vector{Vector{Sample{OrganId,TL}}}
    length_samples::Vector{Sample{OrganId,TO}}
    count_samples::Vector{Sample{OrganId,TC}}
    step::Int
    retain::Bool
    in_step::Bool
    failed::Bool
    registered_count::Int
    removed_count::Int
    geometry_updates::Int
    qualification_entries::Int
end
struct Context{S}
    owner::S
    plant_row::Int
    publisher::Int
end
PSE.runtime_model(context::Context) = context.owner
PSE.runtime_model(state::RegistryState) = state
PSE.current_step(state::RegistryState) = state.step

_criteria(selector) = PSE.criteria(selector)
function _self_source(selector, application, variable)
    selector isa PSE.One || return false
    c = _criteria(selector)
    return get(c,:within,nothing) isa PSE.Self && isempty(c.selectors) &&
        get(c,:application,nothing) === application && get(c,:var,variable) === variable
end
function _target_scale(spec, category)
    spec.applies_to isa PSE.Many || return false
    c = _criteria(spec.applies_to)
    return get(c,:scale,nothing) === category && isempty(c.selectors) &&
        all(key -> key in (:selectors,:scale,:id), keys(c))
end

"""Prepare the admitted original AMAP architecture/geometry/IN projection graph.
The temporary ordinary zero-step compilation verifies ordering only. It is
released here; no ordinary plan, execution target, simulation or runtime is
retained or used by instantiate/step!.
"""
function prepare(model::PSE.CompositeModel; constants=PSE.Constants())
    specs = Tuple(model.applications)
    roles = map(spec -> model_role(spec.model), specs)
    all(role -> role in (:architecture,:publisher,:length,:count), roles) ||
        throw(ArgumentError("this registry layout admits only the qualified original AMAP families"))
    architecture_slot = only(findall(==(:architecture), roles))
    length_slot = only(findall(==(:length), roles))
    count_slot = only(findall(==(:count), roles))
    publisher_slots = findall(==(:publisher), roles)
    architecture = specs[architecture_slot]
    length_spec = specs[length_slot]
    count_spec = specs[count_slot]
    for spec in specs
        isempty(spec.calls) && isempty(spec.updates) && isempty(spec.output_routing) ||
            throw(ArgumentError("calls, duplicate writers and stream routing are outside this registry lane"))
        isempty(PSE.dep(spec.model)) && isempty(PSE.environment_inputs_(spec.model)) &&
            isempty(PSE.environment_outputs_(spec.model)) || throw(ArgumentError("unsupported model protocol"))
        isnothing(spec.environment) && isempty(spec.environment_bindings) && isnothing(spec.environment_window) &&
            isnothing(spec.timestep) || throw(ArgumentError("the original unclocked global AMAP grammar is required"))
        PSE._is_default_clock(PSE.timespec(spec.model)) || throw(ArgumentError("nondefault model clocks unsupported"))
    end
    _target_scale(architecture,:Plant) && isempty(architecture.inputs) && isempty(architecture.outputs_to) ||
        throw(ArgumentError("unsupported architecture routing"))
    _target_scale(length_spec,:IN) && isempty(length_spec.inputs) && isempty(length_spec.outputs_to) ||
        throw(ArgumentError("unsupported length consumer routing"))
    _target_scale(count_spec,:IN) && keys(count_spec.inputs)==(:observed_length,) &&
        _self_source(count_spec.inputs.observed_length,length_spec.name,:observed_length) ||
        throw(ArgumentError("counter must read the original same-object LengthProbe"))
    keys(PSE.inputs_(architecture.model)) == (:_native_pse_state,:development_increment) &&
        keys(PSE.outputs_(architecture.model)) == (:native_revision,) || throw(ArgumentError("unexpected architecture ports"))
    keys(PSE.inputs_(length_spec.model)) == (:length,) && keys(PSE.outputs_(length_spec.model)) == (:observed_length,) ||
        throw(ArgumentError("unexpected LengthProbe ports"))
    keys(PSE.inputs_(count_spec.model)) == (:observed_length,) && keys(PSE.outputs_(count_spec.model)) == (:qualification_runs,) ||
        throw(ArgumentError("unexpected work-counter ports"))
    objects = PSE.model_objects(model)
    scenes = filter(object -> object.scale===:Scene, objects)
    scene = only(scenes)
    scene.id isa PlantId && scene.kind===:scene && isnothing(scene.parent) || throw(ArgumentError("unsupported scene identity/labels"))
    plants = filter(object -> object.scale===:Plant, objects)
    isempty(plants) && throw(ArgumentError("at least one native plant required"))
    length(objects)==length(plants)+1 || throw(ArgumentError("prepare from the original empty-organ initial graph"))
    all(object -> object.id isa PlantId && object.parent==scene.id && object.kind===:plant &&
        isnothing(object.species) && isnothing(object.name) && isnothing(PSE.geometry(object)), plants) ||
        throw(ArgumentError("unsupported plant identity/metadata"))
    plant_ids = PlantId[object.id for object in plants]
    lookup = Dict(id=>row for (row,id) in enumerate(plant_ids))
    initials = [merge(NamedTuple(object.status),PSE.outputs_(architecture.model)) for object in plants]
    PI = typeof(first(initials))
    all(initial -> typeof(initial)===PI, initials) || throw(ArgumentError("heterogeneous native plant input schemas"))
    foreach(initial -> admit_native_state(initial._native_pse_state), initials)
    G = native_geometry_type(first(initials)._native_pse_state)
    all(initial -> native_geometry_type(initial._native_pse_state)===G, initials) || throw(ArgumentError("heterogeneous geometry schemas"))
    publisher_models = [specs[slot].model for slot in publisher_slots]
    isempty(publisher_models) && throw(ArgumentError("native property publishers are required"))
    MP = typeof(first(publisher_models))
    all(publisher -> typeof(publisher)===MP, publisher_models) || throw(ArgumentError("publisher schemas must be homogeneous"))
    publisher_plants = Int[]
    for slot in publisher_slots
        spec = specs[slot]
        spec.applies_to isa PSE.One || throw(ArgumentError("publisher must select one plant"))
        c = _criteria(spec.applies_to)
        id = get(c,:id,nothing)
        id isa PlantId && haskey(lookup,id) && keys(c)==(:selectors,:id) && isempty(c.selectors) ||
            throw(ArgumentError("publisher must use its original explicit plant ID"))
        keys(spec.inputs)==(:native_revision,) && _self_source(spec.inputs.native_revision,architecture.name,:native_revision) ||
            throw(ArgumentError("publisher must read its own architecture revision"))
        destination = only(spec.outputs_to)
        dc = _criteria(destination.selector)
        destination.selector isa PSE.Many && get(dc,:scale,nothing)===:IN &&
            get(dc,:kind,nothing)===:internode && get(dc,:within,nothing) isa PSE.Subtree &&
            all(key->key in (:selectors,:scale,:kind,:within),keys(dc)) || throw(ArgumentError("unsupported publisher destination"))
        keys(PSE.outputs_(spec.model))==(:length,) || throw(ArgumentError("only the exact original length property is admitted"))
        push!(publisher_plants,lookup[id])
    end
    sort(publisher_plants)==collect(eachindex(plants)) || throw(ArgumentError("one publisher per plant required"))
    declared = PSE.outputs_(first(publisher_models)).length
    declared isa PSE.Distributed && declared.declaration isa PSE.Default || throw(ArgumentError("length must be a distributed default"))
    organ_initial = merge((length=declared.declaration.value,), PSE.outputs_(length_spec.model),PSE.outputs_(count_spec.model))
    # Authoring-only reference schedule, including all initially targetless apps.
    checked = PSE.run!(deepcopy(model);steps=0,outputs=:none,constants)
    order = Instruction[]
    for name in checked.compiled.application_order
        slot = only(findall(spec->spec.name===name,specs))
        role = roles[slot]
        index = role===:publisher ? only(findall(==(slot),publisher_slots)) : 0
        push!(order,Instruction(role,index))
    end
    compiled_architecture = only(filter(app->app.id===architecture.name,checked.compiled.applications))
    plant_order = Int[lookup[id::PlantId] for id in compiled_architecture.target_ids]
    inverse = zeros(Int,length(plants))
    for (publisher,plant) in enumerate(publisher_plants); inverse[plant]=publisher; end
    return RegistryProgram(architecture.model,MP[publisher_models...],length_spec.model,count_spec.model,
        PI[initials...],organ_initial,G,scene.id::PlantId,PlantId[id::PlantId for id in scene.children],plant_ids,
        Symbol[specs[slot].name for slot in publisher_slots],publisher_plants,inverse,
        architecture.name,length_spec.name,count_spec.name,order,plant_order,constants)
end

function instantiate(program::RegistryProgram; retain=false)
    initials = map(program.plant_initials) do initial
        merge(initial,(_native_pse_state=clone_native_state(initial._native_pse_state),))
    end
    return _instantiate_owned(program,initials,retain)
end
function _instantiate_owned(program,initials,retain)
    SP=typeof(PSE.Status(first(initials))); SI=typeof(PSE.Status(program.organ_initial)); G=program.geometry_type
    TL=typeof(program.organ_initial.length); TR=typeof(first(initials).native_revision)
    TO=typeof(program.organ_initial.observed_length); TC=typeof(program.organ_initial.qualification_runs)
    n=length(initials); np=length(program.publishers)
    return RegistryState(program,PSE.Status(),SP[PSE.Status(initial) for initial in initials],
        [OrganId[] for _ in 1:n],Dict(id=>row for (row,id) in enumerate(program.plant_ids)),
        OrganId[],PlantId[],SI[],G[],BitVector(),Dict{OrganId,Int}(),[Int[] for _ in 1:n],Int[],falses(n),false,
        [OrganId[] for _ in 1:np],[PSE.RefVector(Base.RefValue{TL}[]) for _ in 1:np],
        Sample{PlantId,TR}[],[Sample{OrganId,TL}[] for _ in 1:np],Sample{OrganId,TO}[],Sample{OrganId,TC}[],
        0,Bool(retain),false,false,0,0,0,0)
end

# Population is runtime data, never a tuple arity or generated model type.
function instantiate(program::RegistryProgram,nplants::Int,increment::Float64,seed::UInt64;retain=false)
    nplants>0 && isfinite(increment) && increment>0 || throw(ArgumentError("positive population/increment required"))
    seed<=typemax(UInt64)-UInt64(nplants-1) || throw(ArgumentError("seed range overflow"))
    length(program.plant_ids)==1 && length(program.publishers)==1 || throw(ArgumentError("use the single-plant authored template"))
    ids=PlantId[PSE.ObjectId(nplants==1 ? :plant : Symbol("plant_",i)) for i in 1:nplants]
    base=first(program.plant_initials)
    initials=[merge(base,(_native_pse_state=clone_native_state(base._native_pse_state,ids[i],seed+UInt64(i-1)),
        development_increment=increment)) for i in 1:nplants]
    order=Instruction[]
    for instruction in program.order
        if instruction.role===:publisher
            append!(order,[Instruction(:publisher,i) for i in 1:nplants])
        else
            push!(order,instruction)
        end
    end
    names=Symbol[Symbol("native_properties_",i,"_Internode") for i in 1:nplants]
    expanded=RegistryProgram(program.architecture,fill(first(program.publishers),nplants),program.length_model,
        program.count_model,initials,program.organ_initial,program.geometry_type,program.scene_id,reverse(ids),ids,
        names,collect(1:nplants),collect(1:nplants),program.architecture_name,program.length_name,program.count_name,
        order,sortperm(ids;lt=PSE._object_id_isless),program.constants)
    return _instantiate_owned(expanded,initials,retain)
end

function contains_object(state::RegistryState,id::PlantId)
    return id==state.program.scene_id || haskey(state.plant_lookup,id)
end
contains_object(state::RegistryState,id::OrganId)=haskey(state.organ_lookup,id)
contains_object(state::RegistryState,id)=contains_object(state,PSE.ObjectId(id))
object_status(state::RegistryState,id::OrganId)=state.organ_statuses[state.organ_lookup[id]]
function object_status(state::RegistryState,id::PlantId)
    return id==state.program.scene_id ? state.scene_status : state.plant_statuses[state.plant_lookup[id]]
end
object_status(state::RegistryState,id)=object_status(state,PSE.ObjectId(id))
record_parent(state::RegistryState,id::OrganId)=state.organ_parents[state.organ_lookup[id]]
record_geometry(state::RegistryState,id::OrganId)=state.organ_geometry[state.organ_lookup[id]]

function register_record!(state::RegistryState{P,SP,SI,G},group::Symbol;
                          id::OrganId,parent::PlantId,geometry::G,initial::NamedTuple) where {P,SP,SI,G}
    group===IN_GROUP || throw(ArgumentError("unknown prepared registry group"))
    haskey(state.organ_lookup,id) && throw(ArgumentError("duplicate native organ identity"))
    haskey(state.plant_lookup,parent) || throw(ArgumentError("native organ parent is not a prepared plant"))
    keys(initial)==(:length,) && typeof(initial.length)===typeof(state.program.organ_initial.length) ||
        throw(ArgumentError("changed native property schema"))
    status=PSE.Status(merge(state.program.organ_initial,initial))::SI
    plant=state.plant_lookup[parent]
    push!(state.organ_ids,id);push!(state.organ_parents,parent);push!(state.organ_statuses,status)
    push!(state.organ_geometry,geometry);push!(state.organ_active,true)
    row=length(state.organ_ids);state.organ_lookup[id]=row
    push!(state.owned_rows[plant],row);push!(state.plant_children[plant],id)
    state.dirty_plants[plant]=true;state.membership_dirty=true;state.registered_count+=1
    return status
end
function reparent_record!(state::RegistryState,id::OrganId,parent::PlantId)
    row=state.organ_lookup[id];old=state.organ_parents[row]
    old==parent && return nothing
    haskey(state.plant_lookup,parent) || throw(ArgumentError("unknown native organ parent"))
    previous=state.plant_lookup[old];current=state.plant_lookup[parent]
    filter!(child->child!=id,state.plant_children[previous]);filter!(entry->entry!=row,state.owned_rows[previous])
    push!(state.plant_children[current],id);push!(state.owned_rows[current],row)
    state.organ_parents[row]=parent;state.dirty_plants[previous]=true;state.dirty_plants[current]=true
    state.membership_dirty=true
    return nothing
end
function update_geometry_record!(state::RegistryState{P,SP,SI,G},id::OrganId,geometry::G) where {P,SP,SI,G}
    state.organ_geometry[state.organ_lookup[id]]=geometry;state.geometry_updates+=1
    return nothing
end
function remove_record!(state::RegistryState,id::OrganId)
    row=state.organ_lookup[id];plant=state.plant_lookup[state.organ_parents[row]]
    state.organ_active[row]=false;delete!(state.organ_lookup,id)
    filter!(child->child!=id,state.plant_children[plant]);filter!(entry->entry!=row,state.owned_rows[plant])
    state.dirty_plants[plant]=true;state.membership_dirty=true;state.removed_count+=1
    return nothing
end

function _commit!(state::RegistryState{P,SP,SI,G,TL}) where {P,SP,SI,G,TL}
    state.membership_dirty || return nothing
    for plant in eachindex(state.dirty_plants)
        state.dirty_plants[plant] || continue
        rows=sort!(copy(state.owned_rows[plant]);by=row->state.organ_ids[row].value)
        publisher=state.program.plant_publishers[plant]
        state.output_ids[publisher]=OrganId[state.organ_ids[row] for row in rows]
        state.output_columns[publisher]=PSE.RefVector(Base.RefValue{TL}[PSE.refvalue(state.organ_statuses[row],:length) for row in rows])
        state.dirty_plants[plant]=false
    end
    state.committed_rows=sort!([row for row in eachindex(state.organ_ids) if state.organ_active[row]];
        by=row->state.organ_ids[row].value)
    state.membership_dirty=false
    return nothing
end
struct OutputTargets{C}
    columns::C
    ids::Vector{OrganId}
end
PSE.object_ids(targets::OutputTargets)=PSE.BoundManyObjectIds(targets.ids)
Base.length(targets::OutputTargets)=length(targets.ids)
Base.isempty(targets::OutputTargets)=isempty(targets.ids)
Base.eachindex(targets::OutputTargets)=eachindex(targets.ids)
function PSE.output_targets(context::Context,names::Tuple{Symbol})
    names===(:length,) || throw(ArgumentError("output port is outside the admitted publisher schema"))
    publisher=context.publisher
    publisher>0 || throw(ArgumentError("only the original property publisher owns distributed output targets"))
    return OutputTargets((length=context.owner.output_columns[publisher],),context.owner.output_ids[publisher])
end

function _architecture!(state)
    program=state.program
    for row in program.plant_order
        status=state.plant_statuses[row]
        PSE.run!(program.architecture,status,NamedTuple(),program.constants,Context(state,row,0))
        state.retain && push!(state.architecture_samples,Sample(program.plant_ids[row],state.step+1,status.native_revision))
    end
    return nothing
end
function _publisher!(state,index)
    program=state.program;row=program.publisher_plants[index]
    PSE.run!(program.publishers[index],state.plant_statuses[row],NamedTuple(),program.constants,Context(state,row,index))
    if state.retain
        for (id,value) in zip(state.output_ids[index],state.output_columns[index])
            push!(state.publisher_samples[index],Sample(id,state.step+1,value))
        end
    end
    return nothing
end
function _length!(state)
    program=state.program
    for row in state.committed_rows
        status=state.organ_statuses[row]
        PSE.run!(program.length_model,status,NamedTuple(),program.constants,Context(state,0,0))
        state.retain && push!(state.length_samples,Sample(state.organ_ids[row],state.step+1,status.observed_length))
    end
    return nothing
end
function _count!(state)
    program=state.program
    for row in state.committed_rows
        status=state.organ_statuses[row]
        PSE.run!(program.count_model,status,NamedTuple(),program.constants,Context(state,0,0))
        state.retain && push!(state.count_samples,Sample(state.organ_ids[row],state.step+1,status.qualification_runs))
        state.qualification_entries+=1
    end
    return nothing
end
function step!(state::RegistryState)
    state.failed && throw(ArgumentError("cannot retry a failed registry timeline"))
    state.in_step && throw(ArgumentError("registry execution cannot be reentered"))
    state.in_step=true
    try
        for instruction in state.program.order
            role=instruction.role
            if role===:architecture
                _architecture!(state)
            elseif role===:publisher
                _publisher!(state,instruction.index)
            elseif role===:length
                _length!(state)
            elseif role===:count
                _count!(state)
            else
                throw(ArgumentError("invalid prepared instruction"))
            end
            _commit!(state)
        end
        state.step+=1;state.in_step=false
    catch
        state.failed=true
        rethrow()
    end
    return state
end
function run!(state::RegistryState;steps::Integer=1)
    steps>=0 || throw(ArgumentError("negative registry step count"))
    for _ in 1:steps;step!(state);end
    return state
end
PSE.step!(state::RegistryState)=step!(state)
PSE.continue!(state::RegistryState;steps::Integer=1)=run!(state;steps)

# Public logical records are typed views over the same canonical references.
function PSE.model_object(state::RegistryState,id::PlantId)
    if id==state.program.scene_id
        return RegistryRecord(id,nothing,state.program.scene_children,state.scene_status,nothing,nothing,:scene,:Scene,nothing)
    end
    row=state.plant_lookup[id]
    return RegistryRecord(id,state.program.scene_id,state.plant_children[row],state.plant_statuses[row],nothing,nothing,:plant,:Plant,nothing)
end
function PSE.model_object(state::RegistryState,id::OrganId)
    row=state.organ_lookup[id]
    return RegistryRecord(id,state.organ_parents[row],OrganId[],state.organ_statuses[row],state.organ_geometry[row],nothing,:internode,:IN,nothing)
end
PSE.model_object(state::RegistryState,id)=PSE.model_object(state,PSE.ObjectId(id))
PSE.model_status(state::RegistryState,id)=object_status(state,id)
PSE.geometry(record::RegistryRecord)=record.geometry
PSE.geometry(state::RegistryState,id::OrganId)=record_geometry(state,id)
PSE.reparent_object!(state::RegistryState,id::OrganId,parent::PlantId)=reparent_record!(state,id,parent)
PSE.update_geometry!(state::RegistryState,id::OrganId,geometry)=update_geometry_record!(state,id,geometry)
PSE.remove_object!(state::RegistryState,id::OrganId;recursive=true)=remove_record!(state,id)
function PSE.model_objects(state::RegistryState;scale=nothing,kind=nothing,species=nothing,id=nothing)
    ids=Id[state.program.scene_id;state.program.plant_ids;collect(keys(state.organ_lookup))]
    sort!(ids;lt=PSE._object_id_isless)
    records=[PSE.model_object(state,key) for key in ids]
    return filter(record->(isnothing(scale)||record.scale==scale) &&
        (isnothing(kind)||record.kind==kind) && (isnothing(species)||record.species==species) &&
        (isnothing(id)||record.id==PSE.ObjectId(id)),records)
end
PSE.object_ids(state::RegistryState;kwargs...)=[record.id for record in PSE.model_objects(state;kwargs...)]

# Host-only stream projection for the same public PSE history interface. Native
# execution above owns concrete vectors and does not construct this dictionary.
function _history_rows!(result,name,var,samples)
    for sample in samples
        key=(name,sample.id,var)
        values=get!(result,key,Tuple{Float64,typeof(sample.value)}[])
        push!(values,(Float64(sample.step),sample.value))
    end
    return nothing
end
function PSE.outputs(state::RegistryState)
    result=Dict{Tuple{Symbol,PSE.ObjectId,Symbol},Any}()
    if state.retain
        for id in state.program.plant_ids
            result[(state.program.architecture_name,id,:native_revision)]=Tuple{Float64,typeof(state.plant_statuses[1].native_revision)}[]
        end
    end
    _history_rows!(result,state.program.architecture_name,:native_revision,state.architecture_samples)
    for index in eachindex(state.publisher_samples)
        _history_rows!(result,state.program.publisher_names[index],:length,state.publisher_samples[index])
    end
    _history_rows!(result,state.program.length_name,:observed_length,state.length_samples)
    _history_rows!(result,state.program.count_name,:qualification_runs,state.count_samples)
    return result
end

end # module ObjectPrograms
