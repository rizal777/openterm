//
//  TerminalView.swift
//  OpenTerm
//
//  Created by Louis D'hauwe on 09/12/2017.
//  Copyright © 2017 Silver Fox. All rights reserved.
//

import UIKit
import InputAssistant
import MobileCoreServices

protocol TerminalViewDelegate: class {

	func didEnterCommand(_ command: String)
	func didChangeCurrentWorkingDirectory(_ workingDirectory: URL)

}

@IBDesignable
class TerminalView: UIView {

	let deviceName = UIDevice.current.name
	let executor = CommandExecutor()
	let textView = TerminalTextView()
	let inputAssistantView = InputAssistantView()
	let autoCompleteManager = AutoCompleteManager()

	let keyboardObserver = KeyboardObserver()

	var currentTextState = ANSITextState()
	var currentCommandStartIndex: String.Index! {
		didSet { self.updateAutoComplete() }
	}

	weak var delegate: TerminalViewDelegate?

	private var isWaitingForCommand = false

	init() {
		super.init(frame: .zero)

		setup()

	}

	override init(frame: CGRect) {
		super.init(frame: frame)

		setup()
	}

	required init?(coder aDecoder: NSCoder) {
		super.init(coder: aDecoder)

		setup()
	}

	private func setup() {

		executor.delegate = self

		textView.translatesAutoresizingMaskIntoConstraints = false
		self.addSubview(textView)

		textView.leadingAnchor.constraint(equalTo: self.leadingAnchor).isActive = true
		textView.trailingAnchor.constraint(equalTo: self.trailingAnchor).isActive = true
		textView.topAnchor.constraint(equalTo: self.topAnchor).isActive = true
		textView.bottomAnchor.constraint(equalTo: self.bottomAnchor).isActive = true

		textView.delegate = self

		self.writePrompt()

		textView.textDragDelegate = self
		textView.textDropDelegate = self

		self.setupAutoComplete()

		keyboardObserver.observe { (state) in

			let rect = self.textView.convert(state.keyboardFrameEnd, from: nil).intersection(self.textView.bounds)

			UIView.animate(withDuration: state.duration, delay: 0.0, options: state.options, animations: {

				self.textView.contentInset.bottom = rect.height
				self.textView.scrollIndicatorInsets.bottom = rect.height

			}, completion: nil)

		}

	}

	/// Performs the given block on the main thread, without dispatching if already there.
	private func performOnMain(_ block: @escaping () -> Void) {
		if Thread.isMainThread {
			block()
		} else {
			DispatchQueue.main.async(execute: block)
		}
	}

	private func appendText(_ text: NSAttributedString) {
		dispatchPrecondition(condition: .onQueue(.main))

		let new = NSMutableAttributedString(attributedString: textView.attributedText ?? NSAttributedString())
		new.append(text)
		textView.attributedText = new

		let rect = textView.caretRect(for: textView.endOfDocument)
		textView.scrollRectToVisible(rect, animated: true)
		self.textView.isScrollEnabled = false
		self.textView.isScrollEnabled = true
	}
	private func appendText(_ text: String) {
		dispatchPrecondition(condition: .onQueue(.main))

		appendText(NSAttributedString(string: text, attributes: [.foregroundColor: textView.textColor ?? .black, .font: textView.font!]))
	}

	// Display a prompt at the beginning of the line.
	func writePrompt() {
		newLine()
		appendText("\(deviceName): ")
		currentCommandStartIndex = textView.text.endIndex
	}

	// Appends the given string to the output, and updates the command start index.
	func writeOutput(_ string: String) {
		var formattedString = string.formattedAttributedString(withTextState: &self.currentTextState)
		formattedString = formattedString.withFilesAsLinks(currentDirectory: executor.currentWorkingDirectory.path)
		
		performOnMain {
			self.appendText(formattedString)
			self.currentCommandStartIndex = self.textView.text.endIndex
		}
	}

	// Moves the cursor to a new line, if it's not already
	func newLine() {
		currentTextState.reset()
		if !textView.text.hasSuffix("\n") && !textView.text.isEmpty {
			appendText("\n")
		}
		currentCommandStartIndex = textView.text.endIndex
	}

	// Clears the contents of the screen, resetting the terminal.
	func clearScreen() {
		currentCommandStartIndex = nil
		textView.text = ""
		currentTextState.reset()
	}

