//
//  TitleFilter.swift
//  NetNewsWire
//
//  Created by Pierre Bresson on 11/4/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Articles
import Foundation
@preconcurrency import NobodyWho
import os
import RSCore

extension Notification.Name {
	static let titleFilterSettingsDidChange = Notification.Name("TitleFilterSettingsDidChangeNotification")
	static let titleFilterStatusDidChange = Notification.Name("TitleFilterStatusDidChangeNotification")
	static let titleFilterDidHideArticles = Notification.Name("TitleFilterDidHideArticlesNotification")
}

@MainActor final class TitleFilter {
	static let shared = TitleFilter()

	enum ModelState: Equatable {
		case notDownloaded
		case downloading(fractionCompleted: Double?)
		case downloaded
		case failed(message: String)
	}

	static let modelDownloadSize: Int64 = 449_397_600

	private(set) var modelState: ModelState {
		didSet {
			if modelState != oldValue {
				postStatusDidChange()
			}
		}
	}

	private(set) var topics: [String]
	private(set) var hidesTopics: Bool
	private(set) var hidesSponsoredContent: Bool

	private(set) var threshold: Double

	static let minimumThreshold = 0.1
	static let maximumThreshold = 0.9

	private(set) var pendingCount = 0 {
		didSet {
			if pendingCount != oldValue {
				postStatusDidChange()
			}
		}
	}

	var isActive: Bool {
		!activeCriteria.isEmpty && modelState == .downloaded
	}

	let database: TitleFilterDatabase

