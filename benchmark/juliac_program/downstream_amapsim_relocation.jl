module DownstreamAMAPSimRelocation
using SHA
import PlantSimEngine as PSE
function check_relocation(NC,source_bundle;
    evidence=joinpath(@__DIR__,"results","amapsim_relocation.json"))
    scratch=mktempdir("/private/tmp";prefix="amap-relocation-")
    bundle=joinpath(scratch,"relocated-bundle")
    cp(source_bundle,bundle)
    relocation_home=mkpath(joinpath(scratch,"fresh-home"))
    external_depot=mkpath(joinpath(scratch,"empty-external-depot"))
    working_directory=mkpath(joinpath(scratch,"empty-cwd"))
    @assert isempty(readdir(relocation_home)) && isempty(readdir(external_depot)) && isempty(readdir(working_directory))
    launcher=joinpath(bundle,"bin","run-pse-program")
    result=withenv("HOME"=>relocation_home,"JULIA_DEPOT_PATH"=>external_depot,
        "JULIA_PROJECT"=>nothing,"JULIA_LOAD_PATH"=>nothing) do
        cd(working_directory) do
            NC.check_native(launcher;nplants=1,steps=2,outputs=:all,profile=:merisier)
        end
    end
    record=(format_version=1,same_host=true,copied_bundle=bundle,source_bundle,
        fresh_home=relocation_home,empty_external_depot=external_depot,empty_cwd=working_directory,
        project_unset=true,load_path_unset=true,
        bundled_depot_note="launcher selects only the copied bundle's share/julia for bundled JLL artifacts",
        external_depot_still_empty=isempty(readdir(external_depot)),
        binary_sha256=bytes2hex(sha256(read(joinpath(bundle,"bin","pse_program")))),
        profile=result.profile,plants=result.plants,steps=result.steps,outputs=result.outputs,
        snapshot_bytes=result.bytes,snapshot_sha256=result.sha256,
        objects=result.work.objects,internodes=result.work.internodes,native=result.work.native,
        original_ordinary_byte_exact=true,timed=false)
    mkpath(dirname(evidence));write(evidence,PSE.JSON.json(record))
    return record
end
end
