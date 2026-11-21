# Separate from the short public native_compilation.jl runner and its 15-minute budget.
# Run in the same PSE/JuliaC environment, with builds performed sequentially.
using PlantSimEngine, JuliaC, Test, SHA
include("native_fixture_apps.jl")
using .NativeFixtureApps

const _growth_root = pkgdir(PlantSimEngine)
const _palm_growth_app = stage_native_fixture(joinpath(_growth_root,
    "test", "fixtures", "local_palm_leaf_birth"))
const _producer_growth_app = stage_native_fixture(joinpath(_growth_root,
    "test", "integration", "fixtures", "distributed_producer_birth");
    fixture_sources=(
        joinpath(_growth_root, "test", "fixtures", "distributed_growth.jl") => "distributed_growth.jl",
        joinpath(_growth_root, "test", "fixtures", "raw_status_readers.jl") => "raw_status_readers.jl",
    ))
# App modules and all preparation methods exist before entering the testset.
Base.include(@__MODULE__, joinpath(_palm_growth_app, "src", "PSELocalPalmLeafBirth.jl"))
Base.include(@__MODULE__, joinpath(_producer_growth_app, "src", "PSEThirtyProducerControl.jl"))

const _scene_dependency_app = stage_native_fixture(joinpath(_growth_root,
    "test", "integration", "fixtures", "scene_dependencies"))
Base.include(@__MODULE__, joinpath(_scene_dependency_app, "src", "PSESceneDependencyControl.jl"))

function _split_neighbour_report(words)
    length(words) >= 8 || error("Incomplete native neighbour report.")
    words[end-5] == 0x50484153454e5343 || error("Missing native phase timing tag.")
    names = (:acquisition, :warmup3, :register, :refresh0, :postbirth_step)
    return (neighbours=words[1:end-6],
        timings_ns=NamedTuple{names}(Tuple(words[end-4:end])))
end

function _ordinary_palm_growth_report(neighbours)
    fixture = PSELocalPalmLeafBirth.LocalPalmLeafBirth
    initial = fixture.prepare_scene(fixture.make_scene(0))
    result = fixture.native_run!(initial, neighbours)
    result.ok || error("The ordinary public palm control failed.")
    report = _split_neighbour_report(PSELocalPalmLeafBirth.neighbour_report(result.state, result.timings))
    return (; a=PSELocalPalmLeafBirth.a_report(result.state, neighbours), report...)
end

function _native_palm_growth_report(executable, neighbours, directory)
    stdout_path = joinpath(directory, "palm-$(neighbours)-stdout.bin")
    stderr_path = joinpath(directory, "palm-$(neighbours)-stderr.bin")
    open(stdout_path, "w") do stdout_io
        open(stderr_path, "w") do stderr_io
            # Exactly one process for each count, using the same executable.
            run(pipeline(`$executable $neighbours`; stdout=stdout_io, stderr=stderr_io))
        end
    end
    stdout_bytes, stderr_bytes = read(stdout_path), read(stderr_path)
    length(stdout_bytes) % sizeof(UInt64) == 0 || error("Invalid native A report.")
    length(stderr_bytes) % sizeof(UInt64) == 0 || error("Invalid native neighbour report.")
    a = copy(reinterpret(UInt64, stdout_bytes))
    report = _split_neighbour_report(copy(reinterpret(UInt64, stderr_bytes)))
    return (; a, report...)
end

@testset "Native growth preserves local palms and thirty distributed destinations" begin
    @testset "Palm with zero and one hundred neighbours" begin
        mktempdir() do directory
            expected_zero = _ordinary_palm_growth_report(0)
            expected_hundred = _ordinary_palm_growth_report(100)
            # Header counts differ; A's timestep, values and sixteen histories do not.
            @test expected_zero.a[5:end] == expected_hundred.a[5:end]
            palm = Compilation.compile(_palm_growth_app; destination=joinpath(directory, "palm"))
            @test isfile(palm.executable)
            digest = sha256(read(palm.executable))
            if !isnothing(PSELocalPalmLeafBirth.TREE_BIRTH)
                @test PSELocalPalmLeafBirth.main(["tree"]) == 0
                @test success(`$(palm.executable) tree`)
            end
            zero = _native_palm_growth_report(palm.executable, 0, directory)
            hundred = _native_palm_growth_report(palm.executable, 100, directory)
            @test sha256(read(palm.executable)) == digest
            @test zero.a == expected_zero.a
            @test hundred.a == expected_hundred.a
            @test zero.a[5:end] == hundred.a[5:end]
            @test zero.neighbours == expected_zero.neighbours
            @test hundred.neighbours == expected_hundred.neighbours
            # Durations are observations, with no threshold or cross-process equality.
            @info "Native palm phases (nanoseconds)" neighbours=0 phases=zero.timings_ns
            @info "Native palm phases (nanoseconds)" neighbours=100 phases=hundred.timings_ns
        end
    end

    @testset "New producer publishes to thirty existing leaves" begin
        mktempdir() do directory
            @test PSEThirtyProducerControl.checkpoint(PSEThirtyProducerControl.STATE, 0)
            @test PSEThirtyProducerControl.main(String[]) == 0
            @test PSEThirtyProducerControl.main(["recover"]) == 0
            @test PSEThirtyProducerControl.main(["first-leaf"]) == 0
            producer = Compilation.compile(_producer_growth_app;
                destination=joinpath(directory, "producer"))
            @test isfile(producer.executable)
            # main checks every destination, every sample, and the same cells/streams.
            @test success(`$(producer.executable)`)
            @test success(`$(producer.executable) recover`)
            @test success(`$(producer.executable) first-leaf`)
        end
    end
end

@testset "Native scene and relative model-call selectors" begin
    mktempdir() do directory
        scene = Compilation.compile(_scene_dependency_app; destination=joinpath(directory, "scene"))
        for args in (String[], ["crown"])
            @test PSESceneDependencyControl.main(args) == 0
            @test success(`$(scene.executable) $args`)
        end
    end
end
