# ECE499 Session Handoff — KCF/NCC Tracker IP (JPEG input, timing, HW bring-up)

*Updated 2026-07-26 (rev 2 — NCC normalizer fix + confirmed synth). Point a fresh assistant at this file. Supersedes the
2026-07-25 handoff.*

---

## 0a. NEWEST (2026-07-28) — NCC rebuilt for the final-demo target

- The demo target changed to a **white/red toy jet on black cloth** (11 photos in
  `Target photos for final demo/`). The shipped bank was cut by
  `build_target_figure.py`, which segments on colour **saturation** — on a mostly
  white jet that selects only the red trim (a 43×127 px sliver on one photo), so
  the template came from the wrong region.
- **New `scripts/build_target_demo.py`** (IP repo, committed `338f531`;
  vendored `aee3b4b` monorepo / `382657a` custom_soc_HW). **No RTL, no AXI
  change** — `.mem` files only. All five NCC/KCF testbenches pass.
- Measured over 924 rendered frames (11 photos × 7 sizes × 4 rotations × 3
  positions) and **150 target-free cloth frames validated against the
  segmentation mask** so none clips the object, each bank at the lowest THRESH
  its own worst target-free case allows:

  | | shipped | new |
  |---|---|---|
  | THRESH | 25 | 18 |
  | lock within ±32 px | 76.6 % | 84.0 % |
  | hand-held envelope (48–84 px) | 81.5 % | 87.2 % |
  | worst target-free confidence | 9 | 8 |
  | target wins when a distractor shares the frame | 82 % | 91 % |

- **THRESH (0x08) is currently 30 in firmware; the model says that costs ~13
  points of acquisition versus 18.** Do NOT set it from the model
  (`kcf_ip.h` explains why — the model runs ~25 points high on target
  confidence). What *does* transfer is the background ceiling: the model's worst
  target-free frame is **8**, and the 2026-07-27 hardware capture independently
  measured **≤ 8**. So ≥ ~16–18 keeps a 2× margin over measured background.
  **Re-measure once on hardware with the new bank, then set it.**
- **Two defects found and fixed on the way** (§10).
- **Known limits, state them rather than be surprised:** one of the 11 photos
  (`target9 (1)`, backdrop luma 72 vs jet 95) is near-zero contrast and is
  essentially unusable — don't demo in that lighting. And a bare bright object
  with no target present WILL acquire (disc 57 %); r² is contrast-invariant so
  this is inherent, not a bug. Keep hands and pale objects out of frame.

---

## 0. TL;DR — where things stand

- **Hardware JPEG frame input** is built, verified in sim, and on all repos: the
  ArduCam sends a compressed JPEG over SPI (~85 ms/frame vs ~850 ms for raw
  RGB565); the IP decodes it to 8-bit luma in hardware. Raw RGB565/BMP retained
  as a demo backup.
- **50 MHz setup timing is CLOSED** (post-route WNS **+1.274 ns**) after the
  FFT/Hann fixes + JPEG-IDCT pipeline.
- **The design fits comfortably** (~83% LUT after the `bram_sdp` fix, §4).
- The tracker **runs on hardware** but has been through several bug-fix rounds
  (KCF confidence, NCC edge-locking, NCC↔KCF thrash). Latest fixes pushed.
- **LUT reduction: DONE and CONFIRMED by re-synth.** Moving `kcf_top`'s ten
  4096×16 buffers into `bram_sdp` took LUTRAM 5,376 → **0** and the design
  **93% → 83%** (59,131 → 52,465 LUT), RAMB36 58 → 66 of 135. Beat the
  prediction; ~10.9k LUTs of headroom recovered (§4, §7). **Closed.**
- **THREE separate root causes of the bad tracking are now fixed** (§8, §8b,
  §8d): the NCC argmax normalizer, the KCF training deadlock, and a KCF
  confidence threshold set above the physically achievable value. They had to
  be found in that order — each was masking the next.
- **NCC edge-lock ROOT-CAUSED AND FIXED** (`31cfac6`) from the new A/B
  capture pair (§8). Window selection divided by *raw* Σf² while the reported
  confidence divided by *zero-mean* Σ(f−f̄)² — so the argmax carried a pure
  brightness bias and parked in the darkest (vignetted) corner, and `0x1C`
  never reported the score that actually won. Also raised the variance floor,
  which had been sitting *at* the sensor noise level. Sim-verified byte-identical
  on target-present cases. **Next action: collaborator re-vendors, rebuilds,
  and re-runs the A/B capture** — then retune `THRESH`, then re-look at KCF.
- **Two open work items:**
  1. **Hold timing** — WHS −1.413 ns, 55 endpoints, **all in the SoC's AXI
     clock-converter (CDC) + MIG DDR3 + RISC-V JTAG/debug, ZERO in the KCF IP**
     (§6). Not fixable from the IP; it is a constraints/P&R job, and §6 now
     lists the specific XDC lines needed (TCK clock + async groups, I/O delays).
  2. **KCF conf ≡ 0 on 522/522 frames: ROOT-CAUSED AND FIXED**, two
     independent causes. (a) `53d4428`/§8b — the filter could only ever be
     trained by the boot designation, because the runtime update required a
     confidence only a trained filter can reach; an NCC acquisition now
     re-trains it. (b) `5d1a949`/§8d — `CONF_K=5` demanded peak/mean > 5, but
     the real target tops out at 4.0-6.9 ideal and 1.6-4.5 realistic, so the
     zero-clamped `max(0, peak-5*mean)` read 0 regardless. Confidence is now
     the ratio itself. **`KCF_THRESH` is rescaled — firmware must retune.**
