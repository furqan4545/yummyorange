# YummyOrange website: design decisions

A static marketing site for YummyOrange. Every word, picture, colour, icon and line of code is YummyOrange's own: the copy
is written from the app's README, its sources and `--targets` output, the pictures are rendered by the app's own
`--snapshot` commands, and the colours come from `Sources/DropWheel/DWPalette.swift`. The order of the page follows
YummyOrange's own story: the gesture, then where its results go (the Clothesline, which only YummyOrange has), then what
each kind of file can do, then the editors, privacy, download and questions.

Guidelines used: the `apple-look` skill (HIG foundations for the web: accessibility, colour, type, layout, writing,
dark mode, motion, branding) and `apple-motion` (springs, response on press, interruptible motion, velocity hand-off,
rubber-banding, reduced motion).

## Name and address

- The product is **YummyOrange**: one word, capital Y and O, spelled the same in every title, heading, alt text,
  label and file name (`YummyOrange.dmg`). It was called DropWheel until 25 November 2026; the icon, the palette and
  every picture stayed. "The wheel" is still the feature's name: it describes the gesture, not the product.
- The site lives at **https://yummyorange.com**. Each page has a `<link rel="canonical">` to its clean address
  (`/`, `/privacy`, `/release-notes`), and the home page's `og:url` and `og:image` are absolute. The update feed the
  app asks is `https://yummyorange.com/updates/appcast.json` (with `appcast.json.sig` beside it).
- Internal names stay as they were, because visitors never see them: the Swift target and the `Sources/DropWheel`
  folder, and `window.DROPWHEEL` in `config.js`, which `Tools/updates/release.sh` looks for in the live site's
  `config.js` before a release.

## Folders

| Path | What it is |
| --- | --- |
| `public/` | **The site. Deploy this folder and nothing else.** `index.html`, `release-notes.html`, `privacy.html`, `css/`, `js/`, `assets/` |
| `public/licenses/ffmpeg.html` | The license and source page of YummyOrange's own ffmpeg (the app's Settings › About links to it): what it is and leaves out, its LGPL licensing, the IJG credit and where the notices of FFmpeg's files under other licenses are, every library, the configure lines, the source tarballs and the rebuild script |
| `public/downloads/helpers/` | The ffmpeg ZIP the app downloads (its name, size and SHA-256 are pinned in `FFmpegHelper.pinnedBuild`) and, in `sources/`, the seven source tarballs, `build-ffmpeg-helper.sh` (also kept as `Tools/helpers/build-ffmpeg-helper.sh`), and the LICENSE.md and BUILD.md that ship inside the ZIP. A new build gets a new file name; old ones stay for the copies of the app that pin them |
| `public/js/config.js` | The one place for release details: DMG URL, notarized or not, version, price, size, minimum macOS, chip, support email |
| `../vercel.json` (repository root) | Hosting: serves `Website/public/` with clean URLs and sets cache and content-type headers (see Hosting) |
| `DESIGN.md` | This file (not deployed) |
| `tools/make-assets.sh` | Re-renders the pictures from a debug build (not deployed) |
| `tools/og-card.html`, `tools/make-og-image.js` | The 1200 × 630 social card and its renderer (not deployed) |
| `unused-assets/` | Renders the page no longer shows (the trio wheels, Settings › General, the welcome tour); the Convert wheel is the social card's source |

## Direction

- **Product.** A macOS menu-bar app: drag any file, tap a key mid-drag, and a radial wheel opens under the pointer;
  let go on a petal to convert, edit or act on the file. New files appear on a shelf or on the Clothesline.
- **Character.** Quick, tactile, a little playful.
- **World.** The app's own welcome page: a dahlia-pink surface with a butter glow, cream petals, black key caps,
  wooden clothespins on a glowing string.
- **Moments.** (1) The playground: a dahlia "desktop" with real-looking files where the wheel actually opens.
  (2) The Clothesline, right after it: the glowing gold-to-pink string that drops out of a notch with swinging
  polaroid cards. Everything else is quiet: warm neutrals, hairlines, one accent.
