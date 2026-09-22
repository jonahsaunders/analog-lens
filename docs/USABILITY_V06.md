# Easier everyday work in v0.6

Analog Lens stays inside xschem in IIC-OSIC-TOOLS. Open **Size & verify** from
its menu, use **Size selected…** in the inspector, or press **Ctrl+5** inside the
analysis window. The existing explorer and comparison tabs remain available.

## One sizing workspace

The new tab keeps the selected device, loaded measurements, conditions, targets,
geometry preview and measured verification together. Enter length, gm/Id and gm,
choose **Preview changes**, then **Apply & run testbench**. The preview opens
inline. **Advanced geometry and tolerance** reveals finger/copy controls and the
pass tolerance; blank counts retain the current device's values.

**Apply only** supports edits inside a subcircuit. Save through xschem and use
**Go to parent** to return before rerunning. This action uses xschem's normal
unsaved-change handling. One xschem Undo restores the complete geometry edit.
Inputs, selection and source changes still invalidate a preview.

On narrow windows the two columns stack and scroll. Tab moves through controls
and brings focused controls into view. The wheel scrolls the page; preview and
log text have their own scrolling. Existing Ctrl+1–4 shortcuts keep their meaning.

## Reuse the selected device's conditions

**Use this device's conditions** copies measured external Vds and Vsb into the
characterization form, including the body-bias sign conversion Vsb = −Vbs.
Recorded corner and temperature are labeled observed or declared. Unknown
fields become blank and must be filled before generating a lookup. Stale or
unverified source revisions cannot supply conditions.

The same action searches this project's generated lookup CSVs and the current
loaded CSV. One matching file/condition slice loads automatically. Multiple
matches appear in a chooser; nothing is selected arbitrarily. Matching checks
PDK, model, corner, temperature, Vds and Vsb. A project's declared comparison
bias does not override a selected device's measured terminal voltage.

These values configure characterization; they do not change the testbench's
sources, corner or temperature. Dependency gaps remain reported separately.

## Recover where the problem appears

The workspace pairs current problems with actions: **Rerun testbench** for stale
measurements, **Generate lookup** for missing curves, **Set up project** for
missing simulator/output setup, and **Choose result file** for attachment
problems. Input and action errors appear inline. Running simulations keep their
existing process ownership and cancellation behavior.

## Optional project setup

Choose **Set up this project…** from the Analog Lens or Session menu. It checks
the simulator, PDK directory, initialization, output directory, testbench, raw API
and result path. Select a check for its explanation and available action. Choose
an output directory or existing raw file, or type the expected future raw path;
blank keeps automatic detection. Choose the analysis type beside the path.

**Save settings** stores result selection without running anything. **Save & run
testbench** starts only when the setup checks are ready. Missing tools or PDK
setup receive IIC-specific guidance; the wizard does not install tools or modify
PDK files. These checks establish readiness, not successful circuit simulation.
The wizard opens only when requested.

## Read verification at a glance

The workspace and **Sizing verification** dialog show target, before, after and
signed percentage error for gm and gm/Id. Each chart centers on its own target;
the band is the allowed tolerance, a circle shows the previous value, and a
diamond shows the measured new value. Missing values have no fabricated marker.
Text and numeric values remain available without relying on color.

Expand **Show measurement details and run log** for the recorded measurements
and isolated OP log. Native simulator output remains in xschem's simulation
console. A Pass covers the two requested device targets; circuit specifications
and layout constraints need their own checks. A width-only change can legitimately
miss gm/Id when the gate bias stays fixed.

## Units and field guidance

Bare numbers retain the units printed beside each field. Explicit examples:

| Field | Accepted examples | Canonical value |
|---|---|---|
| Target gm | `800`, `800 µS`, `0.8 mS` | 800 µS |
| Length / width | `0.5`, `500nm`, `0.5 µm` | 0.5 µm |
| Voltage | `0.7`, `700mV`, `0.7 V` | 0.7 V |
| Temperature | `85`, `85°C` | 85 °C |
| Target tolerance | `10`, `10%` | 10% |

Length and batch lists accept spaces or commas, including `500 nm, 1 µm`.
Units must match the field; expressions and nonfinite values are rejected.
Saved sizing targets use canonical numeric values, so existing session files
remain compatible. Characterization keeps the entered display values while
passing normalized numbers to ngspice's generator.

Focus or point at a field for nearby guidance. Corner selectors read section
names from the installed MOS profile's actual model library. If the library is
unavailable, the field remains editable and explains that choices could not be
read. A listed section is not a claim that every corner has been validated.

See [the v0.5 integration guide](INTEGRATION_V05.md) for dependency fingerprints,
project archives, batch caching and geometry conventions, and
[VALIDATION.md](../VALIDATION.md) for the exact tested environment and coverage.
