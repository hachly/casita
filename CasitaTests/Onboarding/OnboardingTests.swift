import Foundation
import Testing
@testable import Casita

@Suite struct OnboardingStepTests {
    @Test func stepsRunInOrder() {
        #expect(OnboardingStep.allCases == [
            .welcome, .everydayCode, .privateCode, .recoveryKey,
            .fillEveryday, .ageCheck, .paywall,
        ])
    }

    private func walk(ageCheckRequired: Bool) -> [OnboardingStep] {
        var steps = [OnboardingStep.welcome]
        while let next = steps.last!.next(ageCheckRequired: ageCheckRequired) { steps.append(next) }
        return steps
    }

    @Test func walkingForwardVisitsEveryStepOnce() {
        #expect(walk(ageCheckRequired: true) == OnboardingStep.allCases)
    }

    @Test func ageCheckOnlyWhereTheLawAsks() {
        #expect(walk(ageCheckRequired: false) == OnboardingStep.allCases.filter { $0 != .ageCheck })
        #expect(OnboardingStep.fillEveryday.next(ageCheckRequired: false) == .paywall)
        #expect(OnboardingStep.fillEveryday.next(ageCheckRequired: true) == .ageCheck)
    }

    @Test func thePaywallEndsTheFlow() {
        #expect(OnboardingStep.paywall.next(ageCheckRequired: true) == nil)
    }

    @Test func onlyStepsBeforeTheStorageCanGoBack() {
        for step in OnboardingStep.allCases {
            let canGoBack = step.previous != nil
            #expect(canGoBack == (step.rawValue > 0 && step.rawValue <= OnboardingStep.privateCode.rawValue), "\(step)")
            if let previous = step.previous { #expect(previous.rawValue == step.rawValue - 1) }
        }
        #expect(!OnboardingStep.privateCode.storageExists)
        #expect(OnboardingStep.recoveryKey.storageExists)
    }

    @MainActor @Test func goingBackForgetsTheCodeOfTheStepLeft() async {
        let flow = OnboardingModel()
        await flow.advance()
        #expect(flow.step == .everydayCode)
        flow.everydayCode = "123456"
        await flow.advance()
        flow.privateCode = "654321"
        flow.back()
        #expect(flow.step == .everydayCode)
        #expect(flow.privateCode == nil)
        #expect(flow.everydayCode == "123456")
    }
}

@Suite struct CodeRuleTests {
    @Test func minimumLengthPerMethod() {
        #expect(CodeRules.problem(with: "12345", method: .numbers) != nil)
        #expect(CodeRules.problem(with: "123456", method: .numbers) == nil)
        #expect(CodeRules.problem(with: DotsCode.make([0, 1, 2], gridSize: 3), method: .dots) != nil)
        #expect(CodeRules.problem(with: DotsCode.make([0, 1, 2, 5], gridSize: 3), method: .dots) == nil)
        #expect(CodeRules.problem(with: "abcde", method: .letters) != nil)
        #expect(CodeRules.problem(with: "abcdef", method: .letters) == nil)
    }

    @Test func dotsCodesMatchTheEntryScreen() {
        // 3×3 keeps the original form, so codes set before grid sizes still open.
        #expect(DotsCode.make([0, 4, 8, 5], gridSize: 3) == "dots:0-4-8-5")
        // Other grids name their size: the same path is a different code.
        #expect(DotsCode.make([0, 4, 8, 5], gridSize: 5) == "dots5:0-4-8-5")
        #expect(DotsCode.dotCount("dots5:0-4-8-5") == 4)
        #expect(DotsCode.dotCount("123456") == nil)
        #expect(CodeRules.problem(with: DotsCode.make([0, 7, 14, 21], gridSize: 6), method: .dots) == nil)
    }
}

@Suite struct StoragePlanTests {
    private let gb: Int64 = 1 << 30

    @Test func slideSnapsToTheStopsThatFitWithHeadroom() {
        #expect(StoragePlan.sizes(available: 3 * gb) == [.mb512, .gb1, .gb2])
        #expect(StoragePlan.sizes(available: 3 * gb - 1) == [.mb512, .gb1])
        #expect(StoragePlan.sizes(available: 200 * gb) == StorageSize.allCases)
        #expect(StoragePlan.sizes(available: 129 * gb - 1) == Array(StorageSize.allCases.dropLast()))
    }

    @Test func nothingFitsOnAFullPhone() {
        #expect(StoragePlan.sizes(available: gb).isEmpty)
    }

    @Test func unknownFreeSpaceOffersEveryStop() {
        #expect(StoragePlan.sizes(available: nil) == StorageSize.allCases)
    }

    @Test func makeMoreRoomNeedsTheDifferencePlusHeadroom() {
        #expect(StoragePlan.growth(from: .gb2, available: 3 * gb) == .gb4)
        #expect(StoragePlan.growth(from: .gb2, available: 3 * gb - 1) == nil)
        #expect(StoragePlan.growth(from: .gb128, available: 1000 * gb) == nil)
    }

    @Test func labels() {
        #expect(StoragePlan.label(.mb512) == "512 MB")
        #expect(StoragePlan.label(.gb2) == "2 GB")
        #expect(StoragePlan.label(.gb128) == "128 GB")
    }
}

@Suite struct AgeCheckTests {
    @Test func aServiceThatNeverAnswersFallsBackInTime() async {
        let clock = ContinuousClock()
        let start = clock.now
        let answer = await AgeCheck.firstOf(.milliseconds(50), fallback: false) {
            try? await Task.sleep(for: .seconds(3600))
            return true
        }
        #expect(answer == false)
        // Far below the hour it would otherwise wait; loose, because on a
        // phone other tests' Secure Enclave work can hold the threads a while.
        #expect(start.duration(to: clock.now) < .seconds(10))
    }

