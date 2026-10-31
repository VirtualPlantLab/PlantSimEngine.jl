# Choose the benchmark revision's kernel ABI once, at helper-load time. An
# undefined global can gain a binding later in a long-lived Julia process;
# testing isdefined inside a hot function need not establish a constant false
# branch for the frozen original revision.
if isdefined(PSE, :_execution_kernel_status)
    @inline _resolved_kernel_status(owner) = PSE._execution_kernel_status(owner)
else
    @inline _resolved_kernel_status(owner) = owner.status
end
