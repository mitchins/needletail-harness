import Foundation

/// Scalar-level containment (C5.3 oracle support).
///
/// `String.contains(_:)` with a lone invisible scalar (Cf/Cc) is
/// platform-divergent: macOS Foundation returns false even when the
/// scalar is present (grapheme-aware search treats it as invisible),
/// while Linux swift-corelibs finds it. A byte-exact security oracle
/// must therefore assert at `unicodeScalars` level on both platforms —
/// a `!contains` on a lone Cf would FALSE-PASS on mac, hiding a live
/// injection. Multi-scalar patterns are unaffected.
func hasScalar(_ text: String, _ value: UInt32) -> Bool {
    guard let scalar = Unicode.Scalar(value) else { return false }
    return text.unicodeScalars.contains(scalar)
}
