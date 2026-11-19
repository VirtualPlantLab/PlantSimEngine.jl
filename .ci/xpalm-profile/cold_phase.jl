# Diagnostic only. This macro returns the original expression's value unchanged.
# Use explicit Symbol labels and a dedicated phase IO; do not pass model getters.
macro cold_phase(destination, label, expression)
    quote
        local phase_io = $(esc(destination))
        local phase_label = $(esc(label))
        phase_label isa Symbol || throw(ArgumentError("Use a literal cold phase Symbol."))
        occursin(r"^[A-Za-z][A-Za-z_0-9]{0,63}$", String(phase_label)) ||
            throw(ArgumentError("Cold phase labels must be explicit ASCII identifiers."))
        # fflush(NULL) covers C stdio FILE streams beyond stdout/stderr.
        # Correlation remains stream order; this does not flush unknown Julia
        # runtime-private buffers or identify a callee still being compiled.
        ccall(:fflush, Cint, (Ptr{Cvoid},), C_NULL) == 0 || error("C stdio flush failed.")
        flush(phase_io)
        println(phase_io, "COLD_PHASE\tbefore\t", phase_label)
        flush(phase_io)
        local phase_returned = false
        try
            local measured = Base.@timed $(esc(expression))
            ccall(:fflush, Cint, (Ptr{Cvoid},), C_NULL) == 0 || error("C stdio flush failed.")
            flush(phase_io)
            println(phase_io, "COLD_PHASE\tafter\t", phase_label,
                "\twall_seconds=", measured.time,
                "\tcompile_seconds=", measured.compile_time,
                "\trecompile_seconds=", measured.recompile_time,
                "\tallocated_bytes=", measured.bytes)
            flush(phase_io)
            phase_returned = true
            measured.value
        finally
            if !phase_returned
                ccall(:fflush, Cint, (Ptr{Cvoid},), C_NULL)
                flush(phase_io)
                println(phase_io, "COLD_PHASE\tfailed\t", phase_label)
                flush(phase_io)
            end
        end
    end
end
