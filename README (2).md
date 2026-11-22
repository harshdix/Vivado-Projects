# Real-Time Object Detection & Tracking on Nexys 4 DDR

A real-time object detection and tracking system on the **Digilent Nexys 4 DDR** (Xilinx Artix-7 XC7A100T-1CSG324). A USB camera feeds a host PC, which streams grayscale frames to the FPGA over UART. The FPGA does background subtraction, foreground detection and centroid calculation **entirely in hardware** (no soft processor, no OS) and shows the result on a VGA monitor with a green tracking cross.

> B.Tech project, Department of Electronics and Communication Engineering, The LNM Institute of Information Technology, Jaipur (April 2026).
> Guide: Dr. Kusum Lata

## Team

| Name | Contribution |
|------|--------------|
| Harsh Dixit | UART receiver, frame receiver, XDC constraints, Python streamer |
| Devansh Gupta | Frame buffer, background subtractor, centroid calculator |
| Akshat Singh | Top-level, VGA controller, clocking wizard |

## How it works

```
Logitech Brio 105 -> OpenCV (PC) -> 128x96 grayscale -> UART ~3 Mbaud
   -> uart_rx -> frame_receiver -> frame_buffer_dp (current + background BRAM)
   -> bg_subtractor (|curr - bg| > threshold) -> centroid_calc (cx, cy)
   -> vga_controller (640x480 @ 60 Hz, green cross overlay) -> VGA monitor
```

- **PC side:** captures frames, resizes to 128 x 96, converts to grayscale, clamps pixels to 0..252 (0xFD/0xFE/0xFF are sync bytes), applies a Gaussian blur, then streams frames with a 3-byte sync marker.
- **FPGA side:** receives frames into BRAM, subtracts a user-captured background, accumulates spatial moments and divides them with a sequential binary divider to get the centroid.
- **Display:** each camera pixel is upscaled 5 x 5 to fill a 640 x 480 VGA frame.

## Key specs

| Item | Value |
|------|-------|
| Camera resolution | 128 x 96 grayscale |
| UART | 100 MHz clock / 33 clocks per bit, about 3 Mbaud |
| Streaming rate | about 24 FPS |
| VGA output | 640 x 480 @ 60 Hz (25 MHz pixel clock from the Clocking Wizard) |
| Detection threshold | 10 to 160, set live with SW[3:0] |
| Minimum object size | 200 foreground pixels (`MIN_PIX`) |
| Resource use (placed design) | 6,208 LUTs, 683 registers, 4 BRAM tiles, 1 MMCM |

## Repository structure

This matches the Vivado project's own folder layout.

```
object-detection-tracking/
├── README.md
├── .gitignore
├── sources_1/
│   ├── new/
│   │   ├── top.v               top level (clocking, button debounce, threshold, cross overlay, LEDs)
│   │   ├── uart_rx.v
│   │   ├── frame_receiver.v
│   │   ├── frame_buffer_dp.v
│   │   ├── bg_subtractor.v
│   │   ├── centroid_calc.v
│   │   └── vga_controller.v
│   └── ip/
│       └── clk_wiz_0/
│           └── clk_wiz_0.xci   Clocking Wizard IP (100 MHz in, 25 MHz out)
├── sim_1/
│   └── new/
│       ├── tb_uart_rx.v
│       ├── tb_frame_receiver.v
│       ├── tb_frame_buffer_dp.v
│       ├── tb_bg_subtractor.v
│       ├── tb_centroid_calc.v
│       ├── tb_vga_controller.v
│       └── tb_top.v            7 integration tests
├── constrs_1/
│   └── new/
│       └── top.xdc             Nexys 4 DDR pin constraints
├── python/
│   └── pc_streamer.py          camera capture and UART streaming (add your script here)
└── docs/                       report PDF, photos, screenshots
```

## Requirements

**Hardware**
- Digilent Nexys 4 DDR board
- Logitech Brio 105 (any UVC webcam should work)
- VGA monitor and cable
- Micro-USB cable to the PROG/UART port (power, programming and UART)

**Software**
- **Xilinx / AMD Vivado.** This project was created and built with **Vivado 2025.2**. The newest release listed on AMD's site at the time of writing is **2026.2**; if you open the project in a newer version, Vivado will offer to upgrade the Clocking Wizard IP (click *Upgrade Selected*).
- Python 3.x with `opencv-python`, `pyserial` and `numpy`

```bash
pip install opencv-python pyserial numpy
```

## Build the Vivado project

