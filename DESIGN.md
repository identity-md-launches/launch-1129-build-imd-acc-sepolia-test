# imd/acc test page: design reference

Documents the design actually implemented in `site/` (source of truth: `site/src/style.css`,
`site/index.html`, `site/src/main.ts`) as of the final build in this job. A future page for the same
product should reuse these tokens and components rather than invent new ones.

## Overview

Audience: integrators and testers rehearsing the imd/acc cashback flow on Sepolia. The page is a
single-column, card-based utility: calm neutrals, one accent hue for interactive elements, and
status colors only where a state exists (open/paused vault, pending/confirmed/failed action, right
or wrong network). Density is moderate: 16px card padding, 15px body text, 40px controls. Content
is ordered by the visitor's task: wallet, your stack, test tools, leaderboards, contracts, notes.

System-wide rules: tokens below, one filled primary action per view, verb-first button labels in
sentence case, every status carried by text plus a glyph, never by color alone. Page-specific
arrangement (the order of the six cards) is not a rule for other pages.

## Colors

Defined in `site/src/style.css` under `:root`. Two tiers: primitives named by hue (`--gray-*`,
`--blue-*`, `--green-*`, `--red-*`, `--amber-*`) and semantic tokens that components reference.
Theme switching uses one mechanism: `color-scheme: light dark` plus `light-dark()` per token.
`html[data-theme="light"|"dark"]` forces a scheme (set by the theme button, stored in
`localStorage` as `imdacc:theme`); without it the OS preference applies.

| Token | Light | Dark | Job |
| --- | --- | --- | --- |
| `--color-bg` | `#f5f6f8` | `#0f1115` | page background |
| `--color-surface` | `#ffffff` | `#171a21` | cards, inputs, secondary buttons |
| `--color-surface-raised` | `#eceef2` | `#1e222b` | stat tiles, inline code, neutral pills, hover |
| `--color-border` | `#d6dae2` | `#2e3441` | card borders, table rules (structure only) |
| `--color-border-control` | `#7b8597` | `#76808f` | input and secondary/ghost button borders |
| `--color-text` | `#171a21` | `#e7e9ee` | primary text |
| `--color-text-secondary` | `#5c6577` | `#a4adbc` | captions, labels, table headers, muted copy |
| `--color-accent-solid` | `#1f5fbf` | `#7cc4ff` | primary button fill, tag outline |
| `--color-accent-solid-hover` | `#174d99` | `#a5d6ff` | primary button hover |
| `--color-on-accent` | `#ffffff` | `#0f1115` | text on the accent fill |
| `--color-link` | `#174d99` | `#7cc4ff` | links, tag text |
| `--color-focus` | `#1f5fbf` | `#7cc4ff` | `:focus-visible` outline |
| `--color-ok-text` / `--color-ok-bg` | `#1c6f36` / `#e2f4e7` | `#7ddf8e` / `#15301d` | success status, "Open" and "listed" pills |
| `--color-bad-text` / `--color-bad-bg` | `#ad2323` / `#fbe6e6` | `#ff8f8f` / `#3a1a1a` | errors, "Paused", "Wrong network" |
| `--color-pending-text` / `--color-pending-bg` | `#8a5a00` / `#fbf0d6` | `#f2c66b` / `#3a2c0d` | pending action status |

Measured WCAG 2 contrast of the declared pairs (computed from token values with
`test/scratch/contrast.mjs`, light / dark): primary text on surface 17.4 / 14.3; secondary text on
surface 5.9 / 7.7 and on raised 5.1 / 7.0; link on surface 8.2 / 9.3; on-accent on accent 6.1 /
10.1; ok text on ok bg 5.4 / 8.7; bad text on bad bg 5.8 / 7.1; pending text on pending bg 5.2 /
8.5; control border on surface 3.7 / 4.4; focus ring on surface 6.1 / 9.3. The structural
`--color-border` is 1.4:1 by design and is never the only cue for a control.

Rules: the accent hue means interactive, so it never colors static text. Exactly one filled
button per view (Connect wallet; Switch to Sepolia only replaces it when the network is wrong).
Tool buttons are the bordered secondary variant.

## Typography

System stack only, no web fonts: `--font-sans: system-ui, -apple-system, "Segoe UI", Roboto,
"Helvetica Neue", sans-serif`; `--font-mono: ui-monospace, SFMono-Regular, Menlo, Consolas,
monospace` for addresses, hashes and code. Weights used: 400 body, 500 labels/pills, 600 headings,
buttons and stat values.