	private static let modelSource = "hf://ggml-org/Laya-GGUF/Laya-Q8_0.gguf"
	private static let modelFileName = "Laya-Q8_0.gguf"
	private static let idleUnloadInterval: TimeInterval = 60
	private static let downloadStallInterval: TimeInterval = 10
	private static let downloadStallCheckInterval: TimeInterval = 1

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "TitleFilter")

	fileprivate enum Verdict {
		case visible
		case hidden
		case unknown
	}

	fileprivate enum Criterion {
		case sponsoredContent
		case topic(String)

		static let sponsoredContentKey = ""

		var key: String {
			switch self {
			case .sponsoredContent:
				Self.sponsoredContentKey
			case let .topic(topic):
				topic.lowercased()
			}
		}

		var instructions: String {
			switch self {
			case .sponsoredContent:
				"Does this title suggest the article is sponsored or promotional content?"
			case let .topic(topic):
				"The reader asked to hide news articles matching “\(topic)”. Does this article title match? Answer yes if the article is about \(topic) or is itself an example of \(topic)."
			}
		}
	}

	private var verdicts: [String: [String: Double]]
	private var pendingTitles = [String]()
	private var pendingTitleSet = Set<String>()
	private var titlesWithUpdatedDateLastSeen = Set<String>()
	private var modelPath: String?
	private var decision: Decision?
	private var workerTask: Task<Void, Never>?
	private var workerGeneration = 0
	private var idleUnloadTimer: Timer?
	private var isDownloading = false
	private var downloadGeneration = 0
	private var dateLastDownloadProgress = Date()
	private var downloadStallTimer: Timer?

	private init() {
		let savedTopics = AppDefaults.titleFilterTopics
		topics = savedTopics
		hidesTopics = AppDefaults.titleFilterHidesTopics
		hidesSponsoredContent = AppDefaults.titleFilterHidesSponsoredContent
		threshold = AppDefaults.titleFilterThreshold
		database = TitleFilterDatabase()
		
		let criterionKeys = Set(savedTopics.map { Criterion.topic($0).key }).union([Criterion.sponsoredContentKey])
		verdicts = database.cleanUpOldAndFetchAll(topicKeys: criterionKeys)

		modelPath = Self.existingModelPath(savedPath: AppDefaults.titleFilterModelPath)
		modelState = modelPath == nil ? .notDownloaded : .downloaded
	}

	// MARK: - Filtering

	/// Returns the articles that aren’t hidden, in the same order.
	/// Titles that haven’t been judged yet stay visible and are queued for decision.
	func visibleArticles(_ articles: [Article], keeping keptArticleIDs: Set<String> = []) -> [Article] {
		guard isActive else {
			return articles
		}

		var visibleArticles = [Article]()
		visibleArticles.reserveCapacity(articles.count)
		var unjudgedTitles = [String]()
		var titlesNeedingDateLastSeenUpdate = [String]()

		for article in articles {
			if keptArticleIDs.contains(article.articleID) {
				visibleArticles.append(article)
				continue
			}
			guard let title = Self.title(for: article) else {
				visibleArticles.append(article)
				continue
			}
			if titlesWithUpdatedDateLastSeen.insert(title).inserted {
				titlesNeedingDateLastSeenUpdate.append(title)
			}

			switch verdict(for: title) {
			case .hidden:
				continue
			case .visible:
				visibleArticles.append(article)
			case .unknown:
				visibleArticles.append(article)
				unjudgedTitles.append(title)
			}
		}

		// Keeps verdicts for titles that still show up from being deleted at startup.
		database.updateDateLastSeen(titles: titlesNeedingDateLastSeenUpdate)
		enqueue(unjudgedTitles)
		return visibleArticles
	}

	func isHidden(_ article: Article) -> Bool {
		guard isActive, let title = Self.title(for: article) else {
			return false
		}
		return verdict(for: title) == .hidden
	}

	// MARK: - Topics

	@discardableResult
	func addTopic(_ topic: String) -> Bool {
		let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedTopic.isEmpty, !topics.contains(where: { $0.caseInsensitiveCompare(trimmedTopic) == .orderedSame }) else {
			return false
		}
		topics.append(trimmedTopic)
		topicsDidChange()
		return true
	}

	func removeTopic(_ topic: String) {
		guard let index = topics.firstIndex(of: topic) else {
			return
		}
		topics.remove(at: index)
		let topicKey = Criterion.topic(topic).key
		verdicts.removeValue(forKey: topicKey)
		database.deleteTopic(topicKey)
		topicsDidChange()
	}

	func setHidesTopics(_ hides: Bool) {
		guard hides != hidesTopics else {
			return
		}
		hidesTopics = hides
		AppDefaults.titleFilterHidesTopics = hides
		settingsDidChange()
	}

	func setHidesSponsoredContent(_ hides: Bool) {
		guard hides != hidesSponsoredContent else {
			return
		}
		hidesSponsoredContent = hides
		AppDefaults.titleFilterHidesSponsoredContent = hides
		settingsDidChange()
	}

	func setThreshold(_ newThreshold: Double) {
		let roundedThreshold = (newThreshold * 10).rounded() / 10
		let clampedThreshold = min(max(roundedThreshold, Self.minimumThreshold), Self.maximumThreshold)
		guard clampedThreshold != threshold else {
			return
		}
		threshold = clampedThreshold
		AppDefaults.titleFilterThreshold = clampedThreshold
		settingsDidChange()
	}

	// MARK: - Model

	func downloadModel() {
		guard !isDownloading, modelPath == nil else {
			return
		}
		isDownloading = true
		downloadGeneration += 1
		let generation = downloadGeneration
		modelState = .downloading(fractionCompleted: nil)
		startDownloadStallTimer()

		let progressHandler = Self.makeDownloadProgressHandler(generation: generation)
		Task {
			do {
				let path = try await Model.downloadModel(modelPath: Self.modelSource, onDownloadProgress: progressHandler)
				downloadDidFinish(path: path, generation: generation)
			} catch {
				downloadDidFail(error, generation: generation)
			}
		}
	}

	func deleteModel() {
		unloadModel()
		pendingTitles.removeAll()
		pendingTitleSet.removeAll()
		pendingCount = 0

		if let modelPath {
			do {
				try FileManager.default.removeItem(atPath: modelPath)
			} catch {
				Self.logger.error("Couldn’t delete filter model: \(error.localizedDescription)")
			}
		}
		modelPath = nil
		AppDefaults.titleFilterModelPath = nil

		verdicts.removeAll()
		database.deleteAll()

		modelState = .notDownloaded
		NotificationCenter.default.post(name: .titleFilterSettingsDidChange, object: self)
	}
}

// MARK: - Private

private extension TitleFilter {
	static func title(for article: Article) -> String? {
		let title = ArticleStringFormatter.shared.truncatedTitle(article)
		return title.isEmpty ? nil : title
	}

	var activeCriteria: [Criterion] {
		var criteria = [Criterion]()
		if hidesSponsoredContent {
			criteria.append(.sponsoredContent)
		}
		if hidesTopics {
			criteria += topics.map { .topic($0) }
		}
		return criteria
	}

