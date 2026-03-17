# Automated tests : downstream dependency checking

PlantSimEngine is [open sourced on Github](https://github.com/VirtualPlantLab/PlantSimEngine.jl), and so are its other companion packages, [PlantGeom.jl](https://github.com/VEZY/PlantGeom.jl), [PlantMeteo.jl](https://github.com/VEZY/PlantMeteo.jl), [PlantBioPhysics.jl](https://github.com/VEZY/PlantBioPhysics.jl), [MultiScaleTreeGraph.jl](https://github.com/VEZY/MultiScaleTreeGraph.jl), and [XPalm](https://github.com/PalmStudio/XPalm.jl).

One handy CI (Continuous Integration) feature implemented for these packages is automated integration and downstream testing: after changes to a package, its known downstream dependencies are tested to ensure no breaking changes were introduced. 

For instance, PlantBioPhysics uses PlantSimEngine, so the integration workflow checks that PlantBioPhysics's tests do not break unexpectedly after changes to PlantSimEngine. The repository also keeps a separate benchmark workflow and benchmark scripts in the `benchmark/` directory for performance tracking.

If you maintain a package that depends on PlantSimEngine, you can propose adding it to the downstream integration workflow through a pull request.
