//
//  TitleFilterVerdictTable.swift
//  NetNewsWire
//
//  Created by Pierre Bresson on 11/5/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import RSDatabase
import RSDatabaseObjC

struct TitleFilterVerdictTable {

	static let name = "verdicts"

	private struct Column {
		static let topic = "topic"
		static let title = "title"
		static let probability = "probability"
		static let dateLastSeen = "dateLastSeen"
	}

	static func fetchAll(database: FMDatabase) -> [String: [String: Double]] {
		var results = [String: [String: Double]]()
		guard let resultSet = database.executeQuery("SELECT \(Column.topic), \(Column.title), \(Column.probability) FROM \(name);", withArgumentsIn: []) else {
			return results
		}
		defer {
			resultSet.close()
		}
		while resultSet.next() {
			guard let topic = resultSet.string(forColumn: Column.topic), let title = resultSet.string(forColumn: Column.title) else {
				continue
			}
			results[topic, default: [:]][title] = resultSet.double(forColumn: Column.probability)
		}
		return results
	}

	static func save(topic: String, title: String, probability: Double, database: FMDatabase) {
		let dictionary: DatabaseDictionary = [
			Column.topic: topic,
			Column.title: title,
			Column.probability: probability,
			Column.dateLastSeen: Date().timeIntervalSince1970
		]
		database.insertRow(dictionary, insertType: .orReplace, tableName: name)
	}

	static func updateDateLastSeen(titles: [String], database: FMDatabase) {
		let sql = "UPDATE \(name) SET \(Column.dateLastSeen) = ? WHERE \(Column.title) = ?;"
		let now = Date().timeIntervalSince1970
		for title in titles {
			database.executeUpdate(sql, withArgumentsIn: [now, title])
		}
	}

	static func delete(topic: String, database: FMDatabase) {
		database.deleteRowsWhere(key: Column.topic, equals: topic, tableName: name)
	}

	static func deleteAll(database: FMDatabase) {
		database.executeUpdate("DELETE FROM \(name);", withArgumentsIn: [])
	}

	static func deleteTopics(notIn topics: [String], database: FMDatabase) {
		guard !topics.isEmpty else {
			deleteAll(database: database)
			return
		}
		let placeholders = NSString.rs_SQLValueList(withPlaceholders: UInt(topics.count))
		database.executeUpdate("DELETE FROM \(name) WHERE \(Column.topic) NOT IN \(placeholders);", withArgumentsIn: topics)
	}

	static func removeExpired(olderThan cutoff: TimeInterval, database: FMDatabase) {
		let sql = "DELETE FROM \(name) WHERE \(Column.dateLastSeen) < ?;"
		database.executeUpdate(sql, withArgumentsIn: [cutoff])
	}
}
