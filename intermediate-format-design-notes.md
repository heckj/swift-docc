# DocC Interchange Format (DIF) — Design Notes

Working notes from a discussion between Joe Heck and David Rönnqvist, prepping for
a Swift Forums proposal. This is a discussion/scoping document, not a spec: it
records the problem, what DocC does today (with citations so claims are
checkable), the decisions we've made so far and why, and the questions we're
deliberately leaving open for the Forums thread.

**Working name:** "DocC Interchange Format" (DIF). Placeholder-quality — pick
a name later. It is *not* the same thing as today's `.doccarchive`. That
distinction matters throughout this doc: `.doccarchive` (today's folder of
RenderNode JSON + SPA) becomes one *output* that can be built *from* a DIF,
not the format we're designing.

## 1. Motivation

Today, `docc convert` goes: symbol graphs + markdown → RenderNode JSON tree →
one specific presentation (the SPA web app, or flat static HTML via a
routing trick — see §2.3). Any other presentation (ePub, PDF, a custom
renderer) has to reverse-engineer RenderNode JSON itself, and nothing about
the process is queryable, mergeable, or incremental.

We want a single externalized, versioned, queryable format that:

- Represents everything needed to produce *any* presentation (today's SPA,
  flat static HTML, ePub, PDF, or an independent custom renderer) —
  presentation mechanisms should be expressible in terms of RenderNode
  concepts, generated from this format.
- Is directly queryable — curation checks, "documentation coverage" numbers,
  and similar tooling should run as queries against the format itself, not
  require a bespoke pass over the whole archive.
- Supports merge, diff, and incremental update/build — including combining
  symbol information contributed by separate platform builds (e.g. an
  iOS-only build and a tvOS-only build of the same module) into one logical
  document set.
- Is something DocC can build *against* repeatedly and efficiently, not just
  emit once at the end of a pipeline.

## 2. What DocC does today (research findings)

This section only records verified facts about the current codebase, so the
design decisions in §3 can be checked against real constraints instead of
assumptions. File:line citations are to `swift-docc` on the
`intermediate-format` branch.

### 2.1 RenderNode

- `RenderNode` (`Sources/SwiftDocC/Model/Rendering/RenderNode.swift:91`) is a
  `Codable` struct with an explicit `schemaVersion: SemanticVersion` field
  (line 110), currently `0.3.0`, with a documented semver policy (major =
  breaking, minor = additive/optional, patch unused). Its `Codable`
  conformance is hand-written in a dedicated
  `RenderNode/RenderNode+Codable.swift`, fully decoupled from whatever
  internal model produced it.
- An OpenAPI-style JSON Schema already exists for it:
  `Sources/SwiftDocC/SwiftDocC.docc/Resources/RenderNode.spec.json` (also
  `RenderIndex.spec.json`, `IndexingRecords.spec.json`, `ThemeSettings.spec.json`).
- Per-language (Swift/ObjC) variance is handled by `VariantCollection` /
  `VariantOverrides` (`Sources/SwiftDocC/Model/Rendering/Variants/*`): a
  default value plus RFC 6902 JSON-Patch overrides keyed by trait, applied
  lazily rather than by duplicating the whole node per variant. This pattern
  is relevant later (§3.4) as a template for platform-selector variance.

### 2.2 Archive output today

- `.doccarchive` is written by `ConvertFileWritingConsumer`
  (`Sources/DocCCommandLine/Action/Actions/Convert/ConvertFileWritingConsumer.swift`).
  It contains one RenderNode JSON file per topic under `data/`, a navigation
  index (`index/index.json`, a `RenderIndex`), `metadata.json`
  (`BuildMetadata`), `linkable-entities.json`, `link-hierarchy.json`
  (a serialized `PathHierarchy`), optional `documentation-coverage.json` /
  `indexing-records.json` / `assets.json` / `benchmark.json`, and copied
  asset directories.
- **There is no in-repo build step that turns RenderNode JSON into the SPA.**
  The web front end (`swift-docc-render`) is a separate repository. `docc
  convert` writes the JSON above plus a static template directory verbatim;
  the SPA's JS bundle fetches `data/**.json` and `index/index.json` live,
  client-side. Today's "hosting" story is: DocC emits RenderNode JSON, a
  separately-built SPA consumes it at runtime.

### 2.3 Static hosting / flat HTML

- `StaticHostableTransformer`
  (`Sources/DocCCommandLine/Transformers/StaticHostableTransformer.swift`)
  walks `data/**.json` and, for each route, creates a matching
  `/route/index.html` containing the SPA's own `index.html`. This is exposed
  via `docc process-archive transform-for-static-hosting` and as a flag on
  `docc convert`.
- This is a routing trick, not a content transform: RenderNode content is
  unchanged, and pages are still rendered client-side by the same SPA JS
  bundle at every route. It does not "flatten" RenderNode into pre-rendered
  HTML.
- A branch ref in this checkout
  (`dronnqvist/deprecate-transform-for-static-hosting-subcommand`) suggests
  this subcommand may already be under reconsideration — worth confirming
  with maintainers, since it overlaps with what a "flat static HTML" DIF
  output would replace.

### 2.4 Build/conversion pipeline

Documented in
`Sources/SwiftDocC/SwiftDocC.docc/SwiftDocC/CompilerPipeline.md`. Three
phases: **Discovery** (find markup/tutorials/assets/symbol graphs) →
**Analysis & Registration** (`DocumentationContext` builds a `TopicGraph` of
`DocumentationNode`s — the existing in-memory documentation model, distinct
from RenderNode, where curation and link resolution happen) → **Rendering**
(`RenderNodeTranslator` converts each `DocumentationNode` to a `RenderNode`).

### 2.5 Multi-platform symbol merging today

- Within **one** `docc convert` invocation, multiple `.symbols.json` inputs
  for the same module (one per platform) are merged by SymbolKit's
  `GraphCollector` into a `UnifiedSymbolGraph.Symbol` carrying per-platform/
  per-language "selectors" (`SymbolGraphLoader.swift`). This is a **one-shot,
  all-inputs-at-once** operation:
  `SymbolGraphLoader.loadAll()` decodes every input concurrently, feeds all
  of them into a single `GraphCollector`, then calls `finishLoading(...)`
  exactly once
  (`Sources/SwiftDocC/Infrastructure/Symbol Graph/SymbolGraphLoader.swift:55-184`).
  There is no API to feed in one more platform's graph afterward and update
  the result incrementally.
- Worse for our purposes: platform-selector data is **discarded** the moment
  a `DocumentationNode` is constructed from it.
  `DocumentationDataVariants+SymbolGraphSymbol.swift:23,42` filters
  `unifiedSymbol.mixins`/`.names`/`.kind` down to a single
  `guard selector.platform == platformName`. The variant axis DocC actually
  keeps at the `DocumentationNode` level is source **language** (Swift vs.
  Objective-C), not platform.
