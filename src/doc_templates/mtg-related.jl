const MTG_EXAMPLE = """
```@example
mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Scene", 1, 0));
```

```@example
soil = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Soil", 1, 1));
```

```@example
plant = Node(mtg, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1));
```

```@example
internode1 = Node(plant, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2));
```

```@example
leaf1 = Node(internode1, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2));
```

```@example
internode2 = Node(internode1, MultiScaleTreeGraph.NodeMTG("<", "Internode", 1, 2));
```

```@example
leaf2 = Node(internode2, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2));
```
"""

const MAPPING_EXAMPLE = """
```@example
mapping = Dict( \
    "Plant" =>  \
        MultiScaleModel(  \
            model=ToyCAllocationModel(), \
            mapping=[ \
                :A => ["Leaf"], \
                :carbon_demand => ["Leaf", "Internode"], \
                :carbon_allocation => ["Leaf", "Internode"] \
            ], \
        ), \
    "Internode" => ( \
        ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0), \
        Status(TT=10.0) \
    ), \
    "Leaf" => ( \
        MultiScaleModel( \
            model=ToyAssimModel(), \
            mapping=[:soil_water_content => "Soil",], \
        ), \
        ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0), \
        Status(aPPFD=1300.0, TT=10.0), \
    ), \
    "Soil" => ( \
        ToySoilWaterModel(), \
    ), \
)
```
"""

const EXAMPLE_MTG_MODELS = """
```@example
include(joinpath(pkgdir(PlantSimEngine), "examples/ToyAssimModel.jl"));
```

```@example
include(joinpath(pkgdir(PlantSimEngine), "examples/ToyCDemandModel.jl"));
```

```@example
include(joinpath(pkgdir(PlantSimEngine), "examples/ToyCAllocationModel.jl"));
```

```@example
include(joinpath(pkgdir(PlantSimEngine), "examples/ToySoilModel.jl"));
```
"""