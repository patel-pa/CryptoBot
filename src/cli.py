"""Command-line entry point for the scheduled jobs (Kubernetes CronJobs).

    python -m src.cli ingest     store the candles missing from Postgres (every 15 min)
    python -m src.cli retrain    ingest, then train and save the model (daily)

Exit code 0 = success, 1 = failure. Kubernetes marks a Job as failed from the
exit code, and failed jobs are what the monitoring alert watches.
"""
import argparse
import sys
import time
import traceback

from src.collection.fetch_historical import backfill


def ingest():
    backfill()


def retrain():
    # Imported here, not at the top: the ingest job (every 15 min) never loads
    # scikit-learn, which saves start-up time and memory on each run.
    from src.models.train_model import train

    # Train on the freshest data. If the ingest fails, stop: the job must show
    # up as failed instead of quietly training on stale data.
    backfill()
    train()


COMMANDS = {
    "ingest": (ingest, "store the candles missing from Postgres"),
    "retrain": (retrain, "ingest, then train and save the model"),
}


def main(argv=None):
    """Run one command; return the process exit code (0 = success, 1 = failure)."""
    parser = argparse.ArgumentParser(prog="python -m src.cli",
                                     description="CryptoBot scheduled jobs.")
    commands = parser.add_subparsers(dest="command", required=True, metavar="command")
    for name, (_, help_text) in COMMANDS.items():
        commands.add_parser(name, help=help_text)
    args = parser.parse_args(argv)      # unknown or missing command: exits with code 2

    run, _ = COMMANDS[args.command]
    started = time.monotonic()
    print(f"{args.command}: started", flush=True)
    try:
        run()
    except Exception:
        traceback.print_exc()
        print(f"{args.command}: FAILED after {time.monotonic() - started:.1f}s", flush=True)
        return 1
    print(f"{args.command}: finished in {time.monotonic() - started:.1f}s", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