- Separately, `docc merge`
  (`Sources/DocCCommandLine/Action/Actions/Merge/MergeAction.swift`) combines
  already-built **archives** (not symbol graphs) for **disjoint** modules —
  it explicitly errors on overlapping `data/documentation/<module>` content
  (`validateThatArchivesHaveDisjointData()`, lines 142–196). It also does not
  yet merge the LMDB navigator index or reconcile `link-hierarchy.json` /
  `linkable-entities.json` / `metadata.json` (explicit `// TODO`s at lines
  ~52, ~84). There is **no existing path to merge two archives describing
  the same symbol built for different platforms** — that case is rejected
  today.

### 2.6 Incremental/caching support today

None, beyond within-one-run conveniences. `consumeIncremental(...)` just
streams link summaries during a single build; `ContentCache` and
`context.externalCache` are in-memory caches scoped to one conversion. There
is no cross-build cache, no incremental-rebuild mode, and no build-to-build
diff mechanism. The existing `Diffing/*` machinery
(`RenderNode+Diffable.swift`, `Differences.swift`) computes JSON-Patch
differences between two RenderNode *variants* (e.g. Swift vs. ObjC) for the
`variantOverrides` mechanism — it is not a build-to-build diff tool.

### 2.7 Existing indexes / coverage data

`RenderIndex` (`index/index.json`, its own `schemaVersion` 0.1.2, has a
`merge(_:)` used by `docc merge`), a separate LMDB-backed `NavigatorIndex`
for Xcode's doc viewer (not yet merged by `docc merge`), `linkable-entities.json`
+ `link-hierarchy.json` for cross-archive link resolution
(`ExternalPathHierarchyResolver`), and `documentation-coverage.json` (a flat
array of `CoverageDataEntry`, no schema version). Each artifact is
independently versioned; there is no archive-wide manifest version tying them
together, and there is no SQLite or other embedded database anywhere in the
codebase today.

### 2.8 Why the existing in-memory model (`TopicGraph`/`DocumentationNode`) can't just be persisted as-is

We specifically investigated whether the DIF could just be "the existing
`TopicGraph`/`DocumentationNode` model, made `Codable`." It falls down in four
concrete ways:

1. **Non-serializable in-memory types.** `DocumentationNode.markup: any
   Markup` (`DocumentationNode.swift:48`) is backed by swift-markdown's
   `RawMarkup: ManagedBuffer<...>` — a raw, pointer-backed reference tree,
   not designed for serialization. `semantic: Semantic!` (line 51) is an
   `open class` explicitly mutated in place ("Symbol is a by-reference type
   so we're updating the original `semantic` property instance," line 384).
   Neither has a Codable story, unlike RenderNode's dedicated
   `+Codable.swift`.
2. **Build-machine-local state baked into node identity.**
   `TopicGraph.Node.ContentLocation` (`TopicGraph.swift:29-39`) and
   `DocumentationNode.DocumentationChunk.Source` both embed absolute
   filesystem `URL`s. A portable, shareable/mergeable format can't carry
   another machine's absolute paths.
3. **One-shot symbol unification that discards platform data** — see §2.5.
   This is the direct blocker for "expand a symbol's availability from
   another platform build."
4. **Curation is a whole-graph, multi-pass algorithm.**
   `DocumentationContext.register()`
   (`Sources/SwiftDocC/Infrastructure/DocumentationContext.swift`, ~lines
   2018–2260) runs, in strict order over the *entire* graph: register all
   symbols → first manual-curation crawl → `autoCurateSymbolsInTopicGraph()`
   (which needs to know, graph-wide, what was *not* manually curated) →
   second crawl → `autoCurateArticles` + third crawl →
   `removeUnneededAutomaticCuration(...)` (a retroactive fixup that can only
   run once the whole graph's curation is known). `AutomaticCuration.topics(
   for:...)` queries the fully-built `PathHierarchy` and
   `context.topicGraph.reverseEdges` — it needs global state, not just the
   node in question. This is direct evidence that "recompute only the
   affected subgraph" is hard with today's algorithm shape (see §3.5).

Not everything is a dead end, though:

- `TopicGraph` edges are stored as `[ResolvedTopicReference: [ResolvedTopicReference]]`
  (`TopicGraph.swift:130-132`) — value-keyed dictionaries, not object
  pointers. The graph-shaped data itself isn't inherently cycle-prone or
  Codable-hostile; the class-based `Node` is used for identity/mutation
  convenience, not to build a reference-cyclic structure.
- `VariantCollection`'s pattern (default value + keyed JSON-Patch overrides,
  applied lazily instead of duplicating whole nodes) is a legitimate
  architectural precedent for representing platform-selector variance
  losslessly in a new schema — it already solves the general shape of this
  problem, just for language variance today instead of platform variance.

## 3. Decisions made so far

These are working decisions for this doc, reached by walking through the
tradeoffs above. They're not final — anything here can and should be
challenged on the Forums thread — but they're specific enough to design
against rather than being left as pure brainstorming.

### 3.1 Scope: a unifying redesign, not a single-pain-point fix

The three motivations (new presentation targets, queryability, multi-platform
incremental builds) are treated as roughly equal drivers, not sequenced as
"solve one, defer the others." The design should hold together as one format
serving all three from the outset, even if delivery is phased (§3.6).

### 3.2 Additive, non-breaking; DIF as the upstream source of truth

DIF ships as a new artifact alongside today's pipeline — nothing existing
breaks, adoption is opt-in. In practice this also settles the "upstream vs.
evolve-`.doccarchive`-in-place" question we initially left open: DIF is
positioned as its own serialized, standalone artifact, from which one build
step can produce today's `.doccarchive` (RenderNode JSON + SPA) exactly as it
exists now. Today's archive becomes one specific *output* of DIF, not the
thing being redesigned.

### 3.3 Cross-platform merge happens pre-RenderNode, incrementally

Merging a new platform's contribution to a symbol (e.g. adding tvOS
availability to an iOS+macOS build) happens at the symbol/topic-graph level,
*before* RenderNode translation and *before* curation — not by reconciling
already-rendered RenderNode content from independently-built archives
afterward.

Rationale: curation (Topics groups, See Also, whether something is curated
at all) is decided using a symbol's *complete* availability picture. If two
platform builds decide curation independently and are reconciled only after
rendering, there's no single source of truth to resolve a disagreement from,
and content differences deeper than a platform list (a deprecation message,
a differently-available overload) are much harder to splice post-render than
pre-render. This generalizes today's `UnifiedSymbolGraph` selector merge
(§2.5) to be incremental and persistable, rather than one-shot and
in-memory-only.

This is a materially bigger scope than "just persist RenderNode": the format
needs to retain pre-render, selector-level content (per-platform
declarations, availability, doc comments), not only final rendered pages.

Archive-level combination of genuinely *disjoint* modules (what `docc merge`
does today) is a different use case from this decision, which only concerns
merging contributions to the *same* symbol. It does **not**, however, stay
out of DIF's scope indefinitely — §3.22 revisits it once the per-module
provenance work (§3.18–§3.21) makes clear that disjoint-module combination
needs its own DIF-native answer, distinct from this same-symbol merge.

### 3.4 New, purpose-built schema — not a serialization of `TopicGraph`/`DocumentationNode`

Per the evidence in §2.8, the DIF schema is designed independently of DocC's
internal in-memory model, the same way `RenderNode` already is: explicit
`schemaVersion`, hand-written `Codable`, decoupled from whatever internal
type produces or consumes it. Internal refactors to `DocumentationContext` or
`TopicGraph` should not be format-breaking changes.

`VariantCollection`'s default-value-plus-JSON-Patch-overrides pattern is
adopted as a design template (not the literal type) for representing
per-platform selector variance losslessly — this is the mechanism that lets
DIF avoid discarding other platforms' data the way
`DocumentationDataVariants+SymbolGraphSymbol.swift`'s platform filter does
today.

### 3.5 Incremental scope: phase 1 is incremental content, full curation recompute

Given curation is a whole-graph, multi-pass algorithm today (§2.8, point 4),
phase 1 commits to something honest and achievable: adding a platform's
contribution avoids re-parsing/re-rendering content that didn't change, but
still re-runs curation (manual crawl → auto-curate → fixup) over the whole
graph on every update. That's cheap relative to symbol-graph parsing and
RenderNode translation, so it's a real efficiency win even without touching
curation's algorithm shape.

Redesigning curation itself to be locally/incrementally recomputable (only
reprocessing the affected subgraph) is explicitly left as a door held open
for a later phase, not committed to now — it's a bigger algorithmic lift and
shouldn't block getting phase 1 shipped.

### 3.6 Storage: SQLite as the primary store

A single-file SQLite database is adopted as the primary store for DIF, per
David's original suggestion — tables for symbols/selectors, topic-graph
edges, curation state, and render-ready content. This gets transactional
incremental updates without building a bespoke storage engine, and keeps
distribution simple (one file). The tradeoff, to be explicit about on the
Forums thread: this is a new runtime dependency (SQLite) for DocC, and
diffs/merges become database operations rather than text/JSON diffs — code
review of a DIF change won't look like a JSON diff the way reviewing a
RenderNode change does today. Whether that tradeoff needs mitigating (e.g. a
documented way to export a human-diffable view) is an open question (§4).

SQLite here is a storage-engine choice, not a claim about the interface
consumers use. Revisited in §3.12: the query surface DocC actually wants —
retrieving sets of nodes/symbols from the trees, diffing, coverage, curation
issues — is a **programmatic query/traversal API**, not hand-written SQL
against the tables. SQLite gives that API a transactional, indexed engine to
run on; it isn't itself the exposed contract.

Same shape, second file: §3.22 introduces a **collection** artifact — a
second, single-file SQLite database, one level up, composed from multiple
module DIFs rather than written directly by a build. It adds a `sources`
table (module identity/provenance, §3.18–§3.21) and hosts the spine (§3.9),
but otherwise reuses this section's rationale unchanged.

### 3.7 Working name: "DocC Interchange Format" (DIF)

Placeholder, adopted specifically to stop colliding with `.doccarchive` in
this doc's own language. Not meant to be the final name — see §4.

### 3.8 Phase-1 output targets: `.doccarchive` (byte-identical) + ePub

Phase 1 commits to building two concrete outputs from DIF, not just one:

- **Today's `.doccarchive`**, and to a strong, testable bar: byte-for-byte
  identical to what the current direct pipeline produces (same RenderNode
  JSON, same index files). This means `swift-docc-render` and Xcode's LMDB
  navigator need **zero changes** for phase 1 — they keep consuming exactly
  what they do today. It's also a claim that's mechanically checkable in CI
  (diff the two outputs), which matters for a Forums proposal.
- **ePub**, as the proof-of-concept *new* output — chosen deliberately over
  flat static HTML, because ePub is structurally different from a web
  presentation (linear, offline, non-browser) rather than web-adjacent, so it
  exercises DIF's generality rather than just reproducing today's routing
  trick (§2.3) with different plumbing.

Flat static HTML is explicitly *not* a phase-1 target. That means the
`transform-for-static-hosting` subcommand and its possible deprecation
(§2.3) are unaffected by phase 1 and stay an open question (§4) rather than
something this proposal resolves.

### 3.9 The spine: an authored, persisted reading/structure order

Building ePub surfaced a gap that turned out to be bigger than ePub itself:
today, a page hierarchy for a *single* module is ordered by curation (Topics
groups), but a **combined/merged archive** (`docc merge`, §2.5) has no
unified, authored order across its constituent modules — merge only
concatenates disjoint module trees and optionally synthesizes a landing page.
There's no equivalent of an ePub "spine" today, for ePub or for combined
archives.

Decision: DIF persists an explicit, **authored** spine/sequence as
first-class data — not derived at build time from the topic graph — because
the goal is a stable, consistent, inspectable order across combined archives
and ePub alike, not an order that can silently shift if a derivation
algorithm changes between builds.

To keep this non-breaking (§3.2), the spine is an **optional override**:
when an author provides one, it's used as-is; when absent, DIF derives a
default order from existing curation (Topics groups, module order) the same
way builds work today. Existing catalogs need no changes to keep working.

Scope: the spine's primary job is archive-wide/cross-module structure
(fixing the combined-archive gap) and top-level ePub reading order.
Within a single module, existing Topics-group curation continues to
determine order; the spine composes on top of that at the archive-wide
level, it doesn't replace it. Concretely, per §3.22, "archive-wide" means the
spine is data owned by the **collection** artifact, not by any individual
module's DIF — a single-module DIF has no archive to order across, and a
single module's ePub reading order is just its own Topics-group order (this
section's "single module" case above).

The authoring surface for the spine itself — a new directive, a new
manifest file, or an extension of existing curation syntax — is explicitly
*not* designed here; it's a follow-on question (§4), since it's really a new
curation feature in its own right, not a property of the storage format.

### 3.10 Versioning: one top-level DIF manifest version

DIF has a single, explicit top-level schema/manifest version, distinct from
(and coordinating) whatever versioned sub-schemas exist underneath —
matching the discipline RenderNode already applies to itself (§2.1), but
applied one level up so there's one check for "can I even open this DIF
file" rather than needing to reconcile several independently-versioned
pieces (as `.doccarchive` requires today, per §2.7).

### 3.11 Diff: both structural and semantic, semantic derived from structural

"Diff" means two things, not one, and the second is built from the first:

- A **structural diff** over DIF's actual stored content (row/table-level
  changes) — used for merge-conflict detection and to decide what an
  incremental rebuild needs to redo. Not meant to be human-readable on its
  own.
- A **semantic diff** — a human/CI-reviewable summary in documentation
  terms (symbols added/removed, availability changed, content changed,
  curation/spine moved) — derived from the structural diff rather than
  computed independently. This is the one meant for PR checks, changelogs,
  and "what changed in this build" review.

### 3.12 v1 query catalog

Phase 1 commits to four concrete capabilities, all grounded in
existing-but-currently-separate tooling (§2.7) becoming live operations
against DIF instead of bespoke build-time passes — but "query" here means a
**programmatic query/traversal API** (retrieve sets of nodes/symbols from the
trees, diff them, compute stats over them), not hand-written SQL exposed to
callers (§3.6). Three of the four fit that shape directly; the fourth
(full-text search) doesn't, and gets a different answer:

- **Curation gaps** — symbols that exist but aren't reachable from any
  Topics group or the landing page (today's `documentation-coverage.json`
  use case, live instead of a build-time report).
- **Documentation coverage stats** — percentage of public symbols with a
  doc comment, abstract, discussion content, etc. (today's
  `CoverageDataEntry`, queryable). Confirmed by reading
  `CoverageDataEntry.init(documentationNode:renderNode:context:)`
  (`CoverageDataEntry.swift:186-220`): every input it needs — title, kind,
  abstract presence, availability, per-parameter and per-member documented/
  total ratios (`extractChildStats`/`extractFunctionSignatureStats`, lines
  361-435) — comes from core pre-render content (§3.3/§3.4) plus curation
  state (`context.manuallyCuratedReferences`, the same state §3.12's
  "curation gaps" query already needs). One field, `hasCodeListing`
  (line 202), is computed by walking rendered `RenderNode.primaryContentSections`
  (lines 159-176) rather than pre-render markup — so this specific query also
  depends on §3.16's cached render-ready content, not core content alone.
  That's a second, independent justification for §3.16's retention decision,
  beyond output-build performance. Detail level (brief/detailed) and kind
  filtering (`DocumentationCoverageOptions.KindFilterOptions`, explicitly
  documented as "not meant to be persisted between runs",
  `DocumentationCoverageOptions.swift:71`) are query-time parameters, not
  stored data — same pattern as hosting base path (§3.2/§3.8).
- **Link graph traversal** — what links to this symbol, what a page
  references, orphaned pages (building on today's `link-hierarchy.json` /
  `linkable-entities.json`).
- **Full-text search — an export, not a built-in query.** DIF doesn't commit
  to being a search engine (no SQLite FTS5, no built-in ranking/relevance).
  It commits to producing a **corpus export** — per page/symbol: reference,
  title, kind, and plaintext content (abstract, discussion, declaration,
  parameter docs, stripped of markup) — matching the shape of location/kind
  data today's `IndexingRecord` already tracks (`IndexingRecord.swift:14-53`),
  generalized to full text. Building an actual search index from that export
  (SQLite FTS5, a JS-side index for the SPA, an external search service) is a
  **post-DIF** concern, the same shape as markdown output, hosting base path,
  and the version-picker (§3.20) — DIF supplies the content, something
  downstream builds the feature. The export's exact shape isn't designed
  here; it's a small, separate piece of follow-on work.

Diagnostics overlap substantially with this catalog rather than being a
separate concern — see §3.23.

### 3.13 Symbol identity: reuse `identifier.precise`, surface non-matches as diagnostics

Rather than inventing a new merge key, DIF reuses DocC's existing, load-bearing
symbol-identity mechanism. SymbolKit's entire multi-graph merge pipeline
(`GraphCollector` → `UnifiedSymbolGraph.mergeGraph` →
`UnifiedSymbol.mergeSymbol`) already reduces every "is this the same symbol"
decision to plain string equality on `SymbolGraph.Symbol.identifier.precise`
(a compiler-emitted, mangled/USR-like string), enforced with a
`precondition` (`Sources/SymbolKit/UnifiedSymbolGraph/UnifiedSymbol.swift:119-120`).
`UnifiedSymbolGraph.symbols` is itself keyed by this string
(`Sources/SymbolKit/UnifiedSymbolGraph/UnifiedSymbolGraph.swift:407-416`).
Reusing it for DIF's cross-build merge (§3.3) maximizes parity with existing
DocC merge semantics.

Two real gaps informed how DIF handles it, though — SymbolKit only promises
precise identifiers are unique *within a module*, with no documented
guarantee of stability across separate compilations (different platform/SDK/
architecture) for "the same" declaration; and today's pipeline already has a
precedent for silently dropping mismatched data rather than surfacing it
(`Selector` is keyed by `(interfaceLanguage, platform name)` with no
architecture axis, so an arch collision silently keeps one side's data and
drops the other —
`Sources/SymbolKit/UnifiedSymbolGraph/UnifiedSymbol.swift:129-135`).

Decision: DIF matches on `identifier.precise` equality only — no fallback
heuristic matching by path/signature — but when a platform's contribution
doesn't match any existing precise identifier already in DIF, that's a
visible, queryable diagnostic (unified with content diagnostics in §3.23),
not a silent drop. A human can then judge
whether it's genuinely a new symbol or a compiler-identity mismatch worth
investigating.

### 3.14 Store topology: per-build DIF, merged afterward

Each platform build produces its own standalone DIF file, independently and
without coordination. A separate, explicit merge operation combines two or
more of these into one, using the identity mechanism in §3.13. This was
chosen over a single shared DIF that platform builds write into directly,
because SQLite supports one writer at a time even in WAL mode — a shared
file would require platform builds (potentially on different machines, at
different times, or in parallel CI jobs) to serialize access through some
coordination point, reintroducing the shared-mutable-state problem the
per-build approach avoids entirely. It also matches the original motivation
directly: separate platform builds are expected to run separately.

### 3.15 Portability: relative-to-bundle paths only

Per §2.8's finding that today's in-memory model leaks absolute build-machine
file paths into node identity (`TopicGraph.Node.ContentLocation`,
`DocumentationNode.DocumentationChunk.Source`), DIF stores source locations
as paths relative to the documentation bundle root, never absolute. This
keeps "where do I go fix this" diagnostic information useful (unlike
dropping paths entirely) while staying portable across machines, since the
bundle's internal layout is part of the same source checkout regardless of
which machine built it.

### 3.16 Retention: core content plus cached render-ready output

Beyond the core pre-render content DIF already commits to (§3.4), it also
retains cached render-ready output (RenderNode-equivalent content) per
symbol/page. Without this, every output build (rebuilding `.doccarchive`,
building ePub) would re-translate unchanged content from scratch every time
— a weaker incremental story than §3.5 implies, since the incrementality
would only apply to merges, not to repeated output builds. This does mean
DIF needs cache-invalidation logic tied to what selector data actually
changed, and a larger storage footprint than pre-render content alone.
Raw symbol-graph JSON is *not* retained — it wasn't motivated by any
concrete requirement here, and would add storage/complexity for a
future-reprocessing scenario that isn't otherwise in scope.

### 3.17 Atomicity: whole-operation transactions

Each build and each merge is wrapped in a single transaction, rather than
committing at phase or per-symbol granularity. This leans on SQLite's ACID
guarantees to get "no reader ever sees a partially-written DIF" for free — a
DIF file on disk is always either the previous complete state or the new
complete state, never something in between. That matters because DIF is
meant to be diffed, merged, and queried live (§3.11, §3.12); finer-grained
commits would require inventing an explicit "build complete" status marker
that every consumer would need to check, since e.g. a coverage-stats query
mid-build could otherwise report a number that reflects "how much has been
processed so far" rather than "how much is actually documented." Many small
commits are also a well-known SQLite performance anti-pattern independent of
this tradeoff (each commit forces a journal/fsync flush by default).
The cost: a crash late in a large build loses all progress on that build,
and a retry starts over. This is judged acceptable because the store-topology
decision (§3.14) already scopes a crash's blast radius to just the one
platform build in progress — it can't corrupt or partially affect any other
build or the merged result. Per-phase transactions (resuming near a crash
point rather than from zero) remain a fallback if a specific platform build
turns out to be large/slow/fragile enough in practice that losing all
progress on failure becomes a real operational cost, rather than the
theoretical one it is today.

### 3.18 Source provenance: three use cases, and splitting hosting template from revision ref

Grilling on "where does the hosting-location metadata go" surfaced three distinct
consumers, not one:

1. An **edit link** on an article (e.g. "Edit this page on GitHub") pointing at
   the catalog's markdown/tutorial source.
2. A **view-source link** on a symbol, reassembled from the local checkout and
   the symbol's parsed source location.
3. Enough information to **diff two DIFs with different commit histories** and
   present, for each side, a working link back to the hosting service at that
   commit.

Only use case 2 exists today, via `SourceRepository`
(`Sources/SwiftDocC/SourceRepository/SourceRepository.swift`).
`SourceRepository.format(sourceFileURL:lineNumber:)` (lines 44-53) strips the
local `checkoutPath` prefix off an absolute source file URL and appends the
remainder to `sourceServiceBaseURL`. Two things this reveals:

- **The relative path is rooted at the checkout, not the bundle.** `checkoutPath`
  is the repository root. §3.15 says DIF stores paths "relative to the
  documentation bundle root" — but for a typical package layout
  (`Sources/Module/Module.docc/`), the catalog is nested inside the checkout,
  not at its root. A symbol's Swift source file and an article's markdown file
  are naturally relative to two different roots that don't coincide. Sharing
  one URL-construction routine across use cases 1 and 2 requires resolving
  which root DIF actually stores against, or storing the bundle's own path
  within the checkout so both are derivable. Left open below.
- **The revision ref isn't a separate field — it's text baked into a URL.**
  `--source-service-base-url`'s documented example is
  `https://github.com/my-org/my-repo/blob/main`
  (`SourceRepositoryArguments.swift:42-51`); the ref (`main`) is an opaque URL
  path segment, not a structured value. That's sufficient for one-shot
  view-source generation, but it blocks use case 3: there's no way to tell
  whether two stored base-URL strings differ because the ref changed or
  because the hosting service changed, and no way to construct a hosting
  provider's own "compare between two commits" link from an already-assembled
  opaque string.

Use case 1 (edit links) has no existing mechanism at all — verified, nothing
matching an edit-link pattern exists anywhere in the codebase today. It's new
plumbing, not an extension of `SourceRepository`.

Decision: DIF stores source provenance as two separate structured fields,
not one URL string:

- A **hosting template** (service + base URL) — stable, config-like, treated
  as a stored default with an optional per-output-build override, the same
  shape §3.9 already uses for the spine.
- A **revision ref** (commit/branch/tag) — per-build provenance, always
  stored, consumed directly by §3.11's semantic diff to attribute changes to
  a revision range and to construct comparison links back to the hosting
  provider for use case 3.

Ref and commit are **always required**, for every source, regardless of how
it was obtained — not optional for some source kinds. A build-manifest format
already in production use for combining multiple documentation sources (a
sibling project, not this repo) has a `sources` array with `type: "git"`,
`"archive"`, or `"local"` entries; the `"archive"` entries (a prebuilt archive
downloaded from a URL) are the one case that's missing ref/commit today, and
that's judged a gap in that manifest to fix, not a precedent for DIF to
tolerate. An archive source is conceptually already starting from a DIF (or
DIF-equivalent) artifact — one that was itself built from a specific ref and
commit — so that provenance should carry forward, not get dropped at the point
of packaging or downloading. `type` remains useful as descriptive metadata
(how the ref/commit were obtained: direct git introspection, a local
checkout, or inherited from an already-built artifact), but it doesn't gate
whether ref/commit exist.

Two points carried to §4 as open questions rather than resolved here: which
root the stored relative path is computed against (bundle vs. checkout), and
whether the hosting template/revision ref pair is stored once per DIF/build or
once per module (relevant if one DIF can span multiple modules from different
repos or commits, per the combined-archive case in §2.5).

### 3.19 Canonical docs path: stored per module/package, inert until a static-HTML output exists

Use case: an external/SEO-style canonical URL per module/package — so that if
a module's docs get built and hosted in more than one place (mirrors, PR
previews, staging, a vendored copy inside another site), consumers and search
engines have one declared authoritative location.

