//
//  CrashReportingTests.swift
//  GainmapTests
//
//  Regression tests for the Sentry path scrubber. The contract: no client or
//  project folder name may survive redaction — including folders with spaces
//  ("Client Names/…"), which a whitespace-terminated pattern would leak.
//

import XCTest
@testable import GainmapCore

final class CrashReportingTests: XCTestCase {

    // uhdrtool quotes paths in its error lines — the common Sentry payload.
    func testQuotedToolErrorRedactsWholePath() {
        let msg = #"error: cannot open SDR JPEG '/Users/sam/Pictures/SmithWedding/shot 01.jpg'"#
        let out = CrashReporting.redact(msg)
        XCTAssertEqual(out, #"error: cannot open SDR JPEG '/Users/<redacted>'"#)
    }

    func testDoubleQuotedPathRedactsWholePath() {
        let out = CrashReporting.redact(#"wrote "/Users/sam/Desktop/Jones Family/out_UltraHDR.jpg""#)
        XCTAssertEqual(out, #"wrote "/Users/<redacted>""#)
    }

    // Folder names contain spaces; the pattern must not stop at whitespace.
    func testUnquotedPathWithSpacesLeaksNothing() {
        let out = CrashReporting.redact("/Users/sam/Client Names/Wedding 2026/x.jpg")
        XCTAssertFalse(out.contains("Client"))
        XCTAssertFalse(out.contains("Wedding"))
        XCTAssertFalse(out.contains("x.jpg"))
        XCTAssertTrue(out.hasPrefix("/Users/<redacted>"))
    }

    func testVolumesPathRedactsPastFirstSegment() {
        let out = CrashReporting.redact("error: '/Volumes/Shoots 2026/Baker Bat Mitzvah/img.tif'")
        XCTAssertFalse(out.contains("Baker"))
        XCTAssertFalse(out.contains("Shoots"))
        XCTAssertEqual(out, "error: '/Volumes/<redacted>'")
    }

    func testFileURLRedacted() {
        let out = CrashReporting.redact("open file:///Users/sam/Pictures/Smith%20Wedding/x.jpg failed")
        XCTAssertFalse(out.contains("Smith"))
        XCTAssertTrue(out.contains("file:///Users/<redacted>"))
    }

    func testMultilineRedactsEachLineIndependently() {
        let msg = """
        hdr: /Users/sam/A Shoot/hdr.tif
        clamps: peak=3.973 (1.99 stops)  K=4.171  L=806
        """
        let out = CrashReporting.redact(msg)
        XCTAssertFalse(out.contains("A Shoot"))
        // Newline termination keeps subsequent lines intact.
        XCTAssertTrue(out.contains("clamps: peak=3.973 (1.99 stops)  K=4.171  L=806"))
    }

    func testPathFreeMessageUntouched() {
        let msg = "uhdrtool exited with code 139."
        XCTAssertEqual(CrashReporting.redact(msg), msg)
    }
}
