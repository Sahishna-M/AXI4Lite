# AXI4-Lite Slave Controller with Register Bank and FIFO Datapath

An AXI4-Lite slave peripheral written in Verilog-2001. It has a memory-mapped register bank and a 16-entry, 32-bit synchronous FIFO behind one of the registers. The design is verified with a self-checking SystemVerilog testbench (16 directed tests) in QuestaSim, and synthesized with Synopsys Design Compiler on the Nangate 45 nm library.

| Item | Result |
|---|---|
| Directed tests | 16 / 16 pass |
| Fastest period that meets timing | 2.5 ns (400 MHz); 2.0 ns fails |
| Area at 10 ns (relaxed) | 5320.5 µm² |
| Area at 2.5 ns (tight) | 6392.0 µm² |
| Hold violations / DRV violations / latches | 0 / 0 / 0 |

## Contents

1. [Architecture](#architecture)
2. [Register map](#register-map)
3. [Design details](#design-details)
4. [Verification](#verification)
5. [Synthesis](#synthesis)
6. [Repository layout](#repository-layout)
7. [How to run](#how-to-run)
8. [Deviations from the original spec](#deviations-from-the-original-spec)
9. [Known limitations and future work](#known-limitations-and-future-work)

## Architecture

| Module | File | Role |
|---|---|---|
| `slave_fsm` | `rtl/slave_fsm.v` | AXI4-Lite handshaking. Independent write and read state machines. Registers the address, data and strobe, and issues a one-cycle write or read pulse to the register bank. |
| `reg_bank` | `rtl/reg_bank.v` | Address decode, per-register access rules, WSTRB byte masking, SLVERR generation, sticky ERROR bit, interrupt status and enable logic, FIFO push/pop control. |
| `sync_fifo` | `rtl/sync_fifo.v` | Parameterized synchronous FIFO (`WIDTH=32`, `DEPTH=16`). Extra phase bit on the pointers for full/empty detection. |
| `axi_lite_top` | `rtl/axi_lite_top.v` | Top level that connects the three blocks. |

### Ports (top level)

Standard AXI4-Lite signals on all five channels (AW, W, B, AR, R), plus `ACLK`, an active-low reset `ARESETN`, and one interrupt output `irq`.

## Register map

32-bit word-aligned registers.

| Offset | Name | Access | Description |
|---|---|---|---|
| 0x00 | CTRL | R/W | bit 0 ENABLE, bit 1 SOFT_RESET (write 1 to clear the FIFO and the ERROR bit; always reads 0), bits [3:2] MODE. Writing 0xF reads back 0xD. |
| 0x04 | STATUS | RO | bit 0 FIFO_EMPTY, bit 1 FIFO_FULL, bit 4 ERROR (sticky). Reset value 0x1. |
| 0x08 | FIFO_DATA | R/W | Write pushes a word. Read pops the oldest word. |
| 0x0C | (unmapped) | - | Access returns SLVERR. |
| 0x10 | IRQ_EN | R/W | 3-bit interrupt enable mask. |
| 0x14 | IRQ_STATUS | RO / W1C | bit 0 FIFO became full, bit 1 FIFO became empty, bit 2 error. Write 1 to clear a bit. |
| 0x18 | VERSION | RO | `0x0001_0000`. |

`irq = |(IRQ_STATUS & IRQ_EN)`.

### Response rules

| Access | Response |
|---|---|
| Write to a read-only register (STATUS, VERSION) | SLVERR, register unchanged |
| Read or write to an unmapped, misaligned (e.g. 0x01) or out-of-window (e.g. 0x20, 0x100) address | SLVERR, no register disturbed |
| Write to FIFO_DATA while the FIFO is full | SLVERR, ERROR bit set, data dropped |
| Read of FIFO_DATA while the FIFO is empty | OKAY, returns the last value read, ERROR bit set |
| Everything else | OKAY |

## Design details

- **Independent read and write paths.** A read and a write started in the same clock both complete correctly (test 14).
- **AW and W in any order.** The write FSM keeps `aw_done` and `w_done` flags, and commits the write once both have arrived (test 7).
- **Back-pressure.** `BVALID` and `RVALID` stay high, with stable response and data, until the master asserts `BREADY` or `RREADY`. While a write response is pending (`WRITE_RESP` state), `AWREADY` and `WREADY` are low, so a new write is not accepted (test 8).
- **WSTRB.** Byte-lane masking on CTRL and on FIFO_DATA (tests 5 and 6).
- **FIFO.** 16 x 32 bits built from flip-flops. Pointers have one extra phase bit so full and empty are told apart without a counter. Soft reset clears the pointers.
- **Reset.** `ARESETN` is active low and asynchronous. A reset in the middle of a transaction returns every block to idle and clears the abandoned transaction (test 15).
- **Single-cycle commit pulses.** `write_en_pulse` and `read_en_pulse` are high for exactly one clock, which is when the register bank updates state.

## Verification

The testbench is `tb/top.sv` (module `top`). It uses bus-functional tasks (`axi_write`, `axi_read`, plus checking wrappers) with configurable delays on each channel. A watchdog stops a hung simulation.

| # | Test | What it checks |
|---|---|---|
| 1 | Reset values | Idle handshake signals and the reset value of every register |
| 2 | Read/write of writable registers | Bit masks, SOFT_RESET reads 0, IRQ_EN keeps 3 bits |
| 3 | Writes to read-only registers | SLVERR, no change in STATUS and VERSION |
| 4 | Bad addresses | Unmapped, misaligned and out-of-window addresses give SLVERR on read and write |
| 5 | WSTRB on CTRL | Only strobed byte lanes are written, strobe 0 writes nothing |
| 6 | WSTRB on FIFO_DATA | FIFO word is assembled byte by byte |
| 7 | AW and W ordering | Address first, data first, and simultaneous |
| 8 | Back-pressure | Delayed BREADY / RREADY, response held stable, no new write accepted while the response is pending |
| 9 | Back-to-back transactions | No idle gaps, mixed registers |
| 10 | Fill, overflow, drain | FULL after exactly 16 pushes, 17th push rejected, FIFO order, IRQ events |
| 11 | Read from empty FIFO | Last value returned, ERROR set |
| 12 | Pointer wraparound | Pointers pass slot 15 several times in every fill state |
| 13 | Interrupt mask and W1C | Masking, and clearing only the written bit |
| 14 | Concurrent read and write | Same-clock read and write, including FIFO push and pop together |
| 15 | Reset mid-transaction | Clean idle after an interrupted write and read |
| 16 | Soft reset | Clears FIFO and ERROR, does not clear IRQ_STATUS |

Result of the final run (`docs/sim_results.txt`):

```
TESTS PASSED : 16, TESTS FAILED : 0
```

Every test prints per-check PASS/FAIL lines. The final summary counts tests, not individual checks.

## Synthesis

Tool and library:

| Item | Value |
|---|---|
| Synthesis tool | Synopsys Design Compiler W-2024.09-SP2 |
| Library | Nangate Open Cell Library 45 nm |

### Constraints

- Clock `ACLK`, uncertainty 0.05 ns.
- Inputs arrive `IP_DELAY` after the clock edge and outputs must be ready `OP_DELAY` before the next edge. These model the AXI master and the downstream logic as registered: `IP_DELAY = WIRE_DELAY + DFF_CKQ` and `OP_DELAY = WIRE_DELAY + DFF_SETUP`. The values used were `DFF_CKQ = 0.638 ns`, `DFF_SETUP = 0.546 ns` and `WIRE_DELAY = 0.02 ns`. They are estimates, not measured from this design.
- Inputs are driven by a `DFFR_X1` cell (`set_driving_cell`). Each output sees a load of 4 `DFFR_X1` D pins plus a wire estimate.
- `set_max_area 0` so the tool keeps minimizing area after timing is met.

### Clock-period sweep

Full table: `synth/sweep_results.txt`.

| Period (ns) | Frequency (MHz) | Setup slack (ns) | Hold slack (ns) | Cell area (µm²) |
|---|---|---|---|---|
| 2 | 500 | **-0.814 (fails)** | 0.498 | 6036 (not meaningful, run failed timing) |
| 2.5 | 400 | +0.002 | 0.493 | 6392 |
| 3 | 333 | +0.002 | 0.478 | 6123 |
| 3.5 | 286 | +0.011 | 0.478 | 5990 |
| 4 | 250 | +0.001 | 0.478 | 5676 |
| 5 | 200 | +0.064 | 0.498 | 5332 |
| 6 | 167 | +0.566 | 0.498 | 5323 |
| 8 | 125 | +2.168 | 0.498 | 5321 |
| 10 | 100 | +4.168 | 0.498 | 5321 |

- **Maximum frequency.** The fastest period in the sweep that meets timing is **2.5 ns (400 MHz)**. At 2.0 ns there are 700 violating paths. 
- **Area against speed.** From 10 ns to 6 ns the area is flat (about 5320 µm²) because the design is relaxed. Below 5 ns the tool upsizes cells and area rises, by about 20% at 2.5 ns.
- **Critical path.** At 10 ns the longest path decodes the read address into the FIFO `pop`, and then into the FIFO read pointer. At 2.5 ns it is the FIFO read pointer through the read mux into `RDATA`. At 2.0 ns it is a write address into the FIFO storage. The limiting paths run through the FIFO read and write muxes, with 11 to 14 logic levels.
- **Area and timing figures are cell area only.** 

### Area breakdown

| Block | 10 ns (µm²) | Share | 2.5 ns (µm²) | Share |
|---|---|---|---|---|
| `sync_fifo` | 3751 | 70.5% | 4685 | 73.3% |
| `slave_fsm` | 1055 | 19.8% | 1104 | 17.3% |
| `reg_bank` | 495 | 9.3% | 584 | 9.1% |
| Total | 5320.5 | 100% | 6392.0 | 100% |

The FIFO dominates because its 512 storage bits are flip-flops, not a memory macro. The design has 707 flip-flops in total.

### Violations and warnings

- **Setup** is met for every period from 2.5 ns up; 2 ns fails. **Hold** has positive slack (0.48 to 0.50 ns) in every run, so no hold fixing was needed. Hold slack is almost independent of the clock period.
- **Design rule violations:** none (0 max-transition, 0 max-capacitance, 0 max-fanout).
- **Constraint report.** `report_constraint -all_violators` lists `max_area` and `max_leakage_power` as violated. These are the intentionally unreachable targets of `set_max_area 0` and the default leakage goal, not real failures.
- **Latches:** 0.

Reports for the runs are in `docs/synth/`.

## Repository layout

```
.
├── Makefile              # make sim | make synth | make clean
├── setup.sh              # loads QuestaSim, points to Design Compiler
├── rtl/                  # slave_fsm.v, reg_bank.v, sync_fifo.v, axi_lite_top.v
├── tb/top.sv             # self-checking testbench, 16 directed tests
├── sim/Makefile          # compile and run in QuestaSim
├── synth/
│   ├── Makefile          # one run (synth) or full sweep (sweep)
│   ├── scripts/          # setup.tcl, read.tcl, constraints.tcl, compile.tcl, run_all.tcl
│   └── sweep_results.txt # clock-period sweep table
└── docs/                 # simulation log and key synthesis reports
```

## How to run

Tools: QuestaSim (module `questa/2025.1_1`) and Synopsys Design Compiler (W-2024.09-SP2). `setup.sh` has the paths used on NC State's Grendel cluster.

```
make sim      # compile the RTL and testbench, run all 16 tests, write sim/run.log
make synth    # run Design Compiler at every period in the sweep, write synth/sweep_results.txt
make clean    # remove all generated files
```
