# From One Object To A Multiscale CompositeModel

First run all models on one object with the concise `CompositeModel(models...;
status=...)` constructor. Then move organ-specific applications to leaf
objects and aggregate their outputs on a plant with `Many(...,
within=SelfPlant())` or an instance-local selector.

Compare collected, application-qualified outputs with `isapprox`. Exact bitwise
identity is not generally a valid requirement after changing reduction order.

