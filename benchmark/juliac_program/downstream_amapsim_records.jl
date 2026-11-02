module DownstreamAMAPSimRecords
using SHA
import PlantSimEngine as PSE
_digest(path)=bytes2hex(sha256(read(path)))
function save_host_record(result;path=joinpath(@__DIR__,"results","amapsim_host_qualification.json"),
    source_root="/private/tmp/pse-juliac-large-20261102/sources/AMAPSim",
    typed_root="/private/tmp/pse-juliac-large-20261102/typed-sources/AMAPSim",
    evaluation_id="a4e17e57")
    profiles=(:branch46,:branch46,:branch46,:branch46,:merisier)
    length(result.cases)==length(profiles) || error("unexpected default qualification case matrix")
    cases=map(enumerate(result.cases)) do (i,c)
        relative=profiles[i]===:branch46 ? "test/fixtures/native_arena/branch46.fpa" : "test/fixtures/native_originals/merisier.fpa"
        (profile=profiles[i],configuration=(plants=c.plants,steps=c.steps,outputs=c.outputs,increment=.5,seed=1,
            input=relative,input_sha256=_digest(joinpath(source_root,relative))),
         result=(objects=c.work.objects,internodes=c.work.internodes,newborns=length(c.work.newborn_ids),
            lifetime_counter_entries=c.lifetime_counter_entries,registrations=c.registrations,removals=c.removals,
            geometry_updates=c.geometry_updates,native=c.work.native))
    end
    source_files=("downstream_amapsim_fixture.jl","downstream_amapsim_checks.jl",
        "downstream_amapsim_bridge.jl","app/src/object_program.jl","downstream_amapsim_typing.py")
    record=(format_version=1,execution=:warm_Julia_host,kaimon_evaluation_id=evaluation_id,
        julia=string(VERSION),pse=string(Base.pkgversion(PSE)),pse_root=pkgdir(PSE),project=Base.active_project(),
        scope=:original_native_AMAP_architecture_geometry_internode_projection,
        harness=(:original_LengthProbe,:identical_added_QualificationCount),
        ordinary_baselines=(:frozen_original_source,:separate_inference_typed_source),
        comparison=:all_native_mutable_fields_RNG_events_topology_geometry_canonical_status_and_retained_streams_every_step,
        source_root,typed_root,source_typing_manifest_sha256=_digest(joinpath(@__DIR__,"downstream_amapsim_typing.json")),
        source_patch_sha256=_digest(joinpath(@__DIR__,"downstream_amapsim_adapter_typing.patch")),
        fixture_sources=Dict(file=>_digest(joinpath(@__DIR__,file)) for file in source_files),
        passes=result.passes,failures=result.failures,optional_sampler_matrix=result.samplers,
        optional_sampler_note="30 seeded optional forwarding cases compare outputs/errors and complete RNG state; chosen LP matrix draws0; full Merisier scenario consumes actual RNG draws",cases)
    mkpath(dirname(path));write(path,PSE.JSON.json(record));return path
end
end
