# ATmega32 Assembly Controller

**Additional submission files and evidence:** see [Drive submission and evidence](docs/drive-evidence.md) for the separately preserved Drive circuit/report snapshot and available recordings or captures.

An AVR assembly project exploring LCD interfacing, interrupt-driven inputs, stepper control, environmental sensing and later pressure/status-display work on the **ATmega32**. It was developed in Microchip/Atmel Studio with Proteus circuit models.

The original exercise uses a fictional game-themed repulsion-cannon interface, represented with an LED, a stepper motor, an energy counter and display peripherals. This repository collects its firmware revisions and documents their differences.

## Firmware revisions

| Folder | Contents and intended role |
| --- | --- |
| `firmware/boot-display/` | LCD initialization and the `ALTERRA OS BOOTING...` startup message |
| `firmware/basic-operation/` | Button interrupts, single/auto modes, energy state, LED and stepper operation |
| `firmware/combined-controller/` | Combined development revision with sensor-related code; contains the project's `main.asm` plus a separate `LEVE0+1.asm` draft |
| `firmware/reference-environment-sensing/` | Version from the original `EXAMPLE LEVEL2` folder, containing temperature/distance routines; retained as a reference revision, with its authorship/provenance unconfirmed |
| `firmware/pressure-display-draft/` | Later draft with sensor handling, reload logic, MCP3008-related pin definitions and multiple display-page routines |

The presence of a peripheral definition or routine does not establish that the complete feature works. These revisions are preserved snapshots, not a sequence of verified releases.

Internal Studio solution/project filenames and relative relationships are retained. In the combined revision, the project file selects `main.asm`; the separate `LEVE0+1.asm` file is not its configured build entry point.

## Circuits and documentation

| File | Original file and relationship |
| --- | --- |
| [Boot-display circuit](proteus/boot-display.pdsprj) | `Level_0.pdsprj`; originally references `Level_0.hex` |
| [Basic-operation circuit](proteus/basic-operation.pdsprj) | `Level_1.pdsprj`; originally references `LEVEL_1.hex` |
| [Later controller circuit](proteus/pressure-display-draft.pdsprj) | Originally named `Level_0+1.pdsprj`, but its stored firmware path points to **`Level3.hex`** |
| [Design report](docs/embedded-design-report.docx) | Original assembly/peripheral notes and development observations |

The source, project files, circuits and report contents are unchanged. Circuit files were renamed for clarity. Automatic backups, local workspace files, locally generated build folders and unrelated personal notes are excluded. The historical firmware binary explicitly supplied in Drive is preserved separately under `submissions/google-drive/`.

## Concepts explored

- ATmega32 register-level programming with `M32DEF.INC`.
- Stack initialization, GPIO direction and input pull-ups.
- LCD command/data transfers and number-to-text conversion.
- External interrupts, operation modes and stepper sequencing.
- HC-SR04 distance and DS18B20 temperature sensing in later revisions.
- Later attempts at pressure monitoring and rotating status pages.

LCD modes, pin mappings and scheduling approaches vary between revisions. Inspect the selected source and circuit together before using their wiring or timing assumptions.

## Build and open in Proteus

1. Open the selected revision's `.atsln` solution in Microchip/Atmel Studio.
2. Confirm that its device is ATmega32 and that the AVR assembler/device definitions provide `M32DEF.INC`.
3. Build the selected project's `main.asm`, resolving any assembler diagnostics before using its generated firmware.
4. Open the matching Proteus circuit and set the MCU's **Program File** to the newly built HEX file. The saved references include old local paths and will not follow the reorganized folders automatically.
5. Check the MCU clock and all peripheral connections against that revision's source. Assembly delay routines depend on the clock.
6. Verify startup, buttons, mode changes and stepper behavior first, then test each available sensor/display feature separately.

No matching Proteus circuits were separately identified for every source revision. The later circuit's misleading original filename is called out above so it is not mistaken for the basic combined revision.

## Verification and limitations

- Prepared source copies were compared with their originals using SHA-256 hashes.
- All three Proteus project archives passed internal ZIP integrity checks.
- An attempt to start the installed AVR assembler failed before assembly with a Windows DLL-relocation error. **No fresh successful build is claimed.**
- No fresh Proteus simulation or hardware test was performed during repository preparation.
- Advanced revisions remain development drafts. Full sensing, pressure-stabilization, communication and timing behavior are not established by this archive.

Microchip/Atmel Studio, Proteus and vendor device/component libraries are not distributed here.
