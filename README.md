# simd-gpu

A single-core SIMD GPU with a **512-bit datapath**, **16 parallel ALU lanes**, 4-warp round-robin scheduling, a per-warp scoreboard, and an 8-bit byte-multiplexed host interface — built to explore how real GPU parallelism works from the ground up.

Implemented in Verilog and taped out on the **SCL 180nm** process (`C2S0284`), with a 1024 × 32 dual-port SRAM, a synthesizable pad ring, and a fully deterministic 1-cycle DPRAM memory model.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
  - [Chip Top Level](#chip-top-level)
  - [GPU Module](#gpu-module)
  - [Compute Core](#compute-core)
  - [SIMD Wrapper](#simd-wrapper)
  - [Register Files](#register-files)
  - [Scoreboard](#scoreboard)
  - [Reset Synchronizer](#reset-synchronizer)
  - [Shared Memory](#shared-memory)
- [Global Memory](#global-memory)
  - [Dual-Port SRAM Macro](#dual-port-sram-macro)
  - [Port A — Instruction Fetch](#port-a--instruction-fetch)
  - [Port B — Data Load/Store](#port-b--data-loadstore)
- [Host Interface](#host-interface)
- [ISA](#isa)
- [Execution Model](#execution-model)
  - [Warp Scheduling](#warp-scheduling)
  - [SIMD Lane Execution](#simd-lane-execution)
  - [Memory Lane Sequencing](#memory-lane-sequencing)
- [Scoreboard & Hazard Detection](#scoreboard--hazard-detection)
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
| Datapath width | **512-bit (16 × 32-bit SIMD)** | 8–16-bit scalar |
| ALU lanes | **16 × 32-bit in parallel** | 1 per thread |
| Memory | **1024 × 32 Dual-Port SRAM** | Small single-port SRAM |
| Instruction width | **32-bit** | 16-bit |
| Address bus | **10-bit (1024 addresses)** | 8-bit |
| Warps | **4 warps, round-robin scheduled** | Single thread |
| Hazard detection | **Per-warp scoreboard (RAW stalls)** | None |
| Lane masking | **16-bit per-lane execution mask** | N/A |
| Cache | **Removed — deterministic 1-cycle latency** | Optional cache |
| Host interface | **8-bit byte-multiplexed, 4-byte assembled** | Simple parallel bus |
| Process | **SCL 180nm (taped out as C2S0284)** | Simulation only |

The core design philosophy: **no cache, no ambiguity.** By targeting a synchronous DPRAM with a guaranteed 1-cycle read latency, every memory access is fully deterministic. This makes the architecture far easier to reason about and simulate.

---

## Architecture

### Chip Top Level (`C2S0284`)

The physical chip module wraps the GPU and SRAM with SCL 180nm pad cells and implements the host-facing byte-multiplexed interface.

```
C2S0284 (chip_top)
├── SCL Pad Ring
│   ├── pc3c01  — clock input pad + buffer
│   ├── pc3d01  — digital input pads (rst_n, start, host_data_in[7:0], host_addr[9:0], ...)
│   └── pc3o05  — output drive pads (done, host_data_out[7:0], host_ack)
│
├── Host Byte-Multiplexed Write Path
│   ├── write_buffer[23:0]     — accumulates bytes 0–2 on rising edges
│   └── full_host_word[31:0]   — assembled on byte_sel == 2'b11 (byte 3 arrives)
│
├── Port B Arbitration
│   ├── start == 0  →  host controls Port B (load program/data)
│   └── start == 1  →  GPU controls Port B (kernel execution)
│
├── shared_mem (rd3_1024x32)   — 1-cycle DPRAM macro
└── gpu                        — compute engine
```

**Key chip-level signals:**

| Signal | Width | Direction | Description |
|---|---|---|---|
| `clk_pad` | 1 | Input | External clock (through `pc3c01` clock pad) |
| `rst_n_pad` | 1 | Input | Active-low reset |
| `start_pad` | 1 | Input | Assert to begin kernel execution |
| `done_pad` | 1 | Output | Asserted when kernel completes |
| `host_data_in_pad` | 8 | Input | Byte-multiplexed write data |
| `host_data_out_pad` | 8 | Output | Byte-multiplexed read data |
| `host_addr_pad` | 10 | Input | SRAM word address |
| `host_we_pad` | 1 | Input | Write enable |
| `host_byte_sel_pad` | 2 | Input | Byte lane selector (`00`–`11`) |
| `host_req_pad` | 1 | Input | Request strobe |
| `host_ack_pad` | 1 | Output | Acknowledge (1-cycle delayed) |

---

### GPU Module

The `gpu` module is a thin wrapper that instantiates the reset synchronizer and the single compute core.

```
gpu
├── reset_sync     — 2-FF synchronizer (rst_n → rst)
└── compute_core   — all execution logic
```

External memory ports are passed through directly to `compute_core`. The `cfg[5:0]` input is reserved for future configuration.

---

### Compute Core

The compute core is the heart of the GPU. It implements a **4-warp FSM** with a **16-lane SIMD datapath** and handles all instruction fetch, decode, execute, and memory access.

```
compute_core
├── pc[0:3]          — independent 10-bit program counters, one per warp
├── warp_id          — 2-bit active warp selector (round-robin)
├── instr_addr       — pc[warp_id] driven to Port A
│
├── Instruction Decode
│   ├── opcode[31:24]
│   ├── rd[23:20]
│   ├── rs1[19:16]
│   ├── rs2[15:12]
│   └── addr[9:0]
│
├── 16× regfile      — one per SIMD lane (16 × 32-bit registers each)
├── simd_a[511:0]    — packed operand A (16 × 32-bit)
├── simd_b[511:0]    — packed operand B (16 × 32-bit)
├── simd_wrapper     — 16× parallel 32-bit ALU with lane masking
├── simd_out[511:0]  — packed ALU results
├── rf_wd[0:15]      — writeback data per lane (ALU result or load data)
├── rf_we_bus[15:0]  — per-lane write enable (one-hot during LOAD sequencing)
│
├── scoreboard       — per-warp RAW hazard detection
└── lane_ctr[3:0]    — sequencing counter for LOAD/STORE (0–15)
```

**FSM states:**

| State | Description |
|---|---|
| `IDLE` | Waiting for `start` assertion |
| `WAIT_FETCH` | Latching `instr_data` from SRAM Port A (1-cycle latency) |
| `EXECUTE` | Decode and dispatch; stall if scoreboard signals RAW hazard |
| `WAIT_MEM_LOAD` | Sequences 16 consecutive memory reads, one per lane |
| `WAIT_MEM_STORE` | Sequences 16 consecutive memory writes, one per lane |

After each instruction (ADD, LOAD, STORE), `warp_id` increments (mod 4), and the next warp's `pc` drives the next fetch. This round-robin interleaving hides memory latency across warps.

---

### SIMD Wrapper

The SIMD wrapper implements a **512-bit wide execution datapath** across **16 parallel 32-bit ALUs.**

```
Lane 0  → simd_a[31:0]    ─┐
Lane 1  → simd_a[63:32]   ─┤
...                        ─┤  PACK  →  [512-bit simd_a bus]
Lane 15 → simd_a[511:480] ─┘             ↓
                                    16 × 32-bit ALUs
                                    (masked per lane)
                                         ↓
Lane 0  ← rf_wd[0]        ─┐  UNPACK ←  [512-bit simd_out bus]
Lane 1  ← rf_wd[1]        ─┤
...                        ─┤
Lane 15 ← rf_wd[15]       ─┘
```

**Key signals:**

| Signal | Width | Description |
|---|---|---|
| `a[511:0]` | 512-bit | Packed operand A from all 16 lanes |
| `b[511:0]` | 512-bit | Packed operand B from all 16 lanes |
| `opcode[2:0]` | 3-bit | ALU operation (shared across all lanes) |
| `mask[15:0]` | 16-bit | Per-lane execution mask; masked lanes output `0` |
| `result[511:0]` | 512-bit | Packed ALU results |

The mask is currently driven as `16'hFFFF` (all lanes active). Masked-off lanes substitute `0` for both operands before the ALU, producing a zero result without requiring special ALU handling.

---

### Register Files

Each of the 16 SIMD lanes has its own dedicated **regfile**: 16 × 32-bit registers (`R0`–`R15`), synchronously reset to zero.

| Property | Value |
|---|---|
| Registers per lane | 16 × 32-bit |
| Lanes | 16 |
| Total register storage | 256 × 32-bit (8 KB) |
| Write policy | Synchronous, write-enable gated |
| Read policy | Asynchronous (combinational) |

All 16 regfiles receive the same `rs1`, `rs2`, and `rd` selectors — the SIMD model means all lanes execute the same instruction on their own private data.

---

### Scoreboard

The scoreboard tracks **RAW (read-after-write) hazards** independently per warp.

```
scoreboard
├── busy[0:3][15:0]   — 16-bit busy vector per warp (one bit per register)
├── stall             — asserted if rs1 or rs2 is busy for the active warp
├── set_busy          — mark rd as busy on a LOAD dispatch
└── clear_busy        — clear rd busy bit when LOAD completes (lane_ctr == 15)
```

The scoreboard fires a stall when a warp tries to use a register that is still being loaded. Since LOAD takes 16 cycles (one per lane), without the scoreboard a dependent instruction would read stale data. The stall holds the FSM in `EXECUTE` until the register is free.

---

### Reset Synchronizer

A standard 2-flip-flop synchronizer converts the asynchronous active-low `rst_n` pad to a synchronous active-high `rst` for all internal logic.

```
rst_n (async, active-low)
  → FF1 (clk) → FF2 (clk) → rst (sync, active-high)
```

---

### Shared Memory

`shared_mem` is a thin wrapper that maps the GPU's logical Port A / Port B interface onto the SCL 180nm `rd3_1024x32` DPRAM macro's active-low control signals.

| Port | Macro Port | Access | Consumer |
|---|---|---|---|
| Port A | Port 1 | Read-only (`WEB1` tied high) | Instruction fetch |
| Port B | Port 2 | Read/Write | Data load/store + host preload |

---

## Global Memory

### Dual-Port SRAM Macro (`rd3_1024x32`)

The GPU's only memory is a **1024 × 32-bit synchronous dual-port SRAM macro** from the SCL 180nm PDK.

```
┌────────────────────────────────────────────┐
│        Dual-Port SRAM (1024 × 32)          │
│                                            │
│  Port A (Read-Only)  │  Port B (R/W)       │
│  ────────────────── │ ────────────────── │
│  Instruction Fetch  │ Data Load/Store    │
│  10-bit addr         │ 10-bit addr        │
│  32-bit instr out    │ 32-bit data bus    │
│  SCL 180nm           │ Host preload too   │
└────────────────────────────────────────────┘
```

> **Note on cache removal:** A cache layer was deliberately removed from this design. The SCL 180nm DPRAM macro guarantees **1-cycle synchronous read latency**, making cache unnecessary and removing a major source of timing unpredictability. This simplifies verification substantially and keeps the critical path clean.

### Port A — Instruction Fetch

| Property | Value |
|---|---|
| Access type | Read-Only |
| Address bus | 10-bit (1024 addressable words) |
| Data out | 32-bit instruction word |
| Latency | 1 cycle (synchronous) |
| Consumer | `WAIT_FETCH` state → `instr` register |

### Port B — Data Load/Store

| Property | Value |
|---|---|
| Access type | Read / Write |
| Address bus | 10-bit |
| Data bus | 32-bit |
| Latency | 1 cycle (synchronous) |
| Lane sequencing | 16 consecutive cycles per LOAD or STORE |
| Consumer | `WAIT_MEM_LOAD` / `WAIT_MEM_STORE` states + host preload |

---

## Host Interface

The host loads program and data into the SRAM before asserting `start`. Because the physical pads are 8-bit, a 32-bit word is assembled from four byte-lane writes:

```
host_byte_sel = 2'b00  →  write_buffer[7:0]   ← host_data_in
host_byte_sel = 2'b01  →  write_buffer[15:8]  ← host_data_in
host_byte_sel = 2'b10  →  write_buffer[23:16] ← host_data_in
host_byte_sel = 2'b11  →  full_host_word assembled; SRAM write fires
```

`host_ack` is returned 1 cycle after `host_req` (registered). While `start` is asserted, Port B is fully owned by the GPU and host writes are ignored.

---

## ISA

The GPU implements a **32-bit fixed-width instruction set.**

| Instruction | Opcode | Format | Description |
|---|---|---|---|
| `LOAD Rd, addr` | `0x01` | Memory | Load from `addr`; sequences 16 reads (one per lane) |
| `STORE addr, Rs` | `0x02` | Memory | Store to `addr`; sequences 16 writes (one per lane) |
| `ADD Rd, Rs1, Rs2` | `0x03` | Arithmetic | `Rd = Rs1 + Rs2` across all 16 lanes simultaneously |
| `HALT` | `0xFF` | Control | End of kernel; assert `done`, return to `IDLE` |

**Instruction encoding (32-bit):**

| Bits | Field |
|---|---|
| `[31:24]` | Opcode |
| `[23:20]` | Destination register `Rd` |
| `[19:16]` | Source register `Rs1` |
| `[15:12]` | Source register `Rs2` |
| `[9:0]` | Memory address (LOAD/STORE) |

**ALU operations** (selected by `simd_wrapper`'s 3-bit `opcode`):

| opcode | Operation |
|---|---|
| `3'b000` | ADD |
| `3'b001` | SUB |
| `3'b010` | AND |
| `3'b011` | OR |
| `3'b100` | XOR |

**Register file:** Each lane has 16 × 32-bit registers (`R0`–`R15`), all synchronously reset to zero.

---

## Execution Model

### Warp Scheduling

```
Host: assert start
  │
  ▼
Compute Core FSM: IDLE → WAIT_FETCH
  │
  ├── Fetch instruction at pc[warp_id]  (1 cycle, Port A)
  │
  ├── EXECUTE:
  │   ├── ADD?   → all 16 ALUs fire in parallel
  │   │            rf_we_bus = 16'hFFFF (all lanes write)
  │   │            pc[warp_id]++, warp_id = (warp_id + 1) % 4
  │   │
  │   ├── LOAD?  → 16-cycle sequencing loop (WAIT_MEM_LOAD)
  │   │            each cycle: one lane's regfile written via rf_we_bus one-hot
  │   │            pc[warp_id]++, warp_id advances after last lane
  │   │
  │   ├── STORE? → 16-cycle sequencing loop (WAIT_MEM_STORE)
  │   │            each cycle: mem_data_out = lane_rd1[lane_ctr], mem_we = 1
  │   │            pc[warp_id]++, warp_id advances after last lane
  │   │
  │   └── HALT?  → done = 1, return to IDLE
  │
  └── warp_id round-robins: 0 → 1 → 2 → 3 → 0 → ...
```

Each warp has an independent `pc[N]` so warps can be at different instruction offsets simultaneously. Warp interleaving hides the 16-cycle memory latency — while one warp sequences a LOAD, other warps can be executing ADD instructions.

### SIMD Lane Execution

Each ADD instruction cycle:

1. **FETCH** — `instr_addr = pc[warp_id]`; SRAM Port A returns 32-bit instruction in 1 cycle (`WAIT_FETCH`).
2. **DECODE** — opcode, `rd`, `rs1`, `rs2` extracted from `instr`.
3. **PACK** — All 16 regfiles read `rs1` and `rs2`; SIMD wrapper receives `simd_a[511:0]` and `simd_b[511:0]`.
4. **EXECUTE** — 16 × 32-bit ALUs compute results in parallel, producing `simd_out[511:0]`.
5. **WRITEBACK** — `rf_we_bus = 16'hFFFF`; all 16 lanes write `simd_out[lane*32+31 : lane*32]` into `rd`.
6. **PC UPDATE** — `pc[warp_id]++`; `warp_id` increments to schedule the next warp.

### Memory Lane Sequencing

LOAD and STORE do not broadcast a single word to all lanes. Instead, they **sequence across all 16 lanes** using `lane_ctr`:

**LOAD** (`WAIT_MEM_LOAD`): Each cycle, `mem_addr = base_addr + lane_ctr` and `rf_we_bus = 1 << lane_ctr`. One lane's register is written per cycle. After 16 cycles, all lanes have loaded their respective words.

**STORE** (`WAIT_MEM_STORE`): Each cycle, `mem_data_out = lane_rd1[lane_ctr]` and `mem_we = 1`. One lane's data is written to `base_addr + lane_ctr` per cycle. After 16 cycles, all 16 words are stored.

---

## Scoreboard & Hazard Detection

The scoreboard prevents **RAW hazards** where a LOAD destination register is read before the load completes.

```
scoreboard
  busy[warp][reg] = 1   →  register is being loaded
  stall = busy[warp][rs1] | busy[warp][rs2]

  On LOAD dispatch:       busy[warp][rd] ← 1
  On LOAD completion:     busy[warp][rd] ← 0   (when lane_ctr == 15)
```

Hazard example:
```
LOAD  R3, 0x100    ; starts 16-cycle memory sequence; scoreboard marks R3 busy
ADD   R5, R3, R4   ; stalls in EXECUTE until R3 is cleared (all 16 lanes loaded)
```

The scoreboard maintains 4 independent 16-bit busy vectors — one per warp — so stalls on one warp do not affect others.

---

## Kernels

### Vector Addition

Adds two length-16 vectors, one element per SIMD lane.

```asm
; vector_add.asm
; A[16] + B[16] -> C[16], one element per lane

LOAD  R0, 0x000    ; load A[0..15] → R0 across all 16 lanes
LOAD  R1, 0x010    ; load B[0..15] → R1 across all 16 lanes
ADD   R2, R0, R1   ; C[lane] = A[lane] + B[lane], 16 additions in parallel
STORE 0x020, R2    ; store C[0..15] from R2 across all 16 lanes
HALT
```

The single `ADD R2, R0, R1` instruction triggers 16 simultaneous 32-bit additions across the 512-bit SIMD datapath.

---

### Parallel Dot Product

Computes element-wise products; host reduces the 16 partial products.

```asm
; dot_product.asm
; partial[i] = A[i] * B[i] for i in 0..15

; Note: MUL is not in the current ALU ISA.
; The pattern below uses the ADD opcode as a placeholder.

LOAD  R0, 0x000    ; load A[0..15] → R0
LOAD  R1, 0x010    ; load B[0..15] → R1
ADD   R2, R0, R1   ; partial sums (replace with MUL when extended)
STORE 0x020, R2    ; store 16 partial products for host reduction
HALT
```

> **Note:** The current ALU supports ADD, SUB, AND, OR, XOR. MUL is a planned extension (see Next Steps).

---

## Simulation

### Prerequisites

```bash
# Verilog simulator
brew install icarus-verilog        # macOS
sudo apt install iverilog          # Ubuntu

# Python cocotb testbench framework
pip install cocotb

# SystemVerilog → Verilog converter (if needed)
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
- Cycle-by-cycle execution trace (all 16 lanes, all signals)
- Final SRAM data memory state

### Execution Trace Format

Each cycle of the trace shows:

```
Cycle 8   WARP:0  PC:2  INSTR: ADD R2, R0, R1
  Lane  0: R0=0x00000003  R1=0x00000007  →  R2=0x0000000A
  Lane  1: R0=0x00000005  R1=0x00000002  →  R2=0x00000007
  Lane  2: R0=0x00000001  R1=0x00000009  →  R2=0x0000000A
  Lane  3: R0=0x00000008  R1=0x00000004  →  R2=0x0000000C
  ...
  Lane 15: R0=0x00000006  R1=0x00000003  →  R2=0x00000009
```

---

## Design Decisions

### Single compute core with 16 internal lanes, not 16 separate cores

The 16-way parallelism lives inside `compute_core` as a `generate` loop over 16 `regfile` instances and 16 ALU lanes in the `simd_wrapper`. A single instruction decoder, single FSM, and single scoreboard serve all 16 lanes. This is faithful to how a real GPU SM (Streaming Multiprocessor) works: one instruction stream, many data lanes.

### Why no cache?

The SCL 180nm DPRAM macro guarantees a **1-cycle synchronous read latency.** Adding a cache would introduce timing variability, tag-matching logic, eviction policy complexity, and coherence concerns — none of which aid understanding at this stage. Removing it keeps the memory subsystem fully deterministic and the critical path predictable.

### Why sequential LOAD/STORE over 16 cycles?

The shared SRAM Port B is 32-bit wide — there is only one physical memory port. Servicing all 16 lanes in a single cycle would require a 512-bit-wide memory bus. Instead, `lane_ctr` sequences 16 consecutive single-word accesses. Future work could explore a banked memory scheme to reduce this to fewer cycles.

### Why 4 warps?

The `pc[0:3]` array and 2-bit `warp_id` allow 4 independent instruction streams to interleave. This directly hides the 16-cycle LOAD/STORE latency: while one warp sequences a memory operation, the other 3 warps can each execute an ADD in the intervening cycles. Scaling to 8 warps would require a 3-bit `warp_id` and a wider scoreboard.

### Why round-robin warp scheduling?

Round-robin is the simplest correct scheduler and easy to reason about. Each instruction (including a 16-cycle LOAD) advances `warp_id` exactly once at completion, so all warps make progress at the same rate assuming balanced kernels. A priority scheduler or occupancy-aware scheduler is a straightforward next step.

### Why an 8-bit byte-multiplexed host interface?

Minimizing pad count is critical at SCL 180nm. A 32-bit parallel host bus would consume 32 input pads for data alone. The byte-mux scheme needs only 8 data pads at the cost of 4 write cycles per word — acceptable for the one-time program/data load before kernel launch.

### Why 32-bit instructions?

A 32-bit instruction word provides enough opcode space (8-bit opcode field) for the full ALU set, a 10-bit address field for full SRAM coverage, and 4-bit source/destination register selectors — without encoding tricks.

---

## Next Steps

- [ ] Add MUL and DIV to the ALU (extend `opcode` to support 5 additional operations)
- [ ] Implement per-lane NZP flags and predication mask for branch divergence
- [ ] Build a multi-bank memory system to reduce LOAD/STORE from 16 cycles to fewer
- [ ] Write a Python assembler targeting this ISA
- [ ] Extend warp count from 4 to 8 (3-bit `warp_id`, wider scoreboard)
- [ ] Add VCD waveform dump support for GTKWave visualization
- [ ] Add a matrix multiply kernel as a 2D warp grid proof-of-concept
- [ ] Explore a second compute core to demonstrate multi-core scaling

---

## Repository Structure

```
simd-gpu/
├── src/
│   ├── chip_top.v          # Physical chip top: C2S0284, pad ring, host byte-mux
│   ├── gpu.v               # GPU wrapper: reset_sync + compute_core
│   ├── compute_core.v      # 4-warp FSM, 16-lane datapath, LOAD/STORE sequencing
│   ├── simd_wrapper.v      # 512-bit datapath: 16× ALU with lane masking
│   ├── alu.v               # 32-bit ALU: ADD/SUB/AND/OR/XOR
│   ├── regfile.v           # 16×32-bit register file (one instance per lane)
│   ├── scoreboard.v        # Per-warp RAW hazard detection
│   ├── reset_sync.v        # 2-FF async reset synchronizer
│   ├── shared_mem.v        # DPRAM wrapper (Port A read-only, Port B R/W)
│   └── rd3_1024x32.v       # SCL 180nm DPRAM macro stub (synthesis/P&R)
├── test/
│   ├── test_vecadd.py      # cocotb testbench: vector addition
│   ├── test_dotprod.py     # cocotb testbench: dot product
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
