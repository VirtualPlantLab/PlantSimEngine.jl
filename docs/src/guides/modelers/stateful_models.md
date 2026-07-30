# State, History, And Repeated Updates

Object `Status` is current state, not timestep storage. Use
`PreviousTimeStep(:x)` for a one-step lag, or keep a model-owned ring buffer
when the algorithm requires deeper history. Accepted output streams provide
simulation history.

Several writers to one canonical variable are rejected unless the application
declares `Updates`. Iterative trial execution belongs to `calls`; use
`publish=false` until a state is accepted.

