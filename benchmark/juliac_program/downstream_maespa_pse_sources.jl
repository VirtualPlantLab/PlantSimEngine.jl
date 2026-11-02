module DownstreamMAESPAPSESources

using SHA
import PlantSimEngine
const JSON=PlantSimEngine.JSON

"""Hash the loaded local-path PSE dependency, including all src/ext files.
The resolved native Manifest pins registry/git dependencies separately.
"""
function snapshot(;root=dirname(dirname(pathof(PlantSimEngine))))
    root=realpath(root)
    files=String[joinpath(root,"Project.toml")]
    for directory in ("src","ext")
        location=joinpath(root,directory)
        isdir(location) || continue
        islink(location) && error("PSE source inventory refuses symbolic links")
        for (parent,directories,names) in walkdir(location)
            any(name->islink(joinpath(parent,name)),directories) && error("PSE source inventory refuses symbolic links")
            for name in names
                file=joinpath(parent,name)
                islink(file) && error("PSE source inventory refuses symbolic links")
                isfile(file) && push!(files,file)
            end
        end
    end
    sort!(unique!(files))
    any(islink,files) && error("PSE source inventory refuses symbolic links")
    rows=[(path=relpath(file,root),sha256=bytes2hex(sha256(read(file)))) for file in files]
    aggregate=bytes2hex(sha256(join((row.path*"\0"*row.sha256 for row in rows),"\n")))
    return (format_version=1,root,loaded_path=pathof(PlantSimEngine),
        version=string(Base.pkgversion(PlantSimEngine)),files=rows,aggregate_sha256=aggregate)
end

_get(value::AbstractDict,name::Symbol)=value[String(name)]
_get(value,name::Symbol)=getproperty(value,name)
function _canonical(value)
    _get(value,:format_version)==1 || error("unsupported PSE source inventory format")
    rows=[(path=String(_get(row,:path)),sha256=String(_get(row,:sha256))) for row in _get(value,:files)]
    paths=getproperty.(rows,:path)
    issorted(paths) && length(unique(paths))==length(paths) || error("PSE source inventory paths must be sorted and unique")
    aggregate=bytes2hex(sha256(join((row.path*"\0"*row.sha256 for row in rows),"\n")))
    aggregate==_get(value,:aggregate_sha256) || error("PSE source inventory aggregate is invalid")
    return (version=String(_get(value,:version)),files=rows,aggregate_sha256=aggregate)
end

function verify_unchanged(expected,current=snapshot())
    isequal(_canonical(expected),_canonical(current)) || error("loaded PSE dependency sources changed or differ from the native build")
    return current
end

function write_snapshot(path,value=snapshot())
    _canonical(value)
    write(path,JSON.json(value)*"\n")
    return path
end

function verify_archived(path;current=snapshot(),expected_aggregate=nothing)
    archived=JSON.parsefile(path)
    if !isnothing(expected_aggregate)
        _get(archived,:aggregate_sha256)==expected_aggregate || error("native PSE source identity differs from build metadata")
    end
    verify_unchanged(archived,current)
    return archived
end

end
