# Native canonical columns are constructed before Object/CompositeModel
# registration. This extension never replaces an existing canonical RefValue,
# so caller-held references and all compiled carriers keep their live identity.

struct NativeRegionColumn{V,R}
    values::V
    sources::R
end

_is_native_region_column(::NativeRegionColumn) = true

function _try_native_region_column(references::Vector{R}) where {R<:Base.RefArray}
    isempty(references) && return nothing
    source = getfield(first(references), :x)
    source isa Vector || return nothing
    # A prefix of a larger canonical vector is safe; arbitrary gathers and
    # holes use the ordinary synchronized scratch columns.
    for row in eachindex(references)
        reference = references[row]
        getfield(reference, :x) === source || return nothing
        getfield(reference, :i) == row || return nothing
    end
    # After the prefix proof, the canonical vector is the only retained source.
    # Pull/push are no-ops; keeping a duplicate row of RefArray pointers would
    # add O(rows × ports × applications) metadata without serving execution.
    return NativeRegionColumn(source, nothing)
end

@inline _region_pull_column!(::NativeRegionColumn) = nothing
@inline _region_push_column!(::NativeRegionColumn) = nothing

"""
    build_column_statuses(columns::NamedTuple; nrows=nothing)
    build_column_statuses(initial_rows::AbstractVector{<:NamedTuple})

Create canonical Status rows backed by typed numerical column Vectors BEFORE
constructing registry Objects. Returns `(statuses, columns, ownership)`.
Column arrays stay live: writes through a Status, One/Many carrier, or the array
update the same storage. Passing one Vector for several names intentionally
preserves aliases. No pre-existing RefValue or Status is rewritten.

Only homogeneous concrete isbits columns are accepted by this initial helper.
For mutable scientific values use ordinary Status construction; mixed-region
lowering continues to retain those feature paths.
"""
function build_column_statuses(columns::NamedTuple; nrows=nothing)
    names = keys(columns)
    rows = if isempty(columns)
        isnothing(nrows) && throw(ArgumentError("Empty columns require nrows."))
        Int(nrows)
    else
        length(first(values(columns)))
    end
    rows >= 0 || throw(ArgumentError("nrows must be non-negative"))
    isnothing(nrows) || Int(nrows) == rows || throw(ArgumentError(
        "nrows differs from the supplied column lengths.",
    ))
    for (name, values_) in pairs(columns)
        values_ isa Vector || throw(ArgumentError(
            "Canonical column $(name) must be an ordinary Vector.",
        ))
        length(values_) == rows || throw(ArgumentError("Canonical column lengths differ."))
        isconcretetype(eltype(values_)) && isbitstype(eltype(values_)) ||
            throw(ArgumentError("Canonical columns require concrete isbits element types."))
    end
    make_row(row) = PSE.Status(NamedTuple{names}(
        map(values_ -> Ref(values_, row), values(columns))))
    if iszero(rows)
        statuses = PSE.Status[]
    else
        first_status = make_row(1)
        statuses = Vector{typeof(first_status)}(undef, rows)
        statuses[1] = first_status
        for row in 2:rows
            statuses[row] = make_row(row)
        end
    end
    return (;statuses, columns, ownership=:canonical_columns_from_construction)
end

function build_column_statuses(initial_rows::AbstractVector{<:NamedTuple})
    isempty(initial_rows) && throw(ArgumentError("Initial rows must be non-empty."))
    names = keys(first(initial_rows))
    all(row -> keys(row) == names, initial_rows) || throw(ArgumentError(
        "Initial rows require one field schema.",
    ))
    columns = NamedTuple{names}(map(names) do name
        T = typeof(getproperty(first(initial_rows), name))
        isconcretetype(T) && isbitstype(T) || throw(ArgumentError(
            "Canonical row values must be concrete isbits values.",
        ))
        all(row -> typeof(getproperty(row, name)) === T, initial_rows) ||
            throw(ArgumentError("Canonical row fields require one element type."))
        T[getproperty(row, name) for row in initial_rows]
    end)
    return build_column_statuses(columns)
end