- **Signature.** The app's key caps (`⇧ shift`, `⌘ command`, `⌥ option`): near-black caps that press and turn
  dahlia when their wheel is open. They are the controls in both demos, and they switch the explorer's wheel. The
  key names and the cap layout (glyph top right, name bottom left) are the app's, so the site shows them as they are.

## Page order

hero → playground → the Clothesline (demo, the real render, then "Or on a shelf, or in Finder") → from a link to a
file → every file gets its own wheel (a list of kinds, one wheel switched by its key cap, and what the kind works on and becomes) → editors
→ privacy → download → questions → footer.

- The kinds are sorted by how often people reach for them: Images, PDF, Documents, Video, Audio, Spreadsheets,
  Slides, Ebooks, Subtitles, then Folders next to Archives.
- The formats table, the three-card row, the Actions section and the welcome tour are gone: the formats live in the
  explorer's facts column, the Actions wheel is the explorer's ⌥ key, and the tour is one sentence in the download
  steps. Desktop height went from about 10,300 px to about 7,000 px; a 390 px phone from about 13,250 to 8,260.

## Colour

Brand seeds from `DWPalette.swift`: dahlia `#E2669C` (base), butter `#FFE1A1` (glow), cream `#FFF4EA`. Derived
tones computed with the app's own rules: accent `#E266BA`, accentLight `#E98BCB`, accentHighlight `#EEA6D7`,
accentDeep `#A74086`. The wheel's highlight uses the app's 3-stop gradient (accentHighlight → accent → accentDeep).

| Token | Light | Dark | Role, contrast |
| --- | --- | --- | --- |
| `--bg` | `#FBF8F5` | `#141113` | page, warm neutral tinted toward cream |
| `--surface` | `#FFFFFF` | `#1E1A1D` | cards |
| `--surface-2` | `#F4EEEA` | `#29242A` | insets, tab track |
| `--text` | `#1D1B1E` | `#F6F1F3` | 16.2:1 / 16.8:1 on `--bg` |
| `--text-2` | `#5A5157` | `#C4B9BF` | 7.2:1 / 9.9:1 |
| `--text-3` | `#6B6166` | `#A89DA3` | 5.6:1 / 7.2:1 (smallest captions) |
| `--ink` | `#A93F73` | `#F29BC1` | links and notes: 5.4:1 / 9.1:1 |
| `--btn` / `--btn-text` | `#A93F73` / white | `#E2669C` / `#2A0F1F` | primary button: 5.8:1 / 5.6:1 |
| highlighted petal label | `#2A0F1F` (plum) | same | 5.6:1 on `#E266BA`, more on the lighter stops. White was 1.9–2.85:1 |
| `--card-ring` | `#2A0F1F` | `#FFF4EA` | selected or focused Clothesline card, on the wall (dahlia was 2.41:1) |
| file badges | `#6B6468`, PDF `#C44848`, DOCX `#3C67B8`, XLSX `#2E7D52`, WAV `#7650B5`, EPUB `#A85A12` | same | white 10 px text, 4.8:1 to 5.9:1 |
| scene | `#E2669C` + butter glow | `#CF6094` + softer glow | file names sit on a plum pill (white 7.0:1 / 9.3:1); notes are plum `#2A0F1F` (5.6:1 / 4.9:1) |
| `--note-ink` | `#8E2F60` | `#F29BC1` | the Clothesline note on the wallpaper (5.3:1 / 5.8:1 at worst) |

- `color.md › Best practices`: "Avoid using the same color to mean different things." Dahlia fills mean "selected or
  active" (the highlighted petal, a pressed key cap, the string); `--ink` means "link or note". Nothing else is pink.
- The raw brand pink fails 4.5:1 under white text (3.17:1), so it never carries small white text.
- Light and dark follow `prefers-color-scheme`; there is no site-specific switch (`dark-mode.md`). Every render ships
  in both appearances. `prefers-contrast: more` darkens secondary text and hairlines.

