//
//  FilterPreferencesViewController.swift
//  NetNewsWire
//
//  Created by Pierre Bresson on 11/4/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import AppKit
import RSCore

final class FilterPreferencesViewController: NSViewController {

	@IBOutlet var modelStatusImageView: NSImageView!
	@IBOutlet var modelStatusTextField: NSTextField!
	@IBOutlet var downloadProgressIndicator: NSProgressIndicator!
	@IBOutlet var modelButton: NSButton!
	@IBOutlet var sponsoredContentCheckbox: NSButton!
	@IBOutlet var topicsCheckbox: NSButton!
	@IBOutlet var topicTextField: NSTextField!
	@IBOutlet var tableView: NSTableView!
	@IBOutlet var removeButton: NSButton!
	@IBOutlet var filterStatusTextField: NSTextField!
	@IBOutlet var thresholdTextField: NSTextField!
	@IBOutlet var thresholdStepper: NSStepper!

	private var didRegisterForNotifications = false

	convenience init() {
		self.init(nibName: "FilterPreferencesView", bundle: nil)
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		thresholdStepper.minValue = TitleFilter.minimumThreshold
		thresholdStepper.maxValue = TitleFilter.maximumThreshold
		thresholdStepper.increment = 0.1
		modelStatusImageView.image = Assets.Images.filterModelStatus
		view.sizeToFittingSize()
	}

	override func viewWillAppear() {
		super.viewWillAppear()
		updateUI()
		if !didRegisterForNotifications {
			NotificationCenter.default.addObserver(self, selector: #selector(handleTitleFilterSettingsDidChange(_:)), name: .titleFilterSettingsDidChange, object: nil)
			NotificationCenter.default.addObserver(self, selector: #selector(handleTitleFilterStatusDidChange(_:)), name: .titleFilterStatusDidChange, object: nil)
			didRegisterForNotifications = true
		}
	}

	// MARK: - Actions

	@IBAction func modelButtonClicked(_ sender: Any?) {
		switch TitleFilter.shared.modelState {
		case .notDownloaded, .failed:
			TitleFilter.shared.downloadModel()
		case .downloaded:
			confirmDeleteModel()
		case .downloading:
			break
		}
	}

	@IBAction func sponsoredContentCheckboxClicked(_ sender: Any?) {
		TitleFilter.shared.setHidesSponsoredContent(sponsoredContentCheckbox.state == .on)
	}

	@IBAction func topicsCheckboxClicked(_ sender: Any?) {
		TitleFilter.shared.setHidesTopics(topicsCheckbox.state == .on)
	}

	@IBAction func thresholdStepperClicked(_ sender: Any?) {
		TitleFilter.shared.setThreshold(thresholdStepper.doubleValue)
	}

	@IBAction func addTopic(_ sender: Any?) {
		if TitleFilter.shared.addTopic(topicTextField.stringValue) {
			topicTextField.stringValue = ""
		}
	}

	@IBAction func removeTopic(_ sender: Any?) {
		guard let topic = selectedTopic else {
			return
		}
		TitleFilter.shared.removeTopic(topic)
	}

	// MARK: - Notifications

	@objc func handleTitleFilterSettingsDidChange(_ notification: Notification) {
		updateUI()
	}

	@objc func handleTitleFilterStatusDidChange(_ notification: Notification) {
		updateModelUI()
		updateFilterStatus()
	}
}

// MARK: - NSTableViewDataSource

extension FilterPreferencesViewController: NSTableViewDataSource {

	func numberOfRows(in tableView: NSTableView) -> Int {
		TitleFilter.shared.topics.count
	}
}

// MARK: - NSTableViewDelegate

extension FilterPreferencesViewController: NSTableViewDelegate {

	func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		guard let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: "Cell"), owner: nil) as? NSTableCellView else {
			return nil
		}
		cell.textField?.stringValue = TitleFilter.shared.topics[row]
		return cell
	}

	func tableViewSelectionDidChange(_ notification: Notification) {
		updateRemoveButtonState()
	}
}

// MARK: - Private

private extension FilterPreferencesViewController {

	var selectedTopic: String? {
		let row = tableView.selectedRow
		let topics = TitleFilter.shared.topics
		guard row >= 0, row < topics.count else {
			return nil
		}
		return topics[row]
	}

