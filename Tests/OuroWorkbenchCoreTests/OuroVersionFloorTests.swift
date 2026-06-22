import XCTest
@testable import OuroWorkbenchCore

/// Seam B (#F9): the defense-in-depth version floor. The `tools/list` probe (Seam A) is
/// the real gate; this seam turns an `absent` verdict into an actionable "your ouro is
/// too old" message and can fast-path before spawning a turn IF the version is known.
/// Critical invariant: `.unknown` (an unparseable version) must NEVER block — a parse
/// miss is not evidence of "too old".
final class OuroVersionFloorTests: XCTestCase {

    func testFloorConstantIsSixSixZero() {
        XCTAssertEqual(OuroVersionFloor.minimumAlpha, 660)
    }

    func testExactFloorIsSupported() {
        XCTAssertEqual(
            OuroVersionFloor.support(forVersionString: "ouro 0.9.0-alpha.660"),
            .supported
        )
    }

    func testBareAlphaTokenAtOrAboveFloorIsSupported() {
        XCTAssertEqual(OuroVersionFloor.support(forVersionString: "alpha.661"), .supported)
    }

    func testOneBelowFloorIsTooOld() {
        XCTAssertEqual(
            OuroVersionFloor.support(forVersionString: "ouro 0.9.0-alpha.659"),
            .tooOld
        )
    }

    func testFarBelowFloorIsTooOld() {
        XCTAssertEqual(
            OuroVersionFloor.support(forVersionString: "ouro 0.9.0-alpha.12"),
            .tooOld
        )
    }

    func testNoAlphaTokenIsUnknown() {
        // A plain semver with no alpha channel — the floor can't speak, so it must not block.
        XCTAssertEqual(OuroVersionFloor.support(forVersionString: "ouro 0.9.0"), .unknown)
    }

    func testEmptyStringIsUnknown() {
        XCTAssertEqual(OuroVersionFloor.support(forVersionString: ""), .unknown)
    }

    func testGarbageIsUnknown() {
        XCTAssertEqual(OuroVersionFloor.support(forVersionString: "garbage"), .unknown)
    }

    func testNonNumericAlphaIsUnknown() {
        // `alpha.abc` — the token is present but the number doesn't parse ⇒ don't block.
        XCTAssertEqual(OuroVersionFloor.support(forVersionString: "alpha.abc"), .unknown)
    }

    func testWhitespaceAndProseAroundSupportedTokenStillParses() {
        XCTAssertEqual(
            OuroVersionFloor.support(forVersionString: "   ouro version 1.2.3-alpha.700 (build xyz)  "),
            .supported
        )
    }

    func testWhitespaceAndProseAroundTooOldTokenStillParses() {
        XCTAssertEqual(
            OuroVersionFloor.support(forVersionString: "ouro v1.2.3-alpha.500+git.deadbeef"),
            .tooOld
        )
    }

    func testAlphaTokenWithTrailingNonDigitsParsesLeadingNumber() {
        // `alpha.660` directly followed by a `+build` suffix must still read 660.
        XCTAssertEqual(
            OuroVersionFloor.support(forVersionString: "alpha.660+build.5"),
            .supported
        )
    }

    func testAlphaTokenWithNoNumberIsUnknown() {
        // `alpha.` with nothing numeric after it.
        XCTAssertEqual(OuroVersionFloor.support(forVersionString: "ouro alpha."), .unknown)
    }
}
