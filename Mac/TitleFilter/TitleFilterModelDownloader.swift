//
//  TitleFilterModelDownloader.swift
//  NetNewsWire
//
//  Created by Pierre Bresson on 11/10/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import os

final class TitleFilterModelDownloader: NSObject, Sendable {

	typealias ProgressHandler = @MainActor @Sendable (_ fractionCompleted: Double?) -> Void
	typealias CompletionHandler = @MainActor @Sendable (Result<Void, Error>) -> Void

	enum DownloadError: LocalizedError {
		case badStatusCode(Int)

		var errorDescription: String? {
			switch self {
			case let .badStatusCode(statusCode):
				String(format: NSLocalizedString("The server responded with status %ld.", comment: "Filter model download error"), statusCode)
			}
		}
	}

	private struct State {
		var lastReportedPercent = -1
		var didComplete = false
	}

	private let sourceURL: URL
	private let destinationURL: URL
	private let progressHandler: ProgressHandler
	private let completionHandler: CompletionHandler
	private let state = OSAllocatedUnfairLock(initialState: State())
	private nonisolated(unsafe) var session: URLSession?

	private static let requestTimeoutInterval: TimeInterval = 60

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "TitleFilterModelDownloader")

	init(sourceURL: URL, destinationURL: URL, progressHandler: @escaping ProgressHandler, completionHandler: @escaping CompletionHandler) {
		self.sourceURL = sourceURL
		self.destinationURL = destinationURL
		self.progressHandler = progressHandler
		self.completionHandler = completionHandler
		super.init()
	}

	func start() {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = Self.requestTimeoutInterval
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

		let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
		self.session = session
		session.downloadTask(with: sourceURL).resume()
	}

	func cancel() {
		let alreadyCompleted = state.withLock { state in
			let alreadyCompleted = state.didComplete
			state.didComplete = true
			return alreadyCompleted
		}
		guard !alreadyCompleted else {
			return
		}
		session?.invalidateAndCancel()
	}
}

// MARK: - URLSessionDownloadDelegate

extension TitleFilterModelDownloader: URLSessionDownloadDelegate {

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
		guard totalBytesExpectedToWrite > 0 else {
			reportProgress(nil)
			return
		}

		let percent = Int(min(totalBytesWritten, totalBytesExpectedToWrite) * 100 / totalBytesExpectedToWrite)
		let shouldReport = state.withLock { state in
			guard !state.didComplete, percent > state.lastReportedPercent else {
				return false
			}
			state.lastReportedPercent = percent
			return true
		}
		if shouldReport {
			reportProgress(Double(percent) / 100.0)
		}
	}

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		let result: Result<Void, Error>
		if let httpResponse = downloadTask.response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
			result = .failure(DownloadError.badStatusCode(httpResponse.statusCode))
		} else {
			result = Result { try moveDownloadedFile(from: location) }
		}
		complete(with: result)
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		session.finishTasksAndInvalidate()
		if let error {
			complete(with: .failure(error))
		}
	}
}

// MARK: - Private

private extension TitleFilterModelDownloader {

	func moveDownloadedFile(from location: URL) throws {
		let fileManager = FileManager.default
		try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		if fileManager.fileExists(atPath: destinationURL.path) {
			try fileManager.removeItem(at: destinationURL)
		}
		try fileManager.moveItem(at: location, to: destinationURL)
	}

	func reportProgress(_ fractionCompleted: Double?) {
		let progressHandler = progressHandler
		Task { @MainActor in
			progressHandler(fractionCompleted)
		}
	}

	func complete(with result: Result<Void, Error>) {
		let alreadyCompleted = state.withLock { state in
			let alreadyCompleted = state.didComplete
			state.didComplete = true
			return alreadyCompleted
		}
		guard !alreadyCompleted else {
			return
		}

		if case let .failure(error) = result {
			Self.logger.error("Filter model download failed: \(error.localizedDescription)")
		}

		let completionHandler = completionHandler
		Task { @MainActor in
			completionHandler(result)
		}
	}
}
