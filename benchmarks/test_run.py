import json
import hashlib
import io
import tarfile
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import run


class BenchmarkTests(unittest.TestCase):
    def test_release_download_checks_hash_and_extracts_only_binary(self) -> None:
        data = b"test binary"
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w:gz") as package:
            member = tarfile.TarInfo("release/zpeek")
            member.size = len(data)
            package.addfile(member, io.BytesIO(data))
        payload = archive.getvalue()
        asset = "zpeek-linux-x86_64.tar.gz"
        release = json.dumps({"tag_name": "v-test", "assets": [{"name": asset, "browser_download_url": "https://test/archive"}, {"name": "checksums.txt", "browser_download_url": "https://test/checksums"}]}).encode()
        responses = {"https://api.github.com/repos/alaleks/zpeek/releases/latest": release,
                     "https://test/archive": payload,
                     "https://test/checksums": f"{hashlib.sha256(payload).hexdigest()}  {asset}\n".encode()}
        with tempfile.TemporaryDirectory() as tmp, patch.object(run.platform, "system", return_value="Linux"), patch.object(run.platform, "machine", return_value="x86_64"), patch.object(run.urllib.request, "urlopen", side_effect=lambda request, timeout: io.BytesIO(responses[request.full_url])):
            self.assertEqual(run.download_latest(Path(tmp), 10).read_bytes(), data)
            responses["https://test/archive"] = b"corrupt"
            with self.assertRaisesRegex(RuntimeError, "checksum"):
                run.download_latest(Path(tmp), 10)

    def test_cleanup_failure_is_recorded_and_propagated(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            def execute(command: list[str], timeout: float) -> tuple[str, str]:
                if command[-1].startswith("DROP"):
                    raise RuntimeError("cleanup unavailable")
                if command[-1].startswith("CREATE TABLE"):
                    raise RuntimeError("setup unavailable")
                return "version", ""

            argv = ["run.py", "--zpeek", "fake-zpeek", "--driver", "mysql", "--connection", "test", "--output", tmp]
            with patch("sys.argv", argv), patch.object(run, "run_process", side_effect=execute), patch.object(run.signal, "signal"), self.assertLogs("benchmark", level="ERROR"):
                with self.assertRaisesRegex(RuntimeError, "cleanup unavailable"):
                    run.main()
            report = json.loads(next(Path(tmp).glob("*.json")).read_text())
            self.assertEqual(report["cleanup"], "failed")

    def test_defaults_to_twenty_million_rows(self) -> None:
        argv = ["run.py", "--zpeek", "fake-zpeek", "--driver", "postgres", "--connection", "test"]
        with patch("sys.argv", argv), patch.object(run, "benchmark") as benchmark:
            run.main()
        self.assertEqual(benchmark.call_args.args[0].rows, 20_000_000)

    def test_generators_bound_rows(self) -> None:
        self.assertIn("generate_series(11, 20)", run.insert_sql("postgres", "test", 11, 10))
        self.assertIn("numbers(10)", run.insert_sql("clickhouse", "test", 11, 10))
        mysql = run.insert_sql("mysql", "test", 11, 10)
        self.assertIn("SELECT 11 +", mysql)
        self.assertIn("< 10", mysql)
        self.assertEqual(mysql.count("CROSS JOIN"), 5)

    def test_cleanup_and_report_on_success_and_load_failure(self) -> None:
        for fail_load in (False, True):
            with self.subTest(fail_load=fail_load), tempfile.TemporaryDirectory() as tmp:
                commands: list[list[str]] = []

                def execute(command: list[str], timeout: float) -> tuple[str, str]:
                    commands.append(command)
                    if fail_load and command[-1].startswith("INSERT"):
                        raise RuntimeError("injected load failure")
                    if command[-1].startswith("SELECT count"):
                        return '"count"\n"10"\n', ""
                    return "test version", ""

                argv = ["run.py", "--zpeek", "fake-zpeek", "--driver", "postgres", "--connection", "test", "--rows", "10", "--runs", "1", "--output", tmp]
                with patch("sys.argv", argv), patch.object(run, "run_process", side_effect=execute), patch.object(run, "timed", return_value={"wall_s": 1.0, "cpu_s": 0.5, "cpu_percent_one_core": 50.0, "peak_rss_mib": 2.0}), patch.object(run.signal, "signal"):
                    if fail_load:
                        with self.assertRaisesRegex(RuntimeError, "injected"):
                            run.main()
                    else:
                        run.main()
                report = json.loads(next(Path(tmp).glob("*.json")).read_text())
                self.assertEqual(commands[-1][-1], f"DROP DATABASE IF EXISTS {report['database']}")
                self.assertNotIn("--database", commands[-1])
                self.assertFalse(any(command[-1].startswith("DROP TABLE") for command in commands))
                self.assertEqual(report["cleanup"], "complete")
                self.assertEqual(len(report["summary"]), 0 if fail_load else 5)


if __name__ == "__main__":
    unittest.main()
