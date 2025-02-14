## Downstream tests

PlantSimEngine is open sourced on Github [](TODO), and so are its other companion packages, PlantGeom, PlantMeteo, PlantBioPhysics, MultiScaleTreeGraph, and XPalm.

One handy Continuous Integration feature implemented for these packages is automated integration and downstream testing : after changes to a package, its known downstream dependencies are tested to ensure no breaking changes were introduced. For instance, PlantBioPhysics is used in PlantSimEngine, so an integration test ensures that PlantBioPhysics doesn't break in an unforeseen manner after a new PlantSimEngine release.

This is something you can take advantage of if you wish to develop using PlantSimEngine, by providing us with your package name (or adding it to the CI yml file in a Pull Request) ; we can then add it to the list of downstream packages to test, and generate PR when breaking changes are introduced.

## Help improve our documentation !