module DocsSources

using Markdown
using Bonito: DOM
using PlantSimEngine

"""Read an exact source section, failing if its start or end marker moved."""
function read_section(relative_path, from, to=nothing)
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
    return strip(source[first_index:last_index])
end

"""Render a source section as a Julia code block."""
function section(relative_path, from, to=nothing)
    return Markdown.MD([Markdown.Code("julia", read_section(relative_path, from, to))])
end

"""Show source code in a closed, natively expandable HTML details element."""
function details(title, relative_path, from, to=nothing)
    code = read_section(relative_path, from, to)
    return DOM.details(
        DOM.summary(title),
        DOM.div(
            DOM.div(DOM.pre(DOM.code(code; class="language-julia")); class="language-julia");
            class="docstring-body",
        );
        class="jldocstring custom-block",
    )
end

end