- **HARD CONSTRAINT from the user:** do **NOT** change the AXI communication
  architecture / register map — the collaborator's firmware depends on it. All
  changes must be internal (compute/logic), keeping the register interface
  identical.

---

## 1. Repo state — **keep the Infracore `gc2025` monorepo up to date**

> **RULE (from the user, 2026-07-26): the Infracore `gc2025` monorepo must
> ALWAYS be up to date.** It is what the collaborator actually builds, so a fix
> sitting only in the IP repo is invisible to them — it may as well not exist.
> Never end a session with the monorepo lagging
> `ImageProcessing_HW_AcceleratorIP`. This is about *currency*, not about a
> ceremony over which repo is pushed first.

| Repo | Branch | HEAD | Role |
|---|---|---|---|
| **`gc2025`** (`gc2025_infracore/` locally) | `main` | **`c0cb39d`** | **The monorepo the collaborator builds** (`hw/`, GCSDK, `irst_main` firmware, `tracker_viz`). **Must never lag.** |
| `ImageProcessing_HW_AcceleratorIP` | `main` | **`5d1a949`** | IP **source of truth** (src/, data/, tb/, scripts/, docs). Has to be committed before the others can vendor *from* it — mechanics, not ranking. |
| `custom_soc_HW` | `rv32imac-uart1-spi1-i2c0-kcf` | **`6252a9b`** | SoC build; vendors IP into `ip_verilog/kcf/`. Keep in step. |
| `ECE499-Akhil-Sriram-Major-Project` | `main` | **`41c2010`** | docs / this handoff (Akreus29, not Infracore) |

> `Akreus29/gc2025` (`gc2025/` locally) is a **personal mirror, NOT the monorepo**
> — a full IP generation behind (20 files in `hw/ip_verilog/kcf` vs 33) with
> uncommitted local edits. **Do not push it without asking.**

**The invariant to check at the START and END of any RTL session:** every
`src/*.sv` and non-generated `data/*.mem` in the IP repo is byte-identical
(modulo CRLF) to `gc2025_infracore/hw/ip_verilog/kcf/`. One-liner:

```sh
IP=ImageProcessing_HW_AcceleratorIP
V=gc2025_infracore/hw/ip_verilog/kcf
GEN="ball_test_frame.mem tb_target_frame.mem test_frame_watch.mem"
for f in $IP/src/*.sv $IP/data/*.mem; do
  b=$(basename "$f")
  case " $GEN " in *" $b "*) continue;; esac
  diff -q --strip-trailing-cr "$f" "$V/$b" >/dev/null || echo "DRIFT: $b"
done
```

**Re-vendoring the IP** (README "Re-vendoring the KCF IP"):
```
rm -f <V>/*.sv <V>/*.mem
cp ../ImageProcessing_HW_AcceleratorIP/src/*.sv  <V>/
cp ../ImageProcessing_HW_AcceleratorIP/data/*.mem <V>/
# remove generated TEST vectors so they don't pollute the build:
rm -f <V>/ball_test_frame.mem <V>/tb_target_frame.mem <V>/test_frame_watch.mem
# ball_test_frame.mem + tb_target_frame.mem are TRACKED in both build repos,
# so the rm above deletes version-controlled files — restore them:
git -C <repo> checkout -- <V>/ball_test_frame.mem <V>/tb_target_frame.mem
git add -A <V> && git commit -m "[IP] re-vendor …"
```
`<V>` = `hw/ip_verilog/kcf` (gc2025) or `ip_verilog/kcf` (custom_soc_HW).
`core.autocrlf=true` on the build repos → `git add -A` is clean (CRLF-only files
collapse to no-ops; only real content changes commit — the 2026-07-26 re-vendor
staged exactly the 3 changed `.sv`). `create_project.tcl` globs
`ip_verilog/kcf/*.sv` + `*.mem`; `$readmemh` ROMs resolve by bare filename.
Always `git pull` before push (collaborator active on all repos).

---

## 2. What was built / fixed (chronological)

1. **FFT/Hann 50 MHz timing** (`fft1d_64.sv` 2-cycle pipelined butterfly;
   `kcf_top.sv` pre-registered 2-D Hann coeff). Closed the −5.602 ns setup.
2. **Hardware JPEG decoder** (`jpeg_decoder.sv`, `jpeg_idct8x8.sv`,
   `jpeg_frontend.sv`) + fixed OV5642 tables in `data/jpeg_*.mem`. 320×240, 4:2:2,
   no restart, 623-byte fixed header. Strict validator: bad header / missing EOI
   footer / bad Huffman / truncation raise `error`, never `done`. Bit-exact on
   both real capture frames.
3. **Integrated into `frame_input_if.sv`** (v4.1 single-`start` flow: BUF_IDX=0
   resets, stream `JPEG_DATA` 0x3C, `CTRL.start` auto-detects `has_data` and runs
   decode→decimate; `frame_complete` gated on a clean decode). Status:
   `STATUS(0x10)` **[6]=jpeg_busy, [7]=jpeg_error**.
