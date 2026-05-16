# simd-gpu

A 4-core SIMD GPU implementation with a 128-bit datapath, dual-port SRAM, and warp-based dispatching — built to explore how real GPU parallelism works from the ground up.

Implemented in Verilog with full architectural documentation, a clean ISA, working SIMD kernels, and a deterministic 1-cycle DPRAM memory model (no cache complexity).

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
  - [GPU Top Level](#gpu-top-level)
  - [Device Control Register](#device-control-register)
  - [Dispatcher](#dispatcher)
  - [Compute Cores](#compute-cores)
  - [SIMD Wrapper](#simd-wrapper)
  - [Memory Controllers](#memory-controllers)
- [Global Memory](#global-memory)
  - [Dual-Port SRAM Macro](#dual-port-sram-macro)
  - [Port A — Instruction Fetch](#port-a--instruction-fetch)
  - [Port B — Data Load/Store](#port-b--data-loadstore)
- [ISA](#isa)
- [Execution Model](#execution-model)
  - [Warp Dispatch](#warp-dispatch)
  - [SIMD Lane Execution](#simd-lane-execution)
- [Kernels](#kernels)
  - [Vector Addition](#vector-addition)
  - [Parallel Dot Product](#parallel-dot-product)
- [Simulation](#simulation)
- [Design Decisions](#design-decisions)
- [Next Steps](#next-steps)

---

## Overview

Modern GPUs are among the most complex pieces of silicon ever designed — and almost nothing about their internals is publicly documented.

This project cuts through that by building a real, minimal GPU in Verilog with one goal: **make the hardware story of GPU parallelism fully legible.**

### What makes this GPU different from a typical "tiny GPU"?

| Feature | This GPU | Naive tiny GPU |
|---|---|---|
| Datapath width | **128-bit (4 × 32-bit SIMD)** | 8–16 bit scalar |
| ALUs | **4 × 32-bit in parallel** | 1 per thread |
| Memory | **1024 × 32 Dual-Port SRAM** | Small single-port SRAM |
| Instruction width | **32-bit** | 16-bit |
| Address bus | **10-bit (1024 addresses)** | 8-bit |
| Cache | **Removed — deterministic 1-cycle latency** | Optional cache |
| Dispatch | **Warp FSM with pc[0:3] register array** | Round-robin |
| Process | **SCL 180nm** | Simulation only |

The core design philosophy: **no cache, no ambiguity.** By targeting a synchronous DPRAM with a guaranteed 1-cycle read latency, every memory access is fully deterministic. This makes the architecture far easier to reason about and simulate.

---

## Architecture

![GPU Architecture](docs/images/gpu_architecture.png)

### GPU Top Level

The GPU is organized as a hierarchy:

```
GPU
├── Device Control Register   (start · reset · status flags)
├── Dispatcher                (warp_id mux · FSM · pc[0:3] array)
├── Compute Core 0            (regfile[0] · simd_a[31:0]   · pc[0])
├── Compute Core 1            (regfile[1] · simd_a[63:32]  · pc[1])
├── Compute Core 2            (regfile[2] · simd_a[95:64]  · pc[2])
├── Compute Core 3            (regfile[3] · simd_a[127:96] · pc[3])
├── SIMD Wrapper              (128-bit datapath · 4× ALU · rf_wd[0:3])
├── Program Memory Controller (FETCH FSM → Port A, Read-Only)
└── Data Memory Controller    (LOAD/STORE → Port B, Read/Write)
```

All four compute cores share a single **SIMD wrapper** that bundles their register operands into a 128-bit bus, executes four 32-bit ALU operations in parallel, and unpacks results back to individual register files.

---

### Device Control Register

The device control register is the host-facing interface to the GPU. It exposes three signals:

| Signal | Direction | Description |
|---|---|---|
| `start` | Input | Assert high to begin kernel execution |
| `reset` | Input | Synchronous reset — clears all state |
| `status_flags` | Output | Reflects current execution state (idle / running / done / error) |

The host loads program memory and data memory before asserting `start`. Once asserted, control transfers entirely to the dispatcher.

---

### Dispatcher

The dispatcher is the central FSM that manages warp scheduling across all four compute cores.

**Internal signals:**

| Signal | Description |
|---|---|
| `warp_id mux` | Selects the active warp being dispatched |
| `FSM controller` | State machine controlling fetch → decode → execute flow |
| `pc[0:3]` register array | Independent program counters for each of the 4 cores |

**Dispatch flow:**

1. On `start`, the FSM moves from `IDLE` → `DISPATCH`.
2. The dispatcher issues warp assignments to each compute core, driving the appropriate `pc[N]` to the program memory controller.
3. After all warps complete (all cores assert `done`), the FSM transitions to `DONE` and sets the status flag.

The `pc[0:3]` register array means each core maintains an **independent program counter** — critical for correct multi-warp execution where different warps may be at different instruction offsets.

---

### Compute Cores

There are **4 compute cores** (Core 0–3), each operating on its own 32-bit slice of the 128-bit SIMD datapath.

| Core | Register File | SIMD Lane | Program Counter |
|---|---|---|---|
| Core 0 | `regfile[0]` | `simd_a[31:0]` | `pc[0]` |
| Core 1 | `regfile[1]` | `simd_a[63:32]` | `pc[1]` |
| Core 2 | `regfile[2]` | `simd_a[95:64]` | `pc[2]` |
| Core 3 | `regfile[3]` | `simd_a[127:96]` | `pc[3]` |

Each core:
- Reads operands from its dedicated `regfile[N]`
- Contributes its 32-bit operand slice to the SIMD pack bus (`simd_a`)
- Receives its result slice from the SIMD unpack bus (`rf_wd[N]`)

Cores do **not** contain their own ALUs — computation happens centrally in the SIMD wrapper, keeping the per-core logic lean.

---

### SIMD Wrapper

The SIMD wrapper is the computational heart of the GPU. It implements a **128-bit wide datapath** by running **4 × 32-bit ALUs in parallel.**

```
Core 0 → simd_a[31:0]   ─┐
Core 1 → simd_a[63:32]  ─┤  PACK  →  [128-bit simd_a bus]
Core 2 → simd_a[95:64]  ─┤             ↓
Core 3 → simd_a[127:96] ─┘       4 × 32-bit ALUs
                                         ↓
Core 0 ← rf_wd[0]       ─┐  UNPACK ←  [128-bit simd_out bus]
Core 1 ← rf_wd[1]       ─┤
Core 2 ← rf_wd[2]       ─┤
Core 3 ← rf_wd[3]       ─┘
```

**Key signals:**

| Signal | Width | Description |
|---|---|---|
| `simd_a[127:0]` | 128-bit | Packed operand A from all 4 cores |
| `simd_b[127:0]` | 128-bit | Packed operand B from all 4 cores |
| `simd_out[127:0]` | 128-bit | Packed ALU results |
| `rf_wd[0:3]` | 4 × 32-bit | Unpacked writeback data per core |

This design achieves **true data-level parallelism (DLP):** a single instruction dispatched to the SIMD wrapper triggers four simultaneous 32-bit operations — one per lane.

---

### Memory Controllers

Two dedicated controllers handle the split memory interface:

#### Program Memory Controller

- **Purpose:** Fetches the 32-bit instruction word at `pc[N]` each cycle.
- **Interface:** Port A of the dual-port SRAM (Read-Only).
- **Signals:** `mem_addr` (10-bit), `mem_req` (request strobe), `FETCH FSM` (internal state machine managing multi-cycle fetch if needed).
- Since Port A is read-only and the SRAM has 1-cycle latency, instruction fetch is **fully deterministic** with no stall cycles under normal operation.

#### Data Memory Controller

- **Purpose:** Services LOAD and STORE instructions from all cores.
- **Interface:** Port B of the dual-port SRAM (Read/Write).
- **Signals:** `mem_we` (write enable), `tri-state buf` (bidirectional data bus control), `LOAD/STORE` (operation type).
- **Broadcast LOAD:** A single LOAD address can broadcast the same 32-bit value to all 4 SIMD lanes simultaneously — critical for loading shared constants (e.g., a stride value used by all threads).

---

## Global Memory

### Dual-Port SRAM Macro (1024 × 32)

The GPU's only memory is a **1024 × 32-bit synchronous dual-port SRAM macro**, fabricated at **SCL 180nm.**

```
┌─────────────────────────────────────────┐
│         Dual-Port SRAM (1024×32)        │
│                                         │
│  Port A (Read-Only)  │  Port B (R/W)    │
│  ─────────────────── │ ──────────────── │
│  Instruction Fetch   │ Data Load/Store  │
│  10-bit addr bus     │ 10-bit addr      │
│  32-bit instr out    │ 32-bit data bus  │
│  SCL 180nm           │ Broadcast → lanes│
└─────────────────────────────────────────┘
```

> **Note on cache removal:** A cache layer was deliberately removed from this design. The SCL 180nm DPRAM macro guarantees **1-cycle synchronous read latency**, making cache unnecessary and removing a major source of timing unpredictability. This simplifies verification substantially and keeps the critical path clean.

### Port A — Instruction Fetch

| Property | Value |
|---|---|
| Access type | Read-Only |
| Address bus | 10-bit (1024 addressable words) |
| Data out | 32-bit instruction word |
| Latency | 1 cycle (synchronous) |
| Consumer | Program Memory Controller → FETCH FSM |

### Port B — Data Load/Store

| Property | Value |
|---|---|
| Access type | Read / Write |
| Address bus | 10-bit |
| Data bus | 32-bit bidirectional |
| Latency | 1 cycle (synchronous) |
| Broadcast | Single LOAD → all 4 SIMD lanes |
| Consumer | Data Memory Controller · Host |

Port B is shared between **kernel data access** and **host access** (loading initial data into memory before kernel launch). Arbitration between host and GPU accesses is managed by the data memory controller's tri-state buffer logic.

---

## ISA

The GPU implements a **32-bit fixed-width instruction set** designed for SIMD data-parallel kernels.

| Instruction | Format | Description |
|---|---|---|
| `ADD Rd, Ra, Rb` | Arithmetic | `Rd = Ra + Rb` across all 4 lanes |
| `SUB Rd, Ra, Rb` | Arithmetic | `Rd = Ra - Rb` across all 4 lanes |
| `MUL Rd, Ra, Rb` | Arithmetic | `Rd = Ra * Rb` across all 4 lanes |
| `DIV Rd, Ra, Rb` | Arithmetic | `Rd = Ra / Rb` across all 4 lanes |
| `LDR Rd, addr` | Memory | Load 32-bit word from data memory into `Rd` (broadcast capable) |
| `STR addr, Rs` | Memory | Store `Rs` to data memory |
| `CONST Rd, #imm` | Immediate | Load 16-bit sign-extended immediate into `Rd` |
| `CMP Ra, Rb` | Compare | Set NZP flags based on `Ra - Rb` |
| `BRnzp label` | Branch | Branch to `label` if NZP matches condition |
| `RET` | Control | End of kernel; signal core done |

**Register file:** Each core has 16 × 32-bit registers (`R0`–`R15`). Registers `R13`–`R15` are read-only and carry the SIMD-lane metadata:

| Register | Contents |
|---|---|
| `R13` | `lane_id` — which of the 4 lanes this core represents (0–3) |
| `R14` | `warp_id` — current warp being executed |
| `R15` | `total_lanes` — total number of active SIMD lanes |

---

## Execution Model

### Warp Dispatch

```
Host: assert start
  │
  ▼
Dispatcher FSM: IDLE → DISPATCH
  │
  ├── Assign warp 0 → all 4 cores (lanes 0–3)
  │     pc[0], pc[1], pc[2], pc[3] all initialized
  │
  ├── Cores execute in lock-step (same PC per warp)
  │     FETCH → DECODE → EXECUTE → WRITEBACK
  │
  ├── On RET: core asserts done
  │
  ├── Dispatcher waits for all 4 done signals
  │
  └── FSM → DONE; set status_flag[done]
```

Because all 4 cores share the same `warp_id` and execute the same instruction stream, they diverge only in their **lane-specific data** (operands from their individual `regfile[N]`). This is the SIMD execution model in hardware.

### SIMD Lane Execution

Each instruction cycle:

1. **FETCH** — Program memory controller drives `mem_addr = pc[active_warp]` to Port A. SRAM returns 32-bit instruction in 1 cycle.
2. **DECODE** — Instruction decoded into ALU opcode, source/destination registers, and memory control signals.
3. **PACK** — Each core reads its source registers. SIMD wrapper packs `simd_a[127:0]` and `simd_b[127:0]`.
4. **EXECUTE** — 4 × 32-bit ALUs compute results in parallel.
5. **UNPACK** — `simd_out[127:0]` unpacked into `rf_wd[0:3]`, written back to each core's `regfile[N]`.
6. **PC UPDATE** — All `pc[N]` increment together (or branch per NZP result).

Memory instructions (LDR/STR) stall the pipeline for 1 cycle while the data memory controller accesses Port B.

---

## Kernels

### Vector Addition

Adds two length-4 vectors in a single warp dispatch (all 4 lanes active).

```asm
; vector_add.asm
; A[4] + B[4] -> C[4], one element per lane

CONST R0, #0          ; base address of A
CONST R1, #4          ; base address of B
CONST R2, #8          ; base address of C

ADD   R3, R0, %lane_id   ; addr(A[lane]) = baseA + lane_id
LDR   R3, R3             ; load A[lane]

ADD   R4, R1, %lane_id   ; addr(B[lane]) = baseB + lane_id
LDR   R4, R4             ; load B[lane]

ADD   R5, R3, R4         ; C[lane] = A[lane] + B[lane]

ADD   R6, R2, %lane_id   ; addr(C[lane]) = baseC + lane_id
STR   R6, R5             ; store C[lane]

RET
```

All four additions happen in parallel across the SIMD lanes on the single `ADD R5, R3, R4` instruction.

---

### Parallel Dot Product

Computes a dot product of two length-4 vectors using SIMD multiply-accumulate, then reduces.

```asm
; dot_product.asm
; result = sum(A[i] * B[i]) for i in 0..3

CONST R0, #0          ; base address of A
CONST R1, #4          ; base address of B

ADD   R2, R0, %lane_id
LDR   R2, R2          ; load A[lane]

ADD   R3, R1, %lane_id
LDR   R3, R3          ; load B[lane]

MUL   R4, R2, R3      ; partial[lane] = A[lane] * B[lane]

; Store partial products for host-side reduction
CONST R5, #8
ADD   R5, R5, %lane_id
STR   R5, R4

RET
```

The four multiply operations (`MUL R4, R2, R3`) execute simultaneously across the 128-bit SIMD datapath.

---

## Simulation

### Prerequisites

```bash
# Verilog simulator
brew install icarus-verilog        # macOS
sudo apt install iverilog          # Ubuntu

# Python cocotb testbench framework
pip install cocotb

# SystemVerilog → Verilog converter
# Download sv2v from https://github.com/zachjs/sv2v/releases
# Add binary to $PATH
```

### Running

```bash
mkdir build
make test_vecadd       # Run vector addition kernel
make test_dotprod      # Run dot product kernel
```

Simulation outputs a log in `test/logs/` with:
- Initial SRAM data memory state
- Cycle-by-cycle execution trace (all 4 lanes, all signals)
- Final SRAM data memory state

### Execution Trace Format

Each cycle of the trace shows:

```
Cycle 12  WARP:0  PC:5  INSTR: MUL R4, R2, R3
  Lane 0: R2=0x00000003  R3=0x00000007  →  R4=0x00000015
  Lane 1: R2=0x00000005  R3=0x00000002  →  R4=0x0000000A
  Lane 2: R2=0x00000001  R3=0x00000009  →  R4=0x00000009
  Lane 3: R2=0x00000008  R3=0x00000004  →  R4=0x00000020
```

---

## Design Decisions

### Why no cache?

The SCL 180nm DPRAM macro used for global memory guarantees a **1-cycle synchronous read latency.** Adding a cache would introduce timing variability, tag-matching logic, eviction policy complexity, and coherence concerns — none of which aid understanding at this stage. Removing it keeps the memory subsystem fully deterministic and the critical path predictable.

### Why 32-bit instructions?

A 32-bit instruction word provides enough opcode space for the full ALU set, a 16-bit immediate field, and 4-bit source/destination register selectors — without encoding tricks. The 10-bit address bus (1024 words of program memory) also maps cleanly to a 32-bit instruction layout.

### Why 4 cores / 128-bit datapath?

4 lanes gives a meaningful demonstration of SIMD data-level parallelism — enough to run real vector kernels — while keeping the register-file, pack/unpack, and writeback logic simple enough to read in a single sitting. Scaling to 8 or 16 lanes is a straightforward extension.

### Why dual-port SRAM?

Separating instruction fetch (Port A) from data load/store (Port B) eliminates structural hazards entirely. No arbitration is needed between the program counter logic and the data memory controller — they never contend for the same port.

---

## Next Steps

- [ ] Add branch divergence tracking (per-lane NZP + predication mask)
- [ ] Implement a multi-warp scheduler (round-robin across warps while one warp is in LDR stall)
- [ ] Write a simple assembler in Python that targets this ISA
- [ ] Add memory coalescing for sequential SIMD store patterns
- [ ] Explore Tiny Tapeout integration for physical fabrication at SCL 180nm
- [ ] Add a matrix multiply kernel as a 2D warp grid proof-of-concept
- [ ] Generate waveform dumps (VCD) for GTKWave visualization

---

## Repository Structure

```
simd-gpu/
├── src/
│   ├── gpu.sv                  # Top-level GPU module
│   ├── device_control_reg.sv   # Host interface: start/reset/status
│   ├── dispatcher.sv           # Warp FSM + pc[0:3] register array
│   ├── compute_core.sv         # Single SIMD lane: regfile + PC
│   ├── simd_wrapper.sv         # 128-bit datapath: 4× ALU, pack/unpack
│   ├── prog_mem_ctrl.sv        # FETCH FSM → Port A
│   ├── data_mem_ctrl.sv        # LOAD/STORE + tri-state → Port B
│   └── sram_macro.sv           # 1024×32 dual-port SRAM model
├── test/
│   ├── test_vecadd.py          # cocotb testbench: vector addition
│   ├── test_dotprod.py         # cocotb testbench: dot product
│   └── logs/
├── docs/
│   └── images/
│       └── gpu_architecture.png
├── Makefile
├── .gitignore
└── README.md
```

---

## License

MIT License — see [LICENSE](LICENSE) for details.

---

*Built to understand GPUs from the ground up. PRs and questions welcome.*
