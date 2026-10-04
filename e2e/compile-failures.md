# Fixed graph experiment failure checks before code

- Keep all four fine-tuned models, FP32 attention, one-second input, and no
  shifts. Do not reduce quality to meet a speed gate.
- Warm the canonical per-model forward before tracing a complete separation.
  The library already compiles each submodel by default.
- Compare both paths on real passages and silence. Every sample must be finite.
  Maximum absolute output error must be below 0.00001.
- Alternate paths at the same 100 ms request interval in one process. Record
  every duration. Do not compare a cold path with a warm path.
- Record compile startup time and peak MLX allocation. Preserve the 1 GiB
  allocator cache bound. Reject extra memory or a slower candidate.
- A successful probe is not live acceptance. Run the real stream and live
  deadline/coverage checks before installing a product change.
