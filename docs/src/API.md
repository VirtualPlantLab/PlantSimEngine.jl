# API

## Index

```@index
Modules = [PlantSimEngine]
```

## API documentation

```@autodocs
Modules = [PlantSimEngine]
Private = false
```

## Un-exported

Private functions, types or constants from `PlantSimEngine`. These are not exported, so you need to use `PlantSimEngine.` to access them (*e.g.* `PlantSimEngine.DataFormat`). 

```@autodocs
Modules = [PlantSimEngine]
Public = false
Private = true
```

## Example models

PlantSimEngine provides example processes and models to users. They are available from a sub-module called `Examples`. To get access to these models, you can simply use this sub-module:

```julia
using PlantSimEngine.Examples
```

The models are detailed below.

```@autodocs
Modules = [PlantSimEngine.Examples]
Public = true
Private = true
```
