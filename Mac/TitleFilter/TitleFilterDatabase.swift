//
//  TitleFilterDatabase.swift
//  NetNewsWire
//
//  Created by Pierre Bresson on 11/5/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import RSCore
import RSDatabase

@MainActor final class TitleFilterDatabase {

	let databasePath: String

	private let queue: DatabaseQueue

	private static let databaseFileName = "TitleFilter.db"
	private static let retentionDays = 30

	private static let tableCreationStatements = """
	CREATE TABLE IF NOT EXISTS verdicts (topic TEXT NOT NULL, title TEXT NOT NULL, probability REAL NOT NULL, dateLastSeen REAL NOT NULL, PRIMARY KEY (topic, title));
	CREATE INDEX IF NOT EXISTS verdicts_dateLastSeen_index ON verdicts (dateLastSeen);
	CREATE INDEX IF NOT EXISTS verdicts_title_index ON verdicts (title);
	"""

	convenience init() {
		self.init(databasePath: AppConfig.dataFolder.appendingPathComponent(Self.databaseFileName).path)
	}

	init(databasePath: String) {
		self.databasePath = databasePath
		let queue = DatabaseQueue(databasePath: databasePath, journalMode: .wal)
		queue.runCreateStatements(Self.tableCreationStatements)
		self.queue = queue
	}

	// MARK: - Startup
	
	func cleanUpOldAndFetchAll(topicKeys: Set<String>) -> [String: [String: Double]] {
		let cutoff = Date().timeIntervalSince1970 - TimeInterval(days: Self.retentionDays)
		let topicKeyArray = Array(topicKeys)
		nonisolated(unsafe) var verdicts = [String: [String: Double]]()

		queue.runInDatabaseSync { database in
			TitleFilterVerdictTable.removeExpired(olderThan: cutoff, database: database)
			TitleFilterVerdictTable.deleteTopics(notIn: topicKeyArray, database: database)
			verdicts = TitleFilterVerdictTable.fetchAll(database: database)
		}

		return verdicts
	}

	// MARK: - Saving

	func save(topicKey: String, title: String, probability: Double) {
		queue.runInDatabase { database in
			TitleFilterVerdictTable.save(topic: topicKey, title: title, probability: probability, database: database)
		}
	}

	func updateDateLastSeen(titles: [String]) {
		guard !titles.isEmpty else {
			return
		}
		queue.runInTransaction { database in
			TitleFilterVerdictTable.updateDateLastSeen(titles: titles, database: database)
		}
	}

	func deleteTopic(_ topicKey: String) {
		queue.runInDatabase { database in
			TitleFilterVerdictTable.delete(topic: topicKey, database: database)
		}
	}

	func deleteAll() {
		queue.runInDatabase { database in
			TitleFilterVerdictTable.deleteAll(database: database)
		}
	}

	// MARK: - Vacuum

	func vacuum() async {
		await queue.checkpoint()
	}
}
