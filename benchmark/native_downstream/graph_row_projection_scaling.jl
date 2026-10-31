module GraphRowScaling

using Test, Statistics, PlantSimEngine
const PSE = PlantSimEngine
const BP = Main.BoundedPreparation
const GRP = Main.GraphRowProjection
const _escaped_tables = Ref{Any}(nothing)
export graph_row_scaling

_counter_snapshot(counts) = NamedTuple{fieldnames(typeof(counts))}(
    Tuple(getfield(counts, field) for field in fieldnames(typeof(counts))))
function _phase(measured)
    return (seconds=measured.time, allocated_bytes=measured.bytes,
        gc_seconds=measured.gctime,
        compilation_seconds=hasproperty(measured,:compile_time) ? measured.compile_time : nothing,
        recompilation_seconds=hasproperty(measured,:recompile_time) ? measured.recompile_time : nothing)
end

function _fixture(count)
    applications = [(id=Symbol(:metadata_application_, index),slot=3*(count-index)+7)
        for index in 1:count]
    children = Dict{Symbol,Set{Symbol}}()
    owners = Dict{Symbol,Set{Symbol}}()
    for (index,application) in pairs(applications)
        neighbors = Set((applications[mod1(index+1,count)].id,
            applications[mod1(index+3,count)].id))
        children[application.id] = neighbors
        for neighbor in neighbors
            push!(get!(owners,neighbor,Set{Symbol}()),application.id)
        end
    end
    return (;applications,children,owners)
end

# Setup belongs to the measured build phase. Each sample starts with an empty
# projection layout cache; none is reused across samples or policy instances.
Base.@nospecializeinfer @noinline function _build_sample(arm, applications, relations)
    @nospecialize applications relations
    policy = BP.BoundedPolicy(BP.BoundedCounters())
    state = nothing
    if arm === :projection
        state = GRP.ProjectionState()
        GRP._enabled[policy.counts] = state
    elseif arm !== :reference
        error("Unknown metadata micro arm")
    end
    first_table = PSE._freeze_scenario_application_children(applications,relations,policy)
    return Dict{Symbol,Any}(:policy=>policy,:state=>state,:first_table=>first_table)
end

Base.@nospecializeinfer @noinline function _second_table(sample, applications, relations)
    @nospecialize sample applications relations
    return PSE._freeze_scenario_application_children(applications,relations,sample[:policy])
end

function _check(sample, second_table, expected, fixture, arm)
    first_table = sample[:first_table]
    tables = (first_table,second_table)
    @test all(table -> typeof(table) === BP.BoundedSymbolTable, tables)
    for index in 1:2
        table, reference = tables[index], expected.tables[index]
        @test collect(pairs(table)) == collect(pairs(reference))
        @test collect(keys(table)) == [application.id for application in fixture.applications]
        for application in fixture.applications
            @test table[application.id] isa Vector{Symbol}
            @test PSE._application_plans(table,application.slot) == reference[application.id]
        end
    end
    factory_counts = _counter_snapshot(sample[:policy].counts)
    @test factory_counts == expected.factory_counts
    work = (tables=2,rows=sum(length,tables),
        edges=sum((sum(length,values(table);init=0) for table in tables);init=0))
    @test work == expected.work
    projection_counts = sample[:state] === nothing ? nothing : _counter_snapshot(sample[:state].counts)
    if arm === :projection
        @test projection_counts.projections_completed == 2
        @test projection_counts.rows_projected == work.rows
        @test projection_counts.edges_projected == work.edges
        @test projection_counts.layouts_built == 1
        @test projection_counts.layouts_reused == 1
        @test projection_counts.declines == 0
    else
        @test projection_counts === nothing
    end
    return (;factory_counts,work,projection_counts)
end

function _oracle(fixture)
    sample = _build_sample(:reference,fixture.applications,fixture.children)
    second = _second_table(sample,fixture.applications,fixture.owners)
    tables = (sample[:first_table],second)
    return (tables,factory_counts=_counter_snapshot(sample[:policy].counts),
        work=(tables=2,rows=sum(length,tables),
            edges=sum((sum(length,values(table);init=0) for table in tables);init=0)))
end

"""Balanced warm-method metadata helper micro; no scientific simulations.

Call `graph_row_scaling(32)` first, then 128 separately after the cheap gate.
Each sample measures fresh policy/counter/enable setup plus the first relation
table as `build`; `second_table` reuses its layout only within that compilation.
Both tables escape and exact original rows, slots, factory counts and metadata
work are checked outside timing. These ratios are not XP/PB application gains,
cold compilation times, or cross-simulation cache benefits.
"""
Base.@nospecializeinfer @noinline function graph_row_scaling(napplications::Int=32;cycles::Int=4)
    1 <= napplications <= 512 && 1 <= cycles <= 4 || error("Micro budget: 1-512 applications, 1-4 cycles")
    fixture = _fixture(napplications)
    original_relations = (deepcopy(fixture.children),deepcopy(fixture.owners))
    expected = _oracle(fixture)
    escaped = Any[]
    # Warm both helper paths before collecting any sample; state remains fresh.
    for arm in (:reference,:projection)
        warm = Base.invokelatest(_build_sample,arm,fixture.applications,fixture.children)
        second = Base.invokelatest(_second_table,warm,fixture.applications,fixture.owners)
        _check(warm,second,expected,fixture,arm)
        push!(escaped,(warm[:first_table],second))
    end
    samples = Any[]
    for cycle in 1:cycles
        order = isodd(cycle) ? (:reference,:projection) : (:projection,:reference)
        for (position,arm) in pairs(order)
            built = @timed Base.invokelatest(_build_sample,arm,fixture.applications,fixture.children)
            sample = built.value
            second = @timed Base.invokelatest(_second_table,sample,fixture.applications,fixture.owners)
            evidence = _check(sample,second.value,expected,fixture,arm)
            push!(escaped,(sample[:first_table],second.value))
            push!(samples,(cycle,position,arm,build=_phase(built),second_table=_phase(second),
                complete=(seconds=built.time+second.time,allocated_bytes=built.bytes+second.bytes,
                    gc_seconds=built.gctime+second.gctime),evidence))
        end
    end
    @test isequal(original_relations,(fixture.children,fixture.owners))
    _escaped_tables[] = escaped
    ratios = [(cycle=cycle,
        build=only(row.build.seconds for row in samples if row.cycle==cycle && row.arm===:projection)/
            only(row.build.seconds for row in samples if row.cycle==cycle && row.arm===:reference),
        second_table=only(row.second_table.seconds for row in samples if row.cycle==cycle && row.arm===:projection)/
            only(row.second_table.seconds for row in samples if row.cycle==cycle && row.arm===:reference),
        complete=only(row.complete.seconds for row in samples if row.cycle==cycle && row.arm===:projection)/
            only(row.complete.seconds for row in samples if row.cycle==cycle && row.arm===:reference))
        for cycle in 1:cycles]
    return (passed=true,napplications,cycles,samples,ratios,
        median_ratios=(build=median([row.build for row in ratios]),
            second_table=median([row.second_table for row in ratios]),complete=median([row.complete for row in ratios])),
        work=expected.work,escaped_table_count=2*length(escaped),
        scientific_kernel_execution=false,cold_compilation_claim=false,application_speed_claim=false,
        cache_scope=:fresh_policy_layout_per_sample_second_relation_only_reuses_within_compilation,
        build_scope=:policy_counters_enable_state_layout_and_first_relation_table,
        interpretation=:metadata_helper_micro_not_XP_or_PB_application_benchmark)
end

end # module
