module DistributedRouteOwnershipChecks
using PlantSimEngine, Test
const PSE = PlantSimEngine
PSE.@process "route_ownership_before" verbose=false
PSE.@process "route_ownership_broken" verbose=false
PSE.@process "route_ownership_writer" verbose=false

struct Before <: AbstractRoute_Ownership_BeforeModel end
PSE.inputs_(::Before) = NamedTuple()
PSE.outputs_(::Before) = (before=0,)
PSE.run!(::Before, status, environment, constants, context) = (status.before += 1; nothing)

const failed_output_calls = Ref(0)
struct Broken <: AbstractRoute_Ownership_BrokenModel end
PSE.inputs_(::Broken) = NamedTuple()
function PSE.outputs_(::Broken)
    failed_output_calls[] += 1
    error("intentional route ownership authoring failure")
end

struct Writer{S,C} <: AbstractRoute_Ownership_WriterModel
    seed::S
    output_calls::C
end
PSE.inputs_(::Writer) = NamedTuple()
function PSE.outputs_(model::Writer)
    model.output_calls[] += 1
    return (writer_runs=0, payload=Distributed(Default(fill(model.seed[], 2))))
end
PSE.run!(::Writer, status, environment, constants, context) = (status.writer_runs += 1; nothing)

writer_spec(writer) = ModelSpec(writer; name=:writer, on=One(id=:scene),
    outputs_to=(OutputTo(Many(scale=:Leaf, within=SceneScope())),))

@testset "public diagnostics retain distributed outputs after a skipped authored slot" begin
    failed_output_calls[] = 0
    seed, queries = Ref(1f0), Ref(0)
    model = CompositeModel(Object(:scene; scale=:Scene), Object(:a; scale=:Leaf),
        Object(:b; scale=:Leaf); applications=(
            ModelSpec(Before(); name=:before, on=One(id=:scene)),
            ModelSpec(Broken(); name=:broken, on=One(id=:scene)),
            writer_spec(Writer(seed, queries)),
        ))
    @test failed_output_calls[] == 1
    seed[] = 7f0
    report = PSE.compile_model_report(model)
    @test [app.id for app in report.applications] == [:before, :writer]
    @test [app.slot for app in report.applications] == [1, 3]
    @test failed_output_calls[] == 1
    messages = [diagnostic.message for diagnostic in report.diagnostics]
    @test !any(message -> occursin("BoundsError", message), messages)
    @test any(message -> occursin("intentional route ownership", message), messages)
    left, right = model_status(report.model, :a), model_status(report.model, :b)
    has_left = left isa Status && hasproperty(left, :payload)
    has_right = right isa Status && hasproperty(right, :payload)
    @test has_left && has_right
    if has_left && has_right
        @test left.payload == right.payload == fill(7f0, 2)
        @test identity(left.payload !== right.payload)
    end
    @test isnothing(model_status(model, :a))
    @test isnothing(model_status(model, :b))
    @test identity(PSE.Advanced.compiled_bindings(model) === nothing)
end

@testset "real initial and newborn distributed defaults use fresh model values" begin
    seed, queries = Ref(1f0), Ref(0)
    supplied = Float32[99, 99]
    model = CompositeModel(Object(:scene; scale=:Scene),
        Object(:a; scale=:Leaf, status=Status(payload=supplied)),
        Object(:b; scale=:Leaf); applications=(writer_spec(Writer(seed, queries)),))
    author_calls = queries[]
    seed[] = 7f0
    simulation = run!(model; outputs=:all)
    a, b = model_status(model, :a), model_status(model, :b)
    @test queries[] > author_calls
    @test identity(a.payload === supplied)
    @test a.payload == Float32[99, 99]
    @test b.payload == Float32[7, 7]
    @test identity(a.payload !== b.payload)
    before_birth_calls = queries[]
    b.payload[1] = 42f0
    seed[] = 11f0
    register_object!(model, Object(:c; scale=:Leaf))
    step!(simulation)
    c = model_status(model, :c)
    @test queries[] > before_birth_calls
    @test a.payload == Float32[99, 99]
    @test b.payload == Float32[42, 7]
    @test c.payload == Float32[11, 11]
    @test identity(c.payload !== a.payload && c.payload !== b.payload)
    @test model_status(model, :scene).writer_runs == 2
    @test outputs(simulation)[(:writer, ObjectId(:scene), :writer_runs)] == [(1.0, 1), (2.0, 2)]
