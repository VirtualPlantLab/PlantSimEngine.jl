module DownstreamAMAPSimMatrix
using SHA
import PlantSimEngine as PSE
_median(values)=let ordered=sort!(collect(values)), n=length(values)
    isodd(n) ? ordered[(n+1)÷2] : (ordered[n÷2]+ordered[n÷2+1])/2
end
_filehash(path)=bytes2hex(sha256(read(path)))
function run_matrix(M,launcher;destination=joinpath(@__DIR__,"results","amapsim_scaling"),samples=3)
    mkpath(destination)
    cases=((:branch46,1,16,:none),(:branch46,4,16,:none),(:branch46,16,16,:none),
        (:merisier,1,8,:none),(:merisier,4,8,:none),(:merisier,16,2,:none),(:merisier,4,8,:all))
    reports=NamedTuple[]
    for (profile,plants,steps,outputs) in cases
        name="$(profile)-$(plants)-$(steps)-$(outputs)"
        path=joinpath(destination,name*".json")
        if ispath(path)
            saved=PSE.JSON.parsefile(path)
            names=(:original_ordinary_s,:inference_typed_ordinary_s,:common_precompiled_ordinary_s,
                :registry_JIT_s,:native_s,:original_over_native,:common_over_native,:original_over_registry,:common_over_registry)
            medians=NamedTuple{names}(Tuple(Float64(saved["medians"][string(name)]) for name in names))
            push!(reports,(case=saved["case"],objects=saved["native"]["work"]["objects"],
                internodes=saved["native"]["work"]["internodes"],
                lifetime_counter_entries=saved["native"]["ordinary_lifetime_counter_entries"],
                registrations=saved["native"]["registrations"],removals=saved["native"]["removals"],medians=medians))
            @info "Preserving accepted checkpoint" name
            continue
        end
        @info "AMAP timing case" profile plants steps outputs
        result=M.measure_native_case(launcher;nplants=plants,steps,outputs,profile,samples)
        trials=result.jit.samples
        original=_median([x.original_ordinary.execution.seconds for x in trials])
        typed=_median([x.typed_ordinary.execution.seconds for x in trials])
        common=_median([x.typed_precompiled_ordinary.execution.seconds for x in trials])
        registry=_median([x.typed_compiled.execution.seconds for x in trials])
        native=_median([x.execution_s for x in result.native.samples])
        medians=(original_ordinary_s=original,inference_typed_ordinary_s=typed,
            common_precompiled_ordinary_s=common,registry_JIT_s=registry,native_s=native,
            original_over_native=original/native,common_over_native=common/native,
            original_over_registry=original/registry,common_over_registry=common/registry)
        raw=map(trials) do x
            (original_ordinary=(construction=x.original_ordinary.construction,preparation=x.original_ordinary.preparation,execution=x.original_ordinary.execution),
             inference_typed_ordinary=(construction=x.typed_ordinary.construction,preparation=x.typed_ordinary.preparation,execution=x.typed_ordinary.execution),
             common_precompiled_ordinary=(construction=x.typed_precompiled_ordinary.construction,preparation=x.typed_precompiled_ordinary.preparation,execution=x.typed_precompiled_ordinary.execution),
             registry_JIT=(instantiation=x.typed_compiled.instantiation,execution=x.typed_compiled.execution))
        end
        config=result.jit.config
        record=(format_version=1,case=name,configuration=(profile,plants,steps,outputs,increment=.5,seed=1,samples),
            julia=string(VERSION),pse=string(Base.pkgversion(PSE)),pse_root=pkgdir(PSE),
            source_origin_revision=config.source_origin_revision,input_sha256=config.input_sha256,
            source_typing_manifest_sha256=_filehash(joinpath(@__DIR__,"downstream_amapsim_typing.json")),
            source_patch_sha256=_filehash(joinpath(@__DIR__,"downstream_amapsim_adapter_typing.patch")),
            measurement_driver_sha256=_filehash(joinpath(@__DIR__,"downstream_amapsim_measurements.jl")),
            medians,authoring=result.jit.authoring,planning=result.jit.planning,raw_JIT=raw,
            native=result.native,final_fingerprint=last(trials).original_ordinary.fingerprint,
            timing_boundary=:fresh_prepared_state_execution_without_source_hashing_or_snapshot_IO,
            construction_note=result.jit.construction_note,
            primary_baseline=:original_ordinary_PSE,common_input_control=:ordinary_PSE_same_precompiled_native_tables,
            control_factory=:original_plant_declaration_order_v2)
        # Native work has a large newborn-ID vector; preserve counts, not repeat
        # thousands of identities in every timing checkpoint. Exact snapshot
        # hashes above certify the complete identities/topology/status/history.
        work=result.native.work
        native_compact=merge(result.native,(work=(plants=work.plants,steps=work.steps,objects=work.objects,
            internodes=work.internodes,newborns=length(work.newborn_ids),
            surviving_object_qualification_invocations=work.surviving_object_qualification_invocations,native=work.native),))
        record=merge(record,(native=native_compact,))
        write(path*".partial",PSE.JSON.json(record));mv(path*".partial",path)
        push!(reports,(case=name,objects=work.objects,internodes=work.internodes,
            lifetime_counter_entries=result.native.ordinary_lifetime_counter_entries,
            registrations=result.native.registrations,removals=result.native.removals,medians=medians))
        @info "AMAP checkpoint saved" name objects=work.objects medians
    end
    write(joinpath(destination,"summary.json"),PSE.JSON.json((format_version=1,samples,
        provenance_note="First two checkpoints predate a control-only factory correction for lexicographic versus declaration order at populations>=10; their n1/n4 execution graphs and timing boundary are unchanged. Remaining checkpoints use declaration-order v2.",cases=reports)))
    return reports
end
end