	func verdict(for title: String) -> Verdict {
		var isKnown = true
		for criterion in activeCriteria {
			guard let probability = verdicts[criterion.key]?[title] else {
				isKnown = false
				continue
			}
			if probability >= threshold {
				return .hidden
			}
		}
		return isKnown ? .visible : .unknown
	}

	func postStatusDidChange() {
		NotificationCenter.default.post(name: .titleFilterStatusDidChange, object: self)
	}

	func topicsDidChange() {
		AppDefaults.titleFilterTopics = topics
		settingsDidChange()
	}

	func settingsDidChange() {
		if !isActive {
			unloadModel()
			pendingTitles.removeAll()
			pendingTitleSet.removeAll()
			pendingCount = 0
		}
		NotificationCenter.default.post(name: .titleFilterSettingsDidChange, object: self)
	}

	// MARK: Queue

	func enqueue(_ titles: [String]) {
		guard !titles.isEmpty else {
			return
		}

		var newTitles = [String]()
		var newTitleSet = Set<String>()

		for title in titles where !newTitleSet.contains(title) {
			newTitles.append(title)
			newTitleSet.insert(title)
		}

		pendingTitles = pendingTitles.filter { !newTitleSet.contains($0) } + newTitles.reversed()
		pendingTitleSet.formUnion(newTitleSet)
		pendingCount = pendingTitles.count

		startWorkerIfNeeded()
	}

	func startWorkerIfNeeded() {
		guard workerTask == nil, isActive, !pendingTitles.isEmpty else {
			return
		}

		invalidateIdleUnloadTimer()

		workerGeneration += 1
		let generation = workerGeneration
		workerTask = Task {
			await judgePendingTitles()
			guard generation == workerGeneration else {
				return
			}
			workerTask = nil
			startIdleUnloadTimer()
		}
	}

	func judgePendingTitles() async {
		guard let decision = await loadedDecision() else {
			return
		}

		while isActive, self.decision === decision, !Task.isCancelled, let title = pendingTitles.popLast() {
			pendingTitleSet.remove(title)
			pendingCount = pendingTitles.count

			let criteriaToJudge = activeCriteria.filter { verdicts[$0.key]?[title] == nil }
			if criteriaToJudge.isEmpty {
				continue
			}

			let probabilities: [String: Double]
			do {
				probabilities = try await Self.judge(title: title, criteria: criteriaToJudge, decision: decision)
			} catch {
				Self.logger.error("Couldn’t judge title: \(error.localizedDescription)")
				// Treat it as not matching, so a title that keeps failing doesn’t get retried forever.
				probabilities = Dictionary(uniqueKeysWithValues: criteriaToJudge.map { ($0.key, 0.0) })
			}

			record(probabilities, for: title)
		}
	}

	func record(_ probabilities: [String: Double], for title: String) {
		var didHide = false
		for (criterionKey, probability) in probabilities {
			verdicts[criterionKey, default: [:]][title] = probability
			database.save(topicKey: criterionKey, title: title, probability: probability)
			if probability >= threshold {
				didHide = true
				Self.logger.debug("Hiding title: \(title, privacy: .private)")
			}
		}

		if didHide {
			NotificationCenter.default.post(name: .titleFilterDidHideArticles, object: self)
		}
	}

	static func judge(title: String, criteria: [Criterion], decision: Decision) async throws -> [String: Double] {
		let questionIDs = criteria.indices.map { "question\($0)" }
		let questions = zip(questionIDs, criteria).map { questionID, criterion in
			(questionID, DecisionQuestion.noul(instructions: .string(criterion.instructions)))
		}

		let response = try await decision.decide(
			state: .object(["title": .string(title)]),
			questions: OrderedFields(entries: questions)
		)

		var probabilities = [String: Double]()
		for (questionID, criterion) in zip(questionIDs, criteria) {
			if case let .noul(probability) = response.answers[questionID] {
				probabilities[criterion.key] = probability
			} else {
				probabilities[criterion.key] = 0
			}
		}
		return probabilities
	}

	// MARK: Model Loading

	func loadedDecision() async -> Decision? {
		if let decision {
			return decision
		}

		guard let modelPath else {
			return nil
		}

		do {
			let model = try await Model.load(modelPath: modelPath)
			let decision = try Decision(model: model)

			guard self.modelPath == modelPath else {
				return nil
			}

			self.decision = decision
			return decision
		} catch {
			Self.logger.error("Couldn’t load filter model: \(error.localizedDescription)")

			deleteModel()
			modelState = .failed(message: NSLocalizedString("The filtering model couldn’t be loaded. Please download it again.", comment: "Filter settings"))
			return nil
		}
	}