No existing mechanism does this today — verified, no canonical-URL/SEO
meta-tag field exists in `RenderMetadata` or anywhere in the current output
pipeline. It's also a different concept from `RenderReferenceStore.canonicalPath`
(§2.7/§3.4 territory — the shortest curated *navigation* path to a page), which
already uses the word "canonical" for something else; naming will need to
avoid that collision.

Neither phase-1 output (§3.8) is a natural consumer:

- `.doccarchive`'s SPA serves one identical static `index.html` shell at every
  route (§2.2, §2.3) — there's no per-page `<head>` today, and adding one
  would conflict with §3.8's byte-for-byte compatibility bar.
- ePub isn't crawled by search engines, so a canonical tag has no purpose
  there.

What *would* consume it: `Sources/DocCHTML` (e.g.
`MarkdownRenderer.swift:24-30`'s `RenderGoal.conciseness`, explicitly
documented as "optimizing for consumption by machines such as SEO indexers or
LLMs"), tied to the `experimental-html-for-development` flag
(`Convert.swift:650-667`). This is real, in-progress work toward an eventual
flat/static HTML output, not cited anywhere in this doc until now, and it
bears directly on the already-open "`transform-for-static-hosting`'s fate"
question in §4.

Decision: DIF stores the canonical URL as a per-module/package field — same
shape as §3.18's hosting template (stored default, optional per-output-build
override, since a staging or mirror build still wants its canonical tag
pointing at production, not at itself). Mechanically it's a base URL plus each
page's own relative path, same as hosting base path, but persisted rather than
supplied fresh, for the same reason the hosting template is (§3.18).

