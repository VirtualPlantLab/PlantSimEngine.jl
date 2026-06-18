# Create a TimeStepTable{Status} from a DataFrame:
"""
    TimeStepTable{Status}(df::DataFrame)
    
Method to build a `TimeStepTable` (from [PlantMeteo.jl](https://palmstudio.github.io/PlantMeteo.jl/stable/)) 
from a `DataFrame`, but with each row being a `Status`.

# Examples

```julia
using PlantSimEngine, DataFrames

# A TimeStepTable from a DataFrame:
df = DataFrame(
    Tₗ=[25.0, 26.0],
    aPPFD=[1000.0, 1200.0],
    Cₛ=[400.0, 400.0],
    Dₗ=[1.0, 1.2],
)
TimeStepTable{Status}(df)

# A TimeStepTable can also be built directly from Status values:
TimeStepTable(
    [
        Status(Tₗ=25.0, aPPFD=1000.0, Cₛ=400.0, Dₗ=1.0),
        Status(Tₗ=26.0, aPPFD=1200.0, Cₛ=400.0, Dₗ=1.2),
    ]
)
```
"""
function PlantMeteo.TimeStepTable{Status}(df::DataFrames.DataFrame, metadata=NamedTuple())
    PlantMeteo.TimeStepTable((propertynames(df)...,), metadata, [Status(NamedTuple(ts)) for ts in Tables.rows(df)])
end

# """
#     Tables.schema(m::TimeStepTable{Status})

# Create a schema for a `TimeStepTable{Status}`.
# """
# function Tables.schema(m::PlantMeteo.TimeStepTable{T}) where {T<:Status}
#     # This one is complicated because the types of the variables are hidden in the Status as RefValues:
#     # col_types = fieldtypes(getfield(m, :ts)[1])

#     # # Tables.Schema(names(m), DataType[i.types[1] for i in T.parameters[2].parameters])
#     # Tables.Schema(names(m), col_types)
# end