end
@testset "logical destination plans keep static names and no scientific defaults" begin
    seed, queries = Ref(2f0), Ref(0)
    spec = writer_spec(Writer(seed, queries))
    before_layout = queries[]
    layout = only(PSE._output_destination_layout(spec, (:payload,)))
    @test queries[] == before_layout
    @test layout.variable_names === (:payload,)
    @test layout.origin === :inferred
    @test layout.coverage === :exact
    model = CompositeModel(Object(:scene; scale=:Scene),
        Object(:leaf; scale=:Leaf); applications=(spec,))
    applications = PSE._compile_model_applications(model, model.applications,
        PSE._model_timeline(model))
    destinations = PSE._compile_model_output_destination_plans(model, applications)
    plan = only(destinations.plans)
    @test (@inferred PSE._output_destination_variable_names(plan)) === (:payload,)
    @test !hasproperty(plan, :declarations)
    @test !(:declarations in fieldnames(typeof(plan)))
    @test plan.variable_names === (:payload,)
    seed[] = 8f0
    before_actual = queries[]
    declarations = @inferred PSE._model_output_destination_declarations(
        only(applications), ObjectId(:scene), plan)
    @test queries[] == before_actual + 1
    @test declarations.payload.value == Float32[8, 8]
    resolved = only(PSE._resolve_model_output_destinations(model, PSE._applications_by_id(applications), destinations))
    @test identity(resolved.plan === plan)
    @test resolved.declarations.payload.value == Float32[8, 8]
    @test isnothing(model_status(model, :leaf))
    simulation = run!(model; steps=0)
    binding = only(simulation.compiled.distributed_outputs.bindings)
    @test binding.variable_names === (:payload,)
    @test !hasproperty(binding, :declarations)
    @test !(:declarations in fieldnames(typeof(binding)))
    @test identity(binding.columns.payload[1] === model_status(model, :leaf).payload)
end

@testset "public graph views and destination edits preserve exact resolved port names" begin
    GE = PSE.GraphEditor
    model = CompositeModel(Object(:scene; scale=:Scene),
        Object(:leaf; scale=:Leaf); applications=(writer_spec(Writer(Ref(3f0), Ref(0))),))
    view = GE.model_graph_view(model)
    @test isempty(view.diagnostics)
    inferred = only(only(view.applications)["outputsTo"])
    @test inferred["vars"] === nothing
    @test inferred["origin"] == "inferred"
    @test inferred["resolvedVars"] == ["payload"]

    edited = GE.apply_model_graph_edit(model, GE.SetModelOutputDestinations(
        GE.GlobalApplicationRef(:writer), (OutputTo(One(id=:leaf); vars=(:payload,)),),
    ))
    explicit_view = GE.model_graph_view(edited)
    @test isempty(explicit_view.diagnostics)
    explicit = only(only(explicit_view.applications)["outputsTo"])
    @test explicit["vars"] == ["payload"]
    @test explicit["origin"] == "explicit"
    @test explicit["resolvedVars"] == ["payload"]
    @test only(outputs_to(only(model.applications))).vars === nothing
    @test only(outputs_to(only(edited.applications))).vars === (:payload,)
    @test_throws "not declared as a Distributed output" GE.apply_model_graph_edit(
        model, GE.SetModelOutputDestinations(GE.GlobalApplicationRef(:writer),
            (OutputTo(One(id=:leaf); vars=(:unknown,)),)),
    )
    @test isnothing(model_status(model, :leaf))
    @test isnothing(model_status(edited, :leaf))
end

end