    @Test func aQuickAnswerWins() async {
        let answer = await AgeCheck.firstOf(.seconds(5), fallback: false) { true }
        #expect(answer == true)
    }

    @Test func eighteenGateOutcomes() {
        #expect(AgeCheck.outcome(lowerBound: 18, upperBound: nil) == .adult)
        #expect(AgeCheck.outcome(lowerBound: 21, upperBound: nil) == .adult)
        #expect(AgeCheck.outcome(lowerBound: 13, upperBound: 17) == .under18)
        #expect(AgeCheck.outcome(lowerBound: nil, upperBound: 12) == .under18)
        #expect(AgeCheck.outcome(lowerBound: nil, upperBound: nil) == .notShared)
    }
}

/// The resumable part of onboarding: the storage file only appears at its
/// real path once both spaces are in it, so a relaunch either starts first
/// run again or shows the entry screen with working codes.
@Suite struct FirstSpacesTests {
    private let bytes = Int64(ReservedStorage.chunksOffset + 40 * ReservedStorage.chunkSealed)
    private let stretcher = PBKDF2Stretcher(iterations: 1000)

    private func urls() -> (url: URL, partial: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("casita-m8-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent("reserved.bin"), dir.appendingPathComponent("reserved.partial"))
    }

    @Test func bothCodesOpenTheStorageFoundAtTheRealPath() async throws {
        let (url, partial) = urls()
        let built = try await AppModel.buildFirstSpaces(
            at: url, partial: partial, bytes: bytes, privateCode: "private-1", everydayCode: "123456", stretcher: stretcher
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(built.top.slot != built.everyday.slot)

        // What a relaunch does: open the file, type each code.
        let relaunched = try ReservedStorage.open(at: url, stretcher: stretcher)
        await relaunched.setMinimumUnlockDuration(.milliseconds(1))
        let top = try #require(try await relaunched.unlock(code: "private-1"))
        let everyday = try #require(try await relaunched.unlock(code: "123456"))
        #expect(top.slot == built.top.slot)
        #expect(everyday.slot == built.everyday.slot)
        #expect(try await relaunched.children(of: top) == ["Everyday"])
        #expect(try await relaunched.unlock(code: "wrong") == nil)
    }

    @Test func theEverydaySpaceGetsHalfTheRoom() async throws {
        let (url, partial) = urls()
        let built = try await AppModel.buildFirstSpaces(
            at: url, partial: partial, bytes: bytes, privateCode: "private-1", everydayCode: "123456", stretcher: stretcher
        )
        let top = try await built.storage.open(built.top)
        let everyday = try await built.storage.open(built.everyday)
        let topFree = try await built.storage.freeBytes(in: top)
        let everydayFree = try await built.storage.freeBytes(in: everyday)
        #expect(abs(topFree - everydayFree) <= 2 * Int64(ReservedStorage.chunkPlain))
    }

    @Test func aLeftoverPartialFileIsReplaced() async throws {
        let (url, partial) = urls()
        try Data(repeating: 7, count: 1000).write(to: partial)
        _ = try await AppModel.buildFirstSpaces(
            at: url, partial: partial, bytes: bytes, privateCode: "private-1", everydayCode: "123456", stretcher: stretcher
        )
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        let reopened = try ReservedStorage.open(at: url, stretcher: stretcher)
        #expect(await reopened.byteSize == bytes)
    }

    @Test func neverReplacesStorageThatIsAlreadyThere() async throws {
        let (url, partial) = urls()
        try Data("keep me".utf8).write(to: url)
        await #expect(throws: FirstRunError.self) {
            _ = try await AppModel.buildFirstSpaces(
                at: url, partial: partial, bytes: bytes, privateCode: "private-1", everydayCode: "123456", stretcher: stretcher
            )
        }
        #expect(try Data(contentsOf: url) == Data("keep me".utf8))
    }

    @Test func aFailedBuildLeavesNothingBehind() async throws {
        let (url, partial) = urls()
        // Same code twice: the everyday space can't be made.
        await #expect(throws: StorageError.codeInUse) {
            _ = try await AppModel.buildFirstSpaces(
                at: url, partial: partial, bytes: bytes, privateCode: "same", everydayCode: "same", stretcher: stretcher
            )
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }
}

/// Guideline 5.6.3: no rating request in setup, only after real use, once.
@Suite struct RatingPromptTests {
    @Test func asksOnceAfterSixOpensOverThreeDays() throws {
        let defaults = try #require(UserDefaults(suiteName: "RatingPromptTests"))
        defaults.removePersistentDomain(forName: "RatingPromptTests")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!RatingPrompt.takeTurn(defaults: defaults, now: start), "Nothing used yet")
        for _ in 0..<6 { RatingPrompt.spaceOpened(defaults: defaults, now: start) }
        #expect(!RatingPrompt.takeTurn(defaults: defaults, now: start.addingTimeInterval(86_400)), "Six opens, but one day in")
        let later = start.addingTimeInterval(3 * 86_400)
        #expect(RatingPrompt.takeTurn(defaults: defaults, now: later))
        #expect(!RatingPrompt.takeTurn(defaults: defaults, now: later), "Only once")
    }

    @Test func setupHasNoRatingStep() {
        // The small-team page with its rating request is gone from setup.
        #expect(OnboardingStep.allCases.count == 7)
        #expect(SetupFunnel.Step(rawValue: 9) == nil)
        #expect(SetupFunnel.Step.ageCheck.rawValue == 10)
    }
}

