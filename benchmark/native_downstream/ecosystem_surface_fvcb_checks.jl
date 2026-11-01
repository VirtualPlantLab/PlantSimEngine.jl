module EcosystemSurfaceFvcbChecks

using Dates, SHA, Test, PlantSimEngine
const PSE=PlantSimEngine
const Q=Main.CoupledQualification
const Physiology=Q.Physiology
const PB=Q.PlantBiophysics
const PATCHED_ADAPTER_SHA256="a25626153820febae6938a2a6db5af6f7b52d672194f5acd54cbd308cf72b28a"

export reload_surface_fvcb_methods!,surface_fvcb_checks

"""Reload exactly the two repaired wrapper methods, never module/type definitions.

The method expressions are parsed directly from the hash-pinned frozen adapter
source. Positive-area delegation therefore comes from that original scientific
adapter body, rather than a separately transcribed equation or replacement PB
kernel. Call explicitly through Kaimon before the focused gates.
"""
function reload_surface_fvcb_methods!()
    path=joinpath(Q.AMAP_ROOT,"dev","native","pse_physiology.jl")
    source=read(path,String)
    bytes2hex(sha256(source))==PATCHED_ADAPTER_SHA256 ||
        error("Frozen adapter differs from the approved SurfaceFvcb repair")
    output_lines=collect(eachmatch(r"(?m)^PSE\.outputs_\(::SurfaceFvcb\) =[^\n]+$",source))
    run_starts=collect(eachmatch(r"(?m)^function PSE\.run!\(model::SurfaceFvcb,",source))
    length(output_lines)==length(run_starts)==1 || error("Expected exactly one declaration and wrapper kernel")
    declaration=Meta.parse(only(output_lines).match)
    kernel,_=Meta.parse(source,only(run_starts).offset;raise=true)
    Meta.isexpr(declaration,:(=)) && Meta.isexpr(kernel,:function) || error("Unexpected wrapper expression shape")
    Core.eval(Physiology,declaration)
    Core.eval(Physiology,kernel)
    return (source=path,sha256=PATCHED_ADAPTER_SHA256,
        reloaded_methods=(:SurfaceFvcb_outputs_,:SurfaceFvcb_run!),
        reloaded_type_definitions=0,
        scope=:frozen_adapter_compatibility_repair_identical_for_all_comparison_arms)
end

function _fixture(model)
    object=PSE.Object(:unit;status=(aPPFD=900.0,Tₗ=25.0,Cₛ=400.0,
        Dₗ=1.0,area_m2=1.0))
    return PSE.CompositeModel(object;applications=(
        PSE.ModelSpec(model;name=:photosynthesis,on=PSE.One(id=:unit),
            calls=(stomatal_conductance=PSE.One(within=PSE.Self(),
                application=:stomatal_conductance),)),
        PSE.ModelSpec(PB.Medlyn(0.03,12.0);name=:stomatal_conductance,
            on=PSE.One(id=:unit)),),environment=(duration=Hour(1),))
end
_history(simulation)=[(key=key,samples=collect(stream)) for (key,stream) in
    sort!(collect(pairs(PSE.outputs(simulation)));by=pair->repr(first(pair)))]
function _pb_hashes()
    return [(path=relative,sha256=bytes2hex(sha256(read(joinpath(Q.PB_ROOT,relative)))))
        for relative in ("src/processes/photosynthesis/Fvcb.jl",
            "src/processes/conductances/stomatal/medlyn.jl")]
end

"""Validate the complete port contract, zero-area clearing, and original PB physics.

This repair applies to every arm, including the ordinary oracle. It receives no
candidate speedup credit. The positive-area pair uses independent ordinary PSE
timelines: original Fvcb/Medlyn versus SurfaceFvcb delegating to those methods.
"""
function surface_fvcb_checks()
    before=_pb_hashes()
    original=PB.Fvcb(VcMaxRef=80.0,JMaxRef=140.0,RdRef=1.0)
    wrapper=Physiology.SurfaceFvcb(original)
    @testset "Frozen SurfaceFvcb declares and clears the inherited water-conductance output" begin
        @test keys(PSE.outputs_(wrapper))==keys(PSE.outputs_(original))
        contracts=PSE.variable_contracts(wrapper)
        @test contracts.Gₗw==PSE.variable_contracts(original).Gₗw
        @test contracts.Gₛ==PSE.variable_contracts(original).Gₛ
        @test :area_m2 in keys(PSE.inputs_(wrapper))
        status=PSE.Status(area_m2=0.0,A=11.0,Gₛ=12.0,Gₗw=13.0,Cᵢ=14.0)
        Base.invokelatest(PSE.run!,wrapper,status,NamedTuple(),PSE.PlantMeteo.Constants(),nothing)
        @test status.Gₗw===0.0
        @test status.Gₛ===0.0
        @test status.A===0.0
        @test status.Cᵢ===0.0
        reference=Base.invokelatest(PSE.run!,_fixture(original);steps=1,outputs=:all)
        candidate=Base.invokelatest(PSE.run!,_fixture(wrapper);steps=1,outputs=:all)
        @test isequal(PSE.final_state(reference,:unit),PSE.final_state(candidate,:unit))
        @test isequal(_history(reference),_history(candidate))
        @test PSE.model_status(candidate.model,:unit).A>0
        @test PSE.model_status(candidate.model,:unit).Gₗw>0
        @test _pb_hashes()==before
    end
    return (;passed=true,adapter_sha256=PATCHED_ADAPTER_SHA256,
        original_PB_source_hashes=before,
        scope=:complete_wrapper_contract_zero_area_and_exact_positive_area_Fvcb_Medlyn,
        compatibility_repair_for_all_arms=true,benchmark_claim=false)
end

end # module
