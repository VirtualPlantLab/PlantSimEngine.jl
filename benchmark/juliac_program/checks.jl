module ReusableProgramChecks

using Dates
using Test
using PlantSimEngine
import ..ReusableProgram
import ..NativeFixture
const RP = ReusableProgram
const NF = NativeFixture
const PSE = PlantSimEngine

# Independent declarations for admission failures, rather than malformed private
# recipe instances. They exercise the same authored interface as user models.
PSE.@process "native_check_cycle_a" verbose = false
struct CycleA <: AbstractNative_Check_Cycle_AModel end
PSE.inputs_(::CycleA) = (b=Required(Float64),)
PSE.outputs_(::CycleA) = (a=0.0,)
PSE.@process "native_check_cycle_b" verbose = false
struct CycleB <: AbstractNative_Check_Cycle_BModel end
PSE.inputs_(::CycleB) = (a=Required(Float64),)
PSE.outputs_(::CycleB) = (b=0.0,)
PSE.@process "native_check_mutable_default" verbose = false
struct MutableDefault <: AbstractNative_Check_Mutable_DefaultModel end
PSE.inputs_(::MutableDefault) = (payload=Default([1.0]),)
PSE.outputs_(::MutableDefault) = (value=0.0,)

_models(specs) = map(s -> s.model, specs)
_initial(::Type{T}) where {T} = (leaf_area=T(1.5), biomass=T(2))
_rows(::Type{T}) where {T} = [(T=T(8),), (T=T(16),), (T=T(4),)]

function _assert_snapshot(native, ordinary, row)
    snapshot = PSE.final_state(ordinary, ObjectId(native.ids[row]))
    for variable in (:leaf_area, :carbon, :biomass)
        @test native.statuses[row][variable] === snapshot[variable]
    end
end

# This setup starts the ordinary timeline before its first step so registration
# can occur at exactly the same boundary as the direct state's host-side birth.
function _ordinary_start(ids, rows, specs, initial)
    weather = Weather([
        Atmosphere(date=DateTime(2025, 1, 1) + Day(i - 1), T=row.T,
            Wind=1.0, Rh=0.5, P=100.0, Ri_SW_f=100.0, duration=Day(1))
        for (i, row) in enumerate(rows)
    ])
    model = CompositeModel(
        (Object(id; kind=:leaf, status=Status(initial)) for id in ids)...;
        applications=specs, environment=weather,
    )
    return PSE.run!(model; steps=0, outputs=:all)
end

