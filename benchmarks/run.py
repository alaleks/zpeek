#!/usr/bin/env python3
"""Measure zpeek CLI with disposable server-side data (Python 3.10+, Unix)."""
import argparse
import hashlib
import csv
import io
import json
import logging
import os
from pathlib import Path
import platform
import signal
import shutil
import statistics
import subprocess
import tempfile
import tarfile
import time
import urllib.request
import uuid

LOG = logging.getLogger("benchmark")


def download_latest(directory: Path, timeout: float) -> Path:
    machine = platform.machine().lower()
    arch = {"aarch64": "aarch64", "arm64": "aarch64", "amd64": "x86_64", "x86_64": "x86_64"}.get(machine)
    if arch is None:
        raise RuntimeError(f"No release binary for architecture {machine}")
    system = "macos" if platform.system() == "Darwin" else "linux"
    asset = f"zpeek-{system}-{arch}.tar.gz"

    def fetch(url: str) -> bytes:
        request = urllib.request.Request(url, headers={"User-Agent": "zpeek-benchmark"})
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read(128 * 1024 * 1024)

    release = json.loads(fetch("https://api.github.com/repos/alaleks/zpeek/releases/latest"))
    assets = {item["name"]: item["browser_download_url"] for item in release["assets"]}
    if asset not in assets or "checksums.txt" not in assets:
        raise RuntimeError("Latest release is missing the platform archive or checksums.txt")
    LOG.info("Downloading zpeek %s (%s)", release["tag_name"], asset)
    checksums = fetch(assets["checksums.txt"]).decode().splitlines()
    expected = next((line.split()[0] for line in checksums if len(line.split()) == 2 and line.split()[1].lstrip("*") == asset), None)
    archive = fetch(assets[asset])
    if expected is None or hashlib.sha256(archive).hexdigest() != expected:
        raise RuntimeError("Release checksum verification failed")
    binary = directory / "zpeek"
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as package:
        members = [member for member in package.getmembers() if member.isfile() and Path(member.name).name == "zpeek"]
        if len(members) != 1:
            raise RuntimeError("Release archive must contain exactly one zpeek binary")
        source = package.extractfile(members[0])
        if source is None:
            raise RuntimeError("Cannot read release binary")
        with source, binary.open("wb") as destination:
            shutil.copyfileobj(source, destination)
    binary.chmod(0o700)
    return binary


def run_process(command: list[str], timeout: float) -> tuple[str, str]:
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, start_new_session=True) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except BaseException:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise
        if process.returncode:
            # Do not echo the command: it can contain connection credentials.
            raise RuntimeError(f"Client exited with status {process.returncode}: {stderr[-2000:]}")
        return stdout, stderr


def create_sql(driver: str, table: str) -> str:
    if driver == "clickhouse":
        return f"CREATE TABLE {table} (id UInt64, customer_id UInt32, amount UInt32, payload String) ENGINE=MergeTree ORDER BY id"
    return f"CREATE TABLE {table} (id BIGINT PRIMARY KEY, customer_id INTEGER NOT NULL, amount INTEGER NOT NULL, payload VARCHAR(512) NOT NULL)"


def insert_sql(driver: str, table: str, start: int, count: int) -> str:
    if driver == "postgres":
        source = f"SELECT g AS id FROM generate_series({start}, {start + count - 1}) AS g"
    elif driver == "clickhouse":
        source = f"SELECT number + {start} AS id FROM numbers({count})"
    else:
        digits = "(" + " UNION ALL ".join(f"SELECT {i} AS n" for i in range(10)) + ")"
        terms = " + ".join(f"d{i}.n * {10 ** i}" for i in range(6))
        joins = " CROSS JOIN ".join(f"{digits} d{i}" for i in range(6))
        source = f"SELECT {start} + {terms} AS id FROM {joins} WHERE ({terms}) < {count}"
    return f"INSERT INTO {table} SELECT id, id % 10000, id % 100000, repeat('x', 512) FROM ({source}) AS generated"


def scenarios(table: str, rows: int) -> dict[str, str]:
    return {
        "lookup": f"SELECT * FROM {table} WHERE id={max(1, rows // 2)}",
        "page": f"SELECT * FROM {table} ORDER BY id LIMIT 10000",
        "all_ids": f"SELECT id FROM {table}",
        "all_columns": f"SELECT * FROM {table}",
        "aggregate": f"SELECT customer_id, count(*), sum(amount) FROM {table} GROUP BY customer_id",
    }


