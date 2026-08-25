# Importing An MTG

`objects_from_mtg(root)` converts MTG topology and labels into ordinary model
objects. `CompositeModel(root; applications=...)` performs the same adaptation and then
uses the normal CompositeModel compiler. The MTG is an input representation, not a
second runtime.

For growth, prefer `add_organ!`: it creates the MTG node, applies the model's
status policy by default, attaches status, and registers the corresponding
object.
