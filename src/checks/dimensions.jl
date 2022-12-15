"""
    check_dimensions(component,weather)
    check_dimensions(status,weather)

Checks if a component status (or a status directly) and the weather have the same length, or if they can be
recycled (length 1).
"""
function check_dimensions(
    st::T,
    weather::TimeStepTable{A}
) where {T<:TimeStepTable,A<:PlantMeteo.AbstractAtmosphere}

    length(st) > 1 && length(st) != length(weather) &&
        throw(DimensionMismatch("Component status should have the same number of time-steps ($(length(st))) than weather data ($(length(weather)))."))

    return nothing
end

# A Status (one time-step) is always authorized with a Weather (it is recycled).
# The status is updated at each time-step, but no intermediate saving though!
function check_dimensions(
    st::T,
    weather::TimeStepTable{A}
) where {T<:Status,A<:PlantMeteo.AbstractAtmosphere}
    return nothing
end

function check_dimensions(
    st,
    weather::Atmosphere
)
    return nothing
end

# We define this one just to avoid ambiguity between the two above
function check_dimensions(component::T, w::Atmosphere) where {T<:ModelList}
    return nothing
end

function check_dimensions(component::T, w) where {T<:ModelList}
    check_dimensions(status(component), w)
end

# for several components as an array
function check_dimensions(component::T, weather::TimeStepTable{A}) where {T<:AbstractArray{<:ModelList},A<:PlantMeteo.AbstractAtmosphere}
    for i in component
        check_dimensions(i, weather)
    end
end

# for several components as a Dict
function check_dimensions(component::T, weather::TimeStepTable{A}) where {T<:AbstractDict{N,<:ModelList},A<:PlantMeteo.AbstractAtmosphere} where {N}
    for (key, val) in component
        check_dimensions(val, weather)
    end
end
