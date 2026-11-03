# A WebKit viewer for rich agent output (#896)

Status: proposal, no code. Written by iris-dev-3; the first format, the arrival and the security rules
were agreed with the planner before this note (Brian approved the spike).

Agents sometimes want to show something markdown cannot say: a styled page, a table with layout, a diagram.
This note recommends a second, separate way to display that: a window holding a `WKWebView`, opened by the
person from a fenced block. It answers the five questions in the issue and ends with a PR breakdown.

The security posture comes first because the rest follows from it. Iris's guard and taint model assume
that what a model writes cannot act by itself: a message is text, and anything that leaves the Mac goes
through an outbound gate (#812) that only the person can open. A web view breaks that assumption the
moment it runs a script or loads a URL. So the viewer is built so that it can do neither, by several
independent mechanisms, and the note says which change would turn it into an outbound tool.

## 1. Security posture

**What a hostile page would do, if it could.** The model reads untrusted content (a web page, a file, a
peer's message) and is steered into writing HTML. The HTML then tries to: send data out (`<img src>`,
`<link>`, CSS `url()`, `@import`, a form post, `fetch`, a `meta refresh`, a clicked link, `window.open`);
run script; keep something between views (cookies, storage, cache); read what the person types; or look
like Iris itself (a fake approval card, a fake "Allow" button) to get a click that means something else.

**Phase 1 rules.** Each layer fails closed on its own. A test pins each (section 6).

1. **No script.** `WKWebpagePreferences.allowsContentJavaScript = false`;
   `javaScriptCanOpenWindowsAutomatically = false`. No `WKScriptMessageHandler` is registered and no
   `WKUserScript` is added, so there is no bridge from the page to Iris: the view is neither an outbound
   sink nor an input source for the model.
2. **Served only through a custom scheme.** The document loads from a `WKURLSchemeHandler` for
   `iris-view://doc`, never `loadHTMLString` or a file URL with a base (a file base grants file reads, an
   http base grants a network origin). The handler answers with a CSP header:
   `sandbox; default-src 'none'; style-src 'unsafe-inline'; img-src data:`. CSP `sandbox` without
   `allow-scripts` is a second, independent script block; `default-src 'none'` blocks every network load
   the page tries.
3. **No load, no navigation.** A compiled `WKContentRuleList` blocks http, https, ws, wss, ftp and file
   loads. A `WKNavigationDelegate` cancels every navigation except the first (it covers `meta refresh`,
   form submits and clicked links), and `webView(_:createWebViewWith:...)` returns nil. Links are inert in
   phase 1. A later "open this link" is a human-confirmed `NSWorkspace` open that shows the whole URL,
   because a URL's query string is itself a way out.
4. **Nothing kept.** `WKWebsiteDataStore.nonPersistent()`: no cookies, cache or storage. One document per
   window, and the view is released when the window closes.
5. **The page cannot pass for Iris.** A banner drawn in Swift, outside the web view, is always visible and
   the page cannot cover it: "Model-generated content. Nothing here can send or run anything." When the
   conversation has read untrusted content (`hasUntrustedToolOutput`, #813), the banner says so as well,
   as the #813 header does for a peer message. The window is never full-bleed and takes no keyboard focus
   until the person clicks it.
6. **Opened by the person only.** A click on the chip opens it. A model, a job run, a subagent or an
   evaluator cannot: there is no tool and no event that opens a window, so no focus is stolen and no
   page appears unasked. A chip is drawn only in the attended chat window.

**How the existing gates extend, and what they do not.**

- The viewer is not in `OutboundTools.builtIn` and must not be. Rules 1 to 3 give it no way to send
  anything, so it is not an outbound channel, and putting it behind the #812 gate would ask the person to
  approve something that cannot happen. The #812 and #813 gates are unchanged; nothing is relaxed.
- It is not a taint source. Nothing flows from the page back to the model, so opening a document marks
  nothing. A later turn that reads the same text does so through `read_file`, where the guard already
  applies.
- **The tripwire.** If any later change gives the viewer script or a network load, it becomes an outbound
  tool and an input source. That change must add it to `OutboundTools` (and its gate), taint a conversation
  on whatever it reads back, and carry its own review. A test fails if the viewer's configuration allows
  either, so the change cannot be made by accident (section 6, `ViewerConfiguration`).
- The injection guard is not run on a document before it is displayed. The guard protects the model from
  text it reads; the person is shown the same fence in the transcript already, and what the viewer must
  guarantee is that rendering cannot act, which is the rules above and not a scan.

**Phase 2 is a different threat model, not an extension of this one.** Phase 1's guarantee is airtight
because no script runs at all. Phase 2 (section 3) turns JavaScript on for a bundled renderer and feeds it
model-written text as data. Its safety then rests on a third-party library having no path from data to
script, which is a standing risk and not a solved one: Mermaid in particular has a history of cross-site
scripting through diagram text, including under its strict security level. So phase 2 may not inherit
phase 1's "inert" reasoning. It needs its own review: the library's version pinned and bundled, its
advisories tracked, hostile diagram text in the tests, and its renderer view isolated (no network, the same
rules 2 to 4, and its output reduced to script-free markup before the display view ever sees it). PR 4
below is approved on those merits, separately, never by analogy to phase 1.

## 2. How content arrives, and the surface

**Arrival: a fenced block, no new tool.** Today a ```` ```html ```` fence renders as a monospaced code
block (the `markdownBlockStyle(\.codeBlock)` closure in `ChatView`). The viewer adds an "Open in viewer"
chip to that block and changes nothing else about it: the code block's rendering, margins and wrapping are
untouched, and the chip is an overlay affordance only, hover-revealed like #894's copy button. It uses no
`.textSelection` and no new modifier on the Markdown views, so it does not approach the AttributeGraph
cycle (`0ed19c8`, #28); the chip is a sibling view inside the block style, which is what #894 already
established. PR 2 depends on #894's `CodeBlockView` and starts after it merges.

Why a fence and not a tool (`show_html`, `present`):

- **No tokens.** A tool declaration costs prompt tokens on every call (Invariant 6). A fence costs none:
  models already write ```` ```html ```` blocks unprompted, and nothing needs declaring or explaining.
- **Nothing to gate.** There is no tool for a tainted conversation to call, so there is no call to refuse
  and no off-state refusal to write (the dispatcher cannot be asked to show a window).
- **The transcript is the record.** What the person opens is exactly what the model wrote and what is saved.

A tool is deferred, not rejected. If one is needed later (a document too large for a message, or a file in
the workspace), it follows Invariant 6 as a workflow-trigger tool offered only on a triggering turn, and it
reads the file through the existing artifact path (`iris-artifact://`, hash-checked, guarded), not a new
one.

**Surface: a separate window, not inline and not in the composer stack.** A SwiftUI scene opened the way
the Run Log window is (`MainWindow.open(scene:)`, `RunLogView.swift`). A separate window means Invariant 8
does not apply (nothing joins the composer's `VStack`), a large page cannot reflow the chat, and the web
view cannot be hit by chat-list updates. The window carries the conversation's title and the message it
came from.

**Tie to the message and persistence.** The window is keyed by (conversation id, message id, fence index);
the document is the fence's text, read from the stored message. There is no new persisted field, so
Invariant 1 has nothing to protect: after a relaunch the chip is still on the fence and opens the same
document. An open window is not restored at launch (a model-authored page should never reappear without a
click). A document is capped at 1 MB of raw bytes, a code constant and not a setting (a slide or a page with a
couple of `data:` images passes 256 KB quickly). Over the cap the window shows a Swift-drawn "content too
large to display (N KB > 1 MB)" instead of rendering. The HTML is never truncated: a cut in the middle of a
tag is worse than a refusal.

## 3. Formats, in order

1. **Raw HTML and CSS, with inline SVG (phase 1).** With script off this covers styled pages, tables and
   static diagrams drawn as SVG. It is the first format because it needs nothing bundled, adds no binary
   size, and its security argument is the simplest one available.
2. **Diagrams (Mermaid or similar) and slides (reveal.js style) (phase 2).** Neither runs without script,
   so neither can be first. They need the separate threat model above. Proposed shape: a second, hidden
   renderer view, loaded only from bundled resources, with script on and rules 2 to 4 still applied. It
   receives the source as a string through a native call (never concatenated into HTML) and returns
   markup that is sanitized to a script-free allow-list (SVG elements and attributes, no `<script>`, no
   event handlers, no `href`/`xlink:href` to anything but fragments) before the phase-1 display view shows
   it. Model-written bytes then never execute in a view that can show them. The renderer is the risk
   (section 1); the display view stays as safe as phase 1.
3. **Slides** can be a markdown-to-HTML transform with CSS paging (no script): worth trying inside phase 1
   before reveal.js, because it needs no phase 2 at all. Not specified here.

Pick for Brian's own use: HTML and SVG first. It covers the common asks (a report with layout, a comparison
table, a drawn diagram) and it is the only format whose safety is already settled.

## 4. Cost

These are estimates; PR 1 measures them.

- **Binary size.** Nothing for phase 1 (WebKit is a system framework). Phase 2 adds the bundled library:
  Mermaid's minified build is about 2.5 MB, reveal.js under 1 MB.
- **Memory.** A `WKWebView` runs its content in a separate WebContent process: tens of MB per open view,
  estimated. One view per window, released on close. Several viewer windows may be open at once (ordinary macOS
  multi-window), with no cap in v1; WebContent memory is reclaimed on close. If memory ever bites, an
  LRU that closes the oldest is the known lever, and not part of v1.
- **Chat responsiveness.** Expected nil: the page renders out of process, in its own window, and shares
  no layout with the chat. PR 1 measures the chat's frame time with a large page open.

## 5. What this does not do

No script and no network in phase 1. No bridge: a page cannot call Iris, answer the model or read a file.
No auto-open, no restore at launch, no persistence between views. No change to the outbound gate, the
taint model, `OutboundTools`, the guard tiers or any tool declaration. Link-out, forms, downloads,
printing and "save the page" are out; each would need its own look at the rules above.

## 6. Tests that pin it

- **`ViewerConfiguration`** is built by one pure function. A test asserts, field by field: JavaScript off
  in the page preferences, no script-opened windows, no message handlers, no user scripts, a non-persistent
  data store, the scheme handler as the only source. A change that turns any on fails here first (the
  tripwire).
- **The CSP string** is a constant; a test asserts it contains `sandbox`, no `allow-scripts`,
  `default-src 'none'`.
- **Navigation policy** is a pure function over (request, is-first-load) with a table test: first load
  allowed; every other navigation, a form, a `meta refresh` target and a link all cancelled.
- **The content rule list** is compiled in a test and matched against sample URLs for every blocked
  scheme (the belt to the loopback test's suspenders).
- **Zero connections** (PR 1 finds out whether this can run under `swift test`): a loopback listener, a
  document carrying `<img>`, `<link rel=stylesheet>`, `<form>`, `<meta refresh>`, CSS `url()` and `@import`
  pointing at it, and an assertion that the listener accepts nothing. If `WKWebView` cannot run headless
  there, the pure tests above stand and this runs once as a GUI pass under the gui-test-lease (window-only
  capture, rule 34), recorded in the PR.
- **The chip**: a test that a document over 1 MB is refused with the message and not truncated; the existing code-block rendering test is
  untouched, which is the check that the fence's rendering did not change.

## 7. PR breakdown

1. **`ViewerConfiguration`, the scheme handler, the navigation policy, the rule list and their tests.** No
   UI. Answers the headless question and measures memory.
2. **The window, the chip and the banner.** Depends on #894 merging. One lease-guarded GUI pass with a
   window-only capture: a short page, a long page, a hostile page (every channel in section 1), and the
   banner with and without the #813 taint.
3. **Docs.** `docs/features.md` heading for the viewer and what it cannot do; a line wherever agent-facing
   text says that model output is text only, if any (Invariant 9).
4. **Phase 2, separately approved.** The bundled renderer for Mermaid (and slides if wanted): its own
   threat-model review, library version pinned, advisories tracked, hostile-input tests, and the
   sanitizer. Not started until PRs 1 to 3 are in use and Brian has asked for diagrams or slides.

## 8. Decisions

Planner decisions (rule 12; none changes a user-facing promise, so none is Brian's):

1. **Content cap:** 1 MB of raw document bytes, a code constant. Over it, a Swift-drawn message; never a
   truncated render.
2. **Window count:** multiple viewer windows, one document each, each destroyed on close; no cap in v1.
3. **Links are inert in v1.** The navigation delegate cancels every navigation after the first load. A
   later "open this URL" is the human-confirmed `NSWorkspace` open showing the full URL (section 1, rule 3).

No open question is left for Brian.
