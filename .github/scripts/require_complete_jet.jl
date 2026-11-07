# Loaded in the full XPalm test subprocess before JET creates analysis tasks.
module JETAnalysisGuard

using Logging

struct AnalyzerErrorLogger{L<:AbstractLogger} <: AbstractLogger
    inner::L
    errors::Threads.Atomic{Int}
end

is_analyzer_error(level, source) =
    level >= Logging.Error && source isa Module && first(Base.fullname(source)) === :JET

Logging.min_enabled_level(logger::AnalyzerErrorLogger) =
    min(Logging.Error, Logging.min_enabled_level(logger.inner))

function Logging.shouldlog(logger::AnalyzerErrorLogger, level, source, group, id)
    return is_analyzer_error(level, source) ||
           (level >= Logging.min_enabled_level(logger.inner) &&
            Logging.shouldlog(logger.inner, level, source, group, id))
end

Logging.catch_exceptions(logger::AnalyzerErrorLogger) =
    Logging.catch_exceptions(logger.inner)

function Logging.handle_message(
    logger::AnalyzerErrorLogger, level, message, source, group, id, file, line; kwargs...,
)
    if is_analyzer_error(level, source)
        Threads.atomic_add!(logger.errors, 1)
    end
    if level >= Logging.min_enabled_level(logger.inner) &&
       Logging.shouldlog(logger.inner, level, source, group, id)
        Logging.handle_message(logger.inner, level, message, source, group, id, file, line; kwargs...)
    end
    return nothing
end

function install!()
    logger = AnalyzerErrorLogger(global_logger(), Threads.Atomic{Int}(0))
    global_logger(logger)
    atexit() do exit_code
        count = logger.errors[]
        if count > 0
            println(stderr, "JET analysis incomplete: ", count, " internal analyzer error(s).")
            # Julia catches exceptions from exit hooks; failing requires exit().
            exit(iszero(exit_code) ? 1 : exit_code)
        end
    end
    return nothing
end

end

JETAnalysisGuard.install!()
