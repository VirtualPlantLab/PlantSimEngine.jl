# Create a TimeStepTable{Status} from a DataFrame:
"""
    TimeStepTable{Status}(df::DataFrame)
    
Method to build a `TimeStepTable` from a `DataFrame`, but with each 
row being a `Status`.

# Note 

[`ModelList`](@ref) uses `TimeStepTable{Status}` by default (see examples below).

# Examples

```julia
# A TimeStepTable from a DataFrame:
using DataFrames
df = DataFrame(
    Tₗ=[25.0, 26.0],
    PPFD=[1000.0, 1200.0],
    Cₛ=[400.0, 400.0],
    Dₗ=[1.0, 1.2],
)
TimeStepTable{Status}(df)

# A leaf with several values for at least one of its variable will automatically use 
# TimeStepTable{Status} with the time steps:
leaf = ModelList(
    photosynthesis = Fvcb(),
    stomatal_conductance = Medlyn(0.03, 12.0),
    status=(Tₗ=[25.0, 26.0], PPFD=1000.0, Cₛ=400.0, Dₗ=1.0)
)

# The status of the leaf is a TimeStepTable:
status(leaf)

# Of course we can also create a TimeStepTable with Status manually:
TimeStepTable(
    [
        Status(Tₗ=25.0, PPFD=1000.0, Cₛ=400.0, Dₗ=1.0),
        Status(Tₗ=26.0, PPFD=1200.0, Cₛ=400.0, Dₗ=1.2),
    ]
)
```
"""
function PlantMeteo.TimeStepTable{Status}(df::DataFrames.DataFrame, metadata=NamedTuple())
    PlantMeteo.TimeStepTable((propertynames(df)...,), metadata, [Status(NamedTuple(ts)) for ts in Tables.rows(df)])
end

"""
    Tables.schema(m::TimeStepTable{Status})

Create a schema for a `TimeStepTable{Status}`.
"""
function Tables.schema(m::PlantMeteo.TimeStepTable{T}) where {T<:Status}
    # This one is complicated because the types of the variables are hidden in the Status as RefValues:
    Tables.Schema(names(m), DataType[i.types[1] for i in T.parameters[2].parameters])
end