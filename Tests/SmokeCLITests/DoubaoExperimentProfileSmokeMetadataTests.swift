import XCTest
import DoubaoASR
@testable import SmokeCLISupport

final class DoubaoExperimentProfileSmokeMetadataTests: XCTestCase {
    func testProfileMetadataMarksOfficialAsDefaultSafe() {
        XCTAssertEqual(DoubaoExperimentProfile.official.smokeRisk, "default")
        XCTAssertEqual(DoubaoExperimentProfile.official.smokePlacement, "official")
        XCTAssertEqual(DoubaoExperimentProfile.official.includeInSafeSmokeMatrix, true)
        XCTAssertFalse(DoubaoExperimentProfile.official.smokeEvidenceSummary.isEmpty)
    }

    func testProfileMetadataExcludesUnsafeProfilesFromSafeSmokeMatrix() {
        for profile in [DoubaoExperimentProfile.speakerFlat, .speakerTop] {
            XCTAssertEqual(profile.smokeRisk, "unsafe")
            XCTAssertFalse(profile.includeInSafeSmokeMatrix)
            XCTAssertFalse(profile.smokeEvidenceSummary.isEmpty)
        }
    }

    func testProfileMetadataMarksStaticOnlyProfile() {
        XCTAssertEqual(DoubaoExperimentProfile.speakerNestedSeconds.smokeRisk, "static-only")
        XCTAssertEqual(DoubaoExperimentProfile.speakerNestedSeconds.smokePlacement, "extra.asr_params")
        XCTAssertFalse(DoubaoExperimentProfile.speakerNestedSeconds.includeInSafeSmokeMatrix)
        XCTAssertTrue(DoubaoExperimentProfile.speakerNestedSeconds.smokeEvidenceSummary.contains("sentence_max_seconds"))
    }

    func testAllDocumentedProfilesHaveEvidenceMetadata() {
        XCTAssertEqual(Set(DoubaoExperimentProfile.smokeDocumentedProfiles.map(\.rawValue)).count, DoubaoExperimentProfile.smokeDocumentedProfiles.count)

        for profile in DoubaoExperimentProfile.smokeDocumentedProfiles {
            XCTAssertFalse(profile.smokePlacement.isEmpty, profile.rawValue)
            XCTAssertFalse(profile.smokeRisk.isEmpty, profile.rawValue)
            XCTAssertFalse(profile.smokeEvidenceSummary.isEmpty, profile.rawValue)
        }
    }

    func testProfileMetadataDoesNotChangeOfficialJSON() throws {
        let before = buildSessionConfigJSON(deviceId: "dev-1", contextHint: "x", profile: .official)
        _ = DoubaoExperimentProfile.official.smokePlacement
        _ = DoubaoExperimentProfile.official.smokeRisk
        _ = DoubaoExperimentProfile.official.includeInSafeSmokeMatrix
        _ = DoubaoExperimentProfile.official.smokeEvidenceSummary
        let after = buildSessionConfigJSON(deviceId: "dev-1", contextHint: "x", profile: .official)

        XCTAssertEqual(before, after)
    }
}
