# Importing An MTG

`objects_from_mtg(root)` converts MTG topology and labels into ordinary scene
objects. `Scene(root; applications=...)` performs the same adaptation and then
uses the normal Scene compiler. The MTG is an input representation, not a
second runtime.

For growth, prefer `add_organ!`: it creates the MTG node, applies the scene's
status policy, attaches status, and registers the corresponding object.