Consumption is explicitly deferred: the field is stored now, at negligible
cost, but stays inert until a real static-HTML output (`DocCHTML` or
successor) exists to render it. That output's scoping is left to §4's existing
open question rather than decided here. This field joins module version and
§3.18's hosting template/revision ref as per-module identity metadata; all
three share the same open granularity question (per-module vs. per-DIF/build)
in §4.

### 3.20 Module version: prefer symbol-graph data, with an optional `docc convert` override

Use cases: display ("MyFramework 2.3.1" on generated pages), human-readable
labeling for §3.11's semantic diff ("what changed between 2.2 and 2.3"), and a
post-DIF marker that a downstream version-picker can use to offer navigation
to other available versions — itself a post-DIF/output-build concern, likely
composed with §3.18's hosting template and §3.19's canonical URL (e.g. into a
versioned path segment), not designed further here.

Confirmed: `SymbolGraph.Module.version: SemanticVersion?` already exists
(`swift-docc-symbolkit/Sources/SymbolKit/SymbolGraph/Module.swift:26`,
"the semantic version of the module, if available") and survives into
`UnifiedSymbolGraph.moduleData` (`UnifiedSymbolGraph.swift:65,405`), but
nothing in DocC reads or propagates it today — an existing, unused placeholder,
not a new field to invent.

