# External observation schema only; no numerical engine methods are replaced.
module StrictSnapshotObservations
using SHA
import PlantSimEngine
const JSON = PlantSimEngine.JSON
export strict_snapshot_value, strict_json, content_sha256
function strict_snapshot_value(value::Number)
    primitive=isprimitivetype(typeof(value))
    return (type=sprint(show,typeof(value); context=:module=>nothing),
        representation=repr(value), bits=primitive ? bitstring(value) : nothing,
        fields=primitive ? nothing : map(name->strict_snapshot_value(getfield(value,name)),fieldnames(typeof(value))))
end
strict_snapshot_value(value::Union{Nothing,Missing,Symbol,AbstractString}) =
    (type=sprint(show,typeof(value); context=:module=>nothing),representation=repr(value))
strict_snapshot_value(value::NamedTuple) =
    (kind=:NamedTuple,names=keys(value),values=map(strict_snapshot_value,values(value)))
strict_snapshot_value(value::Tuple) = (kind=:Tuple,values=map(strict_snapshot_value,value))
strict_snapshot_value(value::AbstractArray) =
    (type=sprint(show,typeof(value); context=:module=>nothing),
     element_type=sprint(show,eltype(value); context=:module=>nothing),
     shape=size(value),values=[strict_snapshot_value(item) for item in vec(value)])
function strict_snapshot_value(value::AbstractDict)
    return (type=sprint(show,typeof(value); context=:module=>nothing),
        key_type=sprint(show,keytype(value); context=:module=>nothing),
        value_type=sprint(show,valtype(value); context=:module=>nothing),
        entries=[(key=strict_snapshot_value(key),value=strict_snapshot_value(item))
            for (key,item) in sort!(collect(pairs(value));by=pair->repr(first(pair)))])
end
strict_snapshot_value(value::Type) =
    (type=:JuliaType,representation=sprint(show,value; context=:module=>nothing))
function strict_snapshot_value(value)
    names=fieldnames(typeof(value))
    return (type=sprint(show,typeof(value); context=:module=>nothing),
        names,fields=map(name->strict_snapshot_value(getfield(value,name)),names))
end

strict_json(value) = JSON.json(strict_snapshot_value(value))
content_sha256(value) = bytes2hex(sha256(strict_json(value)))
end
