# Visualizing Composite model Structure

Use `Diagnostics.explain_objects`, `Diagnostics.explain_scopes`, and `Diagnostics.explain_instances` to
obtain stable rows for plotting. Draw nodes by object ID and edges from parent
to child; color by scale, species, or instance. Keep simulation visualization
outside model kernels so model code remains independent of topology packages.
