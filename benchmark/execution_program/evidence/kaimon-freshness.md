# Kaimon fresh-image restart evidence

Source-only inspection on 2026-10-30 found local installed **Kaimon 2.9.0**
at `/Users/rvezy/.julia/packages/Kaimon/IfYKv` and **KaimonGate 1.4.0** at
`/Users/rvezy/.julia/packages/KaimonGate/YvD3m`. No Julia/session command was
executed, runtime package paths were not queried, and no Kaimon configuration
or external source was changed.

On macOS/Unix, restart replaces the Julia **process image while preserving the
PID**. The installed gate's
[restart implementation](/Users/rvezy/.julia/packages/KaimonGate/YvD3m/src/gate_protocol.jl:321)
states this explicitly at line 321 and calls `execvp` at line 340. Lines 262–298
reconstruct the launch arguments and carry the same session ID into the new
image. Lines 545–581 handle `:restart`, perform cleanup, and invoke that
replacement. This is a fresh Julia address space, including globals and JIT
state, after a successful exec; it is not an in-process workspace reset.

The Kaimon
[tool handler](/Users/rvezy/.julia/packages/Kaimon/IfYKv/src/tool_definitions_core.jl:578)
checks restart permission and refuses to restart its own coordinator process
(lines 578–587), sends the gate restart request (589), disconnects the old
connection (599–607), and waits for the same session key to reconnect
(610–618). The success text is emitted on reconnection. There is no separate
managed-session or externally started-session soft-reset branch in this
handler. The
[client helper](/Users/rvezy/.julia/packages/Kaimon/IfYKv/src/gate_client_request.jl:474)
likewise describes a gate exec and sends `:restart` (474–483). Managed workers
[boot KaimonGate](/Users/rvezy/.julia/packages/Kaimon/IfYKv/src/session_manager.jl:54)
using the target project (54–70), then use this gate protocol.

Consequently, unchanged `Base.getpid()` and a long `ps` process elapsed time or
cumulative CPU time do **not** establish that Julia globals/JIT state survived.
They describe the OS process identity, which `execvp` preserves. This explains
why restart receipts 023/033 and PID 53643 can be consistent with fresh Julia
images. The source does not independently prove that every historical exec
completed; a PID observation alone cannot distinguish image generations.
There are explicit exec-failure paths at gate lines 342–344 and 573–577.

Future cold arms will use explicit **shutdown, start, and verification of a
different PID**, plus package/project/source provenance, to make each cohort
easy to attest. A before/after `Main` sentinel and loaded-module check can also
distinguish Julia images when using restart. Process freshness remains
separate from disk precompile caches, the configured sysimage, and filesystem
caches. Prior restart checks should be described as fresh-image checks when
their evidence supports that wording, without an unsupported soft-reset claim.

The installed KaimonGate protocol and Kaimon's vendored
`lib/KaimonGate/src/gate_protocol.jl` had identical SHA-256 hashes.

| Local source | SHA-256 |
| --- | --- |
| `Kaimon/IfYKv/Project.toml` | `09d14d425e073ec0440253f7fac7f8d8c3b86a17ae4c1e6c3796455479685143` |
| `Kaimon/IfYKv/src/tool_definitions_core.jl` | `04a39afeb4ef58963f4c8b5ab7c89ceb954205af329d9a850792d582d1c05f4a` |
| `Kaimon/IfYKv/src/gate_client_request.jl` | `edc58d8436d4b8035b7ce078f495af68617a21d74a75e0fbea2cad1abe645142` |
| `Kaimon/IfYKv/src/session_manager.jl` | `8dc75616763dc9aa54c7cbcf6814bbe4c964f9b1feed664ff9a5a636a175be2e` |
| `KaimonGate/YvD3m/Project.toml` | `3b6ff12c18e6f1657d9e17f7b3c57d96fa819bced84506feb2d37ca6390dbfa9` |
| `KaimonGate/YvD3m/src/gate_protocol.jl` | `9204b65d05ce5193bf5c98309e1d9fe1a29ca356177f9efbc88666c8b9ee6997` |

All table paths are relative to `/Users/rvezy/.julia/packages/`.
