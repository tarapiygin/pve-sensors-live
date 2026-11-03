# SPDX-License-Identifier: MIT
import importlib.util
import json
import math
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("agent", ROOT / "src/pve-sensors-agent.py")
agent = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(agent)


def example():
    """Synthetic fixtures only; no production sensor dump is distributed."""
    return {
        "coretemp-isa-ffff": {
            "Adapter": "Synthetic adapter",
            "Package id 0": {"temp1_input": 47.0, "temp1_max": 81.0, "temp1_crit": 101.0},
            "Core 0": {"temp2_input": 46.0},
            "Core 1": {"temp3_input": 43.0},
        },
        "nvme-pci-ffff": {
            "Composite": {"temp1_input": 37.0, "temp1_max": 83.0, "temp1_crit": 85.0},
            "Sensor 1": {"temp2_input": 38.0, "temp2_max": 65261.0},
        },
        "acpi_fan-isa-ffff": {"fan1": {"fan1_input": 0.0}},
    }


class AgentTests(unittest.TestCase):
    def test_basic_cpu_nvme_fan(self):
        metrics = agent.extract_metrics(example())
        self.assertEqual(len(metrics), 6)
        self.assertEqual(next(m for m in metrics if m["role"] == "package")["value"], 47)
        self.assertEqual(next(m for m in metrics if m["role"] == "composite")["max"], 83)
        self.assertEqual(next(m for m in metrics if m["category"] == "fans")["value"], 0)

    def test_firmware_sentinel_removed(self):
        metric = next(m for m in agent.extract_metrics(example()) if m["name"] == "NVMe 1 / Temperature 2")
        self.assertNotIn("max", metric)

    def test_multiple_packages_unique(self):
        raw = example()
        raw["coretemp-isa-eeee"] = raw["coretemp-isa-ffff"]
        metrics = agent.extract_metrics(raw)
        self.assertEqual(len(metrics), len({m["id"] for m in metrics}))
        self.assertEqual(len([m for m in metrics if m["role"] == "package"]), 2)

    def test_amd_labels(self):
        metrics = agent.extract_metrics({"k10temp-pci-ffff": {
            "Tctl": {"temp1_input": 55}, "Tdie": {"temp2_input": 48}, "Tccd1": {"temp3_input": 49}
        }})
        self.assertEqual({m["name"] for m in metrics}, {"CPU 1 / Tctl", "CPU 1 / Tdie", "CPU 1 / CCD 1"})

    def test_no_raw_identifiers_or_labels(self):
        secret = "private-serial-and-custom-label"
        metrics = agent.extract_metrics({"unknown-" + secret: {
            secret: {"temp1_input": 44}, "Adapter": secret, "Serial": secret
        }})
        self.assertEqual(len(metrics), 1)
        self.assertNotIn(secret, json.dumps(metrics))
        self.assertNotIn("unknown-", json.dumps(metrics))
        self.assertEqual(metrics[0]["name"], "Sensor 1 / Temperature 1")

    def test_html_label_is_not_exported(self):
        raw = {"coretemp-isa-ffff": {"<img src=x onerror=alert(1)>": {"temp1_input": 42}}}
        self.assertNotIn("<img", json.dumps(agent.extract_metrics(raw)))

    def test_numeric_validity(self):
        for invalid in (None, "43", True, False, float("inf"), float("nan"), 10 ** 10000):
            self.assertFalse(agent.finite(invalid))
        for valid in (0, 42, -2.5):
            self.assertTrue(agent.finite(valid))

    def test_invalid_values_skipped(self):
        raw = {"custom": {"one": {"temp1_input": -273.15}, "two": {"fan1_input": -1},
                          "three": {"temp2_input": True}, "four": {"in1_input": 12}}}
        self.assertEqual(agent.extract_metrics(raw), [])

    def test_duplicate_channel_ignored(self):
        raw = {"custom": {"a": {"temp1_input": 31}, "b": {"temp1_input": 32}}}
        self.assertEqual(len(agent.extract_metrics(raw)), 1)

    def test_bad_threshold_order(self):
        raw = {"coretemp-test": {"Package id 0": {"temp1_input": 42, "temp1_max": 110, "temp1_crit": 100}}}
        metric = agent.extract_metrics(raw)[0]
        self.assertNotIn("max", metric)
        self.assertEqual(metric["critical"], 100)

    def test_input_schema(self):
        for raw in (None, [], "anything"):
            with self.assertRaises(ValueError):
                agent.extract_metrics(raw)

    def test_interval_validation(self):
        for value in ("0.1", "0.5", "60"):
            self.assertEqual(agent.interval_value(value), float(value))
        for value in ("0", "-1", "61", "nan", "inf", "abc"):
            with self.assertRaises(Exception):
                agent.interval_value(value)

    def test_atomic_publish_and_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "metrics.json"
            agent.publish({"metrics": [{"value": 42}]}, path)
            agent.publish({"metrics": [{"value": 45}]}, path)
            self.assertEqual(json.loads(path.read_text())["metrics"][0]["value"], 45)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o644)
            self.assertEqual(sorted(p.name for p in Path(directory).iterdir()), ["metrics.json"])

    def test_invalid_json_does_not_replace_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "metrics.json"
            agent.publish({"value": 42}, path)
            with self.assertRaises(ValueError):
                agent.publish({"value": math.nan}, path)
            self.assertEqual(json.loads(path.read_text()), {"value": 42})
            self.assertEqual(len(list(Path(directory).iterdir())), 1)

    def test_subprocess_is_fixed_read_only_command(self):
        process = subprocess.CompletedProcess(["sensors", "-j"], 0, json.dumps(example()), "")
        with patch.object(agent.subprocess, "run", return_value=process) as run:
            metrics = agent.read_metrics()
        self.assertTrue(metrics)
        self.assertEqual(run.call_args.args[0], ["/usr/bin/sensors", "-j"])
        self.assertNotIn("shell", run.call_args.kwargs)
        self.assertEqual(run.call_args.kwargs["timeout"], 2.0)

    def test_metric_limit(self):
        raw = {"device": {f"t{i}": {f"temp{i}_input": 40} for i in range(700)}}
        self.assertEqual(len(agent.extract_metrics(raw)), agent.MAX_METRICS)

    def test_validate_stdin_cli(self):
        result = subprocess.run(["python3", "-I", str(ROOT / "src/pve-sensors-agent.py"), "--validate-stdin"],
                                input=json.dumps(example()), text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("6 valid metrics", result.stdout)
        self.assertNotIn("ffff", result.stdout)


if __name__ == "__main__":
    unittest.main()
