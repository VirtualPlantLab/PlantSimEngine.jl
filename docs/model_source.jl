module DocsSources

using Markdown
using PlantSimEngine

"""Render an exact source section, failing if its start or end marker moved."""
function section(relative_path, from, to=nothing)
    path = joinpath(pkgdir(PlantSimEngine), relative_path)
    source = read(path, String)
    starts = findall(from, source)
    length(starts) == 1 || error("Expected one start marker in $relative_path: $from")
    first_index = first(only(starts))
    last_index = lastindex(source)
    if !isnothing(to)
        stop = findnext(to, source, last(only(starts)) + 1)
        isnothing(stop) && error("Missing end marker in $relative_path: $to")
        last_index = prevind(source, first(stop))
    end
    code = strip(source[first_index:last_index])
    return Markdown.MD([Markdown.Code("julia", code)])
end

end
