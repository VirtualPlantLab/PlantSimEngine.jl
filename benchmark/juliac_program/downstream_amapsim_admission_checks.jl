module DownstreamAMAPSimAdmissionChecks
using Test
import ..DownstreamAMAPSimChecks as C
const F=C.TF;const OP=C.OP;const PSE=C.PSE
function _replace_spec!(fixture,name;on=nothing,inputs=nothing)
    index=only(findall(spec->spec.name===name,fixture.model.applications))
    old=fixture.model.applications[index]
    fixture.model.applications[index]=PSE.ModelSpec(old.model;name=old.name,
        on=isnothing(on) ? old.applies_to : on,inputs=isnothing(inputs) ? old.inputs : inputs,
        outputs_to=old.outputs_to)
    return fixture
end
function run_checks()
    cfg=F.config(nplants=1,steps=2)
    result=@testset "Bounded AMAP admission" begin
        f=F.construct(cfg)
        @test OP.prepare(f.model) isa OP.RegistryProgram
        f=F.construct(cfg)
        _replace_spec!(f,:length_probe;on=PSE.Many(scale=:IN,id=PSE.ObjectId((:plant,:Internode,1))))
        @test_throws ArgumentError OP.prepare(f.model)
        f=F.construct(cfg)
        _replace_spec!(f,:qualification_count;on=PSE.Many(scale=:IN,id=PSE.ObjectId((:plant,:Internode,1))))
        @test_throws ArgumentError OP.prepare(f.model)
        f=F.construct(cfg)
        _replace_spec!(f,:qualification_count;inputs=(observed_length=PSE.One(within=PSE.Self(),
            scale=:unmatched,application=:length_probe,var=:observed_length),))
        @test_throws ArgumentError OP.prepare(f.model)
        f=F.construct(cfg)
        envmodel=PSE.CompositeModel(PSE.model_objects(f.model)...;applications=f.applications,environment=NamedTuple())
        @test_throws ArgumentError OP.prepare(envmodel)
        f=F.construct(cfg);plant=PSE.model_object(f.model,:plant)
        plant.status=PSE.Status(merge(NamedTuple(plant.status),(unsupported_values=[1.0],)))
        @test_throws ArgumentError OP.prepare(f.model)
        f=F.construct(cfg);plant=PSE.model_object(f.model,:plant)
        plant.status=PSE.Status(merge(NamedTuple(plant.status),(native_revision=99,)))
        @test_throws ArgumentError OP.prepare(f.model)
        f=F.construct(cfg)
        F.Native.advance_to!(F.Adapter.native_state(f.model,:plant).native,.5;geometry=true)
        @test_throws ArgumentError OP.prepare(f.model)
        f=F.construct(cfg)
        F.Adapter.native_state(f.model,:plant).native.plant.rng.draws+=1
        @test_throws ArgumentError OP.prepare(f.model)
        for profile in (:branch46,:merisier)
            input=profile===:branch46 ? joinpath(F.ROOT,"test","fixtures","native_arena","branch46.fpa") :
                joinpath(F.ROOT,"test","fixtures","native_originals","merisier.fpa")
            @test C.check_case(nplants=1,steps=2,outputs=:all,input=input).steps==2
        end
    end
    return (passes=result.n_passed,failures=length(result.results))
end
end
