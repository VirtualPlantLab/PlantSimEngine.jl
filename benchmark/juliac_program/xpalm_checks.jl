module XPalmChecks
using Test
using PlantSimEngine
import ..ReusableProgram as RP
import ..XPalmFixture as XF

function compare_case(program; n=1,offset=10,days=4,params=NamedTuple(),
                      initial=XF.initial(),rain=3.0,birth=false)
    ids = collect(offset+1:offset+n)
    models = XF.models(;params...)
    native = RP.instantiate(program,models,ids,fill(:soil,n);initial,retain=true)
    @test native.program === program
    @test map(r -> r.name,program.regions) == (:thermal_time,:soil_water)
    @test all(r -> r.rows === native.statuses,native.regions)
    @test native.regions[2].calls.root_growth.rows === native.statuses
    saved = [PlantSimEngine.refvalue(status,:root_depth) for status in native.statuses]
    forcing = XF.rows(days;rain)
    newborn_id = birth ? offset+n+1 : nothing
    ordinary = XF.ordinary(ids,forcing;params,initial,newborn_id,birth_after=1)
    for (i,row) in enumerate(forcing)
        RP.step!(native,row;constants=PlantSimEngine.Constants())
        if birth && i == 1
            RP.add_object!(native,newborn_id,:soil)
        end
    end
    @test isequal(XF.fingerprint(native.ids,native.statuses),XF.fingerprint(ordinary,native.ids))
    @test all(i -> saved[i] === PlantSimEngine.refvalue(native.statuses[i],:root_depth),eachindex(saved))
    for id in native.ids
        actual = [p.values.root_depth for p in native.publications if p.application === :root_growth && p.object_id == id]
        expected = [s.value for s in PlantSimEngine.collect_outputs(ordinary,ObjectId(id),:root_depth;sink=nothing)]
        @test isequal(actual,expected)
        @test length(actual) == (birth && id == newborn_id ? days-1 : days)
        # Every original model output's whole publication series is compared,
        # including parent/child call-time values, not just a scalar checksum.
        for spec in XF.specs(;params...), var in keys(PlantSimEngine.outputs_(spec))
            observed = [p.values[var] for p in native.publications if p.application === spec.name && p.object_id == id]
            reference = [s.value for s in PlantSimEngine.collect_outputs(ordinary,ObjectId(id),var;sink=nothing)]
            @test isequal(observed,reference)
        end
    end
    return (objects=length(native.ids),steps=native.step,
        initial_type=string(typeof(native)),root_depth=[s.root_depth for s in native.statuses])
end

function run_checks()
    summaries = NamedTuple[]
    result = @testset "Original XPalm soil/root program" begin
        program = RP.prepare(XF.specs();initial=XF.initial())
        reference_type = nothing
        for n in (0,1,4), offset in (10,1000), variant in (1,2)
            params = variant == 1 ? (initial_depth=300.0,root_rate=0.3) :
                (initial_depth=120.0,root_rate=0.7,soil_humidity=0.12)
            initial = XF.initial(;ET0=variant == 1 ? 2.5 : 4.0,aPPFD=variant == 1 ? 1.0 : 5.0)
            summary = compare_case(program;n,offset,params,initial,rain=variant == 1 ? 3.0 : 0.0)
            push!(summaries,summary)
            if isnothing(reference_type)
                reference_type = summary.initial_type
            end
            @test summary.initial_type == reference_type
        end
        for n in (0,1)
            push!(summaries,compare_case(program;n,birth=true))
        end
        @test_throws ArgumentError RP.instantiate(program,XF.models(),[1],[:soil])
        @test_throws ArgumentError RP.instantiate(program,XF.models(),[1],[:soil];initial=(ET0=2.5,aPPFD=1))
    end
    counts = Test.get_test_counts(result)
    return (passes=counts.passes+counts.cumulative_passes,
        fails=counts.fails+counts.cumulative_fails,errors=counts.errors+counts.cumulative_errors,
        cases=length(summaries))
end
function _advance!(state,forcing,constants)
    for row in forcing
        RP.step!(state,row;constants)
    end
    return nothing
end

"""Allocation diagnostic only: five warmed loops, no construction/retention/IO."""
function allocation_probe()
    program = RP.prepare(XF.specs();initial=XF.initial())
    state = RP.instantiate(program,XF.models(),collect(1:4),fill(:soil,4);initial=XF.initial())
    forcing = XF.rows(8)
    constants = PlantSimEngine.Constants()
    _advance!(state,forcing,constants)
    return [@allocated(_advance!(state,forcing,constants)) for _ in 1:5]
end

end
