module NewbornFreshDistributedChecks

using Dates, Test, PlantSimEngine
const PSE=PlantSimEngine
const NP=Main.NewbornPreparation
const Checks=Main.NewbornPreparationChecks
const DistributedChecks=Main.NewbornDistributedChecks

export newborn_fresh_distributed_probe, newborn_fresh_distributed_checks

struct FreshDistributedCreator <: Checks.AbstractPreparation_CreatorModel end
PSE.inputs_(::FreshDistributedCreator)=NamedTuple()
PSE.outputs_(::FreshDistributedCreator)=(created=0,)

_distributed_owners(::PSE.NoCompiledDistributedOutputs,id)=0
function _distributed_owners(outputs::PSE.CompiledDistributedOutputs,id)
    return count(owner->owner.kind===:output_destination,
        get(outputs.writer_ownership,(PSE.ObjectId(id),:distributed_signal),()))
end

function PSE.run!(::FreshDistributedCreator,status,environment,constants,context)
    status.created==0 || return nothing
    model=PSE.runtime_model(context)
    newborn=PSE.register_object!(model,PSE.Object(10;
        kind=:preparation_unit,parent=0,status=(distributed_signal=3.0f0,)))
    # The user initialized this cell before the distributed destination index
    # knows the newborn. Targeted from_status preparation can safely capture
    # the logical carrier, but the later ordinary refresh must reject reuse.
    cell=PSE.refvalue(PSE.model_status(model,10),:distributed_signal)
    push!(constants.cells,cell)
    before=_distributed_owners(context.compiled.distributed_outputs,10)
    PSE.run_call!(context,:probe;objects=newborn,publish=false)
    after=_distributed_owners(context.compiled.distributed_outputs,10)
    preparation=NP.newborn_preparation_report(model)
    push!(constants.facts,(owners_before=before,owners_after=after,
        captured_bindings=preparation.captured_bindings,
        promoted_bindings=preparation.promoted_bindings,
        observed=PSE.model_status(model,10).total))
    status.created+=1
    return nothing
end

function _fixture()
    return PSE.CompositeModel(
        PSE.Object(0),
        PSE.Object(1;kind=:preparation_unit,parent=0,
            status=(distributed_signal=0.0f0,));
        applications=(
            PSE.ModelSpec(DistributedChecks.PreparationDistributedWriter();
                name=:distributed_writer,on=PSE.One(id=0),every=Hour(1),
                outputs_to=(PSE.OutputTo(PSE.Many(kind=:preparation_unit,
                    within=PSE.Subtree());vars=(:distributed_signal,)),)),
            PSE.ModelSpec(FreshDistributedCreator();name=:creator,
                on=PSE.One(id=0),every=Hour(1),calls=(
                    probe=PSE.Many(kind=:preparation_unit,within=PSE.Subtree(),
                        application=:probe),)),
            PSE.ModelSpec(Checks.PreparationProbe();name=:probe,
                on=PSE.Many(kind=:preparation_unit),every=Hour(1),inputs=(
                    signals=PSE.Many(within=PSE.Self(),var=:distributed_signal,
                        from_status=true),)),
        ),environment=PSE.Status(T=10.0f0,duration=Hour(1)))
end

function newborn_fresh_distributed_probe(;outputs=:all)
    left,right=(cells=Any[],facts=Any[],),(cells=Any[],facts=Any[],)
    reference=PSE.run!(_fixture();steps=0,outputs,constants=left)
    candidate=NP.prepare_newborn(_fixture();steps=0,outputs,constants=right)
    initial_same=isequal(Checks._snapshot(candidate),Checks._snapshot(reference))
    PSE.step!(reference);PSE.step!(candidate)
    first_same=isequal(Checks._snapshot(candidate),Checks._snapshot(reference))
    report_after_refresh=NP.newborn_preparation_report(candidate)
    left_fact,right_fact=only(left.facts),only(right.facts)
    left_cell,right_cell=only(left.cells),only(right.cells)
    first_value=right_cell[]
    owners_after_refresh=_distributed_owners(candidate.compiled.distributed_outputs,10)
    binding=only(candidate.compiled.input_bindings_by_target[(:probe,PSE.ObjectId(10))])
    aligned_refs=isempty(binding.source_application_ids) &&
        binding.source_ids==[PSE.ObjectId(10)] &&
        only(parent(binding.carrier))===right_cell
    live_after_refresh=PSE.refvalue(PSE.model_status(candidate.model,10),
        :distributed_signal)===right_cell
    PSE.step!(reference);PSE.step!(candidate)
    return (;outputs,initial_same,first_same,left_fact,right_fact,first_value,
        report_after_refresh,owners_after_refresh,aligned_refs,live_after_refresh,
        final_same=isequal(Checks._snapshot(candidate),Checks._snapshot(reference)),
        reference_cell_live=PSE.refvalue(PSE.model_status(reference.model,10),
            :distributed_signal)===left_cell,
        candidate_cell_live=PSE.refvalue(PSE.model_status(candidate.model,10),
            :distributed_signal)===right_cell,
        reference_final_value=left_cell[],candidate_final_value=right_cell[],
        report=NP.newborn_preparation_report(candidate))
end

function newborn_fresh_distributed_checks()
    reports=Any[]
    @testset "Newborn from_status capture rejects newly refreshed distributed ownership" begin
        for outputs in (:none,:all)
            result=newborn_fresh_distributed_probe(;outputs)
            @test result.initial_same
            @test result.first_same
            @test result.left_fact.owners_before==result.left_fact.owners_after==0
            @test result.right_fact.owners_before==result.right_fact.owners_after==0
            @test result.right_fact.captured_bindings>0
            @test result.right_fact.promoted_bindings==0
            @test result.left_fact.observed===result.right_fact.observed===3.0f0
            @test result.report_after_refresh.captured_bindings>0
            @test result.report_after_refresh.promotion_attempts>0
            @test get(result.report_after_refresh.misses,:distributed_source_owner,0)>0
            @test !haskey(result.report_after_refresh.capture_rejections,
                :capture_distributed_source_owner)
            @test result.report_after_refresh.promoted_targets==0
            @test result.report_after_refresh.promoted_bindings==0
            @test result.owners_after_refresh==1
            @test result.first_value===3.0f0
            @test result.aligned_refs
            @test result.live_after_refresh
            @test result.final_same
            @test result.reference_cell_live
            @test result.candidate_cell_live
            @test result.reference_final_value===result.candidate_final_value===7.0f0
            @test result.report.promoted_bindings==0
            push!(reports,result)
        end
    end
    return (;passed=true,reports,
        oracle=:ordinary_full_state_history_and_newborn_canonical_ref_across_writer_refresh)
end

end
