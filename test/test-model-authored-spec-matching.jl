module AuthoredSpecMatchChecks

using Test, PlantSimEngine
const PSE=PlantSimEngine
PSE.@process "authored_spec_match" verbose=false
struct MatchModel{P,R,G} <: AbstractAuthored_Spec_MatchModel
    parameters::P
    declaration_reads::R
    parameter_getters::G
end
function Base.getproperty(model::MatchModel,name::Symbol)
    name===:parameters && (getfield(model,:parameter_getters)[]+=1)
    return getfield(model,name)
end
PSE.inputs_(::MatchModel)=NamedTuple()
function PSE.outputs_(model::MatchModel)
    getfield(model,:declaration_reads)[]+=1
    return (x=0f0,)
end
PSE.run!(::MatchModel,status,environment,constants,context)=nothing
function fixture(count=40)
    reads=Ref(0);getters=Ref(0)
    # Different large immutable layouts expose tuple headers escaping through
    # heterogeneous iteration, as encountered in real downstream models.
    specs=Any[ModelSpec(MatchModel(ntuple(Float64,512+(index%8)),reads,getters);
        name=Symbol(:app_,index),on=Many(scale=:Leaf),output_routing=(x=:stream_only,))
        for index in 1:count]
    model=CompositeModel(Object(:leaf;scale=:Leaf,status=Status(seed=1f0));applications=specs)
    return (;model,reads,getters)
end
function cached_matches!(model,count)
    for _ in 1:count
        preparation=PSE._scenario_preparation(model)
        PSE._validate_authored_scenario(preparation)
    end
    return nothing
end

@testset "Heterogeneous live authoring declarations" begin
    data=fixture();model=data.model
    preparation=model.scenario_plan_cache
    reads=data.reads[];getters=data.getters[]
    @test length(unique(typeof(spec) for spec in model.applications))==8
    @test PSE._authored_specs_match(preparation,model)
    cached_matches!(model,100)
    cached_matches!(model,100)
    bytes=@allocated cached_matches!(model,100)
    @test bytes==0
    @test data.reads[]==reads
    @test data.getters[]==getters
    @test model.scenario_plan_cache===preparation
    @test model_status(model,:leaf).seed===1f0

    first_spec=model.applications[1]
    replacement=ModelSpec(MatchModel(ntuple(Float64,520),data.reads,data.getters);
        name=:app_1,on=Many(scale=:Leaf),output_routing=(x=:stream_only,))
    before_reads=data.reads[];before_getters=data.getters[]
    model.applications[1]=replacement
    @test !PSE._authored_specs_match(preparation,model)
    @test data.reads[]==before_reads && data.getters[]==before_getters
    model.applications[1]=first_spec
    @test PSE._authored_specs_match(preparation,model)
    same_type_replacement=ModelSpec(MatchModel(ntuple(i->Float64(i)+1,513),data.reads,data.getters);
        name=:app_1,on=Many(scale=:Leaf),output_routing=(x=:stream_only,))
    @test typeof(same_type_replacement)===typeof(first_spec)
    model.applications[1]=same_type_replacement
    @test !PSE._authored_specs_match(preparation,model)
    model.applications[1]=first_spec
    @test PSE._authored_specs_match(preparation,model)
    reverse!(model.applications)
    @test !PSE._authored_specs_match(preparation,model)
    reverse!(model.applications)
    push!(model.applications,first_spec)
    @test !PSE._authored_specs_match(preparation,model)
    pop!(model.applications)
    @test PSE._authored_specs_match(preparation,model)

    # A real changed declaration must rebuild; the new spec then matches live.
    model.applications[1]=replacement
    refreshed=PSE._scenario_preparation(model)
    @test refreshed!==preparation
    @test PSE._authored_specs_match(refreshed,model)
    before_force=data.reads[]
    forced=PSE._scenario_preparation(model;force=true)
    @test forced!==refreshed
    @test data.reads[]>before_force
    @test PSE._authored_specs_match(forced,model)
    @test model_status(model,:leaf).seed===1f0
end

@testset "Authoring owner reconstruction and independent copy" begin
    data=fixture(8);original=data.model
    preparation=original.scenario_plan_cache
    old_snapshot=PSE._prepare_scenario_plan(original)
    @test preparation.resolved===old_snapshot
    other=CompositeModel(Object(:leaf;scale=:Leaf,status=Status(seed=1f0));
        applications=copy(original.applications))
    before=data.reads[];before_getters=data.getters[]
    other.scenario_plan_cache=preparation
    owned=PSE._scenario_preparation(other)
    @test owned!==preparation
    @test owned.owner===other
    @test owned.resolved===nothing
    @test PSE._authored_specs_match(owned,other)
    @test data.reads[]==before && data.getters[]==before_getters
    @test original.scenario_plan_cache===preparation
    @test preparation.owner===original
    @test preparation.resolved===old_snapshot
    copied=deepcopy(original)
    copied_owner=PSE._scenario_preparation(copied)
    @test copied_owner.owner===copied
    @test copied_owner!==preparation
    @test PSE._authored_specs_match(copied_owner,copied)
    copied.applications[1]=copied.applications[2]
    @test !PSE._authored_specs_match(copied_owner,copied)
    @test PSE._authored_specs_match(preparation,original)
end

@testset "Empty authoring declarations" begin
    model=CompositeModel(Object(:empty;status=Status(seed=1)))
    @test PSE._authored_specs_match(PSE._scenario_preparation(model),model)
end

end
