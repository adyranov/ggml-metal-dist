# ⚡ Non-Apple GPU support for the Metal backend

Extends the `ggml` Metal backend for non-Apple-Silicon GPUs on macOS — AMD Radeon discrete and Intel integrated on Intel Macs. Changes are additive and localized so pieces can be dropped as upstream gains equivalent support.

The stock backend assumes Apple-Silicon traits that do not hold elsewhere: unified memory, `simd_*` reduction intrinsics, SIMD width 32, and `simdgroup_mm` matrix hardware. AMD GCN/Vega are width 64, RDNA width 32, Intel width 16; none expose `simdgroup_mm`.

## 🧩 Patches

- **Device profile**: vendor classification, `simd_width` probe (`threadExecutionWidth`), discrete-memory upload/download/memset fixes, and non-UMA concurrent-dispatch disable.
- **Reduction enablement**: `has_simdgroup_reduction` on AMD/Intel via `MTLGPUFamilyCommon2`; `has_simdgroup_mm` stays Apple-only. A trusted-reduction gate admits reduction ops only on validated configs (ARM Mac any width, AMD RDNA2 width 32) and falls back to CPU otherwise.
- **Width-agnostic kernels**: `FC_SIMD_WIDTH` function constant injected from the probed width; reduction kernels NW-parametrized (no literal 32). Barrier-based shared-memory reduction for soft_max, the norm family, and `mul_mv`; auto on Intel. Quant/k-quant fixes for variable width, plus a `float`-cast `simd_min`/`simd_max(half)` shim for GCN/Vega.
- **Flash attention**: scalar kernel (adapts to runtime width) for square F16/Q8_0/Q4_0 and the non-square MLA shape (dk=576, dv=512). On AMD RDNA2 (width 32) the vectorized kernel handles masked small-batch decode; prefill, Intel, and width 64 stay scalar. The vec skip-block test uses the float-cast `simd_max` shim to avoid an RDNA miscompile. An opt-in tiled kernel (dk=dv=64) and Intel chunked dispatch avoid command-buffer timeouts.
- **Matmul**: tiled GEMM (`kernel_mul_mat_tiled`) and tiled `mul_mat_id` for GPUs without `simdgroup_mm`, avoiding the slow per-column `mul_mv` watchdog timeout. Backend support for transposed `src1` and strided `sum_rows`.
- **Fused MoE routing** (`kernel_topk_moe`): collapses the per-layer gating → `argsort_top_k` → `get_rows` (→ optional norm/scale) decode chain into one barrier-based dispatch; single-token rows only.
- **Timestep embedding**: `kernel_timestep_embedding_f32` rewritten as a single uniform, fully-bounded store per column (required for diffusion backends that run the full graph on Metal with no per-op CPU fallback).

Touched files: `include/ggml-device-profile.h`, `src/ggml-metal/*`.

## ⚙️ Environment knobs

| Var | Effect |
| --- | --- |
| `GGML_METAL_SIMD_WIDTH=<n>` | force probed width |
| `GGML_METAL_VERIFIED_{APPLE,AMD,INTEL}=1` | trust reductions for a CPU-gated vendor |
| `GGML_METAL_REDUCE_SHMEM=1` | force shared-memory reduction (auto on Intel) |
| `GGML_METAL_FA_SCALAR=1` | force scalar flash-attention |
| `GGML_METAL_FA_INTEL=1` | force tiled flash-attention |
| `GGML_METAL_MM_TILED=1` | force tiled matmul |
| `GGML_METAL_FUSION_DISABLE=1` | disable fused MoE routing |

## 🧪 Validation

Op-level checks run via validation scripts:

```sh
./scripts/dist.sh validate ggml           # smoke (default): MUL_MAT + FLASH_ATTN_EXT
./scripts/dist.sh validate ggml --type build --tier smoke  # CI build-smoke alias
./scripts/dist.sh validate ggml --full    # full test-backend-ops MTL0 suite
```

Force device-agnostic kernels on any Mac against the CPU reference:

```sh
GGML_METAL_FA_SCALAR=1 ./build/bin/test-backend-ops test -o FLASH_ATTN_EXT -b MTL0
GGML_METAL_MM_TILED=1  ./build/bin/test-backend-ops test -o MUL_MAT       -b MTL0
```

Validated at width 32 (ARM Mac, AMD RDNA2); width 16 (Intel) and width 64 (GCN/Vega) stay CPU-gated until validated on-device.

## 🔁 Upstream tracking

Pinned to upstream release tags via `upstream_ref` in `manifest.json`. Renovate detects new tags and opens PRs; `ci.yml` validates only the affected rebuild set. Application repos build directly from upstream refs with reconciled patched ggml injected at build time.

Rebuild rules:

- `ggml` fork updates rebuild all application artifacts.
- Application upstream updates rebuild only that application.
- Local patches in this repo are app compatibility patches only; ggml patch code lives in the ggml fork.

Re-validate after each upstream bump and drop any local app patch once upstream subsumes it.
