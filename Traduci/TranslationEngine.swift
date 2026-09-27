import Foundation
import Observation
import os
import Translation

enum LanguagePair {
    static let source = Locale.Language(identifier: "it")
    static let target = Locale.Language(identifier: "en")
}

/// Apple's on-device Translation framework behind a "latest wins" queue: only text that is on
/// screen right now gets translated, most central first, and every result is cached.
@MainActor
@Observable
final class TranslationEngine {
    enum Status: Equatable {
        case preparing
        case needsDownload
        case ready(offline: Bool)
        case unsupported
        case failed(String)
    }

    /// Drives `.translationTask`; invalidating it hands `run(session:)` a fresh session.
    var configuration = TranslationSession.Configuration(source: LanguagePair.source, target: LanguagePair.target)
    private(set) var status: Status = .preparing
    /// Time until the first result of the latest request arrived.
    private(set) var latencyMilliseconds: Double?

    @ObservationIgnored var onTranslation: ((String, String) -> Void)?
    @ObservationIgnored private(set) var cache: [String: String] = [:]
    @ObservationIgnored private var pending: [String] = []
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var wake: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastRestart = Date.distantPast

    private static let batchSize = 4
    private static let log = Logger(subsystem: "Traduci", category: "translation")

    var canRetry: Bool {
        switch status {
        case .needsDownload, .failed: return true
        case .preparing, .ready, .unsupported: return false
        }
    }

    /// Replaces the queue with what is on screen now, most important first.
    func request(_ sources: [String]) {
        pending = sources.filter { cache[$0] == nil && !inFlight.contains($0) && !failed.contains($0) }
        if !pending.isEmpty { wake?.yield() }
    }

    func retry() {
        failed.removeAll()
        status = .preparing
        configuration.invalidate()
    }

    /// Runs for as long as the `.translationTask` that owns `session`.
    func run(session: TranslationSession) async {
        generation += 1
        let myGeneration = generation
        let (wakeups, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wake = continuation
        defer { if generation == myGeneration { wake = nil } }

        let availability = await LanguageAvailability().status(from: LanguagePair.source, to: LanguagePair.target)
        if availability == .unsupported {
            status = .unsupported
            return
        }
        status = availability == .installed ? .preparing : .needsDownload
        do {
            try await session.prepareTranslation() // one-time download sheet if Italian isn't installed yet
        } catch {
            guard !Task.isCancelled else { return }
            Self.log.error("prepareTranslation failed: \(error.localizedDescription, privacy: .public)")
            status = availability == .installed ? .failed("Translator didn't start. Tap to retry.") : .needsDownload
            return
        }
        let installed = await LanguageAvailability().status(from: LanguagePair.source, to: LanguagePair.target) == .installed
        _ = try? await session.translate("Ciao") // load the model before real text shows up
        status = .ready(offline: installed)
        continuation.yield() // pick up anything requested while we were preparing

        for await _ in wakeups {
            var batchSize = 1 // the most central text goes alone, so its translation shows up first
            while !pending.isEmpty, !Task.isCancelled {
                let batch = Array(pending.prefix(batchSize))
                batchSize = Self.batchSize
                pending.removeFirst(batch.count)
                inFlight.formUnion(batch)
                await translate(batch, using: session)
                inFlight.subtract(batch)
                if consecutiveFailures >= 3 {
                    restart() // the session died (e.g. after a long time in the background)
                    return
                }
            }
        }
    }

    private func translate(_ batch: [String], using session: TranslationSession) async {
        let started = Date()
        var reported = false
        func deliver(_ source: String, _ translation: String) {
            if !reported {
                reported = true
                latencyMilliseconds = Date().timeIntervalSince(started) * 1000
            }
            consecutiveFailures = 0
            store(translation, for: source)
        }

        if batch.count > 1 {
            let requests = batch.map {
                TranslationSession.Request(sourceText: TextNormalizer.translationInput($0), clientIdentifier: $0)
            }
            do {
                for try await response in session.translate(batch: requests) {
                    if let source = response.clientIdentifier {
                        deliver(source, response.targetText)
                    }
                }
                return
            } catch {
                if Task.isCancelled { return }
                Self.log.error("Batch failed, retrying one by one: \(error.localizedDescription, privacy: .public)")
            }
        }

        // One at a time, so a single bad string can't sink the rest.
        for source in batch where cache[source] == nil {
            do {
                let response = try await session.translate(TextNormalizer.translationInput(source))
                deliver(source, response.targetText)
            } catch {
                if Task.isCancelled { return }
                failed.insert(source)
                consecutiveFailures += 1
            }
        }
    }

    private func store(_ translation: String, for source: String) {
        if cache.count > 5_000 { cache.removeAll(keepingCapacity: true) }
        cache[source] = translation
        onTranslation?(source, translation)
    }

    private func restart() {
        consecutiveFailures = 0
        failed.removeAll()
        status = .preparing
        let tooSoon = Date().timeIntervalSince(lastRestart) < 5
        lastRestart = Date()
        Task {
            if tooSoon { try? await Task.sleep(for: .seconds(2)) }
            self.configuration.invalidate()
        }
    }
}
