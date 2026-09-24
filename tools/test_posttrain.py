"""Check complete, seed-separated traffic-signal training games."""

import json
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory


for variant in ("grid4x4", "rushhour"):
    with TemporaryDirectory() as temporary:
        output = Path(temporary) / variant
        subprocess.run([sys.argv[1], str(output), "10", variant], check=True)
        manifest = json.loads((output / "manifest.json").read_text())
        train = [json.loads(line) for line in (output / "train.jsonl").read_text().splitlines()]
        validation = [json.loads(line) for line in (output / "validation.jsonl").read_text().splitlines()]
        assert len(manifest["runs"]) == 10
        assert manifest["train_examples"] == len(train) > 0
        assert manifest["validation_examples"] == len(validation) > 0
        assert {row["seed"] for row in train}.isdisjoint({row["seed"] for row in validation})
        assert all(run["reason"] == "complete" for run in manifest["runs"])
        for row in train + validation:
            assert row["game"] == "sumo-traffic-signals"
            assert [part["role"] for part in row["prompt"]] == ["system", "user"]
            observation = json.loads(row["prompt"][1]["content"])
            assert "your_signals" in observation and "detectors" in observation
            completion = json.loads(row["completion"][0]["content"])
            assert len(completion["orders"]) == 4
            assert all("at" in order and "verb" in order for order in completion["orders"])
        print(f"{variant}: {len(train)} train, {len(validation)} validation decisions")