4. **Smiley-ball designation target** (`data/target_frame.mem`, centre
   **(120,160)**), composited at ~60 px so the NCC 64×64 template captures the
   whole face. Tools: `scripts/build_target.py`, `analyze_target.py`.
5. **LUT-over-util fix** (`jbuf` BRAM inference) + **JPEG-IDCT serialization**
   (single 18×40 MAC) — got the design to fit.
6. **NCC confidence** made brightness-invariant (zero-mean energy + variance
   floor) so `THRESH=0.25` is meaningful.
7. **KCF confidence normalized** (`peak − CONF_K·mean|resp|`, `CONF_K` param
   default 5; `abs_sum` accumulated in `peak_finder.sv`) — fixed the original
   "stuck in KCF, confidence random/high, no KCF→NCC fallback" bug.
8. **JPEG IDCT pipelined** (registered multiply / DSP output reg) — closed the
   −1.418 ns setup path. Bit-identical.
9. **NCC border margin** (`ncc_search.sv`, `BORDER` param default 2) + **acquisition
   hysteresis** (`track_ctrl.sv`, `ACQ_FRAMES` param default 3) — from a live run
   (see §5): kill edge false-locks + damp NCC↔KCF thrash.

All verified with **Icarus Verilog** (`/c/iverilog/bin`, SV works): `tb_jpeg_*`,
`tb_ball_demo`, `tb_image_ip_axilite`, `tb_kcf_top`. Local sim loop: stage
`data/*.mem` + generated vectors in one dir, `iverilog -g2012 -o t.vvp tb/<tb>.sv
src/*.sv && vvp t.vvp` from that dir.

---

## 3. Architecture (for continuity)

Data path: ArduCam OV5642 → SPI → SHAKTI → AXI4-Lite → `image_ip_axilite` →
`frame_input_if` (frame storage + engines) → `track_ctrl` (orchestrator) →
`ncc_search` / `kcf_top` → `result_output_if`. Clock 50 MHz, base `0x0004_2000`.

Coarse-to-fine tracking: `frame_buf` is 320×240; `dec_buf` is a 4×-decimated
80×60 copy. **NCC** slides a 16×16 template over the 80×60 map (window centre →
full-res `4·wy+32, 4·wx+32`); **KCF** then crops the full-res 64×64 at the
NCC centre and refines. Boot designation (`AUTO_TINIT=1`) builds both the NCC
template and pre-trains the KCF filter from `target_frame.mem` at `(TGT_ROW,TGT_COL)`.

**Register map (DO NOT CHANGE — collaborator depends on it):** CTRL 0x00,
MODE 0x04, THRESH 0x08 (NCC acq threshold), STATUS 0x10 ([6]jpeg_busy
[7]jpeg_error), CONFIDENCE 0x1C, IMAGE_FRAME 0x28 (RGB565), BUF_IDX 0x30,
KCF_THRESH 0x34, JPEG_DATA 0x3C. Full details in `ImageProcessing/ICD.md` (v4.1)
and `JPEG_INPUT_INTEGRATION.md`.

---

## 4. Current timing/area picture (collaborator's synth, **post-`bram_sdp`**)

**§7 is CONFIRMED DONE — the re-synth landed and beat the prediction.**

| | before (`1cab7b9`) | after (`6f5894a`) | predicted |
|---|---|---|---|
| Total LUTs | 59,131 (~93%) | **52,465 (~83%)** | ~53,755 (~85%) |
| KCF IP LUTs | 17,451 (5,376 LUTRAM) | **10,786 (0 LUTRAM)** | — |
| RAMB36 | 58 | **66** / 135 | 66 |
| DSP48 | 50 | 46 (KCF) / 50 total | — |

Top-level now: 52,465 LUT, 50,067 FF, 66 RAMB36, 37 RAMB18, 50 DSP48.
~10.9k LUTs of headroom recovered. **The two further cuts in §7 are no longer
needed for area** — keep them shelved unless something else needs the room.

- **Setup: MET, WNS +1.274 ns, TNS 0.000.** Critical paths are inside the
  RISC-V core (`csr` → `ff_pipe1`), +1.6 to +2.7 ns. **KCF IP: zero violations.**
- **Hold: WHS −1.413 ns, THS −24.126 ns, 55 endpoints — see §6. Unchanged.**
- **The "CONSTRAINTS NOT MET" banner is hold + unconstrained paths only** —
  no setup failure anywhere. See §6 for the XDC work that clears it.

---

## 5. Live-hardware behaviour (UART log `uart_rx.txt`) & the fixes

Symptoms on a blank white sheet: NCC↔KCF **thrash** (380 NCC + 423 KCF frames);
tracker **locked onto frame edges** (positions pinned to x=32/288, y=32/208 —
the extreme NCC search windows), not the ball; KCF conf read ~0 a lot; a
**sustained `jpeg_error`** that needed a board reset.

- The KCF-confidence fix (item 7) **did** cure the original "stuck in KCF" —
  it now falls back. The thrash + edge-lock are the follow-on issues.
- **Fixed in RTL:** NCC border margin (drops the edge false-positives) +
  acquisition hysteresis (needs 3 consecutive confident NCC frames before KCF;
  first lock after designation immediate). Pushed (item 9).