def timed(command: list[str], timeout: float, timer: str) -> dict[str, float]:
    # time reports the executed child's RSS, avoiding inherited Python wait4 RSS.
    with tempfile.TemporaryDirectory(prefix="zpeek-time-") as tmp:
        metrics = Path(tmp) / "metrics"
        if platform.system() == "Darwin":
            wrapped = [timer, "-l", "-o", str(metrics), *command]
        else:
            wrapped = [timer, "-f", "%U %S %M", "-o", str(metrics), *command]
        # Discard table output without buffering the retained result in Python.
        with open(os.devnull, "w") as sink:
            started = time.perf_counter()
            with subprocess.Popen(wrapped, stdout=sink, stderr=subprocess.PIPE, text=True, start_new_session=True) as process:
                try:
                    _, errors = process.communicate(timeout=timeout)
                except BaseException:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate()
                    raise
                wall = time.perf_counter() - started
                if process.returncode:
                    raise RuntimeError(f"Measured command failed ({process.returncode}): {errors[-2000:]}")
        text = metrics.read_text()
        if platform.system() == "Darwin":
            fields = text.splitlines()[0].split()
            user, system = float(fields[2]), float(fields[4])
            rss = next(int(line.split()[0]) for line in text.splitlines() if "maximum resident set size" in line) / 1048576
        else:
            user, system, kib = map(float, text.split())
            rss = kib / 1024
        return {"wall_s": wall, "cpu_s": user + system, "cpu_percent_one_core": 100 * (user + system) / wall, "peak_rss_mib": rss}


def positive(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", choices=("postgres", "mysql", "clickhouse"), required=True)
    parser.add_argument("--connection", required=True, help="saved zpeek profile; keep passwords in config/environment")
    parser.add_argument("--config", type=Path)
    parser.add_argument("--zpeek", help="use a local binary instead of downloading the latest release")
    parser.add_argument("--rows", type=positive, default=1_000_000)
    parser.add_argument("--runs", type=positive, default=5)
    parser.add_argument("--timeout", type=positive, default=600, help="seconds per command")
    parser.add_argument("--time", default="/usr/bin/time", help="GNU time on Linux, system time on macOS")
    parser.add_argument("--output", type=Path, default=Path("benchmarks/results"))
    args = parser.parse_args()
    if platform.system() not in ("Linux", "Darwin"):
        parser.error("run on Linux or macOS; Windows users can use WSL")
    with tempfile.TemporaryDirectory(prefix="zpeek-release-") as directory:
        if not args.zpeek:
            args.zpeek = str(download_latest(Path(directory), args.timeout))
        benchmark(args)


def benchmark(args: argparse.Namespace) -> None:
    suffix = uuid.uuid4().hex
    database = "zpeek_bench_" + suffix
    table = "events_" + suffix
    args.output.mkdir(parents=True, exist_ok=True)
    report_path = args.output / f"{database}.json"
    base = [args.zpeek]
    if args.config:
        base += ["--config", str(args.config)]
    base += [args.connection, "--driver", args.driver]

    def query(sql: str, output: str = "table") -> str:
        return run_process([*base, "--allow-dangerous", "--format", output, "-e", sql], args.timeout)[0]

    report = {"driver": args.driver, "database": database, "table": table, "rows": args.rows, "platform": platform.platform(),
              "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
              "cleanup": "pending", "samples": {}, "summary": {}}

    def save() -> None:
        report_path.write_text(json.dumps(report, indent=2) + "\n")

    def interrupted(signum: int, frame: object) -> None:
        raise InterruptedError(f"Interrupted by signal {signum}")

    signal.signal(signal.SIGTERM, interrupted)
    save()
    attempted = False
    try:
        report["zpeek_version"] = run_process([args.zpeek, "--version"], args.timeout)[0].strip()
        LOG.info("Creating database %s", database)
        query(f"CREATE DATABASE {database}")
        base += ["--database", database]
        LOG.info("Creating %s with %d rows", table, args.rows)
        attempted = True
        query(create_sql(args.driver, table))
        for start in range(1, args.rows + 1, 100_000):
            query(insert_sql(args.driver, table, start, min(100_000, args.rows - start + 1)))
        if args.driver == "postgres":
            query(f"ANALYZE {table}")
        elif args.driver == "mysql":
            query(f"ANALYZE TABLE {table}")
        count = list(csv.reader(io.StringIO(query(f"SELECT count(*) FROM {table}", "csv"))))
        if int(count[1][0]) != args.rows:
            raise RuntimeError("Row count verification failed")
        for name, sql in scenarios(table, args.rows).items():
            LOG.info("Measuring %s", name)
            command = [*base, "-e", sql]
            timed(command, args.timeout, args.time)  # warm-up
            samples = []
            report["samples"][name] = samples
            for _ in range(args.runs):
                samples.append(timed(command, args.timeout, args.time))
                save()
            summary = {key: statistics.median(sample[key] for sample in samples) for key in samples[0]}
            summary["peak_rss_mib"] = max(sample["peak_rss_mib"] for sample in samples)
            report["summary"][name] = summary
            LOG.info("%s: %.3f s, %.2f MiB RSS, %.3f CPU s", name, summary["wall_s"], summary["peak_rss_mib"], summary["cpu_s"])
    finally:
        # A second interrupt must not skip the cleanup attempt.
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if attempted:
            try:
                query(f"DROP TABLE IF EXISTS {table}")
                report["cleanup"] = "complete"
            except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
                report["cleanup"] = "failed"
                LOG.error("Cleanup failed for %s; retry DROP TABLE manually: %s", table, error)
                raise
            finally:
                save()
        else:
            report["cleanup"] = "not needed"
            save()
        LOG.info("Report: %s", report_path)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    main()