Decision: lean on the symbol-graph-provided value as the primary source, since
it requires no new authoring surface when the compiler populates it. Because
that's documented as "if available" and isn't reliably populated in practice,
`docc convert` also gains a new, optional CLI option to inject/set a semantic
version for the package/module being built, so version data doesn't depend
entirely on compiler support. When explicitly supplied, the CLI value wins
over the symbol-graph value — but a disagreement between the two is still
surfaced as a diagnostic rather than silently overridden, consistent with
§3.13's non-silent-drop philosophy.

That same philosophy applies to merge, at two separate points: within one
`docc convert` invocation, multiple platform-input symbol graphs for one
module (§2.5) could each carry a different (or absent) `Module.version`; and
separately, DIF's own later cross-build merge (§3.13/§3.14) could combine two
platform builds that declare different versions. Both cases should surface a
diagnostic rather than silently pick one side, the same as §3.18 already
decided for mismatched git commits during merge.

Granularity: stored per module/package — the third field (after §3.18's
hosting template/revision ref and §3.19's canonical URL) to want this same
keying. Resolved below, in §3.21, once build time closes out the pattern.

### 3.21 Build time: per-source, retained through merge, with a derived "last updated"

No existing archive-wide mechanism does this today — the only timestamp
anywhere in the pipeline is `Benchmark`/`BenchmarkResults`'
(`Sources/SwiftDocC/Benchmark/Benchmark.swift:37`), which is opt-in
performance-measurement data, not archive metadata.

This falls out of decisions already made rather than requiring a new one.
§3.14 already makes DIF per-source-build, merged afterward; §3.17 already
gives each of those builds exactly one atomic-transaction timestamp. So a
combined/merged DIF should retain one build time per contributing source —
the same way it retains each source's ref and commit (§3.18) — rather than
collapse to one flat value for the whole combined build. "Last updated" is
then a derived value (`max()` over that retained set), not a stored fact of
its own.

Decision: `build_time` becomes a fourth field on each source record, next to
`type`, `ref`, and `commit` (§3.18). DIF derives a "last updated" summary as
the maximum across all sources, and exports that summary — together with the
full per-source list — as a side-car manifest alongside the SQLite file, so
it's cheaply readable without querying the store. This also answers §3.6's
still-open "documented way to export a human-diffable view" question, and its
shape can draw directly from the build-manifest format already validated in
production for combining multiple documentation sources.

Granularity, resolved: hosting template, revision ref, module version,
canonical URL, and build time are all stored **per source/module** — one
metadata record per module, not one value for the whole DIF/build. Real
evidence for "per module" over "per build": a production build-manifest for
one combined build genuinely spans ~20 distinct sources with independently
varying commits. The one deliberate exception is the hosting template
specifically, which §3.18 already treats as a stored default *with* an
optional per-output-build override — a documented exception, not a
contradiction. §3.22 works out exactly where that per-module record lives.

### 3.22 A second artifact: the DIF collection, composed from module DIFs

§3.3 scopes merge to one module's platform-build contributions, matched by
symbol identity (§3.13). But §3.9's spine and §3.18–§3.21's per-module
provenance were both motivated and validated by a genuinely different case:
combining *disjoint* modules/packages into one site — the case §3.3
explicitly excluded. Confirmed directly: `MergeAction.perform()`
(`MergeAction.swift:37-98`) copies already-rendered `data/**` directories
between archives and merges only `RenderIndex`, with `// TODO`s for
`link-hierarchy.json`/`linkable-entities.json`/`metadata.json` (lines 52,
84) — a post-render file-copy operation, structurally incapable of giving
disjoint-module combination any of DIF's pre-render, queryable, incremental
properties. Leaving disjoint-module combination on today's `docc merge`
would mean §1's "directly queryable... across the whole set" motivation
never actually applies to a real multi-package site, only to a single
module.

This resolves as two levels of the same pattern, not a scope change to §3.3:

- **Level 1 — inside one module's DIF (§3.14, unchanged).** Platform builds
  of the *same* module merge via §3.13. Ref/commit are *expected to match*
  here (same source, different platform compiles) — a mismatch is the
  diagnostic signal (§3.18). Build time genuinely varies per platform build,
  so it's retained per contributing build and resolved to one per-module
  "last updated" (§3.21). Level 1 always resolves to **one summary record
  per module**.
- **Level 2 — a collection spanning N disjoint modules.** The production
  build-manifest's `sources` array (20 packages, not 20 platform builds of
  one package) is this level: one Level-1 summary record per constituent
  module.

Why Level 2 needs its own artifact rather than a bigger shared DIF: disjoint
packages are built independently — different repos, different refs,
different schedules, confirmed directly by that manifest. A single DIF
spanning the whole site would reintroduce exactly the single-writer
coordination problem §3.14 already ruled out for platform builds, one level
up. So the same reasoning that produced "per-build DIF, merged afterward"
produces "per-module DIF, composed afterward" here — a second, distinct
operation, not an expansion of §3.3's merge.

Decision: a **collection** is a second, single-file SQLite database (§3.6),
built by a **compose** operation that ingests N independently-built module
DIFs. This isn't a live federation (no cross-file `ATTACH` at query time) —
compose copies each module's content into the collection's own tables, so
the collection is self-contained and queryable on its own, matching §3.6's
one-file simplicity. Composing is a single writer reading N finished inputs,
the same shape as §3.14's merge — it does not reintroduce the concurrent-
writer problem that ruled out a shared DIF.