function native_column_storage_checks()
    @testset "Native canonical column construction and borrowing" begin
        for T in (Float32, Float64)
            shared = T[1, 2, 3]
            built = build_column_statuses((x=shared, y=shared, z=T[4, 5, 6]))
            @test built.statuses[2].x === T(2)
            built.statuses[2].x = T(9)
            @test shared[2] === T(9)
            @test built.statuses[2].y === T(9)
            shared[1] = T(11)
            @test built.statuses[1].x === T(11)
            targets = [(status=status,) for status in built.statuses]
            state = prepare_region_state(targets, (:x, :y, :z), (:x, :z))
            @test state.data.arrays.x === shared
            @test state.data.arrays.y === shared
            @test all(column -> column.sources === nothing, state.read_columns)
            @test all(column -> column.values === shared || column.values === built.columns.z,
                state.read_columns)
            report = region_state_report(state)
            @test report.native_column_fields == 2
            @test report.column_payload_bytes == 0
            @test !report.duplicate_scalar_columns
            @test !report.canonical_references_replaced
            pull_region_state!(state)
            state.data.arrays.x[3] = T(12)
            push_region_state!(state)
            @test built.statuses[3].y === T(12)
            # Non-prefix/removed rows are gathered instead of falsely claiming
            # that physical array position equals their current logical row.
            subset = [targets[1], targets[3]]
            gathered = prepare_region_state(subset, (:x, :z), (:x,))
            @test region_state_report(gathered).native_column_fields == 0
            gathered.data.arrays.x[2] = T(17)
            push_region_state!(gathered)
            @test shared[3] === T(17)
            @test built.statuses[2].x === T(9)
        end
        rows = build_column_statuses([(a=1.0, b=1), (a=2.0, b=2)])
        @test rows.statuses[2].b == 2
        @test length(build_column_statuses((;); nrows=2).statuses) == 2
        @test_throws ArgumentError build_column_statuses((a=[1.0], b=[1.0, 2.0]))
        @test_throws ArgumentError build_column_statuses((a=Any[1.0],))
        @test_throws ArgumentError build_column_statuses(NamedTuple[])
    end
    return (passed=true, input_representation=:native_before_registry,
        physical_reference_migration=false, mutable_values=:ordinary_feature_path)
end

# Integration fixtures are deliberately generic. The source chain shares its
# scientific kernels with the ordinary-executor control; these two consumers
# exercise live One and Many aliases across a numerical-region boundary.
PSE.@process "native_column_echo" verbose=false
PSE.@process "native_column_sum" verbose=false

struct NativeColumnEcho{T} <: AbstractNative_Column_EchoModel end
PSE.inputs_(::NativeColumnEcho{T}) where {T} = (supply=PSE.Required(T),)
PSE.outputs_(::NativeColumnEcho{T}) where {T} = (observed=zero(T), visits=0)
function PSE.run!(::NativeColumnEcho, status, environment, constants, context)
    status.observed = status.supply
    status.visits += 1
    return nothing
end
region_effects(::Type{<:NativeColumnEcho}) = :local_ports

struct NativeColumnSum{T} <: AbstractNative_Column_SumModel end
PSE.inputs_(::NativeColumnSum{T}) where {T} = (sources=PSE.Required(Vector{T}),)
PSE.outputs_(::NativeColumnSum{T}) where {T} = (total=zero(T), source_count=0)
function PSE.run!(::NativeColumnSum{T}, status, environment, constants, context) where {T}
    status.total = sum(status.sources; init=zero(T))
    status.source_count = length(status.sources)
    return nothing
end

