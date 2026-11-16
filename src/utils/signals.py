"""Stop at once when Kubernetes or Docker stops the container."""
import signal


def stop_on_sigterm():
    """Treat SIGTERM like Ctrl+C: raise KeyboardInterrupt in the main thread.

    Kubernetes (and `docker stop`) asks a container to stop with SIGTERM. The
    container's first process (PID 1) gets no default action from the kernel,
    and Python installs no SIGTERM handler, so without this the signal is
    ignored and the process is killed after the 30 s grace period. With it,
    the process unwinds normally (connections are closed) and stops within
    seconds: Python handles the signal once the current call returns, at most
    one database connect timeout. Call it only in a program's entry point.
    """
    signal.signal(signal.SIGTERM, signal.default_int_handler)