	func unloadModel() {
		workerTask?.cancel()
		workerTask = nil
		invalidateIdleUnloadTimer()
		decision = nil
	}

	/// Let go of the model when there’s nothing to decide.
	func startIdleUnloadTimer() {
		invalidateIdleUnloadTimer()
		idleUnloadTimer = Timer.scheduledTimer(withTimeInterval: Self.idleUnloadInterval, repeats: false) { _ in
			MainActor.assumeIsolated {
				TitleFilter.shared.idleUnloadTimerDidFire()
			}
		}
	}

	func invalidateIdleUnloadTimer() {
		idleUnloadTimer?.invalidate()
		idleUnloadTimer = nil
	}

	func idleUnloadTimerDidFire() {
		idleUnloadTimer = nil
		guard workerTask == nil, pendingTitles.isEmpty else {
			return
		}
		decision = nil
	}

	// MARK: Downloading

	nonisolated static func makeDownloadProgressHandler(generation: Int) -> @Sendable (UInt64, UInt64) -> Void {
		return { downloadedBytes, totalBytes in
			Task { @MainActor in
				TitleFilter.shared.downloadDidProgress(downloadedBytes: downloadedBytes, totalBytes: totalBytes, generation: generation)
			}
		}
	}

	func isCurrentDownload(_ generation: Int) -> Bool {
		isDownloading && generation == downloadGeneration
	}

	func downloadDidProgress(downloadedBytes: UInt64, totalBytes: UInt64, generation: Int) {
		guard isCurrentDownload(generation) else {
			return
		}
		dateLastDownloadProgress = Date()
		guard totalBytes > 0 else {
			return
		}

		let percent = Double(min(downloadedBytes, totalBytes) * 100 / totalBytes)
		let fractionCompleted = percent / 100.0

		if case let .downloading(currentFraction) = modelState, let currentFraction, currentFraction >= fractionCompleted {
			return
		}

		modelState = .downloading(fractionCompleted: fractionCompleted)
	}

	func downloadDidFinish(path: String, generation: Int) {
		guard isCurrentDownload(generation) else {
			if modelPath == nil, !isDownloading {
				Self.logger.info("Abandoned filter model download finished")
				useDownloadedModel(path: path)
			}
			return
		}
		isDownloading = false
		invalidateDownloadStallTimer()
		useDownloadedModel(path: path)
	}

	func useDownloadedModel(path: String) {
		modelPath = path
		AppDefaults.titleFilterModelPath = path
		modelState = .downloaded
		Self.logger.info("Filter model downloaded")
		NotificationCenter.default.post(name: .titleFilterSettingsDidChange, object: self)
	}

	func downloadDidFail(_ error: Error, generation: Int) {
		guard isCurrentDownload(generation) else {
			return
		}
		Self.logger.error("Filter model download failed: \(error.localizedDescription)")
		markDownloadFailed()
	}

	func markDownloadFailed() {
		isDownloading = false
		invalidateDownloadStallTimer()
		modelState = .failed(message: NSLocalizedString("The download failed", comment: "Filter settings"))
	}

	/// The download API can’t time out or be cancelled, so a download that stops making progress is treated as failed.
	func startDownloadStallTimer() {
		invalidateDownloadStallTimer()
		dateLastDownloadProgress = Date()
		downloadStallTimer = Timer.scheduledTimer(withTimeInterval: Self.downloadStallCheckInterval, repeats: true) { _ in
			MainActor.assumeIsolated {
				TitleFilter.shared.checkForDownloadStall()
			}
		}
	}

	func invalidateDownloadStallTimer() {
		downloadStallTimer?.invalidate()
		downloadStallTimer = nil
	}

	func checkForDownloadStall() {
		guard isDownloading else {
			invalidateDownloadStallTimer()
			return
		}
		guard Date().timeIntervalSince(dateLastDownloadProgress) >= Self.downloadStallInterval else {
			return
		}
		Self.logger.error("Filter model download stalled")
		markDownloadFailed()
	}

	static func existingModelPath(savedPath: String?) -> String? {
		if let savedPath, FileManager.default.fileExists(atPath: savedPath) {
			return savedPath
		}

		let cachedModels = (try? getCachedModels()) ?? []

		return cachedModels.first { ($0.path as NSString).lastPathComponent == modelFileName }?.path
	}
}