function run_checks()
    result = @testset "Reusable direct program: admitted subset" begin
        @testset "reuse across values, populations and IDs ($T)" for T in (Float32, Float64)
            authored = NF.specs(; efficiency=T(0.5), conversion=T(0.25))
            program = RP.prepare(authored)
            @test map(r -> r.name, program.regions) == (:assimilation, :accumulation)
            @test isimmutable(program)
            initial = _initial(T)
            representative_type = nothing
            for n in (0, 1, 7), offset in (10, 1000), variant in (1, 2)
                efficiency = T(variant == 1 ? 0.5 : 0.75)
                conversion = T(variant == 1 ? 0.25 : 0.125)
                specs = NF.specs(; efficiency, conversion)
                ids = collect(offset:(offset + n - 1))
                rows = variant == 1 ? _rows(T) : reverse(_rows(T))
                native = RP.instantiate(program, _models(specs), ids, fill(:leaf, n); initial)
                @test native.program === program
                if representative_type === nothing
                    representative_type = typeof(native)
                end
                @test typeof(native) === representative_type
                trace = [T[] for _ in ids]
                for environment in rows
                    RP.step!(native, environment)
                    for i in eachindex(ids)
                        push!(trace[i], native.statuses[i].biomass)
                    end
                end
                ordinary = NF.ordinary(ids, rows; efficiency, conversion, initial...)
                @test native.step == length(rows)
                @test length(PSE.final_state(ordinary, Many(kind=:leaf))) == n
                for i in eachindex(ids)
                    _assert_snapshot(native, ordinary, i)
                    observed = PSE.collect_outputs(ordinary, ObjectId(ids[i]), :biomass; sink=nothing)
                    @test [sample.value for sample in observed] == trace[i]
                    @test all(sample -> sample.value isa T, observed)
                end
            end
        end

        @testset "live references, independent states and boundary births" begin
            specs = NF.specs()
            program = RP.prepare(specs)
            initial = _initial(Float64)
            rows = _rows(Float64)
            left = RP.instantiate(program, _models(specs), [31], [:leaf]; initial)
            right = RP.instantiate(program, _models(specs), [31], [:leaf]; initial)
            carbon = PSE.refvalue(left.statuses[1], :carbon)
            area = PSE.refvalue(left.statuses[1], :leaf_area)
            @test carbon !== PSE.refvalue(right.statuses[1], :carbon)
            @test area !== PSE.refvalue(right.statuses[1], :leaf_area)
            area[] = 3.0
            RP.step!(left, first(rows))
            @test left.statuses[1].carbon == 12.0
            @test left.statuses[1].biomass == 5.0
            @test right.statuses[1].leaf_area == initial.leaf_area
            @test right.statuses[1].biomass == initial.biomass
            @test carbon === PSE.refvalue(left.statuses[1], :carbon)
            @test carbon[] == 12.0

            for initial_ids in (Int[], [42])
                native = RP.instantiate(program, _models(specs), initial_ids,
                    fill(:leaf, length(initial_ids)); initial)
                ordinary = _ordinary_start(initial_ids, rows, specs, initial)
                RP.step!(native, rows[1]); PSE.step!(ordinary)
                saved_refs = [PSE.refvalue(status, :carbon) for status in native.statuses]
                newborn = RP.add_object!(native, 99, :leaf; initial)
                PSE.register_object!(PSE.runtime_model(ordinary), Object(99; kind=:leaf, status=Status(initial)))
                @test typeof(newborn) === program.status_type
                @test native.program === program
                @test all(region -> length(region.rows) == length(initial_ids) + 1, native.regions)
                @test newborn.biomass == initial.biomass
                for row in rows[2:end]
                    RP.step!(native, row); PSE.step!(ordinary)
                end
                @test native.step == length(rows)
                for i in eachindex(native.ids)
                    _assert_snapshot(native, ordinary, i)
                end
                @test all(i -> saved_refs[i] === PSE.refvalue(native.statuses[i], :carbon), eachindex(saved_refs))
                @test newborn.biomass == 5.75
            end
        end

        @testset "explicit rejection and validation before execution" begin
            specs = NF.specs()
            duplicate = ModelSpec(NF.Assimilation(0.75); name=:other,
                on=Many(kind=:leaf), every=Day(1))
            @test_throws ArgumentError RP.prepare((specs[2], duplicate))
            cycle = (
                ModelSpec(CycleA(); name=:cycle_a, on=Many(kind=:leaf), every=Day(1)),
                ModelSpec(CycleB(); name=:cycle_b, on=Many(kind=:leaf), every=Day(1)),
            )
            @test_throws ArgumentError RP.prepare(cycle)
            slower = ModelSpec(specs[1].model; name=:accumulation,
                on=Many(kind=:leaf), every=Day(2))
            @test_throws ArgumentError RP.prepare((slower, specs[2]))
            caller = ModelSpec(specs[1].model; name=:accumulation,
                on=Many(kind=:leaf), every=Day(1),
                calls=(child=One(within=Self(), application=:assimilation),))
            @test_throws ArgumentError RP.prepare((caller, specs[2]))
            @test_throws ArgumentError RP.prepare((specs[1],))
            other_kind = ModelSpec(specs[2].model; name=:stem_assimilation,
                on=Many(kind=:stem), every=Day(1))
            @test_throws ArgumentError RP.prepare((specs[2], other_kind))
            mutable_default = ModelSpec(MutableDefault(); name=:mutable_default,
                on=Many(kind=:leaf), every=Day(1))
            @test_throws ArgumentError RP.prepare((mutable_default,))
            program = RP.prepare(specs)
            models = _models(specs)
            @test_throws ArgumentError RP.instantiate(program, models, [1, 1], [:leaf, :leaf])
            @test_throws ArgumentError RP.instantiate(program, models, [1], Symbol[])
            @test_throws ArgumentError RP.instantiate(program, models, [1], [:leaf]; initial=(unknown=0.0,))
            native = RP.instantiate(program, models, [1], [:leaf])
            before = NamedTuple(native.statuses[1])
            @test_throws ArgumentError RP.step!(native, (other=2.0,))
            @test NamedTuple(native.statuses[1]) == before
            @test native.step == 0
            @test_throws ArgumentError RP.add_object!(native, 1, :leaf)
            @test native.ids == [1]
        end
    end
    counts = Test.get_test_counts(result)
    return (passes=counts.passes + counts.cumulative_passes,
        fails=counts.fails + counts.cumulative_fails,
        errors=counts.errors + counts.cumulative_errors)
end

end # module ReusableProgramChecks
