import Testing
import NeedletailCore

/// CFG-05 spirit — identity strings are never coerced or reinterpreted.
/// Version components are canonical decimal: a leading-zero component is
/// rejected, so parsing can never normalize `0.03.0` into `0.3.0`.
struct VersionIdentityTests {

    @Test("CFG-05 version components are canonical, never coerced")
    func CFG_05_versionComponentsAreCanonical() {
        #expect(NeedletailVersion(parsing: "0.3.0") == NeedletailVersion(major: 0, minor: 3, patch: 0))
        #expect(NeedletailVersion(parsing: "0.3.0")?.description == "0.3.0", "round-trip must be exact")
        #expect(NeedletailVersion(parsing: "0.03.0") == nil, "leading-zero minor must not parse")
        #expect(NeedletailVersion(parsing: "00.3.0") == nil, "leading-zero major must not parse")
        #expect(NeedletailVersion(parsing: "0.3.007") == nil, "leading-zero patch must not parse")
        #expect(NeedletailVersion(parsing: "0.0.0")?.description == "0.0.0", "single zeros stay valid")
    }
}
