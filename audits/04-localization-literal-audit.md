# Localization literal audit

Issue #106 reviewed every Swift source under `Islet/`. The integrated stack contains 172 app Swift
files, including `Support/Localization.swift`.

Visible labels, help, errors, confirmation copy, notifications and accessibility text now use
SwiftUI's localization-aware literal initializers, `LocalizedStringResource`, or
`String(localized:)`. `Localizable.xcstrings` is generated from the compiler's 173 stringsdata
files, not from a sample of screens. The catalog has an `en-XA` pseudolocalization for every key.

The remaining string literals outside the catalog are intentional:

- Stable identifiers and persistence keys: activity and event IDs, Defaults keys, bundle IDs,
  notification names, Keychain service names and migration-domain names.
- Platform values: SF Symbol names, IOKit property names, pasteboard types, framework status values,
  Info.plist keys and colour hex values.
- Protocol and transport data: HTTP methods and headers, URL schemes and paths, Pulse/T3 JSON keys,
  operation values, wire-state values and schema field names. Localizing these would break peers.
- File and process data: executable paths, launch arguments, filesystem paths, extensions and
  provider process names.
- Format and identity strings: registry IDs, checksums, UUID-based IDs, fixed media-clock output,
  log messages and copied diagnostic serialization. These are machine-readable or support-facing.
- Search synonyms: hidden Settings and Quick Actions keyword indexes remain English source data.
  They are not rendered. Localized visible titles are also indexed, so translated UI remains
  searchable.
- Runtime content: calendar/reminder titles, media metadata, device names, Focus names, filenames,
  T3 project/agent data and Pulse provider payload text pass through verbatim. Only Islet-authored
  surrounding phrases are localized.

`LocalizationTests` guards the boundary. It checks catalog JSON and key coverage, English plural
rules, `en-XA` completeness and expansion, placeholder preservation, locale-sensitive formatting,
provider-content passthrough and the full Swift-file inventory.

`TallTierHostingTests` also lays out representative compact-marquee, tall activity, Settings,
onboarding, alert/error and accessibility-heavy surfaces under `en-XA`. It asserts each ideal size
fits its supported production bounds and that the hosted layout is unambiguous. SwiftUI does not
expose per-glyph truncation state for its native text renderer, so final pixel-level and VoiceOver
inspection remains a manual QA limit; the automated pass does not claim to prove those properties.

Run `Scripts/verify-localization-catalog.sh` after changing visible copy. It enables compiler string
extraction in a temporary DerivedData directory, synchronizes a temporary catalog, and fails if a
SwiftUI or explicit localization key lacks checked-in `en-XA` coverage or if an obsolete catalog
entry is marked stale.
