module DirectPlannerFixtures

using Dates, PlantSimEngine
const PSE=PlantSimEngine
const PB=Main.NativePBDriver
const XP=Main.NativeXPDriver
const CR=Main.CompiledRegionsExperiment
# Definitions/helpers only: no future catalogue modules or discovery are loaded.
isdefined(Main,:FutureLayoutFixtures) ||
    Base.include(Main,joinpath(@__DIR__,"future_layout_fixtures.jl"))
const Helpers=Main.FutureLayoutFixtures

export construct_fixture, snapshot, scientific_rngs, identities, same_identity_transitions

PSE.@process "direct_growth_pulse" verbose=false
PSE.@process "direct_growth_source" verbose=false
PSE.@process "direct_growth_collect" verbose=false
struct GrowthPulse <: AbstractDirect_Growth_PulseModel
    count::Int
    first_id::Int
end
struct GrowthSource <: AbstractDirect_Growth_SourceModel end
struct GrowthCollect <: AbstractDirect_Growth_CollectModel end
PSE.inputs_(::GrowthPulse)=NamedTuple()
PSE.outputs_(::GrowthPulse)=(created=0,)
PSE.inputs_(::GrowthSource)=NamedTuple()
PSE.outputs_(::GrowthSource)=(signal=0.0f0,visits=0)
PSE.inputs_(::GrowthCollect)=(signals=PSE.Required(Vector{Float32}),)
PSE.outputs_(::GrowthCollect)=(total=0.0f0,seen_ids=PSE.ObjectId[],seen_values=Float32[])
_unit(id)=PSE.Object(id;kind=:direct_growth_unit,parent=0,
    status=(signal=0.0f0,visits=0))
function PSE.run!(model::GrowthPulse,status,environment,constants,context)
    iszero(status.created) || return nothing
    for offset in 0:(model.count-1)
        PSE.register_object!(PSE.runtime_model(context),_unit(model.first_id+offset))
    end
    status.created=model.count
    return nothing
end
function PSE.run!(::GrowthSource,status,environment,constants,context)
    status.signal+=1.0f0
    status.visits+=1
    return nothing
end
function PSE.run!(::GrowthCollect,status,environment,constants,context)
    values=PSE.bound_input(context,:signals)
    status.total=sum(values;init=0.0f0)
    status.seen_ids=collect(PSE.object_ids(values))
    status.seen_values=collect(values)
    return nothing
end

Base.@nospecializeinfer @noinline function _generic_fixture(config)
    nobjects=config.nobjects
    model=PSE.CompositeModel(PSE.Object(0),(_unit(id) for id in 1:nobjects)...;
        applications=(
            PSE.ModelSpec(GrowthPulse(config.additions,nobjects+1);name=:create,
                on=PSE.One(id=0),every=Hour(1)),
            PSE.ModelSpec(GrowthSource();name=:source,
                on=PSE.Many(kind=:direct_growth_unit),every=Hour(1)),
            PSE.ModelSpec(GrowthCollect();name=:collect,on=PSE.One(id=0),every=Hour(1),
                inputs=(signals=PSE.Many(kind=:direct_growth_unit,within=PSE.SceneScope(),
                    application=:source,var=:signal),)),
        ),environment=(duration=Hour(1),))
    return (;model,initial_ids=collect(PSE.object_ids(model)),package=:generic)
end

Base.@nospecializeinfer @noinline function construct_fixture(kind::Symbol,config;weather=nothing)
    @nospecialize config weather
    if kind===:pb
        fixture=Base.invokelatest(PB.pb_native_fixture;native=false,
            nobjects=config.nobjects,steps=config.steps)
        return (;fixture...,initial_ids=collect(PSE.object_ids(fixture.model)),package=:pb)
    elseif kind===:xp
        model=Base.invokelatest(XP.xpalm_native_fixture;native=false,steps=config.steps,
            seed=config.seed,emission_speed=config.emission_speed,weather)
        return (;model,initial_ids=collect(PSE.object_ids(model)),package=:xp)
    elseif kind===:generic
        return Base.invokelatest(_generic_fixture,config)
    end
    throw(ArgumentError("Expected :pb, :xp or :generic"))
end

snapshot(simulation,kind)=Helpers.portable_snapshot(simulation;kind)
scientific_rngs(model)=Helpers.model_rng_fingerprint(model)

Base.@nospecializeinfer @noinline function identities(model)
    @nospecialize model
    statuses=Dict{Any,Any}()
    references=Dict{Any,Any}()
    for object in PSE.model_objects(model)
        statuses[object.id]=object.status
        for name in propertynames(object.status)
            references[(object.id,name)]=PSE.refvalue(object.status,name)
        end
    end
    return (;statuses,references)
end
function same_identity_transitions(old_left,old_right,new_left,new_right)
    keys(new_left.statuses)==keys(new_right.statuses) || return false
    keys(new_left.references)==keys(new_right.references) || return false
    for key in intersect(keys(old_left.statuses),keys(new_left.statuses))
        (old_left.statuses[key]===new_left.statuses[key])===
            (old_right.statuses[key]===new_right.statuses[key]) || return false
    end
    for key in intersect(keys(old_left.references),keys(new_left.references))
        (old_left.references[key]===new_left.references[key])===
            (old_right.references[key]===new_right.references[key]) || return false
    end
    return true
end

end # module
