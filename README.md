# ECE499-Akhil-Sriram-Major-Project
# RTL Design of a KCF Visual Tracker
---

## Overview

This repository contains a comprehensive Register Transfer Level (RTL) design for the Kernelized Correlation Filter (KCF) visual tracking algorithm. Designed to operate as a standalone IP core, this project offloads the computationally heavy pipeline of visual tracking from a general-purpose processor to dedicated FPGA logic, achieving high-speed, low-latency target tracking.

### Project Team

- **Akhil Sriram** 

**Institution:** Shiv Nadar Institution of Eminence  
**Project Type:** B.Tech Minor Project  
**Mentor:** Dr. Venkatnarayan Hariharan

---

## KCF Tracking Core
* Translates spatial pixel data to the frequency domain using a 2D-Fast Fourier Transform (2D-FFT)
* Implements the "Kernel Trick" (e.g., Gaussian kernel) for high-dimensional feature mapping and target separation
* Performs element-wise complex multiplication to calculate the correlation filter response
* Utilizes an Inverse FFT (IFFT) and Peak Detection logic to extract spatial X/Y target coordinates
* High-level mathematical pipeline developed in Verilog

## AXI Interfacing & Hardware Integration
* Manages control signals (Start, Busy, Done) via a custom AXI4-Lite wrapper
* Designed to handle high-bandwidth, continuous pixel data flow using AXI4-Stream
* Capable of fixed-point arithmetic to optimize Look-Up Table (LUT) consumption
* Written in synthesizable Verilog, targeted and validated on the Artix-7 (Nexys A7) FPGA

---

## Repository Structure

```
## Repository Structure
ECE499-Akhil-Sriram-Major-Project/
├── src/                     # RTL source files (Verilog) for KCF IP and AXI wrappers
├── tb/                      # Testbenches for IP blocks and AXI bus simulation
├── data/                    # Memory initialization files (.mem) for test images
├── docs/                    # Block diagrams, timing analysis, and synthesis reports
└── README.md                # This file
```

---

## Prerequisites

- Xilinx Vivado Design Suite

- Verilog-2001 standard support

- Digilent Nexys A7 (Artix-7) FPGA board (for hardware deployment)

---

## Installation

Clone the repository:
```bash
git clone https://github.com/KalravMathur/BTP-Cache-Controller-MMU.git
cd BTP-Cache-Controller-MMU
```

---

## How to Simulate

Compile and run the simulation using Synopsys VCS:

```bash
# Open the project in Vivado GUI or run in batch mode
# In the Vivado Tcl Console, launch the behavioral simulation:
launch_simulation

# Alternatively, to run a specific testbench file from the command line (if using xsim):
xvlog -sv src/*.v tb/tb_axi_system.v
xelab -debug typical -top tb_axi_system -snapshot tb_snap
xsim tb_snap -gui
```

---

## Design Specifications

### KCF Algorithm Specifications
| Parameter | Value |
|-----------|-------|
| **Tracking Algorithm** | Kernelized Correlation Filter (KCF) |
| **Operational Domain** | Frequency Domain (via FFT/IFFT) |
| **Filter Update Strategy** | Learning-rate based adaptation |
| **Math Implementation** | Fixed-Point Arithmetic |

### Interface & Hardware Specifications
| Parameter | Value |
|-----------|-------|
| **Control Interface** | AXI4-Lite (32-bit Address/Data) |
| **Data Interface** | AXI4-Stream |
| **Target Hardware** | Xilinx Artix-7 (Nexys A7) |
| **Implementation Language** | Verilog |

---

## License

This project is licensed under **Shiv Nadar University License** as specified in the source files.

---