	@discardableResult
	override func becomeFirstResponder() -> Bool {
		return textView.becomeFirstResponder()
	}

	var currentCommand: String {
		get {

			guard let currentCommandStartIndex = currentCommandStartIndex, currentCommandStartIndex <= textView.text.endIndex else {
				return ""
			}

			let currentCmdRange = currentCommandStartIndex..<textView.text.endIndex

			return String(textView.text[currentCmdRange])
		}
		set {

			// Remove current command, if present
			if let currentCommandStartIndex = currentCommandStartIndex, currentCommandStartIndex <= textView.text.endIndex {
				let currentCmdRange = currentCommandStartIndex..<textView.text.endIndex
				let attributedString = NSMutableAttributedString(attributedString: textView.attributedText ?? NSAttributedString())
				attributedString.replaceCharacters(in: NSRange(currentCmdRange, in: textView.text), with: NSAttributedString())
				textView.attributedText = attributedString
			}

			// Add new current command
			appendText(newValue)
		}
	}

}

extension TerminalView: CommandExecutorDelegate {

	func commandExecutor(_ commandExecutor: CommandExecutor, receivedStdout stdout: String) {
		self.writeOutput(sanitizeOutput(stdout))
	}
	func commandExecutor(_ commandExecutor: CommandExecutor, receivedStderr stderr: String) {
		self.writeOutput(sanitizeOutput(stderr))
	}
	func commandExecutor(_ commandExecutor: CommandExecutor, didFinishDispatchWithExitCode exitCode: Int32) {
		DispatchQueue.main.async {
			self.writePrompt()
		}
	}
	func commandExecutor(_ commandExecutor: CommandExecutor, didChangeWorkingDirectory to: URL) {
		DispatchQueue.main.async {
			self.delegate?.didChangeCurrentWorkingDirectory(to)
		}
	}

	func sanitizeOutput(_ output: String) -> String {
		var output = output
		// Replace $HOME with "~"
		output = output.replacingOccurrences(of: DocumentManager.shared.activeDocumentsFolderURL.path, with: "~")
		// Sometimes, fileManager adds /private in front of the directory
		output = output.replacingOccurrences(of: "/private", with: "")
		return output
	}
}

extension TerminalView: UITextDragDelegate {

	private func previewForDrag(dragRequest: UITextDragRequest) -> UIDragPreview {
		let label = UILabel()
		label.text = textView.text(in: dragRequest.dragRange)
		label.backgroundColor = UIColor.clear
		label.textColor = textView.textColor
		label.font = textView.font
		label.textAlignment = .center
		var size = label.sizeThatFits(CGSize(width: 300, height: 200))
		size.width += 10
		size.height += 10
		label.frame = CGRect(origin: CGPoint.zero, size: size)
		
		let parameters = UIDragPreviewParameters()
		parameters.visiblePath = UIBezierPath.init(roundedRect: label.bounds, cornerRadius: 7)
		
		let preview = UIDragPreview(view:label, parameters:parameters)
		return preview
	}
	
	func textDraggableView(_ textDraggableView: UIView & UITextDraggable, itemsForDrag dragRequest: UITextDragRequest) -> [UIDragItem] {
		// allow dragging URLs
		var items = [UIDragItem]()
		for item in dragRequest.suggestedItems {
			let fileURLType = kUTTypeFileURL as String
			if item.itemProvider.hasItemConformingToTypeIdentifier(fileURLType) {
				
				// determine uti making sure not to use dynamic type
				let filename = (textView.text(in: dragRequest.dragRange) ?? "") as NSString
				let uti_ns = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, filename.pathExtension as CFString, nil)?.takeRetainedValue() as NSString?
				var uti = uti_ns != nil ? String(uti_ns!) : (kUTTypeFileURL as String)
				if uti.hasPrefix("dyn.") { uti = kUTTypeFileURL as String }
				
				let provider = NSItemProvider()
				provider.registerFileRepresentation(forTypeIdentifier: uti, fileOptions: .openInPlace, visibility: .all,
													loadHandler: { (completion) in
														
					// read url from source provider
					let _ = item.itemProvider.loadObject(ofClass: URL.self,
														 completionHandler: { (reader, error) in
						completion(reader, true, error)
					})
														
					return nil
				})
				provider.suggestedName = String(filename)
				
				let dragItem = UIDragItem(itemProvider: provider)
				
				
				// We want to set url from attributtedText directory
				textView.attributedText.enumerateAttribute(.link, in: textView.range(dragRequest.dragRange), options: [],
														   using: { (link, _, _) in
					if link is String {
						dragItem.localObject = URL(string: link! as! String)
					} else if(link is URL) {
						dragItem.localObject = link! as! URL
					}
				})
				
				// use label of dragged text as preview
				dragItem.previewProvider = { return self.previewForDrag(dragRequest: dragRequest) }
				items.append(dragItem)
			}
		}
		return items
	}

}

