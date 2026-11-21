module PlantSimEngineSerializationExt

import PlantSimEngine: _WeakStatusChangeSink, ObjectId
import Serialization

# The registry owns the vector. Register the weak reference with the GC again
# on restore, and keep aliases when several statuses watch the same registry.
function Serialization.serialize(s::Serialization.AbstractSerializer, sink::_WeakStatusChangeSink)
    Serialization.serialize_cycle_header(s, sink) && return
    ids = sink.ids.value::Union{Nothing,Vector{ObjectId}}
    Serialization.serialize(s, ids)
    return nothing
end

function Serialization.deserialize(s::Serialization.AbstractSerializer, ::Type{_WeakStatusChangeSink})
    weak = WeakRef(nothing)
    sink = _WeakStatusChangeSink(weak)
    Serialization.deserialize_cycle(s, sink)
    weak.value = Serialization.deserialize(s)::Union{Nothing,Vector{ObjectId}}
    return sink
end

end