- **Sustained `jpeg_error` looks CAMERA-side:** firmware also logged "invalid
  JPEG … rx bytes 0" (a 0-byte / stuck SPI read). The HW decoder correctly
  rejects bad input; recovery is a camera/SPI-FIFO reset in firmware, not an IP
  change. (If complex scenes exceed 16 KB JPEGs, grow `jpeg_frontend` MAXW.)

**Hardware tuning levers (collaborator, biggest first — `JPEG_INPUT_INTEGRATION.md`
§9d):**
1. **Raise `THRESH` (0x08)** above the false-positive band: blank scene read
   NCC conf ≈ 50–63/256 (~20–25%); a real ball read ~95 (~37%) in sim. Try
   **~75–90** so blanks don't acquire. *Biggest immediate lever, no rebuild.*
2. `KCF_THRESH` (0x34): watch `0x1C` on a held target vs empty, set between.
3. `CONF_K` (kcf_top param, default 5): if real interior locks read 0 after the
   border-margin fix, lower it.

### 5b. Paired A/B capture, 2026-07-26 — **found the real bug** (§8)

Two logs at repo root: `uart_rx(without target-only plain sheet).txt` (blank,
535 frames) and `uart_rx(with target with background of plain sheet).txt`
(ball, 339 frames). This pairing is what made the bug provable.

| | blank | with ball |
|---|---|---|
| NCC conf | min 120, **median 139**, max 208 | min 35, median 192, max 240 |
| KCF conf | **0 in 321/321** | **0 in 201/201** |
| NCC/KCF run pattern | rigid 2-NCC / 3-KCF ×107 | rigid 2-NCC / 3-KCF ×67 |
| distinct NCC positions | **14 spots in 214 frames** | 100+ |
| at extreme window | 99% on max-y, 61% max-x | 36% / 15% |

Three findings:

1. **The blank sheet is not producing a scene response at all.** 126 of 214 NCC
   frames landed on *exactly* `(280,192)` — the extreme bottom-right window of
   the BORDER-clamped range — and the whole log only ever visits 14 positions.
   That is a static bias in the argmax, not image content. **Root-caused and
   fixed — see §8.**
2. **No THRESH can separate the two scenes.** Blank max (208) exceeds ball
   median (192). Sweeping THRESH: 180 → 9.8% blank-accept but 78% ball-accept;
   209 → 0% blank but only 10% ball. *The §5 advice to "raise THRESH to 75–90"
   is obsolete* — the blank floor is 120, not 50–63. Retune only after §8.
3. **KCF confidence is 0 on every single frame of both logs (522/522).**
   **Root-caused — it is a training deadlock, see §8b.** The first guess (that
   KCF was handed dark-corner patches) is WRONG and the data refutes it: in the
   ball log KCF was repeatedly handed good *interior* NCC locks at conf 180–231
   and still returned 0, while its position output moved a plausible ±2 px.
   KCF was opening the patch in the right place and correlating it against the
   wrong appearance.

Also: **the camera wedged twice** in the ball log (frames 255–260) —
`FIFO length > 16 KB buffer` ×3, then `bad JPEG SOI` ×3. `jpeg_frontend.MAXW`
is 4096 words = exactly 16 KB, so a busier scene overruns it. Two options:
(a) **firmware, free:** lower the OV5642 JPEG quality so frames stay under
16 KB — try this first; (b) **HW, +4 RAMB36 (66→70 of 135):** `MAXW` 4096 →
8192 **and** raise the matching firmware limit — both must change together or
nothing improves.

**Still needs on-HW diagnosis:** dump `0x1C` with the ball centred + well-lit to
see whether KCF gives a sharp response (conf ≫ 0) once it stops edge-locking.

---

## 6. Hold timing (WHS −1.413 ns, 55 endpoints)

**ALL 55 failing endpoints are OUTSIDE the KCF IP** (verified: 0 in `kcf_ip/…`):
- ~majority in `clock_converter` — Xilinx **AXI clock-converter** IP's async-FIFO
  **gray-code CDC synchronizers** (`xpm_cdc_gray`, `rd/wr_pntr_cdc_inst`).
- a few in `clk_div` (MMCM) and RISC-V `core/debug_module` + `jtag_tap` (slow
  async TCK).
The worst path is inside a 2-flop synchronizer (data delay 0.228 ns, clock skew
0.145 ns). These are **the router's job** (hold fixing via delay insertion) and/or
**constraints** — not RTL in our IP. The KCF IP has **zero** setup or hold
violations. *We cannot fix these by editing the IP.*

Breakdown of the 55 (all inter-clock CDC):

| crossing | endpoints | WHS |
|---|---|---|
| `clk_out1_clk_divider` → `clk_pll_i` | 12 | **−1.413** (design worst) |
| `oserdes_clk_1` → `oserdes_clkdiv_1` | 12 | −0.268 |
| `oserdes_clk` → `oserdes_clkdiv` | 11 | −0.247 |
| `oserdes_clk_2` → `oserdes_clkdiv_2` | 10 | −0.274 |
| `oserdes_clk_3` → `oserdes_clkdiv_3` | 10 | −0.197 |

The four `oserdes_*` groups are **inside the MIG DDR3 controller** — Xilinx-
generated, and its own XDC declares them safe. The 12 on `clk_out1 → clk_pll_i`
are the AXI clock converter's gray-code CDC.