extension TerminalView: UITextDropDelegate {
	func textDroppableView(_ textDroppableView: UIView & UITextDroppable, proposalForDrop drop: UITextDropRequest) -> UITextDropProposal {
		let proposal = UITextDropProposal(operation: UIDropOperation.copy)
		proposal.useFastSameViewOperations = false
		proposal.dropAction = .replaceSelection
		return proposal
	}
	
	func textDroppableView(_ textDroppableView: UIView & UITextDroppable, willPerformDrop drop: UITextDropRequest) {
		textView.pasteDelegate = self
	}
	
	func textDroppableView(_ textDroppableView: UIView & UITextDroppable,
						   dropSessionDidEnd session: UIDropSession) {
		// move cursor to end of document when finished with drop
		let end = textView.endOfDocument
		textView.selectedTextRange = textView.textRange(from: end, to: end)
		textView.becomeFirstResponder()
		textView.pasteDelegate = nil
	}
}

extension TerminalView : UITextPasteDelegate {
	func textPasteConfigurationSupporting(_ textPasteConfigurationSupporting: UITextPasteConfigurationSupporting,
										  transform item: UITextPasteItem) {
		
		// try to pick result from localObject
		if let localUrl: URL = item.localObject as! URL? {
			let currentDirectory = self.executor.currentWorkingDirectory.path
			let result = relative(filename: localUrl.path, to: currentDirectory)
			item.setResult(string: result)
			return
		}

		// we want to paste as the first public type
		for uti in item.itemProvider.registeredTypeIdentifiers {
			if uti.hasPrefix("public.") {
				paste(item: item, uti:uti)
				return
			}
			
		}
		
		// we only get to this point if there are no public types
		let uti = item.itemProvider.registeredTypeIdentifiers.first ?? (kUTTypeFileURL as String)
		paste(item: item, uti:uti)
	}
	
	private func paste(item: UITextPasteItem, uti: String) {
		item.itemProvider.loadInPlaceFileRepresentation(forTypeIdentifier: uti,
														completionHandler: { url, inPlace, error in
															
			guard let url = url else { return }
															
				if inPlace {
					let _ = url.startAccessingSecurityScopedResource()
					let currentDirectory = self.executor.currentWorkingDirectory.path
					let result = relative(filename: url.path, to: currentDirectory)
					item.setResult(string: result)
					url.stopAccessingSecurityScopedResource()
				} else {
					// make sure we have /tmp/drop folder
					let tempFolder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("drop")
					try? FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
																
					// copy to /tmp/drop folder
					let filename = url.lastPathComponent
					let tempUrl = tempFolder.appendingPathComponent(filename).unused()
					do {
						try FileManager.default.copyItem(at: url, to: tempUrl)
						item.setResult(string: tempUrl.path)
					} catch {
						NSLog("Unable to create temp file: \(error)")
					}
				}
		})
	}
}

extension TerminalView: UITextViewDelegate {

	func textViewDidChangeSelection(_ textView: UITextView) {

		//		if currentCommandStartIndex == nil {
		//			return
		//		}
		//
		//		let i = textView.text.distance(from: textView.text.startIndex, to: currentCommandStartIndex)
		//
		//		if textView.selectedRange.location < i {
		//			textView.selectedRange = NSMakeRange(i, 0)
		//		}
		//
	}

	func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {

		guard !isWaitingForCommand else {
			return false
		}

		let i = textView.text.distance(from: textView.text.startIndex, to: currentCommandStartIndex)

		if range.location < i {
			return false
		}

		if text == "\n" {

			let input = textView.text[currentCommandStartIndex..<textView.text.endIndex]

			if input.isEmpty {
				writePrompt()
			} else {
				newLine()
				delegate?.didEnterCommand(String(input))
			}
			return false
		}

		return true
	}

	func textViewDidChange(_ textView: UITextView) {
		updateAutoComplete()
	}

}