The collection adds a `sources` table, one row per module, columns:
`module_id`, `type`, `ref`, `commit`, `version`, `hosting_template`,
`canonical_url`, `build_time` (that module's own resolved Level-1 summary),
plus two columns Level 1 didn't need:

- **`ingested_at`** — when the collection last pulled this module in,
  distinct from when the module itself was built. Without this, compose has
  no way to tell "this module's DIF is unchanged since last ingestion" from
  "it changed," which is what makes composing incremental rather than a full
  rebuild every time (§3.5's incrementality argument, one level up).
- **`ingested_at`** — when the collection last pulled this module in,
  distinct from when the module itself was built. Without this, compose has
  no way to tell "this module's DIF is unchanged since last ingestion" from
  "it changed," which is what makes composing incremental rather than a full
  rebuild every time (§3.5's incrementality argument, one level up).
- **`content_hash`** — resolved: a hash over the module DIF's own tables,
  computed once by the module build itself at the end of its §3.17
  transaction, stored as part of that module's Level-1 summary record. This
  is what compose actually checks for staleness — not `ref`/`commit` (the
  same commit can legitimately produce different DIF content across a DocC
  version bump or a re-render) and not `build_time` (fragile against clock
  skew, and a rebuild with no real changes shouldn't count as stale).
  `ref`/`commit`/`version`/`build_time` keep their existing jobs — display,
  diff attribution, human-readable labeling (§3.18/§3.20/§3.21) — `content_hash`
  exists solely for compose's incremental-ingestion decision.

Two existing mechanisms are reused as-is, not reinvented:

- **§3.17's atomicity** applies to compose directly: one whole-operation
  transaction, same ACID guarantee, same rationale.
- **§3.11's structural/semantic diff** applies between two collection states
  the same way it applies between two module DIFs — "what changed in the
  whole site between build A and build B" becomes a diff over the `sources`
  table (modules added/removed/updated) plus each updated module's own
  Level-1 content diff. No new diff mechanism, just a second scope to run
  the existing one at.

The side-car export manifest proposed in §3.21 still makes sense here, now
explicitly as a cheap projection of the `sources` table (closing §3.6's
human-diffable-export question), not the primary source of truth — the table
is; the JSON is a view of it.

Left open, and not resolved here: whether compose duplicates render-ready
cached content (§3.16) into the collection too (larger collection, but every
output build reads one file) or leaves that cached per module (smaller
collection, but an ePub/`.doccarchive` build spanning the whole site has to
open N files); and whether landing-page synthesis (today's
`MergeAction.LandingPageInfo.synthesize`, `MergeAction.swift:24-34`) becomes
a compose-time concern or stays a downstream, post-DIF output-build concern
like markdown output and hosting base path.

### 3.23 Diagnostics: which ones the query API can compute, which stay build-time-only, and unifying the merge-time ones

Today's diagnostics (`Diagnostic`/`DiagnosticSeverity`,
`Sources/SwiftDocC/Infrastructure/Diagnostics/Diagnostic.swift`,
`DiagnosticSeverity.swift`) have real structure worth preserving, not
reinventing: a three-level severity (`error`/`warning`/`information`,
`Comparable`, with an inclusive `filterLevel` threshold), an opaque
`identifier` plus a `groupIdentifier` that `--Werror`/`--Wwarning` use to
override severity per diagnostic group (`DiagnosticEngine.swift:44-60,174-186`),
and structured `notes`/`solutions`. Confirmed roughly 130 distinct diagnostic
identifiers exist across the codebase today. `DiagnosticEngine` itself is
purely in-process and transient — diagnostics are collected during one build
and dispatched to consumers, never persisted in `.doccarchive`
(`DiagnosticEngine.swift:14-22`). A `--diagnostics-file` flag can export them
as a versioned, `Codable` `DiagnosticFile` (own semver, currently 1.1.0,
`DiagnosticFile.swift:14-27`) — but that's a one-shot build byproduct, not a
re-derivable artifact.

Sampling the ~130 identifiers splits them into two groups that need different
treatment, not one:

- **Parse/syntax-time diagnostics** (e.g. `Directive.UnexpectedCharacter`,
  `Directive.MissingExpectedCharacter`, `DuplicateMetadata`) fire while
  parsing raw catalog markdown/directives, *before* a `DocumentationNode` (and
  therefore a DIF record) exists for that content. These can't be recomputed
  from a persisted DIF after the fact — DIF only ever sees content that
  already parsed successfully. If DIF wants to retain these at all, that's a
  build-provenance-style record attached to a module's build (the same shape
  as the `DiagnosticFile` export, alongside build time and revision ref,
  §3.18/§3.21), not something the query API recomputes.
- **Graph/content-shape diagnostics** (e.g. `CyclicReference`,
  `InvalidDocumentationLink`, `invalidLinkDestination`,
  `DocumentedParameterNotFound`, `DuplicateParameterDocumentation`,
  `DocumentHasNoAbstract`, `DocumentedPossibleValueNotFound`) depend only on
  the finished graph/content state DIF already stores — declarations, doc
  comments, link targets, the topic graph. These genuinely become calls
  against the programmatic query API (§3.12), re-derivable at any time, not
  just at build time. Several already overlap directly with §3.12's existing
  catalog: `CyclicReference` and `InvalidDocumentationLink`/
  `invalidLinkDestination` are link-graph-traversal queries;
  `DocumentHasNoAbstract` and the parameter-completeness diagnostics are
  coverage-stats queries at a finer grain than §3.12 currently spells out.
- **Cross-archive/dependency diagnostics** (`Dependency.NotFound`,
  `Dependency.MissingLinkableEntities`, `Dependency.MissingLinkHierarchy`)
  are about resolving `--dependency` archives for external links — this maps
  onto §3.22's collection/compose layer rather than a single module's DIF.

Decision: DIF's `identifier`/`groupIdentifier`/severity scheme carries over
unchanged from today's `Diagnostic`, so existing user-facing severity
semantics (and existing per-ID `--Werror`/`--Wwarning` configuration) stay
meaningful whether a diagnostic came from a live `docc convert` build or a
later query-API call. Severity-override configuration and `filterLevel`
remain query-time parameters, never stored — the same "post-DIF parameter"
pattern already established for hosting base path (§3.2/§3.8) and coverage's
`KindFilterOptions` (§3.12).

**Unifying the merge-time anomaly diagnostics.** §3.13 (symbol-identifier
mismatch), §3.18 (git-commit mismatch across merged platform builds), and
§3.20 (module-version mismatch) each independently said "surface this as a
diagnostic," without saying what that resolves to. They now do: these are
`Diagnostic` records using this section's same shape (severity, identifier,
groupIdentifier, summary), stored where the merge or compose operation that
detected them ran (a module DIF for §3.13/§3.18/§3.20's platform-build
merges, the collection for a compose-time equivalent), and retrieved through
the same programmatic query API as content diagnostics — not printed once
and discarded, and not a separate diagnostic representation of their own.

## 4. Open questions for the Forums thread

Deliberately left open rather than pre-decided, either because they're
genuinely underdetermined by what we know today, or because they're the kind
of thing that benefits from wider input before committing. (Versioning
strategy, diff semantics, the v1 query catalog, cross-repo scope, and the
compatibility bar were resolved in a follow-up grilling pass and moved to
§3.8–§3.12. Symbol identity, store topology, path portability, retention
scope, and atomicity were resolved in a further pass focused specifically on
requirements/constraints and moved to §3.13–§3.17. What's left below is what's
still genuinely open.)

- **Final naming.** "DIF" is a placeholder. What should the format and its
  file extension actually be called, given `.doccarchive` is already taken?
- **`transform-for-static-hosting`'s fate.** Flat static HTML is explicitly
  not a phase-1 target (§3.8), so the
  `dronnqvist/deprecate-transform-for-static-hosting-subcommand` branch ref
  found in this checkout (§2.3) is unaffected by this proposal. Should a
  *later* phase target flat static HTML as a real pre-rendered-content
  output (superseding today's routing trick), and if so, what's the
  deprecation path for the existing flag/subcommand? Relatedly: `Sources/DocCHTML`
  (§3.19) is already real, in-progress work toward a non-SPA HTML output
  explicitly framed around SEO/LLM consumption — is it the intended successor
  here, and does that change the phase-1/later-phase split? Not resolved here.
- **Phase 2 curation redesign.** §3.5 holds the door open for making
  curation itself incrementally recomputable. Worth scoping now even
  loosely (e.g. what would "affected subgraph" mean for automatic curation's
  currently-global queries), or genuinely deferred until phase 1 ships?
- **Spine authoring surface.** §3.9/§3.22 commit to the spine as persisted,
  collection-level data, but deliberately don't design how an author actually
  writes one — a new directive, a new manifest file alongside the DocC
  catalog, or an extension of existing Topics-group curation syntax? This is
  really a new curation feature in its own right and may deserve its own
  follow-on proposal rather than being decided as a side effect of this one.
- **Migration verification tooling.** §3.8 commits to a byte-for-byte
  compatibility bar for `.doccarchive` built from DIF, checkable by diffing
  outputs in CI — but the specific verification tooling/process for that
  (a one-time compatibility test suite vs. an ongoing CI gate on every
  DIF-related change) isn't designed here.
- **Source-provenance path root.** §3.18 finds that a symbol's view-source
  link is computed relative to the repository checkout root, while §3.15
  stores paths relative to the documentation bundle root — and for a typical
  package layout, those aren't the same root. Does DIF standardize on one
  root for both symbol source and catalog article paths, or store the
  bundle's own path within the checkout so both are derivable?
- **Collection content duplication.** §3.22 leaves open whether compose
  duplicates render-ready cached content (§3.16) into the collection (larger
  file, single-file output builds) or leaves it per module (smaller
  collection, multi-file reads for whole-site output builds).
- **Landing-page synthesis timing.** Today's `docc merge` synthesizes a
  landing page at merge time (`MergeAction.LandingPageInfo.synthesize`).
  Does that become a compose-time concern for the collection (§3.22), or a
  downstream, post-DIF output-build concern like markdown output and hosting
  base path?

## 5. Key source citations (for follow-up verification)

- `Sources/SwiftDocC/Model/Rendering/RenderNode.swift`,
  `RenderNode/RenderNode+Codable.swift`
- `Sources/SwiftDocC/Model/Rendering/Variants/*`
- `Sources/SwiftDocC/Indexing/RenderIndexJSON/RenderIndex.swift`
- `Sources/SwiftDocC/Model/BuildMetadata.swift`
- `Sources/DocCCommandLine/Action/Actions/Convert/ConvertFileWritingConsumer.swift`
- `Sources/DocCCommandLine/Transformers/StaticHostableTransformer.swift`
- `Sources/DocCCommandLine/Action/Actions/Merge/MergeAction.swift`,
  `ArgumentParsing/Subcommands/Merge.swift`
- `Sources/SwiftDocC/Infrastructure/Symbol Graph/SymbolGraphLoader.swift`
- `Sources/SwiftDocC/Model/DocumentationNode.swift`,
  `Sources/SwiftDocC/Semantics/Symbol/DocumentationDataVariants+SymbolGraphSymbol.swift`
- `Sources/SwiftDocC/Infrastructure/Topic Graph/TopicGraph.swift`
- `Sources/SwiftDocC/Infrastructure/DocumentationContext.swift`
- `Sources/SwiftDocC/Infrastructure/Topic Graph/AutomaticCuration.swift`
- `Sources/SwiftDocC/Infrastructure/Link Resolution/ExternalPathHierarchyResolver.swift`
- `Sources/SwiftDocC/SwiftDocC.docc/SwiftDocC/CompilerPipeline.md`
- `Sources/SymbolKit/SymbolGraph/SymbolGraph.swift`,
  `Sources/SymbolKit/SymbolGraph/Symbol/Identifier.swift`
- `Sources/SymbolKit/UnifiedSymbolGraph/UnifiedSymbolGraph.swift`,
  `UnifiedSymbolGraph/UnifiedSymbol.swift`
- `Sources/SymbolKit/SymbolGraph/SymbolGraph+Overloads.swift`
- `Sources/SwiftDocC/Infrastructure/Symbol Graph/ExtendedTypeFormatTransformation.swift`
- `Sources/SwiftDocC/Infrastructure/ContentCache.swift`
- `Sources/SwiftDocC/SourceRepository/SourceRepository.swift`,
  `ArgumentParsing/Options/Source Repository/SourceRepositoryArguments.swift`
- `Sources/DocCHTML/MarkdownRenderer.swift`
- `Sources/SwiftDocC/Benchmark/Benchmark.swift`, `BenchmarkResults.swift`
- `Sources/SwiftDocC/Infrastructure/Workspace/DefaultAvailability.swift`,
  `CatalogDiscoveryOptions.swift`
- `swift-docc-symbolkit/Sources/SymbolKit/SymbolGraph/Module.swift`,
  `UnifiedSymbolGraph/UnifiedSymbolGraph.swift` (checked out as a sibling
  package dependency, not vendored in this repo)
- `Sources/SwiftDocC/Infrastructure/Diagnostics/Diagnostic.swift`,
  `DiagnosticSeverity.swift`, `DiagnosticEngine.swift`, `DiagnosticFile.swift`
- `Sources/SwiftDocC/Infrastructure/CoverageDataEntry.swift`
- `Sources/SwiftDocC/Coverage/DocumentationCoverageOptions.swift`