	func updateUI() {
		let filter = TitleFilter.shared
		sponsoredContentCheckbox.state = filter.hidesSponsoredContent ? .on : .off
		topicsCheckbox.state = filter.hidesTopics ? .on : .off
		thresholdStepper.doubleValue = filter.threshold
		thresholdTextField.stringValue = filter.threshold.formatted(.percent.precision(.fractionLength(0)))
		tableView.reloadData()
		updateRemoveButtonState()
		updateModelUI()
		updateFilterStatus()
	}

	func updateRemoveButtonState() {
		removeButton.isEnabled = selectedTopic != nil
	}

	func updateModelUI() {
		let downloadTitle = String(format: NSLocalizedString("Download (%@)", comment: "Filter settings"), ByteCountFormatter.string(fromByteCount: TitleFilter.modelDownloadSize, countStyle: .file))

		switch TitleFilter.shared.modelState {
		case .notDownloaded:
			modelStatusImageView.contentTintColor = .systemGray
			modelStatusTextField.stringValue = NSLocalizedString("Not downloaded", comment: "Filter settings")
			modelButton.title = downloadTitle
			showModelButton()

		case .downloading(let fractionCompleted):
			modelStatusImageView.contentTintColor = .systemOrange
			modelButton.isHidden = true
			downloadProgressIndicator.isHidden = false
			if let fractionCompleted {
				let format = NSLocalizedString("Downloading: %@", comment: "Filter settings")
				modelStatusTextField.stringValue = String(format: format, fractionCompleted.formatted(.percent.precision(.fractionLength(0))))
				downloadProgressIndicator.stopAnimation(self)
				downloadProgressIndicator.isIndeterminate = false
				downloadProgressIndicator.doubleValue = fractionCompleted
			} else {
				modelStatusTextField.stringValue = NSLocalizedString("Starting download", comment: "Filter settings")
				downloadProgressIndicator.isIndeterminate = true
				downloadProgressIndicator.startAnimation(self)
			}

		case .downloaded:
			modelStatusImageView.contentTintColor = .systemGreen
			modelStatusTextField.stringValue = NSLocalizedString("Downloaded", comment: "Filter settings")
			modelButton.title = NSLocalizedString("Delete Model", comment: "Filter settings")
			showModelButton()

		case .failed(let message):
			modelStatusImageView.contentTintColor = .systemRed
			modelStatusTextField.stringValue = message
			modelButton.title = downloadTitle
			showModelButton()
		}
	}

	func showModelButton() {
		downloadProgressIndicator.stopAnimation(self)
		downloadProgressIndicator.isHidden = true
		modelButton.isHidden = false
	}

	func updateFilterStatus() {
		filterStatusTextField.stringValue = filterStatusText()
	}

	func filterStatusText() -> String {
		let filter = TitleFilter.shared
		if filter.modelState != .downloaded {
			return NSLocalizedString("Download the model to start filtering.", comment: "Filter settings")
		}
		if !filter.isActive {
			if filter.hidesTopics && filter.topics.isEmpty {
				return NSLocalizedString("Add a topic to start filtering.", comment: "Filter settings")
			}
			return NSLocalizedString("Filtering is off.", comment: "Filter settings")
		}
		if filter.pendingCount > 0 {
			let format = NSLocalizedString("Titles left to check: %ld", comment: "Filter settings")
			return String(format: format, filter.pendingCount)
		}
		return ""
	}

	func confirmDeleteModel() {
		guard let window = view.window else {
			return
		}

		let alert = NSAlert()
		alert.alertStyle = .warning
		alert.messageText = NSLocalizedString("Delete the filtering model?", comment: "Delete filtering model alert title")
		alert.informativeText = NSLocalizedString("Articles will no longer be filtered until you download the model again.", comment: "Delete filtering model alert message")
		alert.addButton(withTitle: NSLocalizedString("Delete", comment: "Delete filtering model"))
		alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel deleting filtering model"))

		alert.beginSheetModal(for: window) { result in
			if result == .alertFirstButtonReturn {
				TitleFilter.shared.deleteModel()
			}
		}
	}
}
