# Shakti Yamuna ↔ Image-Processing IP — Integration & Build Handoff

Self-contained guide for a fresh Claude session (or engineer) working in this workspace.
You have two repos that matter here:

- `ImageProcessing_HW_AcceleratorIP/` — the KCF/NCC tracker IP (native SystemVerilog, AXI4-Lite).
- `gc2025/` — the SHAKTI Yamuna SoC (Bluespec BSV → Verilog → Vivado) + GCSDK bare-metal SDK.

> **Ground rules (non-negotiable, from the project owner):**
> 1. **NEVER run `make` yourself** (`make build`, `make software`, or any build). Builds are
>    performance-hungry and hang the machine — prepare everything, then tell the user the exact
>    command to run themselves.
> 2. The workspace root is **not** a git repo. Each subdirectory is its own repo. Run git only
>    inside a subdirectory.
> 3. `ImageProcessing_HW_AcceleratorIP/ICD.md` is the **single contract** between IP and SoC
>    software. Any format/protocol mismatch is fixed **IP-side**, never worked around in the
>    driver or SoC.
> 4. When a decision is ambiguous, ask the user instead of picking silently.

---

## 1. Integration architecture (how the IP attaches to the SoC)

**Key fact: the IP is NOT wrapped in BSV.** The Bluespec compiler (`bsc`) never sees it. The
BSV SoC exposes a flat AXI4-Lite *master* port at the `mkSoc`/`mkDebugSoc` Verilog boundary, and
the IP's `s_axi` slave port is wired to it **in plain Verilog inside `fpga_top.v`** — the same
pattern the SoC already uses for the MIG DDR3, Ethernet-lite, and XADC Xilinx IPs.

Signal path: `CPU (RV32IMACSU) → fast AXI4 fabric → axi2axil bridge → slow AXI4-Lite fabric →
v_to_slaves[5] → kcf_master port on mkDebugSoc → image_ip_axilite`. This path was proven on
real hardware with an earlier +1-adder test slave, so the plumbing itself is trusted.

### Board-copy rule (critical)

For the `arty_a7_yamuna` board, the authoritative sources live in
**`gc2025/hw/boards/arty_a7_yamuna/`** (`Soc.bsv`, `Soc.defines`, `fpga_top.v`, `tcl/`).
`make build` **copies these over the hw-root versions** — editing `gc2025/hw/Soc.bsv` or
`gc2025/hw/boards/../../fpga_top.v` at the root gets silently overwritten. **Only ever edit the
`boards/arty_a7_yamuna/` copies.**

### The five integration touchpoints (ALL ALREADY DONE, uncommitted)

The integration is complete and working in the tree as of 2026-07-19; nothing is committed in
`gc2025`. Listed here both as current-state documentation and as the recipe if it ever has to be
redone:

1. **Address map** — `gc2025/hw/boards/arty_a7_yamuna/Soc.defines`:
   ```
   `define Kcf_slave_num 5          // line ~66, slow-fabric slave index
   `define KcfBase  'h0004_2000     // line ~77
   `define KcfEnd   'h0004_20FF
   ```
   (If adding a *new* slave from scratch: bump `Num_Slaves`, add the `_slave_num` define +
   base/bound, add the decode branch in `fn_slave_map`.)

2. **SoC port** — `gc2025/hw/boards/arty_a7_yamuna/Soc.bsv`:
   - `fn_slave_map` decode branch: `else if (addr >= `KcfBase && addr <= `KcfEnd) slave_num = `Kcf_slave_num;` (line ~121)
   - Interface declaration: `interface AXI4_Lite_Master_IFC#(`paddr, `buswidth, `USERSPACE) kcf_master;` (line ~138)
   - Binding: `interface kcf_master = slow_fabric.v_to_slaves[`Kcf_slave_num];` (line ~677)
   - `bsc` flattens this into flat ports named `kcf_master_awvalid`, `kcf_master_awaddr`,
     `kcf_master_m_awready_awready`, … on the generated `mkDebugSoc` Verilog.

3. **RTL sources** — all 17 `.sv` files + 3 `.mem` ROM-init files from the IP repo are copied to
   **`gc2025/hw/ip_verilog/kcf/`** (top module: `image_ip_axilite.sv`; `kcf_axi_slave.v` in the
   same dir is the old link-test adder, kept as an unreferenced fallback). If the IP repo's
   `src/` or `data/` changes, re-copy:
   ```bash
   cp ImageProcessing_HW_AcceleratorIP/src/*.sv  gc2025/hw/ip_verilog/kcf/
   cp ImageProcessing_HW_AcceleratorIP/data/*.mem gc2025/hw/ip_verilog/kcf/
   ```

4. **Vivado project tcl** — `gc2025/hw/boards/arty_a7_yamuna/tcl/create_project.tcl`
   (lines ~43-45) adds the sources:
   ```tcl
   add_files -norecurse -fileset [get_filesets sources_1] [glob $home_dir/ip_verilog/kcf/*.v]
   add_files -norecurse -fileset [get_filesets sources_1] [glob $home_dir/ip_verilog/kcf/*.sv]
   add_files -norecurse -fileset [get_filesets sources_1] [glob $home_dir/ip_verilog/kcf/*.mem]
   ```
   The `.mem` files must be design sources so bare `$readmemh("hann_64.mem")` names resolve.

5. **Top-level wiring** — `gc2025/hw/boards/arty_a7_yamuna/fpga_top.v`:
   `kcf_master_*` wires declared (~line 356), connected to the `core` (mkDebugSoc) instance
   (~line 726), and consumed by the IP instance (~line 871):
   ```verilog
   image_ip_axilite #(.ADDR_WIDTH(32)) kcf_ip (
     .clk(core_clk), .rst_n(~soc_reset),
     .s_axi_awaddr(kcf_master_awaddr), ... ,
     .irq_out()          // unconnected for now
   );
   ```
   Single clock domain (`core_clk`), no CDC. Reset is active-low from `~soc_reset`.

### Software contract

- Register map, packed-pixel upload protocol, and the designation → acquire → track → loss
  flow are defined in **`ImageProcessing_HW_AcceleratorIP/ICD.md`** (v2.0, LOCKED). Do not
  restate or re-derive it — read that file.
- Bare-metal driver + test app (branch `ip-interface` of the `embedded_appn` repo, checked out
  as a worktree at `gc2025/GCSDK/software/examples/ip_interface/`):
  - `kcf_ip.h` / `kcf_ip.c` — driver; `KCF_IP_BASE 0x00042000` must equal `KcfBase`.
  - `ip_interface.c` — hardware mirror of the ICD testbench scenario.
- The IP ignores `wstrb` → the CPU must use **32-bit stores only**.

---

## 2. Toolchain & environment (nothing is on the non-interactive PATH)

| Tool | Location |
|---|---|
| RISC-V GCC 13.2.0 (multilib), openocd, elf2hex | `/home/kalrav/riscv_multilib/bin` |
| Bluespec compiler `bsc` | `/home/kalrav/Desktop/bsc/inst/bin` |
| Xilinx Vivado 2018.3 | `~/Xilinx/Vivado/2018.3` |

Before any build/debug command works in a shell:

```bash
export PATH="/home/kalrav/riscv_multilib/bin:/home/kalrav/Desktop/bsc/inst/bin:$PATH"
source ~/Xilinx/Vivado/2018.3/settings64.sh     # only needed for bitstream builds
```

Note: the GCC prefix is `riscv64-unknown-elf-*` (multilib — handles rv32 via
`-march=rv32imac -mabi=ilp32`). GCSDK Makefiles construct `riscv$(XLEN)-unknown-elf-gcc`, so
check the specific Makefile if a `riscv32-...` name is expected.

---

## 3. Python venv for the SoC hardware build

The `gc2025/hw` BSV→Verilog flow calls `python3 -m configure.main` (see `gc2025/hw/Makefile`
line ~104), which needs the SHAKTI `soc_config` package and friends. Requirements:
`gc2025/hw/requirements.txt`:

```
repomanager==1.5.1
Cerberus>=1.3.1
ruamel.yaml>=0.17.16
pytz
aapg
git+https://gitlab.com/shaktiproject/cores/soc_config.git@2.4.0
```

**A working venv already exists: `gc2025/.venv` (Python 3.12)** with `soc_config 2.4.0`,
`Cerberus`, `repomanager`, `aapg`, `ruamel.yaml` installed. Use it — do not create a new one:

```bash
source /home/kalrav/Desktop/dev_infracore/gc2025/.venv/bin/activate
```

(`gc2025/hw/.venv310_new` also exists but is an empty skeleton — ignore it.)

Only if `gc2025/.venv` were ever missing/broken, recreate with:

```bash
cd /home/kalrav/Desktop/dev_infracore/gc2025
python3 -m venv .venv
source .venv/bin/activate
pip install -r hw/requirements.txt     # needs network for the gitlab soc_config URL
```

The Makefile uses whatever `python3` is first on PATH, so the venv must be **activated in the
same shell** the user runs `make` from.

---

## 4. Build & run commands (give these to the USER — do not run them)

### 4a. SoC bitstream (BSV → Verilog → Vivado bit/MCS)

```bash
cd /home/kalrav/Desktop/dev_infracore/gc2025/hw
source ../.venv/bin/activate
export PATH="/home/kalrav/riscv_multilib/bin:/home/kalrav/Desktop/bsc/inst/bin:$PATH"
source ~/Xilinx/Vivado/2018.3/settings64.sh
make build BOARD=arty_a7_yamuna XLEN_build=32
```

Always `BOARD=arty_a7_yamuna` and `XLEN_build=32` (Yamuna is RV32IMACSU; the Ganga/Kaveri RV64
configs in the same tree are NOT this project). Vivado logs land under
`gc2025/hw/fpga_project/c-class/c-class.runs/` (`core_synth_1/runme.log`,
`fpga_top_utilization_synth.rpt`, `impl_1/…`) — these are readable without running anything.

### 4b. Bare-metal app (GCSDK)

```bash
cd /home/kalrav/Desktop/dev_infracore/gc2025/GCSDK
export PATH="/home/kalrav/riscv_multilib/bin:$PATH"
make software PROGRAM=ip_interface TARGET=yamuna     # build only
make upload  PROGRAM=ip_interface TARGET=yamuna      # build + flash to board
```

Syntax-checking driver C code with the cross-compiler directly (fast, safe to do yourself) is
fine; only `make` targets are off-limits.

### 4c. Board bring-up / debug

```bash
# terminal 1 (from gc2025/hw):
openocd -f shakti-arty.cfg
# terminal 2:
riscv64-unknown-elf-gdb -x gdb.script
# UART0 serial monitor:
sudo miniterm /dev/ttyUSB1 19200
```

### 4d. IP standalone simulation (Icarus — safe to run yourself, it's light)

Run **from `data/`** so bare `$readmemh` filenames resolve:

```bash
cd /home/kalrav/Desktop/dev_infracore/ImageProcessing_HW_AcceleratorIP/data
iverilog -g2012 -o t.vvp ../src/*.sv ../tb/tb_image_ip_axilite.sv && vvp t.vvp   # ICD scenario
iverilog -g2012 -o t2.vvp ../src/*.sv ../tb/tb_kcf_top.sv && vvp t2.vvp          # KCF regression
```

`tb_image_ip_axilite` exercises the full ICD v2 flow (designation, acquisition with NCC→KCF
switch, tracking, 3-frame loss fallback) and must print ALL TESTS PASSED before any RTL change
is handed to the user for a Vivado build.

---

## 5. Current state & known issues (updated 2026-07-19, second pass)

- **ICD v3.0 implemented, locked, and verified** (IP repo). All three resource
  fixes from the failed-placement diagnosis are DONE:
  1. `ifft2d_64` staging buffer deleted (on-the-fly conjugation into the inner
     `fft2d_64`; `S_CONJ_IN` removed — also −4,096 cycles/IFFT).
  2. `(* ram_style = "block" *)` forced on every large array (`kcf_top`,
     `fft2d_64`, `frame_input_if`).
  3. `fft1d_64` `out_re/out_im` copy arrays replaced by a combinational read
     port; `fft2d_64` reads results serially through it.
- **ICD v3 camera format is in**: 320×240 RGB565, 2 px per 32-bit write
  (38,400 writes/frame), hardware RGB565→gray (BT.601) + hardware un-flip of
  the bottom-right-first scan; all coordinates upright. New `KCF_THRESH`
  (0x34) separates the KCF loss threshold from the NCC acquisition
  threshold; response scaling fixed (IFFT no longer over-normalized) so KCF
  confidence is ~200–300 locked vs ≲70 lost, and spectral column 0 is zeroed
  (kills the historical (63,0)/(59,0) wrap-artifact peaks).
- **Standalone Vivado 2024.2 OOC synthesis of the IP PASSES** on
  xc7a100tcsg324-1: **15,405 LUTs (24%) / 10,831 FFs (8.5%) / 63 RAMB36 /
  27 DSP / 0 latches** — vs the ~60K LUTs / ~150K FFs the IP contributed to
  the failed build. Combined with the Yamuna baseline the design should now
  place with margin.
- Verified before handoff (per §4d rule): `tb_image_ip_axilite` (full ICD v3
  camera-order scenario), `tb_upload_check` (bit-exact storage+decimation),
  `tb_kcf_top`, `tb_fft1d_64` — ALL PASSED.
- **`gc2025/hw/ip_verilog/kcf/` is now populated and committed** with the 17
  fixed `.sv` + 3 `.mem` files (touchpoint 3) — pull `gc2025` on the build
  machine, keep your local wiring (touchpoints 1,2,4,5, still uncommitted on
  the Linux box), and re-run `make build BOARD=arty_a7_yamuna XLEN_build=32`.
- **Driver TODO (SoC side)**: update `KCF_FRAME_*` macros + upload loop to
  ICD v3 — 320×240, `REG(0x28) = ((uint32_t*)cam)[j]` for j < 38,400,
  frame complete at BUF_IDX == 76,800, set KCF_THRESH ≈ 0x0080, and read
  ABS_ROW (0–239) / ABS_COL (0–319) as upright coordinates.
- Pending housekeeping in `gc2025`: staged-set cleanup (build-overlay files)
  from the 2026-07-19 audit.