Scale (rem, 16px root): `--text-xs` 12px pills; `--text-sm` 13px captions, table headers, mono,
status lines; `--text-md` 15px body; `--text-lg` 17px h3; `--text-xl` 20px h2; `--text-2xl` 28px h1;
`--text-stat` 22px stat values. Inputs are 16px so iOS does not zoom. Line-height 1.5 for body,
1.1–1.2 for headings. `h1` has `letter-spacing: -0.01em` and `text-wrap: balance`; the lede and
notes use `text-wrap: pretty` with a 70ch measure. Numbers that change (stat values, numeric table
cells, the amount input) use `font-variant-numeric: tabular-nums`. Long addresses use
`overflow-wrap: anywhere` so they never force horizontal scroll; the links in tables show a
shortened address with the full one in `title`.

## Layout

Content width `--content-width` 64rem (1024px), centered, with 16px inline padding (12px under
30rem). Spacing scale on a 4px base: `--space-1` 4px to `--space-8` 32px. Cards stack vertically
with 16px between them; inside a card, groups are separated by 16px and items within a group by
8–12px. `.row` is the horizontal control group (flex, 12px gap, wraps). `.stats` is an auto-fit
grid of tiles with a 10rem minimum (two columns at or under 30rem). `.cols` places the two
leaderboards side by side and collapses to one column at 47.5rem. Logical properties
(`margin-inline`, `padding-inline-start`, `inset-inline-start`, `text-align: start/end`) are used
throughout. Checked in the browser at 320, 360 and 1280 CSS px: no horizontal overflow at any of
them (`scrollWidth === clientWidth`).

## Elevation & depth

Flat by design: no shadows. Depth comes from two tonal layers (page background, card surface) plus
a third raised tone for tiles and pills, and 1px structural borders on cards and table rows. The
skip link is the only element with a z-index.

## Shapes

`--radius-sm` 6px for inputs, buttons; `--radius-md` 10px for stat tiles; `--radius-lg` 14px for
cards (inner radius plus the 4px step so nested corners read concentric; cards drop to 10px on
small screens where padding shrinks). Pills and the header tag are fully rounded (999px).

## Components

All in `site/index.html` and styled in `site/src/style.css`; behavior in `site/src/main.ts`.

- **Buttons** `.btn` with `.btn-primary` (accent fill), `.btn-secondary` (surface + control
  border), `.btn-ghost` (theme toggle). 40px min height, 600 weight, `scale: 0.96` on press with a
  120ms `cubic-bezier(0.2, 0, 0, 1)` transition on color properties only; disabled state is native
  `disabled` at 0.55 opacity. While a transaction runs the button is disabled, gets
  `aria-busy="true"` and its label changes to a progressive verb ("Minting…", "Stacking…",
  "Connecting…").
- **Action status** `.action-status` with `role="status"` under each action: `.pending`, `.ok`,
  `.bad` variants each prefix a glyph (⏳ ✓ ✕) so color is never the only cue, and carry a
  "View on Etherscan" link when a transaction hash exists.
- **Pills** `.pill` (neutral) with `.ok`, `.bad`, `.pending` variants: vault state, network badge,
  per-project "listed" / "direct, no points".
- **Stat tile** `.stat` inside `dl.stats`: caption `dt`, value `dd`.
- **Tables** `table.list`: start-aligned text, `.num` cells end-aligned with tabular numbers, a
  single-cell `.empty` row that says how to fill the table.
- **Address list** `dl.addresses`: label above a full-width monospace explorer link.
- **Field** `.field`: visible `<label for>` above a text input with `inputmode="decimal"`;
  invalid input sets `aria-invalid="true"` and the error text appears in the action status.
- **Skip link** `.skip-link`: first focusable element, visible on focus.
- **Theme toggle** `#btn-theme`: cycles system → light → dark; transitions are suppressed for one
  frame during the switch.

## States and motion

Focus: `:focus-visible` 2px solid `--color-focus` with 2px offset on every control and link.
Hover styles are gated behind `@media (hover: hover)`. Motion is limited to the 120ms button
transition and the press scale; both are disabled under `prefers-reduced-motion: reduce`.
Loading states are text ("Scanning Stacked events: block … of …", "sent, waiting for
confirmation…"). Empty states name the next action (use the faucet, add a project to
`projects.json`).

## Assets

No images, icons or font files. The favicon is an empty `data:` URL so gateways do not 404.
Runtime data files `config.json` and `projects.json` are copied verbatim from `site/public/` into
`dist/` and are read with relative URLs, so they can be edited on the exported copy.
