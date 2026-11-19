module OrdinaryObservations
using Dates
export canonical, TYPE_LABELS

# Only diagnostic type labels are memoized. Julia 1.13's alias display can
# otherwise dominate the untimed snapshot of thousands of scientific arrays.
const TYPE_LABELS = IdDict{Any,String}()
_type_label(T::Type) = get!(() -> string(T), TYPE_LABELS, T)
canonical(value::Union{Nothing,Missing,Symbol,AbstractString}) = value
canonical(value::Union{Dates.TimeType,Dates.Period}) = (type=_type_label(typeof(value)), value=repr(value))
canonical(value::Number) = (type=_type_label(typeof(value)), value=value)
canonical(value::Type) = (type=:JuliaType, value=_type_label(value))
canonical(value::NamedTuple) = NamedTuple{keys(value)}(map(canonical, values(value)))
canonical(value::Tuple) = map(canonical, value)
canonical(value::Pair) = (canonical(first(value)), canonical(last(value)))
canonical(value::AbstractArray) = (type=_type_label(typeof(value)), element_type=_type_label(eltype(value)),
    shape=size(value), values=[canonical(item) for item in vec(value)])
canonical(value::AbstractDict) = [(key=canonical(key), value=canonical(item))
    for (key,item) in sort!(collect(pairs(value)); by=pair -> repr(first(pair)))]
function canonical(value)
    names = fieldnames(typeof(value))
    return (type=_type_label(typeof(value)), fields=NamedTuple{names}(
        Tuple(canonical(getfield(value, name)) for name in names)))
end

end
