# From a sizing miss to a measured pass

This lesson runs against your installed SKY130 models in IIC-OSIC-TOOLS. It
creates editable xschem schematics, a real lookup, simulator logs and a
`targets.json` containing measured targets and before/after results. No PDK
files are copied or modified. The existing `lookup-template.csv` is synthetic
and is not used by this lesson.

From the repository in an IIC terminal:

```sh
python3 tools/create_tutorial.py --output /foss/designs/analog-lens-lesson
cd /foss/designs/analog-lens-lesson
xschem sizing.sch
```

Use a new output directory for each attempt. The generated project xschemrc
loads the installed PDK and this checkout of Analog Lens. Generation simulates
all three stages and fails if the adjusted circuit misses either target by
more than 10%. It preserves decks, raw files and logs for diagnosis.

## Lesson 1: Gate bias and width have different roles

1. **Run testbench**, select M1 and open **Size & verify**. The initial device
   has W = 10 µm, L = 0.5 µm, Vgs = 0.9 V and Vds = 0.9 V.
2. Load `lookup.csv`. Its trust status should become **Verified**. Select
   **Use this device's conditions** to check the matching condition slice.
3. Enter L = 0.5 µm and the `gm_uS` and `gmid` values printed by the generator
   or recorded in `targets.json`. Those targets are measured directly at the
   final 20 µm width near Vgs = 0.7 V. This avoids assuming that doubling width
   exactly doubles gm and current; model width effects can be appreciable.
4. Choose **Preview sizing changes**. Expect total width near 20 µm and an
   estimated required Vgs near 0.7 V. The preview explains the bias difference.
   Minor upward width rounding is shown separately.
5. Choose **Apply & verify in testbench**. Width changes; the gate source still
   supplies 0.9 V. Inspect the target errors and gate-bias advice. The generator's
   `width_only` measurement records what your installed models actually do;
   it is not a claim that every model revision must produce the same error.
6. Edit the BIAS code block's `vg g 0 .9` to the exact `estimated_vgs_v` from
   `targets.json`. Save and rerun. The old sizing verdict correctly becomes
   outdated when the bias source changes. Reuse the new conditions, preview
   the same targets and apply/run again to obtain a verdict for this revision.
7. Compare with `bias_adjusted` in `targets.json` or open `adjusted.sch`, which
   contains the completed geometry and bias. Both device targets should be
   within 10%; this is not circuit gain, bandwidth or layout qualification.

One xschem Undo restores the sizing geometry. Bias-source edits have their own
normal editor Undo. Analog Lens never adjusts voltage sources automatically.

If results differ, first check the selected corner, temperature, external Vds
and Vsb, model revision and geometry counts. A lookup from a different PDK
revision is **Outdated** and must be regenerated. Missing Vgs in an imported
CSV leaves the bias estimate unavailable rather than inventing a voltage.

## Lesson 2: A current mirror couples two devices

Open `mirror.sch` and run the testbench. M1 is diode-connected and fed by the
reference current; M2 shares its gate and has twice the width. Inspect both
devices and keep a baseline. M2's current should be approximately twice the
reference current. The ratio need not be exactly two: drain voltages, width
effects and finite output resistance differ.

Change the `vout` source to inspect headroom and current-ratio changes, then
compare against the baseline. Resize M2 while keeping M1 fixed and observe
which device metrics change. This is a manual circuit lesson: the extension
sizes one selected transistor and does not promise to jointly optimize a pair.