**Also unconstrained (this is why the banner says NOT MET) — XDC work, collaborator:**
1. **312 pins on `bse2_inst/TCK` have no clock defined** (HIGH). JTAG TCK is a
   free-running async debug clock: `create_clock -name tck -period 100 [get_pins bse2_inst/TCK]`
   then `set_clock_groups -asynchronous -group tck -group [all other clocks]`.
   That also clears most of the **924 unconstrained internal endpoints** (nearly
   all in `core/jtag_tap/` and `core/sync_request_to_dm/`).
2. **37 ports with no input delay + 37 with no output delay** (`gpio_4/7/8/14-31`,
   `io7-io20_cell`, `spi0_*`, `uart0_SIN/SOUT`, `sys_rst`, `ddr3_reset_n`).
   UART/GPIO/`sys_rst` are genuinely async → `set_false_path`. SPI is the one
   that actually matters for the camera; give it real `set_input_delay`/
   `set_output_delay` against the SPI clock.
3. For the 12 remaining CDC endpoints, confirm the AXI clock-converter IP's own
   `.xdc` is being read (check `report_cdc`), or add
   `set_max_delay -datapath_only` across the crossing.

None of this touches the KCF IP or the register map.

---

## 7. LUT reduction — **DONE + re-synth CONFIRMED** (2026-07-26)

