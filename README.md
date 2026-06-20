# Aleph-1 · Fullscreen Black Hole (BlackHoleScreenWarp-Aleph1)

A macOS fullscreen Aleph-1 visual effects overlay — a real-time Schwarzschild black hole renderer that replaces the event horizon with a blue-white eye-shaped black hole in the style of Aleph-1 from *Wuthering Waves*, warping the live desktop in real time, with layered flow streams, filaments, particles, viscous slime, and edge dispersion effects flowing downward from the center.

> **⚠️ Health Warning**  
> Although we all know Aleph-1 is adorable, please do not stare at it for extended periods. The silver-white accretion disk and other components have high sharpness and brightness that can easily cause eye strain and damage.  
> **Photosensitive Epilepsy Warning**: This program contains rapidly changing brightness, high-contrast flashing patterns, and dynamic visual effects that may trigger photosensitive epileptic seizures. If you or a family member have a history of epilepsy, please consult a doctor before running this software. If you experience dizziness, blurred vision, muscle twitching, confusion, or any other discomfort during use, stop immediately and rest with your eyes closed.

## Principles

Based on Eric Bruneton's high-quality real-time Schwarzschild black hole rendering method, this project numerically integrates photon geodesic equations in a Metal fragment shader to compute gravitational lensing, photon rings, and accretion disk radiation in real time.

The core shader is ported from [ghostty-blackhole](https://github.com/s0xDk/ghostty-blackhole), adapted from a Ghostty terminal custom shader into a macOS fullscreen Metal overlay.

This fork additionally references the *Wuthering Waves* Wiki description of Aleph-1: its appearance resembles a black hole with a downward-flowing blue iris at the center and a white accretion disk. The shader preserves the black hole lensing framework while replacing the final compositing layers with a blue-white eye-shaped iris, silver-blue-purple accretion disk, clock-scale photon ring, star field, and a downward-flowing non-Newtonian slime column.

## Visual Layers

| Layer | Name | Description |
|-------|------|-------------|
| L1 | Aleph-1 Iris | Black pupil (with irregular cracked edges) + electric blue iris radial fibers + upper orange-red cloud streaks/cracks + mushroom-cloud blue-white burst crown + non-Newtonian bifurcated viscous drip + eyeball texture (iris_plume_mask) |
| L2 | Cold Accretion Disk | Keplerian thin disk, silver-white → blue-purple spectrum, with Doppler beaming, purple routing paths, sparse outer perturbation arms |
| L3 | Photon Ring Ticks | Flattened elliptical clock-scale ticks (cool white-blue), stronger in lower half |
| L4 | Star Field | Randomly generated lensed star field + cosmic background streamlines |

## Dependencies

- macOS 13+
- Xcode Command Line Tools (provides Swift and Metal compilers)
- Screen Recording permission — required for desktop screenshot capture as background texture

## Build

```bash
cd BlackHoleScreenWarp-Aleph1
swift build
```

## Usage

```bash
# Demo mode: show black hole immediately, exit after N seconds
.build/debug/BlackHoleScreenWarp --demo --duration 16

# Manual mode: type 'start' in terminal to trigger; type 'exit' for exit animation
.build/debug/BlackHoleScreenWarp --manual

# Work-interval trigger: black hole appears after N minutes
.build/debug/BlackHoleScreenWarp --delay-min 55

# Self-capture mode: auto-save render snapshots at specified times
.build/debug/BlackHoleScreenWarp --demo --duration 24 \
  --capture-dir ./verification/capture \
  --capture-times 7.2,11,16,22

# Show help
.build/debug/BlackHoleScreenWarp --help
```

## Keyboard Controls

| Key | Action |
|-----|--------|
| `Esc` | Force-trigger exit collapse animation, then quit |

In `--manual` mode, the overlay does not steal keyboard focus or intercept mouse events. The reliable control method is via terminal: type `start` + Enter to trigger, type `exit` + Enter to play the exit animation and quit.

## Trigger and Exit Conditions

| Mode | Trigger | Exit |
|------|---------|------|
| `--demo` | Immediate on launch | Auto-exit after `--duration N` seconds; or press `Esc` |
| `--delay-min N` | After N minutes of runtime | Press `Esc` for forced exit animation; or auto-exit with `--duration` |
| `--manual` | Type `start` in terminal | Type `exit` or press `Esc`; quit directly if not yet triggered |

## CLI Arguments

| Argument | Description |
|----------|-------------|
| `--demo` | Immediately start the black hole effect demo |
| `--manual` | Launch and wait for manual trigger |
| `--delay-min <N>` | Black hole appears after N minutes of runtime |
| `--duration <N>` | Auto-exit after N seconds |
| `--capture-dir <path>` | Output directory for self-capture frames |
| `--capture-times <t1,t2,...>` | Comma-separated capture timestamps in seconds |
| `--help, -h` | Show help |

## Animation Timeline

| Time | Event |
|------|-------|
| 0s | Accretion disk, black eyelid, and eyeball texture begin fading in together |
| ~2.5s | Non-Newtonian slime begins flowing from the eyeball's lower edge |
| ~3.5s | Slime begins continuous downward stretching |
| ~5.5s | Black hole fully formed; eyeball texture approaches full opacity |
| ~16s | Slime stretch reaches maximum length |

## Project Structure

```
BlackHoleScreenWarp-Aleph1/
├── Package.swift              # Swift Package Manager config
├── README.md                  # Chinese README (中文)
├── README_EN.md               # This file (English)
├── Assets/
│   └── aleph/
│       ├── iris_plume_mask.png   # Eye iris/mushroom-cloud texture (512×512 RGBA)
│       └── slime_mask.png        # Slime shape texture (256×512 RGBA)
├── Sources/
│   ├── main.swift                # Entry point + CLI argument parsing
│   ├── BlackHoleWindow.swift     # Fullscreen transparent overlay window
│   └── BlackHoleRenderer.swift   # Metal renderer + embedded MSL shader (~1600 lines)
└── verification/                 # Iterative verification screenshots & backups
```

## Notes

- This is a prototype demo. It does not install LaunchAgents, add login items, or auto-reside in the background.
- It does not move, delete, or modify any real files.
- It does not upload screen content or call any remote APIs.
- Screen Recording permission is required to capture desktop content; otherwise a black screen is shown.

## References & License

- [ghostty-blackhole](https://github.com/s0xDk/ghostty-blackhole) — Original Schwarzschild shader
- [Eric Bruneton's black hole shader](https://ebruneton.github.io/black_hole_shader/) — Theoretical foundation
- [black-hole (WebGL)](https://github.com/oseiskar/black-hole) — WebGL Schwarzschild geodesic simulation
- [Aleph-1 | Wuthering Waves Wiki](https://wutheringwaves.fandom.com/wiki/Aleph-1) — Aleph-1 appearance reference
- [NASA SVS Black Hole Accretion Disk](https://svs.gsfc.nasa.gov/13326/) — Accretion disk visualization reference

This project follows the license terms of the original ghostty-blackhole.

---

*Aleph-1 character design and *Wuthering Waves* intellectual property belong to Kuro Games. This project is a non-commercial fan work created for educational and technical research purposes only.*