function native_column_integration_fixture(::Type{T}=Float64;
    native::Bool=true, nobjects::Int=4, nmodels::Int=3,
    echo_on=PSE.One(id=:echo)) where {T}
    rows = [NamedTuple(GP._chain_status(nmodels, T, 0, row)) for row in 1:nobjects]
    source = native ? build_column_statuses(rows) :
        (statuses=PSE.Status.(rows), columns=nothing, ownership=:ordinary_reference_cells)
    echo = native ? build_column_statuses((observed=T[0], visits=[0])) :
        (statuses=[PSE.Status(observed=zero(T), visits=0)], columns=nothing,
            ownership=:ordinary_reference_cells)
    objects = PSE.Object[PSE.Object(row; kind=:native_unit,
        status=source.statuses[row]) for row in 1:nobjects]
    push!(objects, PSE.Object(:echo; status=only(echo.statuses)))
    push!(objects, PSE.Object(:sum; status=PSE.Status(total=zero(T), source_count=0)))
    applications = PSE.ModelSpec[PSE.ModelSpec(GP.ChainStage{stage,T,false}(T(0.5), T(stage));
        name=GP._stage_name(stage), on=PSE.Many(kind=:native_unit), every=Hour(1))
        for stage in 1:nmodels]
    push!(applications, PSE.ModelSpec(NativeColumnEcho{T}(); name=:echo,
        on=echo_on, every=Hour(1),
        inputs=(supply=PSE.One(id=1, within=PSE.SceneScope(),
            application=GP._stage_name(nmodels), var=GP._stage_name(nmodels)),)))
    push!(applications, PSE.ModelSpec(NativeColumnSum{T}(); name=:sum,
        on=PSE.One(id=:sum), every=Hour(1),
        inputs=(sources=PSE.Many(kind=:native_unit, within=PSE.SceneScope(),
            application=GP._stage_name(nmodels), var=GP._stage_name(nmodels)),)))
    model = PSE.CompositeModel(objects...; applications, environment=(duration=Hour(1),))
    return (; model, source, echo, nmodels, nobjects)
end

function _native_integration_binding(simulation, application, object, input)
    return only(binding for binding in simulation.compiled.input_bindings_by_target[
        (application, PSE.ObjectId(object))] if binding.input === input)
end

function _native_integration_columns(program)
    return [batch for node in program.plan.nodes for batch in node.batches
        if batch isa RegionColumnBatch]
end

