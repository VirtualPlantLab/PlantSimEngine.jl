# Scalar-local fusion experiment. Included after driver.jl; it never rewrites
# a scientific equation or replaces the original model methods.

"""A field schema and exact within-row Ref alias pattern, independent of N rows."""
struct LocalStateRecipe{Names,Aliases} end

_local_state_cell_type(::Ref{T}) where {T} = T

function local_state_recipe(status::PSE.Status)
    names = propertynames(status)
    references = map(name -> PSE.refvalue(status, name), names)
    for (name, reference) in zip(names, references)
        T = _local_state_cell_type(reference)
        isconcretetype(T) && isbitstype(T) || throw(ArgumentError(
            "Scalar-local fusion requires concrete isbits cells; field $(name) has $(T).",
        ))
    end
    aliases = ntuple(length(names)) do i
        something(findfirst(j -> references[j] === references[i], 1:i), i)
    end
    return LocalStateRecipe{names,aliases}()
end

"""
    make_local_status(recipe, source)

Load one row into a fresh ordinary Status with local RefValue cells. Original
kernel methods may inline through this function and let Julia scalar-replace
the nonescaping cells. This is an opportunity, not a guarantee about native
code. Exact aliases in the recipe remain aliases in the local status.
"""
@inline @generated function make_local_status(
    ::LocalStateRecipe{Names,Aliases}, source,
) where {Names,Aliases}
    references = [Symbol(:local_cell_, i) for i in eachindex(Names)]
    loads = [:( $(references[i]) = Ref(getproperty(source, $(QuoteNode(Names[i])))))
        for i in eachindex(Names) if Aliases[i] == i]
    cells = Expr(:tuple, (references[Aliases[i]] for i in eachindex(Names))...)
    constructor = :(PSE.Status(NamedTuple{$(QuoteNode(Names))}($cells)))
    return Expr(:block, loads..., constructor)
end

"""Copy each unique cell back once; no framework metadata is made per row."""
@inline @generated function writeback_local_status!(
    destination, local_status, ::LocalStateRecipe{Names,Aliases},
) where {Names,Aliases}
    stores = [:(setproperty!(destination, $(QuoteNode(Names[i])),
        getproperty(local_status, $(QuoteNode(Names[i])))))
        for i in eachindex(Names) if Aliases[i] == i]
    return Expr(:block, stores..., :(nothing))
end

struct ScalarLocalRegion{R,B}
    first_entry::Int
    last_entry::Int
    batches::B
    recipe::R
end

function make_scalar_local_region(node::ProgramFusedRegion)
    isempty(node.batches) && throw(ArgumentError("Cannot scalarize an empty region."))
    sources = first(node.batches).statuses
    isempty(sources) && throw(ArgumentError("Cannot scalarize an empty row group."))
    recipe = local_state_recipe(first(sources))
    for batch in node.batches
        length(batch.statuses) == length(sources) || throw(ArgumentError(
            "Scalar-local region memberships differ.",
        ))
        for row in eachindex(sources)
            _program_same_status_references(sources[row], batch.statuses[row]) ||
                throw(ArgumentError("Scalar-local applications must share the same row cells."))
            typeof(local_state_recipe(batch.statuses[row])) === typeof(recipe) ||
                throw(ArgumentError("Scalar-local rows require one schema and alias pattern."))
        end
    end
    return ScalarLocalRegion(node.first_entry, node.last_entry, node.batches, recipe)
end

@inline function _publish_local_output!(
    output::PSE.RuntimeOutputStream{V}, local_status, step,
) where {V}
    # Reuse PSE's type checking, accepted stream storage, snapshot behavior and
    # temporal-buffer policy. The only change is where this scalar is read.
    PSE._model_publish_runtime_output_value!(output, output.stream,
        getproperty(local_status, V), step)
    return nothing
end

@inline _publish_local_outputs!(::Tuple{}, local_status, step) = nothing
@inline function _publish_local_outputs!(outputs::Tuple, local_status, step)
    _publish_local_output!(first(outputs), local_status, step)
    _publish_local_outputs!(Base.tail(outputs), local_status, step)
    return nothing
end

@inline @generated function _program_run_scalar_region!(
    node::ScalarLocalRegion{R,B}, simulation, step,
) where {R,B}
    count = fieldcount(B)
    environments = [Symbol(:local_environment_, i) for i in 1:count]
    setup = [:( $(environments[i]) = _program_direct_environment(
        getfield(node.batches, $i), simulation, step)) for i in 1:count]
    stages = Expr[]
    for i in 1:count
        push!(stages, quote
            batch = getfield(node.batches, $i)
            @inbounds target = batch.batch.targets[row]
            context = target.context
            context isa PSE.RunContext && (context.time = float(step))
            Base.@inline PSE.run!(target.model, local_status,
                $(environments[i]), simulation.constants, context)
            if batch.batch.output_publication.enabled
                @inbounds _publish_local_outputs!(batch.output_bindings[row], local_status, step)
            end
        end)
    end
    return quote
        $(setup...)
        for row in eachindex(getfield(node.batches, 1).statuses)
            @inbounds source = getfield(node.batches, 1).statuses[row]
            local_status = make_local_status(node.recipe, source)
            try
                $(stages...)
            finally
                # Preserve live partial state if a scientific method throws,
                # matching the ordinary executor's mutation behavior.
                writeback_local_status!(source, local_status, node.recipe)
            end
        end
        nothing
    end
end

function local_storage_checks()
    @testset "Scalar-local state recipes" begin
        for T in (Float32, Float64)
            shared = Ref(T(1))
            source = PSE.Status((a=shared, b=shared, c=Ref(T(2))))
            recipe = local_state_recipe(source)
            local_status = make_local_status(recipe, source)
            @test typeof(local_status.a) === T
            @test local_status isa PSE.Status
            @test PSE.refvalue(local_status, :a) === PSE.refvalue(local_status, :b)
            @test PSE.refvalue(local_status, :a) !== shared
            local_status.a = T(3)
            local_status.c = T(4)
            @test local_status.b === T(3)
            @test source.a === T(1)
            writeback_local_status!(source, local_status, recipe)
            @test source.a === T(3)
            @test source.b === T(3)
            @test source.c === T(4)
            @test_throws ArgumentError local_state_recipe(PSE.Status(a=T[1]))
            @test_throws ArgumentError local_state_recipe(PSE.Status((a=Ref{Real}(T(1)),)))
        end
        empty_status = PSE.Status()
        recipe = local_state_recipe(empty_status)
        local_status = make_local_status(recipe, empty_status)
        @test isempty(local_status)
        @test writeback_local_status!(empty_status, local_status, recipe) === nothing
    end
    return (passed=true, numeric_types=("Float32", "Float64"),
        aliases=:preserved, kernel_equations=:original_methods)
end