**Diagnosis (settled, from `core_syn_area.txt`).** All 5,376 LUTRAM was at
`kcf_top`'s *own* hierarchy level — its ten 4096×16 buffers (`patch_buf,
alpha_re/im, x_hat_re/im, y_hat_re/im, mul_re/im, resp_map`). The same report
line shows **12 RAMB36** there. A 4096×16 array costs 2 RAMB36, so 12 RAMB36 =
exactly **six** arrays in BRAM and **four** in distributed RAM, at
5376 / 4 = **1,344 LUTRAM each**. That arithmetic is what pinned the split down;
the earlier guess of "~4 spill" was right but unquantified.

The four spillers were never identified individually (no Vivado log for the
current netlist exists locally — `KCF_Implementation.runs/synth_1/runme.log` is
from the old `fft1d_32` design and is useless here). Structurally the ten arrays
were *not* uniform: `patch_buf` and `resp_map` each sat alone in an always block,
while `alpha`, `x_hat`, `y_hat` and `mul` were **two arrays sharing one always
block**. 6/4 decomposes cleanly as `patch_buf + resp_map + two pairs` in BRAM
with **two of the four pairs** spilling.

**Fix applied — `src/bram_sdp.sv` (new).** Rather than keep guessing which two
pairs Vivado choked on, all ten arrays were moved into `bram_sdp`, a module whose
entire body is the canonical UG901 simple-dual-port template. Inference no longer
has to succeed inside a large FSM (fanned-out address counters, FSM-decoded write
enables, paired arrays), so it is deterministic for all ten. Cost: +8 RAMB36
(58 → 66 of 135 available — ample).

`bram_sdp` reproduces the **read-first** collision behaviour and the 1-cycle
registered read latency exactly, which is what makes the swap bit-exact. It is
plain inferred Verilog, **not** `xpm_memory_sdpram` — XPM would have forced BRAM
too, but iverilog cannot elaborate it, and that would have destroyed the local
`tb_kcf_top` verification loop this project depends on.

**Verification (all with Icarus 12.0):** `tb_kcf_top`, `tb_ball_demo` and
`tb_image_ip_axilite` produce **byte-identical stdout** before vs after (diffed,
not eyeballed) and still pass — e.g. `tb_kcf_top` peak=(63,0) val=218,
raw_peak=458 mean|resp|=48; texture raw_peak=361 mean=77 conf=0. The other eight
testbenches still compile. No AXI/register-map change.

**NEXT ACTION — collaborator:** re-synthesise and report LUT / LUTRAM / RAMB36.
Expect LUTRAM 5,376 → **0**, total ~59,131 → ~53,755 LUTs (**~93% → ~85%**),
RAMB36 58 → 66. Setup timing should be unaffected or slightly better (BRAM reads
are faster than a 4096-deep LUTRAM mux); confirm WNS is still positive.

**If more headroom is still needed** (two further cuts scoped but NOT implemented,
deliberately held back so the re-synth measures one change at a time):
1. **Drop `resp_map` entirely** — have `peak_finder` read the shared `u_fft`
   output directly during `S_D_PKWAIT` instead of copying the IFFT result into a
   private buffer. Saves one 4096×16 buffer (2 RAMB36). Read latency already
   matches (both are 1-cycle registered), so this is the low-risk one.
2. **Drop `mul_re/mul_im`** — write `conj(alpha)·X_hat` back into `u_fft` at
   `cnt_d` while reading it at `cnt` (the write trails the read by one element,
   so it only overwrites already-consumed locations). Saves two buffers
   (4 RAMB36) but couples tightly to `fft2d_64` internals — higher risk.
3. Smaller: `u_fft`/`u_fft1d`/`u_bfly` logic (~14k LUTs combined) — but that is
   on the closed timing path, touch only with care.

---

## 8. NCC normalizer bug — root cause + fix (2026-07-26, `31cfac6`)

**This is the cause of the edge-lock, and the reason the BORDER margin didn't
help.** It was never a threshold-tuning problem.

`ncc_search` scored candidate windows with

```
score = cross² / Σf²            ← RAW energy   (S_CMP: cand_cross_sq * best_ef)
```

but *reported* confidence as

```
conf  = cross² / max(Σ(f−f̄)², FLOOR) · Et    ← ZERO-MEAN energy
```

Two different normalizers, so **the value at `0x1C` was never the score that
won the argmax.** The old comment claimed this "changes only the confidence
scale, not which window wins" — that is exactly backwards; it changes *which
window wins* and nothing else.

Why raw `Σf²` is wrong: the template is zero-mean, so
`cross = Σf·(t−t̄) ≡ Σ(f−f̄)(t−t̄)` — the window DC **already cancels in the
numerator**. Leaving DC in the denominator makes the metric
`≈ correlation × (σ_f / rms_f)`, i.e. a pure **brightness bias**: it is
maximized by the *darkest* window in range, independent of shape. With lens
vignetting the darkest window is the bottom-right corner — which is precisely
where 126/214 blank frames locked. `BORDER` couldn't fix it because the bias is
global; the margin just moved the lock one grid step inward.

**Second defect, same block:** `EF_ZM_FLOOR = 4096` = 256 px × σ²=16, i.e.
**σ = 4 — the OV5642's own noise floor.** The floor exists to stop noise
correlating perfectly, but setting it *at* the noise level does nothing: a blank
sheet still read conf 120–208. Raised to `36864` (σ=12) and exposed as a
parameter for HW tuning.

**Fix:** both selection and reporting now use `Σ(f−f̄)²` (floored). The argmax
is a genuine correlation coefficient and `0x1C` reports the winning window's own
score. Net logic change is neutral — `best_ef`/`best_fsum`/`cand_ef`/`cand_fsum`
collapse into one `best_ef_zm`/`cand_ef_zm` pair; the compare multiplies widen
72→73 bits and one 17×17 moves into the spare `S_SQ` state (off the compare
path, so no new timing pressure).

**Verified (Icarus 12.0), baseline-vs-fixed stdout diffed, not eyeballed:**
`tb_ball_demo` and `tb_kcf_top` **byte-identical**; `tb_image_ip_axilite`
identical except the **blank**-frame re-acquisition confidence `2 → 0`. Exactly
the intended signature: target-present behaviour untouched, blank suppressed.

## 8b. KCF conf ≡ 0 — training deadlock (2026-07-26, `53d4428`)

**The KCF filter could only ever be trained by the BOOT designation.**

At runtime, the only path in `track_ctrl` reaching `S_KCF_UPD` (the filter
update) required `kcf_peak_val >= kcf_thresh` — but a filter cannot produce that
confidence until it has been trained on the target's actual appearance:

```
conf 0 → loss branch → update SKIPPED → alpha stays frozen → conf 0 → …
```

So `alpha` stayed pinned to whatever the boot designation produced and never
adapted for the whole run. Hence no runtime learning at all.

> **CORRECTION.** An earlier revision of this file called `target_frame.mem`
> a "synthetic smiley". It is **not** synthetic — `scripts/build_target.py`
> sources the **real photo** `New_training_target.jpeg`, segments the ball and
> composites it at 60 px on a neutral background. The designation target was
> always a genuine picture of the actual ball. That makes §8d the important
> half of the story: pre-training was real, but the *threshold* was set above
> what that target can produce. The rigid *3 KCF frames then fall back* pattern in both logs is the
direct signature of the loss branch being taken every single frame
(`LOSS_FRAMES=3`), which also proves the collaborator has `KCF_THRESH > 0`.

**Why the "dark corner" theory was wrong:** KCF was handed good interior NCC
locks (conf 180–231) many times in the ball log and still returned 0, with
sensible ±2 px displacements. It was opening the patch in the *right place* and
correlating against the *wrong appearance*. Position was fine; the filter was stale.

**Fix (`53d4428`):** an NCC acquisition is a **re-designation**. The first KCF
frame after one now mirrors the boot path (`S_TI_DET → S_TI_UPD`): discard the
detection displacement (it came from a filter trained on something else) and
**train on the freshly acquired, NCC-centred patch**. That frame reports the NCC
position/confidence instead of a stale-filter displacement.

**This is only safe BECAUSE of §8.** It trains on whatever NCC acquired, so it
depends on NCC not false-positiving — exactly the risk the old
"skip update on loss frames" comment was guarding against. `THRESH` +
`ACQ_FRAMES` are the gate. **Retune `THRESH` on hardware before trusting it.**

Verified (Icarus 12.0): `tb_ball_demo`/`tb_kcf_top` byte-identical;
`tb_image_ip_axilite` acquisition frame `ABS (130,152) → (128,152)` — now the
**exact** ball centre — `conf 115 → 256`, frame 2 `conf 69 → 67`, loss detection
still drops tracking after 3 blank frames, ALL TESTS PASSED.

---

## 8d. KCF `CONF_K=5` was above the achievable ratio (2026-07-26, `5d1a949`)

The second, **independent** cause of conf ≡ 0. Even with §8b fixed — filter
correctly trained on the real target, perfectly centred, exact scale — the
threshold was unreachable.

Modelled the exact RTL detect pipeline in numpy (Hann·patch → FFT →
conj(α)·X̂ → IFFT) using the **baked** `hann_64.mem` / `gauss_label_64.mem`
ROMs and `lambda = 3/256`, on the real ball photo:

| condition | peak/mean\|resp\| |
|---|---|
| ideal — train == detect, exact scale and centring | **4.0 – 6.9** |
| realistic — scale ±15%, centring ±4 px | **1.6 – 4.5** |

across **every** training diameter from 40 to 76 px, and insensitive to
`lambda` (0.004–1.0) and to background level (140–230). `CONF_K = 5` requires
peak/mean > 5 for confidence to be non-zero, so `max(0, peak − 5·mean)` read
**0 essentially always**. No designation image and no ball diameter fixes this.

`tb_kcf_top`'s 9.5 comes from a **synthetic high-contrast patch**, not the real
target — which is exactly why simulation never exposed it.

**Fix:** report the ratio itself instead of a zero-clamped difference:

```
conf = min(CONF_MAX, (peak << CONF_SHIFT) / max(mean|resp|, 1))
```

`CONF_SHIFT = 5` → 32 counts per 1.0 of ratio (old `CONF_K=5` point ≡ 160).
One 16-cycle restoring divide per detect (~4.9 ms frame). `peak_val` commits on
the final divide cycle, one cycle before `detect_done`, preserving the existing
handshake. FSM widened 4 → 5 bits for `S_D_PKDIV`.

**`KCF_THRESH` (0x34) IS RESCALED — firmware must retune.** Unavoidable:
confidence was identically 0, so every `KCF_THRESH > 0` behaved identically and
a retune was needed regardless.

Measured in sim after the fix (divider verified bit-exact by hand):

| case | peak/mean | conf |
|---|---|---|
| `tb_kcf_top` match | 458/48 = 9.54 | **305** |
| `tb_kcf_top` non-target texture | 361/77 = 4.69 | **150** |
| `tb_image_ip_axilite` tracked ball | 7.7 | **245** |
| `tb_image_ip_axilite` blank crop | 4.4 | **142** |

Roughly a 2× separation between locked and lost. `KCF_THRESH = 192` (ratio 6.0)
sits cleanly between and is the value now used in `tb_image_ip_axilite`;
**start there on hardware.**

### On the designation target itself

`build_target.py --sweep` and the KCF model agree that ball diameter is a weak
lever — NCC margin is 0.20–0.27 across 44–140 px, and the KCF ratio has no
reliable trend. A 48 px ball (8 px Hann margin) is **not** an improvement:
it scored worst in the model (ideal 4.8, realistic-avg 2.1) versus 60 px
(5.8 / 3.4) and 68 px (6.3 / 4.5). The 2-D Hann retains 95.9% of a 48 px ball
versus 100% of a 60 px one, but the larger ball simply carries more structure
through the effective window. **Keep the current 60 px** unless hardware says
otherwise; if you do experiment, 68 px is the one worth trying.

---

## 8e. NEXT ACTIONS (in this order — one change measured at a time)

1. Re-vendor + rebuild, re-run the **same A/B capture pair**. Expect: blank
   NCC conf collapses from ~139 toward single digits, the `(280,192)` corner
   lock disappears, **and KCF conf becomes non-zero on real locks.**
2. **Then** re-read `THRESH` (0x08). The old numbers are meaningless post-fix;
   set it between the new blank ceiling and the new ball floor. Do this before
   trusting §8b, which trains on whatever NCC acquires.
3. **Then set `KCF_THRESH` (0x34) = 192** to start — it is now a ratio in 1/32
   units (§8d), NOT the old scale, so the firmware's existing value is wrong.
   Refine from measured `0x1C` on a held target vs. an empty scene; expect
   roughly 245-305 locked and 98-150 lost.
4. Ball diameter is a weak lever and 48 px is worse than the current 60 px
   (§8d) — do not spend time there unless 1-3 are exhausted.

Requested from the collaborator (better than the current pair): one capture
purely **without** the ball, and one with the ball present **from frame 1**,
moved in a **cross pattern starting from centre**. The cross gives a known
ground-truth trajectory to score tracking error against, which neither current
log allows.

---

## 9. Gotchas / lessons

- **If you compute a score two ways, the argmax and the reported number must use
  the SAME formula.** `ncc_search` selected on `cross²/Σf²` and reported
  `cross²/Σ(f−f̄)²` for months; the reported confidence was never the score that
  won, so every attempt to fix the edge-lock by tuning `THRESH`/`BORDER` was
  tuning the wrong quantity. A comment even asserted the mismatch was harmless.
  When a metric is normalized, **check what cancels in the numerator** — the
  zero-mean template already removed the window DC, so leaving DC in the
  denominator was a pure brightness bias, not a scale choice.
- **A noise floor set AT the noise level does nothing.** `EF_ZM_FLOOR` was
  256·σ² with σ=4, which is the OV5642's own read noise. Floors must sit well
  above what they are meant to reject (now σ=12).
- **Capture the negative control.** The blank-sheet log is what made the bug
  provable: 126/214 frames on *one* pixel-exact window, only 14 distinct
  positions in 214 frames. A tracking log alone always looks plausible — the
  scene moves, so the output moves. Pair every capture with a target-absent run.
- **Never variable-part-select a registered memory read** → distributed-RAM blowup.
- **Registered addr + registered BRAM data = 2-cycle read latency** — match wait states.
- **`(* ram_style = "block" *)` is a hint, not a guarantee.** Vivado 2018.3
  silently ignored it for 4 of 10 identically-attributed arrays. If an array
  must be BRAM, put it in its own tiny module holding nothing but the canonical
  SDP template (`src/bram_sdp.sv`) — inference is reliable there and unreliable
  inside a big FSM. Prefer that over `xpm_memory_sdpram`, which forces BRAM but
  cannot be elaborated by iverilog and so breaks the local sim loop.
- **Read a utilisation report arithmetically.** RAMB36 count ÷ 2-per-4096×16
  array told us exactly how many arrays inferred (6) vs spilled (4), and
  LUTRAM ÷ spillers gave the 1,344-LUT unit cost — no Vivado log needed.
- **Baseline before refactoring, then `diff` the sim stdout.** "Tests still
  pass" is weaker than "output is byte-identical"; the latter is what proves
  a memory-inference refactor didn't perturb the arithmetic.
- iverilog rejects `'{…}` localparam arrays, SV `int`, `void'()` cast → use
  `$readmemh` ROMs and `if($value$plusargs)`.
- Decoder `error`/`done` are 1-cycle pulses; wrapper latches sticky `jpeg_error`.
- **NO AXI/register-map changes** (user's hard constraint). Internal compute/logic only.
- **Keep the Infracore `gc2025` monorepo up to date** — see §1. A fix that
  lands only in the IP repo is invisible to the collaborator. Re-vendor and
  push it as part of the same task, not as a follow-up.
- Always `git pull` before push (collaborator active on all repos); exclude the
  generated test-vector `.mem` from the vendored `kcf/` dir.
- Test balls in `tb_ball_demo`/`tb_image_ip_axilite` are interior → unaffected by
  the NCC border margin.

Assistant memory files with the same facts:
`kcf-confidence-and-idct-timing.md`, `hw-tracking-debug.md`,
`ncc-target-training.md`, `jpeg-revendor-and-icd-gap.md`, `fft-timing-fix.md`.

---

## 10. NCC rebuild for the final-demo jet (2026-07-28)

### 10a. Two defects found

1. **The packed bank could overflow 9-bit signed.** `build_bank` rescaled once
   so the peak fit, but `force_zero_mean` nudges individual entries *after* the
   rescale and can push one back to +256 — which wraps to −256 in the 9-bit
   field and silently destroys the `Σ(t) == 0` identity that makes confidence a
   true percentage. `tb_tmpl_bank.mem` was shipping a member decoding to
   −256..43 with **sum −512**, and *both* ball testbenches still passed because
   the other two members carried the match. Now iterated to fit and asserted
   (range **and** zero sum) before writing.

2. **`tb_ncc_scales` was specified against a threshold nothing runs.** It set
   `THRESH_PCT = 60` while firmware ran 25 (now 30), so its "a bright distractor
   must not acquire" check never tested the shipped operating point — the
   shipped bank scores **49** on that scene, far above 25. The check passed for
   years while the property it claimed was false.
   Normalized correlation is **contrast-invariant**, so a bare bright disc
   scores like a target at *any* usable threshold; no threshold can reject it.
   The property that actually protects a demo is that a real target *out-ranks*
   it. The testbench now runs at the shipped THRESH, ranks the distractor
   against a real target, and adds `scale_both.mem` (target + disc in one frame)
   which must lock the **target**.

### 10b. What was rejected, and why — each measured, not assumed

| tried | result |
|---|---|
| lower `EF_ZM_MIN` (20k…150k) | looked like +8 points until the controls were validated — the first negative set **accidentally clipped the object**, so cloth scored 0. With real cloth a lower gate admits fold texture and forces THRESH up further than it gains. **Stays 150000.** |
| Tikhonov divisor `(ef_zm + λ)` instead of the hard gate | +0.5 points. Not worth an RTL change. |
| 4, 5, 6 bank members | +0.4 points for double the multipliers. |
| relative-brightness gate (window mean − frame mean) | targets p5 = 3, cloth p95 = 15. No separation — the object is too small a fraction of a 16×16 window to lift its mean. |
| clutter-whitened template (`target − α·blob`) | disc 31 → 27 while costing accuracy and negative margin. |
| fully rotation-averaged profile | +1.7 points accuracy, but the disc distractor rises to **76 %**, which would let a hand acquire. Rejected on that. |

The accuracy ceiling is set by the contrast gate refusing dim/small targets, and
that is a genuine information limit here, not a tuning miss: cloth folds and a
dim target overlap in every scalar the hardware computes.

### 10c. Lessons

- **A negative control that clips the target is not a negative control.** Two
  separate conclusions in this session reversed once the controls were validated
  against the segmentation mask. Validate the control, not just the experiment.
- **When a metric is invariant to something, no threshold on it can reject that
  something.** r² is contrast-invariant, so "reject the bright disc with a
  threshold" was never achievable — only ranking is.
- **A testbench constant that does not match what firmware writes tests nothing.**
  Same class as the Q8.8/percent contract bug in §8d; check the two agree.
- The model over-predicts *target* confidence by ~25 points (documented in
  `kcf_ip.h`) but predicts the *background ceiling* exactly (8, matching the
  hardware capture). Trust it for the floor, not the ceiling.