## Type

- System font stack only, no web font (`typography.md`, apple-motion §15). The notes use `ui-rounded` semibold, as
  the app's onboarding notes do.
- Scale (rem, so it follows the reader's text size): display `clamp(2.5rem, 6vw, 4.5rem)` 600 / 1.04 / −0.03em;
  H2 `clamp(1.875rem, 4vw, 2.75rem)` 600 / 1.1 / −0.022em; H3 1.0625–1.375rem 600; lede 1.1875rem / 1.5; body
  1.0625rem / 1.55; small 0.9375rem; caption 0.8125rem.
- **Wheel text** (`typography.md`: 11 pt minimum on phones, 10 pt on the desktop). Petal names are 11 px or more on
  screen. Each wheel measures its labels with the page's font against each petal's real shape and tries, in order:
  the app's capitals; upper and lower case without tracking; the labels that still don't fit broken into words and at
  hyphen points ("Back-ground"); the same without petal icons. Desktop wheels mostly keep the capitals; 390 px phones
  use upper and lower case without icons, all at 11 px; only a 320 px phone shrinks the tool names, to no less than
  10 px. The centre capsule is 10 px or more and widens up to the hole (a long name drops to upper and lower case).
- Key cap names are 11 px; a cap is as wide as its name (so "command" fits).

## Layout

- One content column, max 1120 px, 24 px gutters (16 px under 760 px). Sections 128 px apart (88 px on phones).
- The explorer: a vertical list of kinds (each with its sample file) at the left, the wheel in the middle with its
  three key caps above it, and the facts at the right. At 960 px and less the kinds become a scrolling row and the
  facts go under the wheel.
- Responsive: no horizontal page scroll at 1440, 390 or 320 px in Chromium and WebKit; the download card's columns
  are `minmax(0, 1fr)`, the spec rows stack under 600 px, and file paths break anywhere. Under 760 px the
  Clothesline's note sits left of the notch with its arrow pointing up at it, and says "Tap the notch" on touch.
  The real-thing video is hidden under 600 px (it would be 60 px tall); its Play button sits top right, off the cards.

## Interaction and motion

- **Response on press** (`apple-motion §1`): buttons and key caps react on `pointerdown`.
- **Direct manipulation** (§2): files and cards follow the pointer 1:1 from where they were grabbed, with
  `setPointerCapture`; a 6 px threshold before a drag starts. While a wheel is open the dragged file goes under the
  wheel layer, so the centre capsule that names the highlighted petal is never covered.
- **Springs, interruptible** (§3–4): a small spring integrator (`response`, `damping`) drives the wheel's bloom (0.3 s,
  damping 1, like the app's), files returning home, and cards making room. Every animation starts from the current
  value.
- **Velocity hand-off** (§5): a released card or file keeps the pointer's velocity into its spring.
- **Card swing.** Cards are damped pendulums driven by their pin's acceleration: damping ratio about 0.41 (response
  1.15 s), settled within 0.6° in about 1.7 s; the pin's acceleration is smoothed over a few frames. Neighbours that only make room feel a third of the push (about 10°); a card just
  hung, thrown or carried feels all of it for 0.9 s (13° to 17° in a quick drag). Past 0.32 rad the swing meets a progressively stiffer
  spring, with a stop at 0.6 rad that only removes outward speed, so there is no brick wall.
- **The string's fall** is the one bounce without a throw, on purpose: it falls under its own weight, as in the app
  (whose fall spring has damping 0.6); here it is calmer, 0.78. Everything else without momentum is damping 1.
- **Momentum projection and rubber-banding** (§6, §9): a long line scrolls sideways by dragging the string or by
  two-finger scrolling; both rubber-band at the ends and spring back. A flick lands where Apple's projection says.
- **Spatial consistency** (§7): the line comes out of the notch and goes back into it; the wheel blooms from the
  pointer; a file returns to its spot.
