module CachedOwnerIdentityChecks

using Test, PlantSimEngine
const PSE=PlantSimEngine
const C=Main.PersistentTightChecks
const E=Main.PersistentFeatureChecks
const M=Main.CachedOwnerMeasurements

export cached_owner_identity_checks

"""Check retained identities against actual owners from the initial ordinary plan.

The original root/child owners are observed only by this cold diagnostic, before
the candidate is installed. A private step must still execute the typed driver.
Afterwards, metadata-only region diagnostics and intentional public exposure
must both return those exact owner objects. No report's static claim or internal
identity counter substitutes for these independent comparisons.
"""
function cached_owner_identity_checks(arm::Symbol;caches=M.new_caches())
    M.policies(arm).owner || throw(ArgumentError("Identity gate requires an owner-reuse arm"))
    constants=C._constants()
    simulation=PSE.run!(C.persistent_fixture(;birth=false,removal=false);
        steps=0,outputs=:all,constants)
    roots=Dict{Tuple{Symbol,PSE.ObjectId},Any}()
    children=Dict{Tuple{Symbol,PSE.ObjectId},Any}()
    for group in simulation.execution_plan.groups
        group.application.id in (:root,:stable_root) || continue
        for batch in group.batches, owner in batch.targets
            key=(group.application.id,owner.object_id)
            roots[key]=owner
            collection=E._raw_collection(owner,:child)
            children[key]=E._raw_child_owner(collection)
        end
    end
    Base.invokelatest(M.lower_candidate!,simulation,arm;caches,count_calls=true)
    @testset "Cold owner reuse retains actual ordinary owner identities: $arm" begin
        @test length(roots)==length(children)==3
        constants.tick[]=1
        Base.invokelatest(PSE.step!,simulation)
        report=M.candidate_report(simulation,arm)
        @test report.executed_numerical_roots==3
        @test report.executed_numerical_calls==3
        regions=M.candidate_regions(simulation,arm)
        checked_roots=0
        for region in regions
            @test region.active && !region.exposed
            @test length(region.retained_root_owners)==length(region.row_ids)
            for (id,owner) in zip(region.row_ids,region.retained_root_owners)
                @test owner===roots[(region.application,id)]
                checked_roots+=1
            end
        end
        @test checked_roots==3
        checked_children=0
        for group in simulation.execution_plan.groups
            group.application.id in (:root,:stable_root) || continue
            # Public indexing deliberately exposes these roots only now, after
            # the private execution and metadata-only identity checks.
            for batch in group.batches, owner in batch.targets
                key=(group.application.id,owner.object_id)
                @test owner===roots[key]
                collection=E._raw_collection(owner,:child)
                @test E._raw_child_owner(collection)===children[key]
                @test !owner.call_context_cache.in_use
                checked_children+=1
            end
        end
        @test checked_children==3
        return (;passed=true,arm,checked_roots,checked_children,
            report=M.candidate_report(simulation,arm),
            scope=:independent_original_root_and_per_call_site_child_object_identity)
    end
end

end # module
