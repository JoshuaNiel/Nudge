# App icon

**Shipped:** concept 3, "Tipping point". A cream lowercase "n" on a teal gradient, with a yellow ball just tipped past the top of the arch: a small push at the tipping point.
Its three versions are copied into `Nudge/Nudge/Assets.xcassets/AppIcon.appiconset` (light, dark, tinted).

The other concepts are kept here for reference:
- **Concept 1, Ring + nudge:** an indigo progress ring with a coral dot pushing its leading end.
- **Concept 2, Two friends:** a clock speech bubble bumped by a smaller friend bubble, on coral and magenta.

`variants-sheet.png` shows each one in light, dark and tinted. It is the only rendered image kept in the repo. The per-concept PNGs and `contact-sheet.png` (all three at 1024, 120, 60 and 40 px) are not committed, because they would add about 10 MB to git history. `render.swift` regenerates them byte-for-byte (verified 2026-11-23); see below.

## Regenerate
`render.swift` draws every concept with CoreGraphics. Each concept's colours for light, dark and tinted are set inside the script.
```
cd design/app-icon
swiftc -O render.swift -o /tmp/nudge-icon-render
/tmp/nudge-icon-render --out ./out                        # every concept × variant, plus sheets with --sheet
/tmp/nudge-icon-render --concept 3 --variant dark --out ./out
```
Each output is a 1024×1024 opaque sRGB PNG with no pre-rounded corners; iOS applies the mask.
Copy `concept-3*.png` over the three files in `AppIcon.appiconset` to update the shipped icon.