- **Deep links** land at once: smooth scrolling is turned on only after the page has loaded, so `/#faq` doesn't glide
  9,000 px, while clicks on in-page links still glide (never under Reduce Motion).
- **Reduced motion** (`motion.md`): the wheel and line appear in place, cards don't swing and change places at once,
  notes are already drawn, the loop doesn't autoplay, and nothing smooth-scrolls.

## From a link to a file (1.0.11)

The app's link downloads (`LinkDownload.swift`), simulated on the Clothesline's desk: a browser window with five tabs
(YouTube, X, Instagram, TikTok, Threads, as plain text, no logos) showing made-up posts by `yummyorange` that use the
page's own pictures. Press the address (it is selected at once, plum on accent-highlight, 9.3:1), drag 6 px and a
link chip follows the pointer 1:1; ⇧ (the key or the on-screen cap, a second finger on touch) blooms the Convert wheel
with MP4, MP3, M4A and WAV, the only wheel a link has (⌘ and ⌥ say so, as in the app). Letting go on a petal shows the
corner banner ("→ MP4  ·  Sunset drive") with a download's progress; the line drops from the notch near the end, and
the new card flies out of the banner, swooping down across the wall and up into the first pin, which catches it and
sets it swinging (the Clothesline's pendulum). A drag let go elsewhere springs back into the address with the release
velocity and fades into it. Keyboard: Return or a lone ⇧ on the address opens the wheel; arrows, Return, Esc. Reduce
Motion: no flight or swing, the line and card appear in place; the progress bar still fills (status, not motion). On
phones the note sits where the line will hang until the first step, then between the browser and the key.

## Accessibility

- Keyboard: every file is a button. Enter (or tapping ⇧ / ⌘ / ⌥ on its own) opens a wheel on the focused file;
  arrows move around the petals, Enter applies, Esc closes. The wheel is a `menu` with `aria-activedescendant`.
  Clothesline cards are buttons: ← → select, ⌥← ⌥→ move a card, Delete takes it off, ⌘Z puts it back. The explorer's
  kinds are WAI tabs (arrows in both directions; `aria-orientation` follows the layout) and its key caps are toggle
  buttons (`aria-pressed`); a lone tap of ⇧, ⌘ or ⌥ (⌃ also opens Actions) switches the wheel while focus is in the explorer.
- Screen readers: key caps inside buttons are `aria-hidden`, so buttons read "Convert", "Tools", "Actions"; file
  badges and durations are hidden, so files read "lake.png", "sunset.mp4". The playground's instructions are
  described once, on the list of files. Results and wheel changes are announced in a polite live region.
- Touch: tap a file, then a key cap, then a petal. Key caps are 52 px tall; tabs are 44 px on coarse pointers; the
  result shelf's close button has a 44 px hit area.
- Nothing is said by colour alone: a highlighted petal changes fill and label colour, and the capsule names it.

## Writing

- Plain, specific, calm (`writing.md`). Headline: "Convert files in the middle of a drag". No exclamation marks, no
  hype, and no claims the app doesn't back: result names are the ones the app writes (`lake compressed.jpg`,
  `lake codes.txt`, `estimate PDFA.pdf`, `estimate pages/`…; "name 2.ext" only when a name is taken); permissions
  are listed in a question of their own; ffmpeg is named once beside the download button; "Apple silicon" because
  `build.sh` builds for the Mac it runs on.
- The privacy section makes YummyOrange's own case ("Work happens where the file is"), not a comparison with other
  converters.

## Release state

`config.js` decides what the download buttons do. While `dmgURL` is empty, every download button reads "Coming soon"
or "Download coming soon", links nowhere (`aria-disabled`), "Try it on this page" becomes the primary button, and
Get YummyOrange says the first release is on its way. With a URL set, the buttons download it; on a phone or tablet
they share the page's link instead ("Send the link to your Mac"). While `notarized` is false the download steps
include System Settings › Privacy & Security › Open Anyway. `price` and `supportEmail` add a Price row and a Contact
link once set.