"""
    native_column_integration_checks()

Compare canonical columns constructed before registration against ordinary
RefValue construction. Exercise live One/Many aliases, external mutations,
raw retained histories, ordinary continue!, object addition and removal. This
is a correctness gate, not a performance measurement or migration of existing
Status identities. Reports distinguish typed values from the deliberately
different physical RefValue/RefArray carrier storage types.
"""
function native_column_integration_checks()
    reports = NamedTuple[]
    @testset "Canonical column regions integrate with live PSE features" begin
        for T in (Float32, Float64)
            fixture = native_column_integration_fixture(T; native=true)
            control = native_column_integration_fixture(T; native=false)
            simulation = PSE.run!(fixture.model; steps=0, outputs=:all)
            reference = PSE.run!(control.model; steps=0, outputs=:all)
            program = compile_regions(simulation; regions=true,
                resolved_calls=false, compact=true)
            initial = region_report(program)
            @test initial.native_column_fields > 0
            @test !initial.canonical_scalar_copy_retained
            @test all(state -> !state.duplicate_scalar_columns, initial.selected_state)
            @test initial.execution_records_removed > 0
            for batch in _native_integration_columns(program)
                arrays = batch.state.data.arrays
                for name in keys(arrays)
                    expected = name in keys(fixture.source.columns) ?
                        getproperty(fixture.source.columns, name) :
                        name === :supply ? fixture.source.columns.stage_3 :
                        getproperty(fixture.echo.columns, name)
                    @test getproperty(arrays, name) === expected
                end
            end
            source_status = PSE.model_status(fixture.model, 1)
            source_status.stage_1 = T(-3)
            PSE.model_status(control.model, 1).stage_1 = T(-3)
            @test fixture.source.columns.stage_1[1] === T(-3)

            # Writes through either public carrier keep the same live source
            # array. Obtain views again after any topology refresh below.
            echo_status = PSE.model_status(fixture.model, :echo)
            sum_status = PSE.model_status(fixture.model, :sum)
            fixture.source.columns.stage_3[1] = T(-7)
            PSE.model_status(control.model, 1).stage_3 = T(-7)
            @test echo_status.supply === T(-7)
            @test first(sum_status.sources) === T(-7)
            echo_status.supply = T(-9)
            PSE.model_status(control.model, :echo).supply = T(-9)
            @test fixture.source.columns.stage_3[1] === T(-9)
            one_binding = _native_integration_binding(simulation, :echo, :echo, :supply)
            @test PSE.Diagnostics.input_value(one_binding) === T(-9)
            sum_status.sources[2] = T(-11)
            PSE.model_status(control.model, :sum).sources[2] = T(-11)
            @test fixture.source.columns.stage_3[2] === T(-11)
            many_binding = _native_integration_binding(simulation, :sum, :sum, :sources)
            plain_many_binding = _native_integration_binding(reference, :sum, :sum, :sources)
            many_type = typeof(PSE.Diagnostics.input_carrier(many_binding))
            plain_many_type = typeof(PSE.Diagnostics.input_carrier(plain_many_binding))
            canonical_many_typed = PSE.Diagnostics.input_carrier(many_binding) isa PSE.RefVector{T}
            ordinary_many_typed = PSE.Diagnostics.input_carrier(plain_many_binding) isa PSE.RefVector{T}
            @test canonical_many_typed
            @test ordinary_many_typed

            PSE.continue!(reference; steps=1)
            advance_regions!(program; steps=1)
            @test isequal(GP.fingerprint(simulation), GP.fingerprint(reference))
            @test PSE.model_status(fixture.model, :sum).source_count == fixture.nobjects
            @test source_status === PSE.model_status(fixture.model, 1)

            # The standard executor uses the installed compact batches too.
            PSE.continue!(reference; steps=1)
            PSE.continue!(simulation; steps=1)
            @test isequal(GP.fingerprint(simulation), GP.fingerprint(reference))
            source_status.stage_1 = T(17)
            PSE.model_status(control.model, 1).stage_1 = T(17)
            PSE.continue!(reference; steps=1)
            advance_regions!(program; steps=1)
            @test isequal(GP.fingerprint(simulation), GP.fingerprint(reference))

            newborn = build_column_statuses([NamedTuple(
                GP._chain_status(fixture.nmodels, T, 0, 91))])
            PSE.register_object!(fixture.model, PSE.Object(91; kind=:native_unit,
                status=only(newborn.statuses)))
            PSE.register_object!(control.model, PSE.Object(91; kind=:native_unit,
                status=GP._chain_status(fixture.nmodels, T, 0, 91)))
            PSE.continue!(reference; steps=1)
            advance_regions!(program; steps=1)
            @test isequal(GP.fingerprint(simulation), GP.fingerprint(reference))
            @test PSE.model_status(fixture.model, 91).visits_1 == 1
            @test only(newborn.statuses).stage_1 === newborn.columns.stage_1[1]
            after_add = region_report(program)
            # A second canonical allocation is a gather, so scratch storage is
            # allowed. No column claims ownership of unrelated physical rows.
            @test after_add.canonical_scalar_copy_retained

            PSE.remove_object!(fixture.model, 2)
            PSE.remove_object!(control.model, 2)
            PSE.continue!(reference; steps=1)
            advance_regions!(program; steps=1)
            observed, expected = GP.fingerprint(simulation), GP.fingerprint(reference)
            @test isequal(observed, expected)
            @test !haskey(observed.states, PSE.ObjectId(2))
            @test haskey(observed.histories, (:stage_1, PSE.ObjectId(2), :stage_1))
            @test source_status === PSE.model_status(fixture.model, 1)
            @test fixture.source.columns.stage_1[1] === source_status.stage_1
            push!(reports, (value_type=T, passed=true,
                initial_native_fields=initial.native_column_fields,
                initial_duplicate_scalar_columns=initial.canonical_scalar_copy_retained,
                initial_removed_records=initial.execution_records_removed,
                final_rebuilds=program.rebuilds,
                canonical_many_carrier=string(many_type),
                ordinary_many_carrier=string(plain_many_type),
                canonical_many_values_typed=canonical_many_typed,
                ordinary_many_values_typed=ordinary_many_typed,
                same_carrier_storage_type=many_type === plain_many_type,
                physical_reference_migration=false))
        end
    end
    return (; cases=length(reports), reports)
end
