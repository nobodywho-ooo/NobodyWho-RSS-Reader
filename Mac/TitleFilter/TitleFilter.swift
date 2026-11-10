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

	private static let modelSourceURL = URL(string: "https://huggingface.co/ggml-org/Laya-GGUF/resolve/main/Laya-Q8_0.gguf")
	private static let modelFileName = "Laya-Q8_0.gguf"
	private static let modelFolderName = "TitleFilter"
	private static let idleUnloadInterval: TimeInterval = 60

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "TitleFilter")

	fileprivate enum Verdict {
		case visible
		case hidden
		case unknown
	}

	fileprivate struct Criterion {
		let key: String
		let instructions: String

		static let sponsoredContentKey = ""

		static let sponsoredContent = Criterion(
			key: sponsoredContentKey,
			instructions: "Does this title suggest the article is sponsored or promotional content?"
		)

		static func key(forTopic topic: String) -> String {
			topic.lowercased()
		}

		static func topic(_ topic: String) -> Criterion {
			Criterion(
				key: key(forTopic: topic),
				instructions: "The reader asked to hide news articles matching “\(topic)”. Does this article title match? Answer yes if the article is about \(topic) or is itself an example of \(topic)."
			)
		}
	}

	private var verdicts: [String: [String: Double]]
	private var activeCriteria = [Criterion]()
	private var pendingTitles = [String]()
	private var titlesWithUpdatedDateLastSeen = Set<String>()
	private var modelPath: String?
	private var decision: Decision?
	private var modelLoadTask: Task<Decision?, Never>?
	private var workerTask: Task<Void, Never>?
	private var workerGeneration = 0
	private var idleUnloadTimer: Timer?
	private var downloader: TitleFilterModelDownloader?

	private init() {
		let savedTopics = AppDefaults.titleFilterTopics
		topics = savedTopics
		hidesTopics = AppDefaults.titleFilterHidesTopics
		hidesSponsoredContent = AppDefaults.titleFilterHidesSponsoredContent
		threshold = AppDefaults.titleFilterThreshold
		database = TitleFilterDatabase()
		
		let criterionKeys = Set(savedTopics.map { Criterion.key(forTopic: $0) }).union([Criterion.sponsoredContentKey])
		verdicts = database.cleanUpOldAndFetchAll(topicKeys: criterionKeys)

		modelPath = Self.existingModelPath()
		modelState = modelPath == nil ? .notDownloaded : .downloaded
		updateActiveCriteria()
	}

	// MARK: - Filtering

	/// Splits articles into those that stay visible and those that are hidden, each in the same order.
	/// Articles in `keptArticleIDs` always stay visible.
	/// Titles that haven’t been judged yet stay visible and, if `queuesUnjudgedTitles` is true, are queued for decision.
	func partition(_ articles: [Article], keeping keptArticleIDs: Set<String> = [], queuesUnjudgedTitles: Bool = true) -> (visible: [Article], hidden: [Article]) {
		guard isActive else {
			return (articles, [])
		}

		var visibleArticles = [Article]()
		visibleArticles.reserveCapacity(articles.count)
		var hiddenArticles = [Article]()
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
				hiddenArticles.append(article)
			case .visible:
				visibleArticles.append(article)
			case .unknown:
				visibleArticles.append(article)
				unjudgedTitles.append(title)
			}
		}

		// Keeps verdicts for titles that still show up from being deleted at startup.
		database.updateDateLastSeen(titles: titlesNeedingDateLastSeenUpdate)
		if queuesUnjudgedTitles {
			enqueue(unjudgedTitles)
		}
		return (visibleArticles, hiddenArticles)
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
		let topicKey = Criterion.key(forTopic: topic)
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
		guard downloader == nil, modelPath == nil, let modelSourceURL = Self.modelSourceURL else {
			return
		}
		modelState = .downloading(fractionCompleted: nil)

		let modelFileURL = Self.modelFileURL
		let downloader = TitleFilterModelDownloader(
			sourceURL: modelSourceURL,
			destinationURL: modelFileURL,
			progressHandler: { fractionCompleted in
				TitleFilter.shared.downloadDidProgress(fractionCompleted)
			},
			completionHandler: { result in
				TitleFilter.shared.downloadDidComplete(result, modelPath: modelFileURL.path)
			}
		)
		self.downloader = downloader
		downloader.start()
	}

	func deleteModel() {
		downloader?.cancel()
		downloader = nil
		unloadModel()
		modelLoadTask = nil
		pendingTitles.removeAll()
		pendingCount = 0

		if let modelPath {
			do {
				try FileManager.default.removeItem(atPath: modelPath)
			} catch {
				Self.logger.error("Couldn’t delete filter model: \(error.localizedDescription)")
			}
		}
		modelPath = nil

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

	func updateActiveCriteria() {
		var criteria = [Criterion]()
		if hidesSponsoredContent {
			criteria.append(.sponsoredContent)
		}
		if hidesTopics {
			criteria += topics.map { .topic($0) }
		}
		activeCriteria = criteria
	}

	var knownCriterionKeys: Set<String> {
		Set(topics.map { Criterion.key(forTopic: $0) }).union([Criterion.sponsoredContentKey])
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
		updateActiveCriteria()
		if !isActive {
			unloadModel()
			pendingTitles.removeAll()
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

		for title in titles where newTitleSet.insert(title).inserted {
			newTitles.append(title)
		}

		pendingTitles = pendingTitles.filter { !newTitleSet.contains($0) } + newTitles.reversed()
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
			pendingCount = pendingTitles.count

			let criteriaToJudge = activeCriteria.filter { verdicts[$0.key]?[title] == nil }
			if criteriaToJudge.isEmpty {
				continue
			}

			let probabilities: [String: Double]
			do {
				probabilities = try await Self.judge(title: title, criteria: criteriaToJudge, decision: decision)
			} catch is CancellationError {
				return
			} catch {
				guard !Task.isCancelled else {
					return
				}
				Self.logger.error("Couldn’t judge title: \(error.localizedDescription)")
				// Treat it as not matching, so a title that keeps failing doesn’t get retried forever.
				probabilities = Dictionary(uniqueKeysWithValues: criteriaToJudge.map { ($0.key, 0.0) })
			}

			guard !Task.isCancelled, self.decision === decision else {
				return
			}

			record(probabilities, for: title)
		}
	}

	func record(_ probabilities: [String: Double], for title: String) {
		let knownCriterionKeys = knownCriterionKeys
		var didHide = false
		for (criterionKey, probability) in probabilities where knownCriterionKeys.contains(criterionKey) {
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

		if let modelLoadTask {
			return await modelLoadTask.value
		}

		guard let modelPath else {
			return nil
		}

		let task = Task {
			await loadDecision(modelPath: modelPath)
		}
		modelLoadTask = task
		let decision = await task.value
		if modelLoadTask == task {
			modelLoadTask = nil
		}
		return decision
	}

	func loadDecision(modelPath: String) async -> Decision? {
		do {
			let model = try await Model.load(modelPath: modelPath)
			let decision = try Decision(model: model)

			guard self.modelPath == modelPath, isActive else {
				return nil
			}

			self.decision = decision
			return decision
		} catch {
			guard self.modelPath == modelPath else {
				return nil
			}
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

	static var modelFileURL: URL {
		AppConfig.dataSubfolder(named: modelFolderName).appendingPathComponent(modelFileName)
	}

	func downloadDidProgress(_ fractionCompleted: Double?) {
		guard downloader != nil, case .downloading = modelState else {
			return
		}
		modelState = .downloading(fractionCompleted: fractionCompleted)
	}

	func downloadDidComplete(_ result: Result<Void, Error>, modelPath: String) {
		guard downloader != nil else {
			return
		}
		downloader = nil

		switch result {
		case .success:
			self.modelPath = modelPath
			modelState = .downloaded
			Self.logger.info("Filter model downloaded")
			NotificationCenter.default.post(name: .titleFilterSettingsDidChange, object: self)
		case .failure:
			modelState = .failed(message: NSLocalizedString("The download failed", comment: "Filter settings"))
		}
	}

	static func existingModelPath() -> String? {
		let path = modelFileURL.path
		return FileManager.default.fileExists(atPath: path) ? path : nil
	}
}
