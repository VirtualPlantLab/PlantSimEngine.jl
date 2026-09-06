module GenericJuliaFixture

export stable_merge_sort

function stable_merge_sort(values::AbstractVector{T}) where {T}
    length(values) <= 1 && return collect(values)
    middle = length(values) ÷ 2
    left = stable_merge_sort(view(values, firstindex(values):middle))
    right = stable_merge_sort(view(values, (middle + 1):lastindex(values)))
    return merge_sorted(left, right)
end

function merge_sorted(left::Vector{T}, right::Vector{T}) where {T}
    result = T[]
    left_index = firstindex(left)
    right_index = firstindex(right)
    while left_index <= lastindex(left) && right_index <= lastindex(right)
        if isless(right[right_index], left[left_index])
            push!(result, right[right_index])
            right_index += 1
        else
            push!(result, left[left_index])
            left_index += 1
        end
    end
    append!(result, @view left[left_index:lastindex(left)])
    append!(result, @view right[right_index:lastindex(right)])
    return result
end

end # module GenericJuliaFixture
