import SwiftUI
import UIKit

struct MarkdownTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    
    // Create a placeholder text property
    var placeholderText: String = "Write your blog post here..."
    
    // Maintain a reference to the active text view
    private static var activeTextView: UITextView?

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.backgroundColor = UIColor.clear
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.autocorrectionType = .yes
        textView.autocapitalizationType = .sentences
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        
        // Save a reference to the active text view
        MarkdownTextView.activeTextView = textView
        
        // Add placeholder or content
        if text.isEmpty {
            textView.text = placeholderText
            textView.textColor = UIColor.placeholderText
        } else {
            // Apply markdown formatting
            textView.attributedText = MarkdownTextView.renderMarkdownHidingMarkers(text)
            textView.textColor = UIColor.label
        }
        
        // Listen for refresh notifications
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.refreshPreview(_:)),
            name: NSNotification.Name("RefreshMarkdownPreview"),
            object: nil
        )
        
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // Handle placeholder state
        if text.isEmpty && !uiView.isFirstResponder {
            uiView.text = placeholderText
            uiView.textColor = UIColor.placeholderText
            return
        }
        
        // If the text changed and view isn't actively being edited by the user
        if let currentText = uiView.text, currentText != text && !uiView.isFirstResponder {
            // Apply markdown formatting
            uiView.attributedText = MarkdownTextView.renderMarkdownHidingMarkers(text)
            uiView.textColor = UIColor.label
        }
        
        // Update selection only if needed and the view is first responder
        if uiView.isFirstResponder && uiView.selectedRange != selectedRange {
            // Ensure valid range
            if let attributedText = uiView.attributedText {
                let maxLength = attributedText.length
                let location = min(selectedRange.location, maxLength)
                let length = min(selectedRange.length, maxLength - location)
                
                let validRange = NSRange(location: location, length: length)
                uiView.selectedRange = validRange
            }
        }
    }

    static func dismantleUIView(_ uiView: UITextView, coordinator: Coordinator) {
        // Remove notification observer when view is dismantled
        NotificationCenter.default.removeObserver(coordinator)
        
        // Clear reference if this is the active text view
        if activeTextView === uiView {
            activeTextView = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownTextView
        // Track if we're actively formatting to avoid recursive updates
        private var isFormatting = false
        
        init(_ parent: MarkdownTextView) {
            self.parent = parent
        }
        
        func textViewDidChange(_ textView: UITextView) {
            guard !isFormatting else { return }
            
            DispatchQueue.main.async {
                if let text = textView.text {
                    self.parent.text = text
                    
                    // If we're not actively editing, reapply formatting
                    if !textView.isFirstResponder {
                        self.applyFormattingPreservingCursor(textView)
                    }
                }
            }
        }
        
        func textViewDidChangeSelection(_ textView: UITextView) {
            DispatchQueue.main.async {
                self.parent.selectedRange = textView.selectedRange
            }
        }
        
        func textViewDidBeginEditing(_ textView: UITextView) {
            // Remove placeholder if needed
            if textView.textColor == UIColor.placeholderText {
                textView.text = ""
                textView.textColor = UIColor.label
            } else if let attributedText = textView.attributedText {
                // Convert to plain text for editing
                let plainText = attributedText.string
                let selectedRange = textView.selectedRange
                textView.text = plainText
                textView.selectedRange = selectedRange
            }
        }
        
        func textViewDidEndEditing(_ textView: UITextView) {
            // Add placeholder if needed
            if let text = textView.text, text.isEmpty {
                textView.text = self.parent.placeholderText
                textView.textColor = UIColor.placeholderText
            } else {
                // Apply formatting when done editing
                applyFormattingPreservingCursor(textView)
            }
        }
        
        // Apply formatting while preserving cursor position
        private func applyFormattingPreservingCursor(_ textView: UITextView) {
            isFormatting = true
            let currentRange = textView.selectedRange
            
            // Safely unwrap the text
            guard let plainText = textView.text else {
                isFormatting = false
                return
            }
            
            // Apply markdown formatting
            textView.attributedText = MarkdownTextView.renderMarkdownHidingMarkers(plainText)
            
            // Restore cursor position
            if currentRange.location <= textView.attributedText.length {
                textView.selectedRange = currentRange
            }
            isFormatting = false
        }
        
        // Handle refresh notification
        @objc func refreshPreview(_ notification: Notification) {
            DispatchQueue.main.async {
                guard !self.isFormatting else { return }
                self.isFormatting = true
                
                // Get the text view
                let textView = MarkdownTextView.activeTextView ?? self.parent.findUITextView()
                
                if let textView = textView {
                    // Get the updated text and range
                    if let updatedText = notification.userInfo?["text"] as? String {
                        // Store current cursor position
                        let currentSelection = textView.selectedRange
                        
                        // Update the text if needed
                        if let currentText = textView.text, currentText != updatedText {
                            self.parent.text = updatedText
                            textView.text = updatedText
                        }
                        
                        // Apply formatting
                        textView.attributedText = MarkdownTextView.renderMarkdownHidingMarkers(updatedText)
                        
                        // Restore cursor position or use new one from notification
                        if let newRange = notification.userInfo?["range"] as? NSRange {
                            if newRange.location <= textView.attributedText.length {
                                textView.selectedRange = newRange
                                self.parent.selectedRange = newRange
                            }
                        } else {
                            // Make sure selection is within bounds
                            let maxLength = textView.attributedText.length
                            let location = min(currentSelection.location, maxLength)
                            let validRange = NSRange(location: location, length: 0)
                            textView.selectedRange = validRange
                        }
                    }
                }
                
                self.isFormatting = false
            }
        }
    }
    
    // Helper method to find the UITextView in the view hierarchy
    func findUITextView() -> UITextView? {
        // First check if we have a cached reference
        if let activeTextView = MarkdownTextView.activeTextView {
            return activeTextView
        }
        
        // Look for our UITextView in the app's key window
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first(where: { $0.isKeyWindow }) {
            return findTextView(in: window)
        }
        return nil
    }
    
    // Recursively search for UITextView
    private func findTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView {
            return textView
        }
        
        for subview in view.subviews {
            if let found = findTextView(in: subview) {
                return found
            }
        }
        
        return nil
    }

    // Render markdown, hiding markers and applying formatting
    static func renderMarkdownHidingMarkers(_ markdown: String) -> NSAttributedString {
        let attr = NSMutableAttributedString(string: markdown, attributes: [.font: UIFont.preferredFont(forTextStyle: .body)])
        
        // Simple, non-recursive markdown parsing
        let boldPattern = "\\*\\*(.*?)\\*\\*"
        let italicPattern = "(?<!\\*)\\*(?!\\*)(.*?)\\*(?!\\*)"
        let headingPattern = "^(#+) (.*)$"
        let quotePattern = "^> (.*)$"
        let codePattern = "`(.*?)`"
        
        // Process headings
        if let regex = try? NSRegularExpression(pattern: headingPattern, options: .anchorsMatchLines) {
            let matches = regex.matches(in: markdown, options: [], range: NSRange(location: 0, length: markdown.count))
            for match in matches.reversed() {
                if match.numberOfRanges >= 3 {
                    let hashCount = match.range(at: 1).length
                    let titleRange = match.range(at: 2)
                    let font = hashCount == 1 ? UIFont.preferredFont(forTextStyle: .title1) : UIFont.preferredFont(forTextStyle: .title2)
                    attr.addAttribute(.font, value: font, range: titleRange)
                }
            }
        }
        
        // Process bold text
        if let regex = try? NSRegularExpression(pattern: boldPattern, options: []) {
            let matches = regex.matches(in: markdown, options: [], range: NSRange(location: 0, length: markdown.count))
            for match in matches.reversed() {
                if match.numberOfRanges >= 2 {
                    let range = match.range(at: 1)
                    attr.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize), range: range)
                }
            }
        }
        
        // Process italic text
        if let regex = try? NSRegularExpression(pattern: italicPattern, options: []) {
            let matches = regex.matches(in: markdown, options: [], range: NSRange(location: 0, length: markdown.count))
            for match in matches.reversed() {
                if match.numberOfRanges >= 2 {
                    let range = match.range(at: 1)
                    attr.addAttribute(.font, value: UIFont.italicSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize), range: range)
                }
            }
        }
        
        // Process quotes
        if let regex = try? NSRegularExpression(pattern: quotePattern, options: .anchorsMatchLines) {
            let matches = regex.matches(in: markdown, options: [], range: NSRange(location: 0, length: markdown.count))
            for match in matches.reversed() {
                if match.numberOfRanges >= 2 {
                    let range = match.range(at: 1)
                    let paragraphStyle = NSMutableParagraphStyle()
                    paragraphStyle.headIndent = 20
                    paragraphStyle.firstLineHeadIndent = 20
                    attr.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
                    attr.addAttribute(.foregroundColor, value: UIColor.systemGray, range: range)
                }
            }
        }
        
        // Process inline code
        if let regex = try? NSRegularExpression(pattern: codePattern, options: []) {
            let matches = regex.matches(in: markdown, options: [], range: NSRange(location: 0, length: markdown.count))
            for match in matches.reversed() {
                if match.numberOfRanges >= 2 {
                    let range = match.range(at: 1)
                    let codeFont = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize - 1, weight: .regular)
                    attr.addAttribute(.font, value: codeFont, range: range)
                    attr.addAttribute(.backgroundColor, value: UIColor.systemGray6, range: range)
                }
            }
        }
        
        return attr
    }
} 