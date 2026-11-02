isdefined(@__MODULE__,:DownstreamMAESPAFixture) || include(joinpath(@__DIR__,"downstream_maespa_fixture.jl"))
isdefined(@__MODULE__,:RegistryPrograms) || include(joinpath(@__DIR__,"app","src","registry_program.jl"))

module DownstreamMAESPARegistry
import ..DownstreamMAESPAFixture as Fixture
import ..RegistryPrograms as Registry
const PSE=Fixture.PSE

function _objects(state)
    return sort!(collect(Registry.object_records(state));by=object->repr(object.id.value))
end
function _rngs(state,fixture)
    rows=Any[]; seen=IdDict{Any,Nothing}()
    for (index,spec) in enumerate(fixture.model.applications)
        _,family,row=state.applications[index]
        Fixture._rngs!(rows,seen,state.groups[family].targets[row].model,"application[$index].$(spec.name)")
    end
    Fixture._rngs!(rows,seen,fixture.target_rng,"construction.target_rng")
    Fixture._rngs!(rows,seen,fixture.meteorology_rng,"construction.meteorology_rng")
    return rows
end

"""Materialize the same public observation schema as the ordinary baseline.
The observation adapter is outside the measured compiled runtime.
"""
function snapshot(state,fixture)
    objects=_objects(state)
    canonical=Fixture.canonical
    states=[(object_id=canonical(object.id.value),status=canonical(NamedTuple(object.status))) for object in objects]
    topology=[(object_id=canonical(object.id.value),parent=canonical(object.metadata.parent),
        children=canonical(PSE.ObjectId[id for id in object.metadata.children]),
        scale=object.metadata.scale,kind=object.metadata.kind,species=object.metadata.species,
        geometry=canonical(object.metadata.geometry)) for object in objects]
    history=sort!([(key=canonical(record.key),samples=[(time=canonical(first(sample)),value=canonical(last(sample)))
        for sample in record.samples]) for record in Registry.output_records(state)];by=row->repr(row.key))
    return (step=state.step,states,topology,history,
        committed_canopy=canonical(state.environment.canopy),scientific_rngs=_rngs(state,fixture))
end
function witness(state)
    objects=_objects(state)
    scales=Dict{Symbol,Int}(); crowns=NamedTuple[]
    for object in objects
        category=isnothing(object.metadata.scale) ? :none : object.metadata.scale
        scales[category]=get(scales,category,0)+1
        category===:Crown || continue
        status=object.status
        push!(crowns,(object_id=object.id.value,
            active=count(identity,status.logical_leaf_unit_active),
            accepted=count(identity,status.non_tuzet_logical_leaf_exchange_available),
            trials=sum(status.non_tuzet_logical_leaf_temperature_trial_count),
            mask_matches=isequal(status.logical_leaf_unit_active,status.non_tuzet_logical_leaf_exchange_available),
            aggregation_available=status.crown_leaf_exchange_aggregation_available,
            controller_available=status.non_tuzet_crown_leaf_exchange_controller_available,
            assimilation=status.net_assimilation_crown_umol_co2_s,
            temperature=status.mean_leaf_temperature_crown_c))
    end
    soil=only(filter(object->object.id==PSE.ObjectId(:soil),objects)).status
    return (step=state.step,objects=length(objects),applications=length(state.applications),
        scales,crowns=sort!(crowns;by=row->repr(row.object_id)),
        active=sum(row.active for row in crowns;init=0),accepted=sum(row.accepted for row in crowns;init=0),
        trials=sum(row.trials for row in crowns;init=0),
        nonzero_assimilation=count(row->isfinite(row.assimilation)&&!iszero(row.assimilation),crowns),
        soil_available=soil.soil_water_balance_available,
        soil_storage=soil.soil_storage_after_m,soil_residual=soil.soil_water_mass_balance_residual_m)
end
function prepare(fixture)
    program=Registry.prepare(fixture.model;outputs=fixture.config.outputs,constants=fixture.constants)
    return Registry.instantiate(program)
end
candidate()=(kind=:full_compiled,prepare=prepare,advance=Registry.advance!,snapshot=snapshot,witness=witness)

"""Emit ordinary observations using the same explicit, concrete record schema.
Specializing the child-ID carrier is observational formatting only; the full
host parity gate separately compares its original public container type.
"""
function print_ordinary(simulation,io=Core.stdout)
    encoding=Registry.RegistryEncoding
    objects=collect(PSE.model_objects(simulation.model))
    encoding.encode_record(io,("F",PSE.current_step(simulation),length(simulation.model.applications),length(objects)))
    for object in objects
        encoding.encode_record(io,("T",object.id,object.parent,Registry._typed_ids(object.children),
            object.scale,object.kind,object.species,PSE.geometry(object)))
        status=PSE.final_state(simulation,object.id)
        for (name,value) in pairs(status)
            encoding.encode_record(io,("S",object.id,name,value))
        end
    end
    for ((application,id,variable),samples) in PSE.outputs(simulation)
        encoding.encode_record(io,("H",application,id,variable))
        for (time,value) in samples
            encoding.encode_record(io,("O",application,id,time,variable,value))
        end
    end
    encoding.encode_record(io,("E",simulation.model.environment.canopy))
    return nothing
end

end
