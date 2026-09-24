# Traffic-signal post-training

`tools/export_posttrain.nim` plays ten complete native games per certified
variant. At each command turn it captures the exact hosted system prompt and
seat observation. The shipped greedy and fixedcycle policies supply replies
accepted by the production parser. All four seats choose from one pre-turn
state, then the native simulator advances. Whole games stay in one data split.

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/sumo-posttrain tools/export_posttrain.nim
python3 tools/test_posttrain.py /tmp/sumo-posttrain
/tmp/sumo-posttrain /tmp/sumo-data 10 grid4x4
```

The other certified variant is `rushhour`. Ten games yielded 1,024 training
and 256 validation decisions for each variant. The largest examples used
3,004 and 3,010 tokens with a local Qwen2.5 tokenizer, within 4,096 tokens.
One CPU optimizer step on a tiny local model reduced validation loss from
5.5549 to 5.4569 and 5.4737 to 5.3831, respectively. These short runs
verify the training path, not policy quality.

From a Metta checkout with `metta-posttrain` installed:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/sumo-data --output /tmp/sumo-adapter \
  --model Qwen/Qwen3-0.6B --max-steps 100 --max-length 4096
```

The exporter includes public detectors and the acting seat's private notes,
but no other controller's orders. Numeric Metta RL and PufferLib training need
a bounded codec for each seat's four intersection orders.
