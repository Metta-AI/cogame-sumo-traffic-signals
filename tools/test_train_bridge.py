"""Exercise complete traffic-signal games through the numeric bridge."""

import json
import random
import subprocess
import sys
from pathlib import Path


manifest = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
for variant in ("grid4x4", "rushhour"):
    for policy in ("teacher", "random"):
        with subprocess.Popen(
            [sys.argv[1], str(manifest), variant],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        ) as bridge:
            assert bridge.stdin is not None and bridge.stdout is not None

            def request(payload):
                bridge.stdin.write(json.dumps(payload) + "\n")
                bridge.stdin.flush()
                return json.loads(bridge.stdout.readline())

            observation = request({"kind": "reset", "seed": f"{variant}-{policy}", "players": 4})
            rng = random.Random(42)
            decisions = 0
            while observation["kind"] == "decision":
                view = observation["semantic_view"]
                assert "detectors" in view and "your_signals" in view
                assert observation["messages"][0]["content"].startswith("You")
                encoded = request({"kind": "encode"})
                assert encoded["decision_id"] == observation["decision_id"]
                assert len(encoded["values"]) == 201
                assert [len(head["choices"]) for head in encoded["action_heads"]] == [4, 4, 7] * 4
                if policy == "teacher":
                    action = json.loads(request({"kind": "teacher"})["response"])
                else:
                    action = {head["name"]: rng.choice(head["choices"]) for head in encoded["action_heads"]}
                assert all(action[head["name"]] in head["choices"] for head in encoded["action_heads"])
                result = request(
                    {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(action)}
                )
                assert result["kind"] == "accepted" and result["action"] == action
                observation = result["observation"]
                decisions += 1
            assert 4 <= decisions <= 128
            assert set(observation["scores"]) == {"0", "1", "2", "3"}
            assert all(0 <= score <= 1 for score in observation["scores"].values())
            assert all(-1 <= utility <= 1 for utility in observation["utilities"].values())
            bridge.stdin.close()
            assert bridge.wait() == 0
        print(f"{variant} {policy}: {decisions} decisions, 201 values")
