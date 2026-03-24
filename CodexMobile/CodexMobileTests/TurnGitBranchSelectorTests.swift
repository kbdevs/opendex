// FILE: TurnGitBranchSelectorTests.swift
// Purpose: Verifies new branch creation names normalize toward the opendex/ prefix without double-prefixing.
// Layer: Unit Test
// Exports: TurnGitBranchSelectorTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class TurnGitBranchSelectorTests: XCTestCase {
    func testNormalizesCreatedBranchNamesTowardOpendexPrefix() {
        XCTAssertEqual(opendexNormalizedCreatedBranchName("foo"), "opendex/foo")
        XCTAssertEqual(opendexNormalizedCreatedBranchName("opendex/foo"), "opendex/foo")
        XCTAssertEqual(opendexNormalizedCreatedBranchName("  foo  "), "opendex/foo")
    }

    func testNormalizesEmptyBranchNamesToEmptyString() {
        XCTAssertEqual(opendexNormalizedCreatedBranchName("   "), "")
    }

    func testCurrentBranchSelectionKeepsCheckedOutElsewhereRowsSelectableWhenWorktreePathIsMissing() {
        XCTAssertFalse(
            opendexCurrentBranchSelectionIsDisabled(
                branch: "opendex/feature-a",
                currentBranch: "main",
                gitBranchesCheckedOutElsewhere: ["opendex/feature-a"],
                gitWorktreePathsByBranch: [:],
                allowsSelectingCurrentBranch: true
            )
        )
    }

    func testCurrentBranchSelectionKeepsCheckedOutElsewhereRowsEnabledWhenWorktreePathExists() {
        XCTAssertFalse(
            opendexCurrentBranchSelectionIsDisabled(
                branch: "opendex/feature-a",
                currentBranch: "main",
                gitBranchesCheckedOutElsewhere: ["opendex/feature-a"],
                gitWorktreePathsByBranch: ["opendex/feature-a": "/tmp/opendex-feature-a"],
                allowsSelectingCurrentBranch: true
            )
        )
    }
}
