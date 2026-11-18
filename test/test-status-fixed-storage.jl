module FixedStatusStorageChecks
using PlantSimEngine, Test
const PSE = PlantSimEngine
const RF32 = Base.RefValue{Float32}
const RF64 = Base.RefValue{Float64}
const RR = Base.RefValue{Rational{Int}}
const RV32 = Base.RefValue{Vector{Float32}}
const RC32 = Base.RefValue{PSE.RefVector{Float32}}
const RN = Base.RefValue{Nothing}
const NAMES = (:x,:q,:seed,:literal,:private_only)
const SCHEMA = PSE._fixed_status_type(NAMES, Tuple{Union{RF32,RF64},RR,Union{RV32,RC32},RN,Nothing})

@testset "fixed canonical namespace has real presence, exact refs and stable identity" begin
    source = Status(x=3f0, q=1//2, seed=Float32[2])
    state = PSE._new_prepared_status(SCHEMA, source)
    @test state isa SCHEMA
    @test PSE._new_prepared_status(SCHEMA,state) === state
    @test keys(state) === (:x,:q,:seed)
    @test Tuple(state) == (3f0,1//2,Float32[2])
    @test !hasproperty(state,:literal) && !hasproperty(state,:private_only)
    @test fieldtype(PSE._status_schema_references(SCHEMA),5) === Nothing
    @test_throws KeyError state.literal
    for name in keys(source)
        @test PSE.refvalue(state,name) === PSE.refvalue(source,name)
    end
    header = PSE._status_identity(state)
    epoch = PSE._status_reference_epoch(state)
    state.x = 5f0
    @test source.x === 5f0
    @test PSE._status_reference_epoch(state) == epoch
    PSE._set_status_reference!(state,:x,PSE.refvalue(state,:x))
    @test PSE._status_reference_epoch(state) == epoch
    literal = Ref(nothing)
    PSE._set_status_reference!(state,:literal,literal)
    @test hasproperty(state,:literal) && state.literal === nothing
    @test keys(state) === (:x,:q,:seed,:literal)
    @test PSE._status_identity(state) === header
    @test PSE._status_reference_epoch(state) == epoch+1
    @test_throws ArgumentError PSE._set_status_reference!(state,:private_only,Ref(1))
    @test_throws ArgumentError PSE._set_status_reference!(state,:private_only,Ref(nothing))
    @test !hasproperty(state,:private_only)
    PrivateProjection = PSE._projected_status_type(SCHEMA,(:private_only,),Tuple{RF32})
    private_ref = Ref(7f0)
    private_view = PSE._construct_status(
        PSE.ExactReferenceFactory(SCHEMA,Tuple{RF32},PrivateProjection,(:private_only,)),
        state,(private_ref,))
    @test private_view.private_only === 7f0
    @test PSE.refvalue(private_view,:private_only) === private_ref
    @test !hasproperty(state,:private_only)
    @test_throws ArgumentError PSE._new_prepared_status(SCHEMA,Status(x="invalid"))
    @test_throws ArgumentError PSE._new_prepared_status(SCHEMA,Status(unprepared=1))
    carrier = PSE.RefVector([Ref(8f0)])
    carrier_ref = Ref(carrier)
    PSE._set_status_reference!(state,:seed,carrier_ref)
    @test PSE.refvalue(state,:seed) === carrier_ref
    @test carrier !== source.seed
    shallow = copy(state)
    @test PSE.refvalue(shallow,:x) === PSE.refvalue(state,:x)
    @test PSE._status_identity(shallow) !== header
    PSE._drop_status_reference!(shallow,:literal)
    @test !hasproperty(shallow,:literal) && hasproperty(state,:literal)
    PSE._set_status_reference!(shallow,:literal,literal)
    @test keys(shallow) === keys(state)
end

@testset "dense hot and full namespace snapshot use identical private overrides" begin
    owner = PSE._new_prepared_status(SCHEMA,Status(x=3f0,q=1//2,seed=Float32[2]))
    private = Ref(100.0)
    Projected = @inferred PSE._projected_status_type(SCHEMA,Val((:x,:q)),Tuple{RF64,RR})
    # Execution targets carry a handle to the snapshot, even for a wide namespace.
    @test sizeof(Projected) == sizeof(SCHEMA)
    @test Projected === PSE._projected_status_type(SCHEMA,(:x,:q),Tuple{RF64,RR})
    @test PSE._projected_status_type(SCHEMA,Val(()),Tuple{}) ===
        PSE._projected_status_type(SCHEMA,(),Tuple{})
    @test_throws ArgumentError PSE._projected_status_type(SCHEMA,Val((:unprepared,)),Tuple{RF32})
    factory = PSE.ExactReferenceFactory(SCHEMA,Tuple{RF64},Projected,(:x,))
    old = PSE._construct_status(factory,owner,(private,))
    @test old.x === 100.0 && first(Tuple(old)) === 100.0
    @test PSE.refvalue(old,:x) === private
    @test PSE.refvalue(old,:seed) === PSE.refvalue(owner,:seed)
    @test keys(old) === (:x,:q,:seed)
    replacement = Ref(4f0)
    PSE._set_status_reference!(owner,:x,replacement)
    PSE._set_status_reference!(owner,:literal,Ref(nothing))
    @test keys(old) === (:x,:q,:seed) && !hasproperty(old,:literal)
    @test old.x === 100.0 && PSE.refvalue(old,:x) === private
    Fresh = @inferred PSE._projected_status_type(SCHEMA,Val((:x,:q)),Tuple{RF32,RR})
    @test Fresh === PSE._projected_status_type(SCHEMA,(:x,:q),Tuple{RF32,RR})
    @test Fresh !== Projected
    current = PSE._construct_status(PSE.ExactReferenceFactory(SCHEMA,Tuple{},Fresh,()),owner,())
    @test PSE.refvalue(current,:x) === replacement
    @test current.x === first(Tuple(current)) === 4f0
    @test keys(current) === (:x,:q,:seed,:literal)
    @test PSE._status_reference_epoch(old) < PSE._status_reference_epoch(current)
    owner.q = 2//3
    @test old.q == current.q == 2//3
    old.x = 101.0
    @test private[] === 101.0 && owner.x === 4f0
end

@testset "sparse recipe commits metadata once without replacing its canonical header" begin
    state = PSE._new_prepared_status(SCHEMA,Status(x=1f0,q=1//2,seed=Float32[]))
    original = state
    epoch = PSE._status_reference_epoch(state)
    recipe = PSE._CanonicalStatusRecipe(state,false)
    replacement = Ref(2.0)
    @test PSE._status_recipe_set_reference!(recipe,:x,replacement)
    @test PSE.refvalue(state,:x) !== replacement
    @test PSE._finish_canonical_status_recipe!(recipe) === original
    @test PSE.refvalue(state,:x) === replacement
    @test PSE._status_reference_epoch(state) == epoch+1
    @test PSE._finish_canonical_status_recipe!(recipe) === original
    @test PSE._status_reference_epoch(state) == epoch+1
    @test_throws ArgumentError PSE._status_recipe_set_reference!(recipe,:x,Ref("bad"))
    @test PSE.refvalue(state,:x) === replacement
end

@testset "sparse edits preserve aliases and commit atomically across a wide status" begin
    names = ntuple(i -> Symbol(:port_, i), 160)
    schema = PSE._fixed_status_type(names, NTuple{length(names), RF32})
    state = PSE._new_prepared_status(schema, nothing)
    recipe = PSE._CanonicalStatusRecipe(state, true)
    epoch = PSE._status_reference_epoch(state)
    shared = Ref(4f0)
    for name in (last(names), first(names), names[80])
        PSE._status_recipe_set_reference!(recipe, name, shared)
    end
    @test PSE._finish_canonical_status_recipe!(recipe) === state
    @test keys(state) == (first(names), names[80], last(names))
    @test all(name -> PSE.refvalue(state, name) === shared, keys(state))
    @test PSE._status_reference_epoch(state) == epoch + 1
    PSE._finish_canonical_status_recipe!(recipe)
    @test PSE._status_reference_epoch(state) == epoch + 1

    # A bad edit after a valid one must leave both the reference and its epoch alone.
    for (name, reference, error_type) in ((:unprepared, shared, KeyError),
                                         (last(names), Ref(4.0), ArgumentError))
        pending = PSE._CanonicalStatusRecipe(state, false)
        PSE._status_recipe_set_reference!(pending, first(names), Ref(5f0))
        push!(pending.edit_names, name)
        push!(pending.edit_references, reference)
        @test_throws error_type PSE._finish_canonical_status_recipe!(pending)
        @test PSE.refvalue(state, first(names)) === shared
        @test PSE._status_reference_epoch(state) == epoch + 1
    end
end

function _wide_status_commit_bytes!(recipe, name, value)
    PSE._status_recipe_set_reference!(recipe, name, Ref(value))
    return @allocated PSE._finish_canonical_status_recipe!(recipe)
end

@testset "a sparse edit copies a heterogeneous status directory once" begin
    names = ntuple(i -> Symbol(:port_, i), 160)
    classes = ntuple(i -> isodd(i) ? RF32 : RF64, length(names))
    schema = PSE._fixed_status_type(names, Tuple{classes...})
    state = PSE._new_prepared_status(schema, nothing)
    recipe = PSE._CanonicalStatusRecipe(state, true)
    _wide_status_commit_bytes!(recipe, first(names), 1f0)
    bytes = _wide_status_commit_bytes!(recipe, first(names), 2f0)
    # Allow space for the staging vector, the tuple and its final directory.
    @test bytes <= 64 * length(names) + 4096
    @test PSE.refvalue(state, first(names))[] === 2f0
end

@testset "deepcopy preserves internal ref aliases, RefAny and RefReal stay exact" begin
    S = PSE._fixed_status_type((:a,:b,:abstract,:opaque),Tuple{RF32,RF32,Base.RefValue{Real},Base.RefValue{Any}})
    reference = Ref(1f0)
    source = Status((a=reference,b=reference,abstract=Ref{Real}(2f0),opaque=Ref{Any}(3f0)))
    state = PSE._new_prepared_status(S,source)
    copied = deepcopy(state)
    @test PSE.refvalue(copied,:a) === PSE.refvalue(copied,:b)
    @test PSE.refvalue(copied,:a) !== reference
    @test typeof(PSE.refvalue(state,:abstract)) === Base.RefValue{Real}
    @test typeof(PSE.refvalue(state,:opaque)) === Base.RefValue{Any}
end

_fixed_status_presence(status, name::Symbol) = hasproperty(status, name)
function _store_fixed_status_presence!(result::Base.RefValue{Bool}, status, name::Symbol)
    result[] = hasproperty(status, name)
    return nothing
end
_fixed_status_presence_allocations(result, status, name::Symbol) =
    @allocated _store_fixed_status_presence!(result, status, name)

@testset "presence queries inspect cells without reading values or constructing names" begin
    dense = Status((x=Ref{Float32}(), literal=Ref(nothing)))
    fixed = PSE._new_prepared_status(SCHEMA,Status(x=3f0,q=1//2,seed=Float32[]))
    Projected = PSE._projected_status_type(SCHEMA,(:private_only,),Tuple{RF32})
    view = PSE._construct_status(
        PSE.ExactReferenceFactory(SCHEMA,Tuple{RF32},Projected,(:private_only,)),
        fixed,(Ref(7f0),))
    result = Ref(false)
    for (status, name, expected) in ((dense,:x,true), (dense,:literal,true),
        (dense,:missing,false), (dense,:vars,false), (Status(),:missing,false),
        (fixed,:x,true), (fixed,:literal,false), (fixed,:private_only,false),
        (fixed,:missing,false), (view,:private_only,true), (view,:literal,false),
        (view,:missing,false))
        @test (@inferred _fixed_status_presence(status,name)) === expected
        _store_fixed_status_presence!(result,status,name)
        _fixed_status_presence_allocations(result,status,name)
        @test _fixed_status_presence_allocations(result,status,name) == 0
        @test result[] === expected
    end
    PSE._set_status_reference!(fixed,:literal,Ref(nothing))
    @test (@inferred _fixed_status_presence(fixed,:literal)) === true
    @test fixed.literal === nothing
    @test (@inferred _fixed_status_presence(view,:literal)) === false
    @test keys(fixed) === (:x,:q,:seed,:literal)
    @test keys(view) === (:x,:q,:seed,:private_only)
end
end