1. Open Vivado and click **Create Project**, choose **RTL Project**.
2. Choose the part **xc7a100tcsg324-1** (or the board **Nexys 4 DDR**).
3. Add `sources_1/new/*.v` as design sources, and `sources_1/ip/clk_wiz_0/clk_wiz_0.xci` as the clock IP.
4. Add `sim_1/new/*.v` as simulation sources.
5. Add `constrs_1/new/top.xdc` as the constraints file.
6. Set **`top`** as the top module (`sources_1/new/top.v`).
7. If the IP shows as locked or out of date, right-click it in the Sources panel and choose **Upgrade IP**, then **Generate Output Products**.
8. Click **Generate Bitstream**. The file is created at `<project>.runs/impl_1/top.bit`.

## Run the simulations

In Vivado, right-click the testbench you want, choose **Set as Top** (under Simulation Sources), then click **Run Simulation > Run Behavioral Simulation**. Start with `tb_top.v`. It runs 7 integration tests:

1. UART sync LED state machine
2. Background capture
3. Object detection (centroid position check)
4. Green cross visible on VGA
5. VGA outputs zero during sync intervals
6. Dark frame makes the centroid invalid (object leaves the scene)
7. Object movement tracking

The other testbenches check each module on its own (`tb_uart_rx`, `tb_frame_receiver`, `tb_frame_buffer_dp`, `tb_bg_subtractor`, `tb_centroid_calc`, `tb_vga_controller`).

## Run on the board

1. Set all switches DOWN (SW = 0000).
2. Connect the Micro-USB and VGA cables, then power on.
3. Program the bitstream from **Hardware Manager > Open Target > Auto Connect > Program Device**.
4. Set your COM port in `pc_streamer.py`, then run `python python/pc_streamer.py`. LED[0] and LED[2] go solid, which confirms the stream.
5. Slide **SW[1]** up (threshold 30) as a starting point.
6. Point the camera at an empty background and wait about 3 seconds for the exposure to settle.
7. Press and hold **BTNC** for about 2 seconds. LED[1] flashes for about 1.3 seconds, which means the background is captured.
8. Introduce an object. LED[3] lights and the green cross appears on the VGA display.
9. If the cross is unstable, slide the switches up one step. If it disappears while tracking, slide down.

Reset is the **CPU RESET** button (active low).

### Threshold switches (SW[3:0])

| SW[3:0] | Threshold | Use case |
|---------|-----------|----------|
| 0000 | 10 | Very dark, controlled environment |
| 0001 | 20 | Dark indoor |
| 0010 | 30 | Typical indoor, **start here** |
| 0011 | 40 | Moderate ambient variation |
| 0100 | 50 | Bright indoor or near a window |
| 0101 | 60 | High-noise environment |
| 0110 to 1111 | 70 to 160 | Progressively less sensitive |

### LED reference

| LED | Signal | Meaning |
|-----|--------|---------|
| LED[0] | uart_valid | UART stream is live |
| LED[1] | capture_bg | Background captured (flashes about 1.3 s) |
| LED[2] | frame_done | Frames arriving (solid at about 24 FPS) |
| LED[3] | centroid_valid | Object detected and tracked |

## Results

- All 7 integration tests pass in simulation.
- On hardware the cross follows left, right, up and down movement at about 24 FPS.
- Centroid division takes 42 cycles (1.68 µs at 25 MHz).

## Challenges and fixes (summary)

| Problem | Fix |
|---------|-----|
| Camera not usable directly on Artix-7 | PC acts as a bridge: OpenCV capture, then UART streaming |
| `fb_raddr` stuck at 0 | Use a 17-bit constant (`17'd205`) so the product is not truncated |
| `cy` always 127 | Latch `lat_y` / `lat_n` at `frame_end` before they reset |
| Centroid offset | Added a 2-stage pipeline delay for BRAM + subtractor latency |
| Ghost cross at power-up | `bg_valid` gate suppresses the cross until BTNC is pressed |
| Jittery cross | Disabled auto-exposure, Gaussian blur, pixel clamp, live threshold, `MIN_PIX = 200` |
| LEDs too fast to see | Pulse stretchers (84 ms and 1.34 s) |

See the full report in `docs/` for details.

## Future work

- Replace the PC link with an OV7670 camera over PMOD for a standalone system
- Use DDR2 SDRAM as a frame buffer for 320 x 240 or higher
- Morphological filtering (erosion and dilation) on the foreground mask
- Multi-object tracking
- Pipelined divider to cut centroid latency

## References

1. Digilent, *Nexys 4 DDR Reference Manual*
2. Xilinx, *7 Series FPGAs Data Sheet: Overview* (DS180)
3. Xilinx, *Vivado Design Suite User Guide* (UG893)
4. Xilinx, *Clocking Resources in 7 Series FPGAs* (UG472)
5. OpenCV and PySerial documentation