## Launch checklist (outside the site's reach)

1. Make the release with `Tools/updates/release.sh` (see the README's "Updates and releases"): it builds and signs
   with a **Developer ID Application** certificate, notarizes and staples the app and the DMG, writes
   `downloads/YummyOrange.dmg`, the update ZIP (`downloads/YummyOrange-<version>-<build>.zip`), `updates/appcast.json` and
   its signature `updates/appcast.json.sig`, and sets `dmgURL`, `version` and `notarized: true` in `config.js`. The
   feed address, `https://yummyorange.com/updates/appcast.json`, is pinned as `FEED_URL` in
   `Tools/updates/release-identity`; `vercel.json` keeps `appcast.json` and `appcast.json.sig` out of every cache,
   since they must change together.
2. Set `price` and `supportEmail`.
3. In Vercel: the project `yummyorange` (team ali-furqans-projects) is connected to the GitHub repository and reads the root `vercel.json`, which serves `Website/public/`; add
   `yummyorange.com` and make it the primary domain, with `www.yummyorange.com` redirecting to it: the app asks the
   apex address, and the canonical links name it.
4. There is no build step, so site.js is not minified (97 KB raw, about 29 KB with the compression Vercel applies).
5. If the app is built universal (Intel too), change `chip` in `config.js` and the FAQ answer "Which Macs".

## Hosting

`vercel.json` (in `Website/`, next to `public/`):

- `outputDirectory: public`, no framework, no build. `cleanUrls` serves `privacy.html` at `/privacy` and redirects
  the `.html` address there (the pages still link to `privacy.html` and `release-notes.html`, so a plain
  `python3 -m http.server` preview works; on Vercel those links take one redirect).
- `assets/`: `Cache-Control: public, max-age=604800, stale-while-revalidate=86400` (a week). The file names carry no
  version, so a longer or `immutable` lifetime would keep a changed picture stale; rename a file to change it sooner.
  Pages, `css/` and `js/` keep Vercel's default (revalidate every time), since `config.js` changes at each release.
- `updates/appcast.json`: `application/json; charset=utf-8`; `appcast.json.sig`: `text/plain; charset=utf-8`; both
  `no-cache, max-age=0, must-revalidate`. Vercel clears its own edge cache on every deploy.
- `downloads/*.dmg` and `*.zip` get `application/x-apple-diskimage` and `application/zip`.
- `downloads/helpers/*.zip` and `downloads/helpers/sources/*.tar.xz` / `*.tar.gz` (`application/x-xz`,
  `application/gzip`): `Cache-Control: public, max-age=31536000, immutable`, because their names carry the version
  and never change. `build-ffmpeg-helper.sh`, `LICENSE.md` and `BUILD.md` in `sources/` are served as
  `text/plain; charset=utf-8`, so a browser shows them, with Vercel's default caching (their names carry no version).
- Every response: `X-Content-Type-Options: nosniff` and `Referrer-Policy: strict-origin-when-cross-origin`.

## Performance

- No framework, no build step, no web fonts. One CSS file, `config.js` and `site.js`.
- Pictures are WebP at 2× their displayed size, lazy-loaded below the fold, with `width`/`height`. The wheels are live
  SVG drawn from the app's geometry (`WheelGeometry.swift`).
- Videos: two 1440 × 250 H.264 loops, 0.35 MB each, `preload="none"`, loaded only when on screen (never under 600 px).

## Preview and assets

- Preview: `python3 -m http.server 8000` in `public/`, then open http://127.0.0.1:8000/.
- Re-render the pictures: `tools/make-assets.sh <scratch-dir> [<folder with Tests/fixtures>]` from a debug build
  (`swift build`; the binary keeps the target's internal name, `.build/debug/DropWheel`); it needs ffmpeg and cwebp.
  The menu picture is 804 × 592 since Check for Updates… joined the menu. Re-render the social card:
  `NODE_PATH="$(npm root -g)" node tools/make-og-image.js`.
