module PersistentTargetlessChecks
using Test, PlantSimEngine
const PSE=PlantSimEngine
const C=Main.PersistentTightChecks
const PT=Main.PersistentTightProgram
const F=Main.DirectPlannerFixtures

export persistent_targetless_checks
function _fixture()
    model=C.persistent_fixture(;removal=false)
    PSE.remove_object!(model,1)
    PSE.remove_object!(model,2)
    return model
end
"""A known application with zero targets becomes typed after its first birth."""
function persistent_targetless_checks()
    left,right=C._constants(),C._constants()
    reference=C._prepare(_fixture(),left;outputs=:all)
    candidate=C._prepare(_fixture(),right;candidate=true,outputs=:all)
    phases=Any[]
    @testset "Initially targetless application receives actual typed newborn work" begin
        initial=PT.persistent_regions(candidate)
        @test all(row->row.application!==:root,initial)
        stable=only(row for row in initial if row.application===:stable_root)
        previous=PT.persistent_tight_report(candidate)
        for tick in 1:3
            if tick==3
                PSE.remove_object!(reference.model,3)
                PSE.remove_object!(candidate.model,3)
            end
            C._step_pair!(reference,candidate,left,right,tick)
            current=PT.persistent_tight_report(candidate)
            @test current.executed_numerical_roots-previous.executed_numerical_roots==(tick==2 ? 2 : 1)
            @test current.executed_numerical_calls-previous.executed_numerical_calls==(tick==2 ? 2 : 1)
            regions=PT.persistent_regions(candidate)
            @test only(row for row in regions if row.application===:stable_root).identity===stable.identity
            if tick==2
                newborn=only(row for row in regions if row.application===:root)
                @test newborn.active
                @test newborn.last_execution_ids==[PSE.ObjectId(3)]
                @test newborn.last_execution_model_revision==candidate.compiled.revision
                @test newborn.numerical_signature===stable.numerical_signature
            end
            push!(phases,(;tick,report=current))
            previous=current
        end
    end
    return (passed=true,phases,
        scope=:zero_target_known_application_with_existing_scheduled_controller,
        signature_scope=:exact_numeric_entry_types_not_a_codecache_or_zero_JIT_claim)
end
end
