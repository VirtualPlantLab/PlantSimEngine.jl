module GraphRowProjectionChecks

using Test, PlantSimEngine
const PSE = PlantSimEngine
const BP = Main.BoundedPreparation
const GRP = Main.GraphRowProjection
export graph_row_projection_checks

function _ordinary_rows(applications, relations, policy)
    return PSE._scenario_metadata_symbol_table(policy,
        (application.id for application in applications),
        (PSE._scenario_metadata_ids(policy,
            (application.id for application in applications
                if application.id in get(relations, parent.id, Set{Symbol}())))
            for parent in applications),
        (application.slot for application in applications))
end
_counts(value) = NamedTuple{fieldnames(typeof(value))}(Tuple(getfield(value, name)
    for name in fieldnames(typeof(value))))
function _enabled_policy()
    policy = BP.BoundedPolicy(BP.BoundedCounters())
    state = GRP.ProjectionState()
    GRP._enabled[policy.counts] = state
    return policy, state
end

function _compare(applications, relations; policy=nothing, state=nothing)
    if policy === nothing
        policy, state = _enabled_policy()
    end
    reference_policy = BP.BoundedPolicy(BP.BoundedCounters())
    old_factory = _counts(policy.counts)
    old_completions = state.counts.projections_completed
    old_rows = state.counts.rows_projected
    old_edges = state.counts.edges_projected
    expected = _ordinary_rows(applications, relations, reference_policy)
    actual = PSE._try_freeze_scenario_relation_rows(applications, relations, policy)
    @test actual !== nothing
    @test typeof(actual) === typeof(expected) === BP.BoundedSymbolTable
    @test collect(keys(actual)) == collect(keys(expected)) == [application.id for application in applications]
    @test collect(pairs(actual)) == collect(pairs(expected))
    @test collect(values(actual)) == collect(values(expected))
    for application in applications
        @test actual[application.id] == expected[application.id]
        @test PSE._application_plans(actual, application.slot) == expected[application.id]
        @test actual[application.id] isa Vector{Symbol}
        @test getproperty(actual, application.id) == expected[application.id]
    end
    after_factory = _counts(policy.counts)
    reference_factory = _counts(reference_policy.counts)
    for name in keys(reference_factory)
        # maximum is a high-water mark rather than an additive count.
        if name === :maximum_table_entries
            @test getproperty(after_factory,name) == max(getproperty(old_factory,name),length(applications))
        else
            @test getproperty(after_factory,name)-getproperty(old_factory,name) == getproperty(reference_factory,name)
        end
    end
    @test state.counts.projections_completed-old_completions == 1
    @test state.counts.rows_projected-old_rows == length(applications)
    @test state.counts.edges_projected-old_edges == sum(length, values(expected); init=0)
    return (; policy, state, table=actual)
end

mutable struct MutableApplication
    id::Symbol
    slot::Int
end

"""Cheap metadata-only parity: no scientific model, environment or kernel runs."""
function graph_row_projection_checks(; sizes=(0,1,4,8))
    cases = 0
    @testset "Projected relation rows retain original bounded metadata" begin
        for count in sizes
            applications = [(id=Symbol(:application_, index), slot=5*(count-index)+3)
                for index in 1:count]
            ids = [application.id for application in applications]
            for kind in (:empty, :sparse, :dense, :unknown)
                relations = Dict{Symbol,Set{Symbol}}()
                if kind === :dense
                    for id in ids
                        relations[id] = Set(ids)
                    end
                elseif kind in (:sparse, :unknown)
                    for (index,id) in pairs(ids)
                        relations[id] = Set((id, ids[mod1(index+1,length(ids))]))
                    end
                end
                if kind === :unknown
                    relations[:unknown_row] = Set(ids)
                    for id in ids
                        push!(relations[id], :unknown_neighbor)
                    end
                end
                checked = _compare(applications, relations)
                _compare(applications, relations; policy=checked.policy, state=checked.state)
                @test checked.state.counts.layouts_reused == 1
                cases += 1
            end
        end
        applications = [(id=:alpha,slot=9),(id=:beta,slot=3),(id=:gamma,slot=17)]
        relations = Dict(:alpha=>Set([:gamma,:alpha,:beta,:unknown]), :beta=>Set([:alpha]))
        checked = _compare(applications, relations)
        @test checked.table[:alpha] == [:alpha,:beta,:gamma]
        @test checked.table[9] == [:alpha,:beta,:gamma]
        @test checked.state.counts.unknown_neighbors_ignored == 1
        # Relations are always read anew; no row or negative match is cached.
        empty!(relations[:alpha]); relations[:gamma] = Set([:beta])
        _compare(applications, relations; policy=checked.policy, state=checked.state)
        reverse!(applications)
        reordered = _compare(applications, relations; policy=checked.policy, state=checked.state)
        @test collect(keys(reordered.table)) == [:gamma,:beta,:alpha]
        @test checked.state.counts.layouts_built == 2
        cases += 3

        inactive = BP.BoundedPolicy(BP.BoundedCounters())
        @test PSE._try_freeze_scenario_relation_rows(applications, relations, inactive) === nothing
        @test inactive.counts.metadata_symbol_tables == 0
        active, state = _enabled_policy()
        @test PSE._try_freeze_scenario_relation_rows(applications,
            Dict(:alpha=>[:beta]), active) === nothing
        @test PSE._try_freeze_scenario_relation_rows([MutableApplication(:alpha,1)],
            relations, active) === nothing
        for invalid in ([(id=:same,slot=1),(id=:same,slot=2)],
                        [(id=:alpha,slot=1),(id=:beta,slot=1)])
            @test PSE._try_freeze_scenario_relation_rows(invalid, relations, active) === nothing
            @test_throws ArgumentError _ordinary_rows(invalid, relations,
                BP.BoundedPolicy(BP.BoundedCounters()))
        end
        @test state.counts.projections_completed == 0
        @test active.counts.metadata_symbol_tables == 0
        @test active.counts.metadata_id_sequences == 0
    end
    return (passed=true, cases, scientific_kernel_execution=false,
        oracle=:literal_original_row_algorithm_with_identical_bounded_factories,
        coverage=(:empty,:sparse,:dense,:unknown_neighbors,:unknown_rows,
            :unsorted_non_dense_slots,:live_relation_changes,:application_reordering,
            :inactive_policy,:unsupported_containers,:duplicate_names,:duplicate_slots))
end

end # module
