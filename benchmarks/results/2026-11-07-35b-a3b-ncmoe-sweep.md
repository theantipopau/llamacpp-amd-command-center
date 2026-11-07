# 35B-A3B expert-offload sweep (RX 9070 XT, Vulkan b12110)

Measured 2026-11-07 with `llama-bench` from the installed Vulkan build b12110 (`cd959bae9`),
by hand: Tune cannot run these models (it hard-codes three model ids and skips anything the
fit estimate rejects, and it has no expert-offload option). Same prompt, generation and
repetition settings as Tune uses: `-p 2048 -n 128 -r 3 -fa 1 -ngl 99 -dev Vulkan0`, one slot,
about 8k test context. The desktop was in normal use (browser, editors), so the +/- is real
noise: treat the shape as the result, not the third digit. Not the server's 64k x 2 context:
a larger KV cache leaves less VRAM, so the best `-ncmoe` on the server is likely a little
higher than here. Quality and tool calling were not tested.

`-ncmoe N` keeps the experts of the first N layers (of 40) on the CPU. Smaller N puts more
of the model in VRAM. Tokens per second, mean +/- standard deviation over 3 runs.

| Model | -ncmoe | prompt 2048 | generation 128 |
|---|---:|---:|---:|
| Qwen3.6 35B-A3B (UD-Q4_K_M) | 40 | 264.7 +/- 36.5 | 34.7 +/- 0.6 |
| | 32 | 339.9 +/- 31.3 | 41.6 +/- 0.2 |
| | 26 | 404.2 +/- 46.2 | 47.4 +/- 0.3 |
| | 22 | 487.0 +/- 37.8 | 53.3 +/- 0.4 |
| | 18 | 370.4 +/- 19.6 | 59.0 +/- 3.0 |
| | 14 | 419.5 +/- 19.3 | 54.6 +/- 1.8 |
| | 10 | 506.1 +/- 28.4 | 51.2 +/- 1.5 |
| Ornith 1.5 35B-A3B (Q4_K_M) | 40 | 319.5 +/- 1.7 | 37.0 +/- 0.2 |
| | 32 | 383.9 +/- 2.2 | 44.2 +/- 0.1 |
| | 26 | 454.6 +/- 9.9 | 50.9 +/- 0.1 |
| | 22 | 527.9 +/- 21.9 | 57.1 +/- 0.1 |
| | 18 | 644.8 +/- 8.4 | 65.2 +/- 0.2 |
| | 14 | 443.3 +/- 2.8 | 55.8 +/- 2.3 |
| | 10 | 497.6 +/- 19.5 | 54.2 +/- 1.8 |

Generation peaks around 18 expert layers on the CPU and falls again below that (the card is
nearly full and Vulkan starts paging). For comparison, from the saved Tune receipts on the same
build: Qwen3.5 9B Vulkan b12110 prompt 3141 / generation 94.7; Qwen3 4B prompt 5540 /
generation 180.1.

Both models load and run on Vulkan b12110, including Ornith 1.5 35B-A3B (its 9B sibling is
the one AMD's ROCm 7.2.1 / b8407 package cannot load).
