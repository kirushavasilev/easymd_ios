//
//  ContentView.swift
//  Test
//
//  Created by 1 on 23/06/25.
//

import SwiftUI
import PhotosUI
import UIKit
import SQLite3
import Foundation

// Helper extension for chunking arrays
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

struct BlogPost: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String
    let date: String
    let lastEdited: String
    let fileURL: URL
    let content: String
    let tools: [String]
    let isDraft: Bool
    let isArchived: Bool // Represents the "draft" field in frontmatter (website visibility)
}

class BlogStore {
    static let shared = BlogStore()
    private var db: OpaquePointer?
    private let fileManager = FileManager.default
    private let docsURL: URL
    private let dbURL: URL
    private let appDataDir: URL
    
    private init() {
        // Use proper iOS Application Support directory for persistent app data
        // This is the recommended directory for app-generated content that should persist
        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appDataDir = appSupportDir.appendingPathComponent("KVBlogApp")
        
        // Use Application Support for drafts (proper persistent storage)
        docsURL = appDataDir.appendingPathComponent("Drafts")
        
        // Database in Application Support directory (Apple recommended)
        dbURL = appDataDir.appendingPathComponent("blogs.sqlite")
        
        print("📂 Using iOS Application Support directory")
        print("📂 App data directory: \(appDataDir.path)")
        print("📂 Drafts directory: \(docsURL.path)")
        print("📂 Database location: \(dbURL.path)")
        
        // Ensure directories exist
        createAppDirectories()
        
        // Check if database file exists
        if FileManager.default.fileExists(atPath: dbURL.path) {
            print("✅ Database file exists")
        } else {
            print("📝 Creating new database file")
        }
        
        openDatabase()
        createTable()
        
        // Debug: Check if database was created successfully
        if FileManager.default.fileExists(atPath: dbURL.path) {
            print("✅ Database file confirmed after creation")
            
            // Set file attributes to ensure persistence
            do {
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = false // Allow iCloud backup
                var mutableDbURL = dbURL
                try mutableDbURL.setResourceValues(resourceValues)
                print("✅ Database backup settings configured")
            } catch {
                print("⚠️ Could not set database backup settings: \(error)")
            }
        } else {
            print("❌ Database file not found after creation!")
        }
        
        // Migrate any existing drafts from Documents directory
        migrateExistingDrafts()
        
        // Try to restore from UserDefaults backup if needed
        restoreFromBackup()
        
        // Clean up any existing duplicates and orphaned files
        cleanupDuplicatesAndOrphans()
        
        // Backup critical draft info to UserDefaults as secondary persistence
        backupDraftMetadata()
    }
    
    private func createAppDirectories() {
        do {
            // Create main app directory
            if !fileManager.fileExists(atPath: appDataDir.path) {
                try fileManager.createDirectory(at: appDataDir, withIntermediateDirectories: true)
                print("✅ Created app data directory: \(appDataDir.path)")
            }
            
            // Create drafts subdirectory
            if !fileManager.fileExists(atPath: docsURL.path) {
                try fileManager.createDirectory(at: docsURL, withIntermediateDirectories: true)
                print("✅ Created drafts directory: \(docsURL.path)")
            }
        } catch {
            print("❌ Error creating app directories: \(error)")
        }
    }
    
    private func migrateExistingDrafts() {
        // Check both Documents and old KVBlogApp directory for existing drafts
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let oldKVBlogAppDir = documentsDir.appendingPathComponent("KVBlogApp")
        
        let searchDirectories = [documentsDir, oldKVBlogAppDir]
        
        for searchDir in searchDirectories {
            guard fileManager.fileExists(atPath: searchDir.path) else { continue }
            
            do {
                let files = try fileManager.contentsOfDirectory(at: searchDir, includingPropertiesForKeys: nil)
                let markdownFiles = files.filter { $0.pathExtension == "md" }
                
                print("🔄 Checking \(searchDir.lastPathComponent) - found \(markdownFiles.count) markdown files")
                
                for file in markdownFiles {
                    // Check if it's a draft by reading the content
                    if let content = try? String(contentsOf: file, encoding: .utf8),
                       content.contains("draft: true") {
                        
                        let newLocation = docsURL.appendingPathComponent(file.lastPathComponent)
                        
                        // Skip if already exists in new location
                        if fileManager.fileExists(atPath: newLocation.path) {
                            print("⏭️ Draft already exists at new location: \(file.lastPathComponent)")
                            continue
                        }
                        
                        do {
                            // Copy to new location
                            try fileManager.copyItem(at: file, to: newLocation)
                            print("✅ Migrated draft: \(file.lastPathComponent)")
                            
                            // Set backup attributes for the migrated file
                            var resourceValues = URLResourceValues()
                            resourceValues.isExcludedFromBackup = false
                            var mutableNewLocation = newLocation
                            try mutableNewLocation.setResourceValues(resourceValues)
                            
                            // Remove from old location
                            try fileManager.removeItem(at: file)
                        } catch {
                            print("❌ Failed to migrate \(file.lastPathComponent): \(error)")
                        }
                    }
                }
            } catch {
                print("❌ Error reading directory \(searchDir.path): \(error)")
            }
        }
    }
    
    func backupDraftMetadata() {
        let drafts = getAllBlogs().filter { $0.isDraft }
        
        // Create comprehensive backup with full content
        var draftBackups: [[String: Any]] = []
        
        for draft in drafts {
            let backup: [String: Any] = [
                "id": draft.id,
                "title": draft.title,
                "summary": draft.summary,
                "content": draft.content,
                "tools": draft.tools,
                "date": draft.date,
                "path": draft.fileURL.path,
                "timestamp": Date().timeIntervalSince1970
            ]
            draftBackups.append(backup)
        }
        
        UserDefaults.standard.set(draftBackups, forKey: "comprehensive_draft_backup")
        UserDefaults.standard.synchronize() // Force immediate save
        print("💾 Comprehensive backup: \(drafts.count) drafts saved to UserDefaults")
    }
    
    private func restoreFromBackup() {
        guard let backupData = UserDefaults.standard.array(forKey: "comprehensive_draft_backup") as? [[String: Any]] else {
            print("📋 No comprehensive backup data found")
            return
        }
        
        print("🔄 Attempting to restore \(backupData.count) drafts from UserDefaults backup")
        var restoredCount = 0
        
        for draftData in backupData {
            guard let id = draftData["id"] as? String,
                  let title = draftData["title"] as? String,
                  let summary = draftData["summary"] as? String,
                  let content = draftData["content"] as? String,
                  let tools = draftData["tools"] as? [String],
                  let date = draftData["date"] as? String else { 
                print("❌ Invalid backup data structure")
                continue 
            }
            
            // Check if this draft already exists
            let existingDrafts = getAllBlogs().filter { $0.isDraft }
            if existingDrafts.contains(where: { $0.id == id }) {
                print("⏭️ Draft already exists: \(title)")
                continue
            }
            
            // Create new file for restored draft
            let safeTitle = title.isEmpty ? "Untitled" : title.replacingOccurrences(of: " ", with: "_")
            let filename = "\(safeTitle)_\(id).md"
            let newFileURL = docsURL.appendingPathComponent(filename)
            
            // Recreate the markdown content
            let toolsString = tools.map { "\"\($0)\"" }.joined(separator: ", ")
            let markdownContent = """
            ---
            title: "\(title)"
            summary: "\(summary)"
            date: "\(date)"
            draft: true
            tools: [\(toolsString)]
            ---
            
            \(content)
            """
            
            do {
                // Write file to new location
                try markdownContent.write(to: newFileURL, atomically: true, encoding: .utf8)
                
                // Set backup attributes
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = false
                var mutableNewFileURL = newFileURL
                try mutableNewFileURL.setResourceValues(resourceValues)
                
                // Save to database
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"
                let dateString = dateFormatter.string(from: Date())
                
                saveBlog(
                    id: id,
                    title: title,
                    summary: summary,
                    date: dateString,
                    filepath: newFileURL.path,
                    isDraft: true
                )
                
                print("✅ Restored draft from backup: \(title)")
                restoredCount += 1
                
            } catch {
                print("❌ Failed to restore draft \(title): \(error)")
            }
        }
        
        if restoredCount > 0 {
            print("🎉 Successfully restored \(restoredCount) drafts from UserDefaults backup")
        }
    }
    
    private func openDatabase() {
        let result = sqlite3_open(dbURL.path, &db)
        if result != SQLITE_OK {
            print("❌ Error opening database: \(result)")
            if let errorMessage = sqlite3_errmsg(db) {
                print("❌ Database error message: \(String(cString: errorMessage))")
            }
            return
        }
        print("✅ Database opened successfully")
    }
    
    private func createTable() {
        let createTableString = """
        CREATE TABLE IF NOT EXISTS blogs(
            id TEXT PRIMARY KEY,
            title TEXT,
            summary TEXT,
            date TEXT,
            filepath TEXT,
            isDraft INTEGER,
            isArchived INTEGER DEFAULT 0,
            originalFilename TEXT
        );
        """
        
        var createTableStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, createTableString, -1, &createTableStatement, nil) == SQLITE_OK {
            if sqlite3_step(createTableStatement) == SQLITE_DONE {
                print("Blogs table created.")
            } else {
                print("Blogs table could not be created.")
            }
        } else {
            print("CREATE TABLE statement could not be prepared.")
        }
        sqlite3_finalize(createTableStatement)
        
        // Add isArchived column to existing tables if it doesn't exist
        let addColumnString = "ALTER TABLE blogs ADD COLUMN isArchived INTEGER DEFAULT 0;"
        var addColumnStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, addColumnString, -1, &addColumnStatement, nil) == SQLITE_OK {
            sqlite3_step(addColumnStatement) // This will fail if column exists, which is fine
        }
        sqlite3_finalize(addColumnStatement)
        
        // Add originalFilename column to existing tables if it doesn't exist  
        let addFilenameColumnString = "ALTER TABLE blogs ADD COLUMN originalFilename TEXT;"
        var addFilenameColumnStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, addFilenameColumnString, -1, &addFilenameColumnStatement, nil) == SQLITE_OK {
            sqlite3_step(addFilenameColumnStatement) // This will fail if column exists, which is fine
        }
        sqlite3_finalize(addFilenameColumnStatement)
    }
    
    func saveBlog(id: String, title: String, summary: String, date: String, filepath: String, isDraft: Bool, isArchived: Bool = false, originalFilename: String? = nil) {
        let insertStatementString = "INSERT OR REPLACE INTO blogs (id, title, summary, date, filepath, isDraft, isArchived, originalFilename) VALUES (?, ?, ?, ?, ?, ?, ?, ?);"
        var insertStatement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, insertStatementString, -1, &insertStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(insertStatement, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStatement, 2, (title as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStatement, 3, (summary as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStatement, 4, (date as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStatement, 5, (filepath as NSString).utf8String, -1, nil)
            sqlite3_bind_int(insertStatement, 6, isDraft ? 1 : 0)
            sqlite3_bind_int(insertStatement, 7, isArchived ? 1 : 0)
            
            if let filename = originalFilename {
                sqlite3_bind_text(insertStatement, 8, (filename as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(insertStatement, 8)
            }
            
            if sqlite3_step(insertStatement) == SQLITE_DONE {
                print("✅ Successfully saved blog: \(title) (Draft: \(isDraft))")
            } else {
                let errorMessage = sqlite3_errmsg(db)
                print("❌ Could not insert/update row: \(String(cString: errorMessage!))")
            }
        } else {
            print("INSERT statement could not be prepared.")
        }
        
        sqlite3_finalize(insertStatement)
        
        // Force database sync to ensure persistence
        sqlite3_exec(db, "PRAGMA synchronous = FULL;", nil, nil, nil)
        
        // Auto-backup to UserDefaults whenever a draft is saved
        if isDraft {
            backupDraftMetadata()
        }
    }
    
    func deleteBlog(id: String) {
        let deleteStatementString = "DELETE FROM blogs WHERE id = ?;"
        var deleteStatement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, deleteStatementString, -1, &deleteStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(deleteStatement, 1, (id as NSString).utf8String, -1, nil)
            
            if sqlite3_step(deleteStatement) == SQLITE_DONE {
                print("Successfully deleted row.")
            } else {
                print("Could not delete row.")
            }
        } else {
            print("DELETE statement could not be prepared.")
        }
        
        sqlite3_finalize(deleteStatement)
    }
    
    func getAllBlogs() -> [BlogPost] {
        var blogs: [BlogPost] = []
        let queryStatementString = "SELECT id, title, summary, date, filepath, isDraft, COALESCE(isArchived, 0), originalFilename FROM blogs;"
        var queryStatement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
            while sqlite3_step(queryStatement) == SQLITE_ROW {
                let id = String(describing: String(cString: sqlite3_column_text(queryStatement, 0)))
                let title = String(describing: String(cString: sqlite3_column_text(queryStatement, 1)))
                let summary = String(describing: String(cString: sqlite3_column_text(queryStatement, 2)))
                let dateString = String(describing: String(cString: sqlite3_column_text(queryStatement, 3)))
                let filepath = String(describing: String(cString: sqlite3_column_text(queryStatement, 4)))
                let isDraft = sqlite3_column_int(queryStatement, 5) == 1
                let isArchived = sqlite3_column_int(queryStatement, 6) == 1
                
                // Get original filename if it exists
                var originalFilename: String? = nil
                if let filenamePtr = sqlite3_column_text(queryStatement, 7) {
                    originalFilename = String(cString: filenamePtr)
                }
                
                // Try to load the file content
                let fileURL = URL(fileURLWithPath: filepath)
                if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                    print("📖 Reading file for \(title): \(fileURL.path)")
                    print("📖 File content length: \(content.count) chars")
                    print("📖 Content preview: \(String(content.prefix(200)))...")
                    
                    // Use original filename info if available, otherwise fall back to file modification date
                    let lastEdited: String
                    if let filename = originalFilename {
                        lastEdited = "Synced from GitHub:\(filename)"
                    } else {
                        lastEdited = getLastEditedDate(for: fileURL)
                    }
                    
                    let displayDate = formatDisplayDate(from: dateString)
                    let tools = extractTools(from: content)
                    
                    // Extract actual content
                    let blogContent = extractContent(from: content)
                    print("📖 Extracted blog content length: \(blogContent.count) chars")
                    
                    // Create blog post
                    let post = BlogPost(
                        id: id,
                        title: title,
                        summary: summary,
                        date: displayDate,
                        lastEdited: lastEdited,
                        fileURL: fileURL,
                        content: blogContent,
                        tools: tools,
                        isDraft: isDraft,
                        isArchived: isArchived // Use the actual isArchived value from database
                    )
                    blogs.append(post)
                }
            }
        } else {
            print("SELECT statement could not be prepared")
        }
        
        sqlite3_finalize(queryStatement)
        return blogs
    }
    
    private func getLastEditedDate(for fileURL: URL) -> String {
        let dateTimeFormatter = DateFormatter()
        dateTimeFormatter.dateStyle = .medium
        dateTimeFormatter.timeStyle = .short
        
        if let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
           let modDate = attrs.contentModificationDate {
            return dateTimeFormatter.string(from: modDate)
        }
        return "-"
    }
    
    private func formatDisplayDate(from dateString: String) -> String {
        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.dateStyle = .medium
        dateOnlyFormatter.timeStyle = .none
        
        // Try parsing as ISO8601
        if let date = ISO8601DateFormatter().date(from: dateString) {
            return dateOnlyFormatter.string(from: date)
        }
        
        // Try parsing as yyyy-MM-dd
        let simpleDateFormatter = DateFormatter()
        simpleDateFormatter.dateFormat = "yyyy-MM-dd"
        
        // Clean the string and try to parse
        let cleanDateString = dateString.replacingOccurrences(of: "\"", with: "")
                                       .trimmingCharacters(in: .whitespacesAndNewlines)
        
        if let date = simpleDateFormatter.date(from: cleanDateString) {
            return dateOnlyFormatter.string(from: date)
        }
        
        // If all parsing attempts fail, return the original string
        return dateString
    }
    
    private func extractTools(from content: String) -> [String] {
        if let frontMatter = content.components(separatedBy: "---").dropFirst().first,
           let toolsString = extractYAMLValue(frontMatter, key: "tools") {
            return toolsString.replacingOccurrences(of: "[\\[\\]\"]", with: "", options: .regularExpression)
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
    }
    
    private func extractContent(from content: String) -> String {
        return content.components(separatedBy: "---")
            .dropFirst(2)
            .joined(separator: "---")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func extractYAMLValue(_ yaml: String, key: String) -> String? {
        for line in yaml.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):") {
                return line.components(separatedBy: ":").dropFirst().joined(separator: ":")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\"", with: "")
            }
        }
        return nil
    }
    
    func publishDraft(_ post: BlogPost) -> Bool {
        // Get the existing content
        guard var content = try? String(contentsOf: post.fileURL, encoding: .utf8) else { return false }
        
        // Check if it has the draft flag
        if let range = content.range(of: "draft: true") {
            // Replace draft flag with false
            content.replaceSubrange(range, with: "draft: false")
            
            // Write the updated content back to the same file
            do {
                try content.write(to: post.fileURL, atomically: true, encoding: .utf8)
                
                // Update the database record
                saveBlog(
                    id: post.id,
                    title: post.title,
                    summary: post.summary,
                    date: post.date,
                    filepath: post.fileURL.path,
                    isDraft: false,
                    isArchived: post.isArchived
                )
                
                return true
            } catch {
                print("Error publishing draft: \(error)")
                return false
            }
        }
        
        return false
    }
    
    // Add debugging helpers
    func dumpAllRecords() {
        print("------- DATABASE RECORDS -------")
        let queryStatementString = "SELECT id, title, filepath, isDraft FROM blogs;"
        var queryStatement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
            while sqlite3_step(queryStatement) == SQLITE_ROW {
                let id = String(describing: String(cString: sqlite3_column_text(queryStatement, 0)))
                let title = String(describing: String(cString: sqlite3_column_text(queryStatement, 1)))
                let filepath = String(describing: String(cString: sqlite3_column_text(queryStatement, 2)))
                let isDraft = sqlite3_column_int(queryStatement, 3) == 1
                print("ID: \(id), Title: \(title), Path: \(filepath), Draft: \(isDraft)")
            }
        }
        sqlite3_finalize(queryStatement)
        print("-------------------------------")
    }
    
    // Clean up duplicate records and orphaned files
    func cleanupDuplicatesAndOrphans() {
        print("🧹 Starting cleanup of duplicates and orphans...")
        
        // Get all records from database
        let allBlogs = getAllBlogs()
        var seenIDs = Set<String>()
        var duplicateIDs: [String] = []
        
        // Find duplicate IDs
        for blog in allBlogs {
            if seenIDs.contains(blog.id) {
                duplicateIDs.append(blog.id)
                print("🔍 Found duplicate ID: \(blog.id) for post: \(blog.title)")
            } else {
                seenIDs.insert(blog.id)
            }
        }
        
        // Remove duplicates (keep the first occurrence)
        for duplicateID in duplicateIDs {
            let duplicates = allBlogs.filter { $0.id == duplicateID }
            // Keep the first, delete the rest
            for (index, duplicate) in duplicates.enumerated() {
                if index > 0 {
                    print("🗑️ Removing duplicate record: \(duplicate.title) (ID: \(duplicate.id))")
                    deleteBlog(id: duplicate.id)
                    // Also remove the file
                    try? FileManager.default.removeItem(at: duplicate.fileURL)
                }
            }
        }
        
        // Find orphaned files (files without database records)
        let fileManager = FileManager.default
        guard let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
        do {
            let files = try fileManager.contentsOfDirectory(at: docsURL, includingPropertiesForKeys: nil)
            let markdownFiles = files.filter { $0.pathExtension == "md" }
            
            for file in markdownFiles {
                let hasRecord = allBlogs.contains { $0.fileURL.path == file.path }
                if !hasRecord {
                    print("🗑️ Found orphaned file: \(file.lastPathComponent)")
                    try? fileManager.removeItem(at: file)
                }
            }
        } catch {
            print("❌ Error during cleanup: \(error)")
        }
        
        print("✅ Cleanup completed")
    }
    
    func createOrUpdateBlogFile(post: BlogPost?, title: String, summary: String, date: Date, content: String, tools: [String], isDraft: Bool, image: UIImage?) -> URL {
        print("createOrUpdateBlogFile called - Updating existing post: \(post != nil)")
        if let existingPost = post {
            print("Using existing post with ID: \(existingPost.id), path: \(existingPost.fileURL.path)")
            dumpAllRecords()
        }
        
        // Determine file path - use existing path for updates
        var fileURL: URL
        var id: String
        
        if let existingPost = post {
            // Always use the existing file URL for updates
            fileURL = existingPost.fileURL
            id = existingPost.id
            
            // Force delete the old record first to avoid duplicates
            print("Deleting existing database record with ID: \(id)")
            deleteBlog(id: id)
        } else {
            // Create a new file with unique ID
            id = UUID().uuidString
            let safeTitle = title.isEmpty ? "Untitled" : title.replacingOccurrences(of: " ", with: "_")
            let filename = "\(safeTitle)_\(id).md"
            fileURL = docsURL.appendingPathComponent(filename)
            print("Creating new file: \(fileURL.path) with ID: \(id)")
            
            // Safety check: Make sure we don't have any existing records with this ID
            let existingPosts = getAllBlogs()
            if existingPosts.contains(where: { $0.id == id }) {
                print("⚠️ Found duplicate ID \(id), generating new one")
                id = UUID().uuidString
                let newFilename = "\(safeTitle)_\(id).md"
                fileURL = docsURL.appendingPathComponent(newFilename)
            }
        }
        
        // Format content
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: date)
        let toolsString = tools.map { "\"\($0)\"" }.joined(separator: ", ")
        
        var frontMatter = "---\n"
        frontMatter += "title: \"\(title)\"\n"
        frontMatter += "summary: \"\(summary)\"\n"
        frontMatter += "date: \"\(dateString)\"\n"
        frontMatter += "draft: \(isDraft)\n"
        frontMatter += "tools: [\(toolsString)]\n"
        frontMatter += "---\n\n"
        
        var md = frontMatter
        
        // Add content with embedded images
        md += content
        
        // Write to file
        do {
            try md.write(to: fileURL, atomically: true, encoding: .utf8)
            
            // Update database
            print("Saving blog to database - ID: \(id), path: \(fileURL.path)")
            saveBlog(
                id: id,
                title: title,
                summary: summary,
                date: dateString,
                filepath: fileURL.path,
                isDraft: isDraft
            )
            
            print("✅ Successfully saved blog post to: \(fileURL.path)")
            
            // Verify the save worked by immediately checking the database
            let verifyPosts = getAllBlogs()
            let savedPost = verifyPosts.first { $0.id == id }
            if let post = savedPost {
                print("✅ Verification: Post found in database - Title: \(post.title), Draft: \(post.isDraft)")
            } else {
                print("❌ Verification failed: Post not found in database!")
            }
            
            dumpAllRecords()
            return fileURL
        } catch {
            print("Failed to save post: \(error)")
            return fileURL
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    
    var id: String { self.rawValue }
    
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    
    var iconName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

// ThemeManager to handle app-wide theming
class ThemeManager: ObservableObject {
    @Published var currentTheme: AppTheme {
        didSet {
            UserDefaults.standard.set(currentTheme.rawValue, forKey: "selectedTheme")
        }
    }
    
    init() {
        let savedTheme = UserDefaults.standard.string(forKey: "selectedTheme") ?? AppTheme.system.rawValue
        if let theme = AppTheme(rawValue: savedTheme) {
            self.currentTheme = theme
        } else {
            self.currentTheme = .system
        }
    }
    
    // Helper for getting the effective color scheme (accounts for system theme)
    var effectiveColorScheme: ColorScheme? {
        return currentTheme.colorScheme
    }
}

// Custom modifier to force proper dark mode on sheets
struct DarkModeSheetModifier: ViewModifier {
    @ObservedObject var themeManager: ThemeManager
    
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(themeManager.effectiveColorScheme)
            .background(Color(.systemBackground).ignoresSafeArea())
    }
}

// Extension to make it easier to apply the modifier
extension View {
    func applyDarkModeSheet(themeManager: ThemeManager) -> some View {
        self.modifier(DarkModeSheetModifier(themeManager: themeManager))
    }
}

// MARK: - GitHub Integration

// GitHub API Service
class GitHubService: ObservableObject {
    @Published var isAuthenticated = false
    @Published var username: String?
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var userRepositories: [GitHubRepository] = []
    
    // Configuration manager for user settings
    @Published var configManager = GitHubConfigManager()
    
    // Helper function to extract original filename from sync metadata
    func getOriginalFileName(from post: BlogPost) -> String? {
        if post.lastEdited.hasPrefix("Synced from GitHub:") {
            return String(post.lastEdited.dropFirst("Synced from GitHub:".count))
        }
        return nil
    }
    
    // Dynamic repository information from user configuration
    private var repoOwner: String {
        return configManager.repositoryOwner
    }
    
    private var repoName: String {
        return configManager.repositoryName
    }
    
    private var blogPath: String {
        return configManager.blogDirectoryPath
    }
    
    private var imagePath: String {
        return configManager.imageDirectoryPath
    }
    
    enum ConnectionStatus: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)
        
        var displayText: String {
            switch self {
            case .disconnected: return "Not Connected"
            case .connecting: return "Connecting..."
            case .connected: return "Connected"
            case .error(let message): return "Error: \(message)"
            }
        }
        
        var color: Color {
            switch self {
            case .disconnected: return .gray
            case .connecting: return .orange
            case .connected: return .green
            case .error: return .red
            }
        }
        
        // Equatable conformance for error case
        static func == (lhs: ConnectionStatus, rhs: ConnectionStatus) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected),
                 (.connecting, .connecting),
                 (.connected, .connected):
                return true
            case (.error(let lhsMessage), .error(let rhsMessage)):
                return lhsMessage == rhsMessage
            default:
                return false
            }
        }
    }
    
    init() {
        checkAuthenticationStatus()
    }
    
    private func checkAuthenticationStatus() {
        // Check if we have a stored token
        if let token = getStoredToken() {
            connectionStatus = .connecting
            validateToken(token)
        }
    }
    
    private func getStoredToken() -> String? {
        // For now, we'll use UserDefaults. In production, use Keychain
        return UserDefaults.standard.string(forKey: "github_token")
    }
    
    private func storeToken(_ token: String) {
        // Store securely in UserDefaults (should be Keychain in production)
        UserDefaults.standard.set(token, forKey: "github_token")
    }
    
    private func removeToken() {
        UserDefaults.standard.removeObject(forKey: "github_token")
    }
    
    private func validateToken(_ token: String) {
        // Validate token by making a simple API call
        guard let url = URL(string: "https://api.github.com/user") else { return }
        
        var request = URLRequest(url: url)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.connectionStatus = .error(error.localizedDescription)
                    self?.isAuthenticated = false
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 200,
                   let data = data {
                    
                    if let userInfo = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let username = userInfo["login"] as? String {
                        self?.username = username
                        self?.isAuthenticated = true
                        self?.connectionStatus = .connected
                    }
                } else {
                    self?.connectionStatus = .error("Invalid token")
                    self?.isAuthenticated = false
                    self?.removeToken()
                }
            }
        }.resume()
    }
    
    func authenticate(with token: String) {
        storeToken(token)
        validateToken(token)
    }
    
    func disconnect() {
        removeToken()
        isAuthenticated = false
        username = nil
        connectionStatus = .disconnected
        userRepositories = []
        configManager.clearConfiguration()
    }
    
    // Fetch user's repositories
    func fetchUserRepositories() async throws -> [GitHubRepository] {
        guard let token = getStoredToken() else {
            throw GitHubError.notAuthenticated
        }
        
        guard let url = URL(string: "https://api.github.com/user/repos?per_page=100&sort=updated") else {
            throw GitHubError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw GitHubError.requestFailed
        }
        
        guard let reposData = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw GitHubError.invalidResponse
        }
        
        var repositories: [GitHubRepository] = []
        
        for repoData in reposData {
            guard let id = repoData["id"] as? Int,
                  let name = repoData["name"] as? String,
                  let fullName = repoData["full_name"] as? String,
                  let owner = repoData["owner"] as? [String: Any],
                  let ownerLogin = owner["login"] as? String,
                  let isPrivate = repoData["private"] as? Bool,
                  let defaultBranch = repoData["default_branch"] as? String,
                  let htmlUrl = repoData["html_url"] as? String else {
                continue
            }
            
            let description = repoData["description"] as? String
            let hasPages = repoData["has_pages"] as? Bool ?? false
            let language = repoData["language"] as? String
            
            let repository = GitHubRepository(
                id: id,
                name: name,
                fullName: fullName,
                owner: ownerLogin,
                description: description,
                isPrivate: isPrivate,
                defaultBranch: defaultBranch,
                hasPages: hasPages,
                language: language,
                htmlUrl: htmlUrl
            )
            
            repositories.append(repository)
        }
        
        DispatchQueue.main.async {
            self.userRepositories = repositories
        }
        
        return repositories
    }
    
    // Check if a repository has the specified directory
    func checkRepositoryStructure(repository: GitHubRepository, blogPath: String) async throws -> Bool {
        guard let token = getStoredToken() else {
            throw GitHubError.notAuthenticated
        }
        
        guard let url = URL(string: "https://api.github.com/repos/\(repository.fullName)/contents/\(blogPath)") else {
            throw GitHubError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubError.requestFailed
        }
        
        // Directory exists if we get 200, doesn't exist if we get 404
        return httpResponse.statusCode == 200
    }
    
    // MARK: - Repository Operations
    
    struct GitHubFile {
        let name: String
        let path: String
        let content: String
        let sha: String
    }
    
    struct BlogSyncResult {
        let syncedPosts: [BlogPost]
        let deletedPosts: [BlogPost]
        let updatedPosts: [BlogPost]
        let newPosts: [BlogPost]
        let errors: [String]
    }
    
    // Fetch all markdown files from the configured blog directory
    func fetchBlogFiles() async throws -> [GitHubFile] {
        guard let token = getStoredToken() else {
            throw GitHubError.notAuthenticated
        }
        
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/contents/\(blogPath)") else {
            throw GitHubError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw GitHubError.requestFailed
        }
        
        guard let files = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw GitHubError.invalidResponse
        }
        
        var blogFiles: [GitHubFile] = []
        
        // Filter for .md files and fetch their content
        for file in files {
            guard let name = file["name"] as? String,
                  let path = file["path"] as? String,
                  let _ = file["download_url"] as? String, // download_url available but using Contents API instead
                  let sha = file["sha"] as? String,
                  name.hasSuffix(".md") else { continue }
            
            print("🔍 Processing GitHub file: \(name) with SHA: \(sha)")
            
            // First try the GitHub Contents API for this specific file
            let content = try await fetchFileContentDirect(path: path, token: token)
            blogFiles.append(GitHubFile(name: name, path: path, content: content, sha: sha))
        }
        
        return blogFiles
    }
    
    // Fetch content of a specific file with cache-busting
    private func fetchFileContent(from urlString: String) async throws -> String {
        // Add cache-busting parameter to force fresh content
        let cacheBustUrl = urlString + "?t=\(Int(Date().timeIntervalSince1970))"
        
        guard let url = URL(string: cacheBustUrl) else {
            throw GitHubError.invalidURL
        }
        
        var request = URLRequest(url: url)
        // Add headers to prevent caching
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("0", forHTTPHeaderField: "Expires")
        
        print("🌐 Fetching fresh content from: \(cacheBustUrl)")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            print("📡 HTTP Response: \(httpResponse.statusCode)")
            print("📡 Headers: \(httpResponse.allHeaderFields)")
        }
        
        let content = String(data: data, encoding: .utf8) ?? ""
        print("📡 Downloaded content length: \(content.count) chars")
        print("📡 Content preview: \(String(content.prefix(200)))...")
        
        return content
    }
    
    // Fetch file content directly using GitHub Contents API (more reliable)
    private func fetchFileContentDirect(path: String, token: String) async throws -> String {
        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/contents/\(path)"
        guard let url = URL(string: urlString) else {
            throw GitHubError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        // Force fresh content
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        
        print("🌐 Fetching direct from Contents API: \(urlString)")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            print("❌ Direct fetch failed with status: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            throw GitHubError.requestFailed
        }
        
        guard let fileData = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentB64 = fileData["content"] as? String else {
            throw GitHubError.invalidResponse
        }
        
        // Decode base64 content
        let cleanB64 = contentB64.replacingOccurrences(of: "\n", with: "")
        guard let decodedData = Data(base64Encoded: cleanB64),
              let content = String(data: decodedData, encoding: .utf8) else {
            throw GitHubError.invalidResponse
        }
        
        print("📡 Direct API content length: \(content.count) chars")
        print("📡 Direct content preview: \(String(content.prefix(200)))...")
        
        return content
    }
    
    // Check if a local file has been modified recently (within last 24 hours)
    private func hasRecentLocalChanges(_ post: BlogPost) -> Bool {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: post.fileURL.path)
            if let modificationDate = attributes[.modificationDate] as? Date {
                let hoursSinceModification = Date().timeIntervalSince(modificationDate) / 3600
                return hoursSinceModification < 24 // Modified within 24 hours
            }
        } catch {
            print("⚠️ Could not check modification date for \(post.title)")
        }
        return false
    }
    
    // Clean up all orphaned and problematic local posts
    func cleanupOrphanedPosts() async -> BlogSyncResult {
        var deletedPosts: [BlogPost] = []
        var errors: [String] = []
        
        print("🧹 Starting cleanup of orphaned posts...")
        
        do {
            // Get all local published posts
            let allLocalPosts = BlogStore.shared.getAllBlogs()
            let localPublishedPosts = allLocalPosts.filter { 
                !$0.isDraft && ($0.lastEdited.contains("Synced from GitHub") || $0.fileURL.path.contains("remote_") || $0.fileURL.path.contains("synced_"))
            }
            
            // Get GitHub files for comparison
            let gitHubFiles = try await fetchBlogFiles()
            let gitHubTitles = Set(gitHubFiles.compactMap { file in
                parseBlogFile(file)?.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            })
            
            print("📊 Found \(localPublishedPosts.count) local synced posts")
            print("📊 Found \(gitHubFiles.count) GitHub posts")
            
            for localPost in localPublishedPosts {
                let localTitle = localPost.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                let fileName = generateFileName(from: localPost.title)
                
                // Check if this post exists on GitHub by title
                let existsOnGitHub = gitHubTitles.contains(localTitle)
                let hasRecentChanges = hasRecentLocalChanges(localPost)
                let isProblematicFile = fileName.isEmpty || fileName == "untitled-post" || localPost.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                
                if !existsOnGitHub || isProblematicFile {
                    if !hasRecentChanges || isProblematicFile {
                        print("🗑️ Cleaning up orphaned post: '\(localPost.title)' (problematic: \(isProblematicFile))")
                        BlogStore.shared.deleteBlog(id: localPost.id)
                        try? FileManager.default.removeItem(at: localPost.fileURL)
                        deletedPosts.append(localPost)
                    } else {
                        print("⏭️ Skipping '\(localPost.title)' - has recent local changes")
                    }
                }
            }
            
            print("🧹 Cleanup complete! Deleted \(deletedPosts.count) orphaned posts")
            
        } catch {
            print("❌ Cleanup failed: \(error.localizedDescription)")
            errors.append("Failed to cleanup orphaned posts: \(error.localizedDescription)")
        }
        
        return BlogSyncResult(
            syncedPosts: [],
            deletedPosts: deletedPosts,
            updatedPosts: [],
            newPosts: [],
            errors: errors
        )
    }
    
    // Clean, simple refresh sync - like app startup (no duplicates!)
    func performCompleteRefreshSync() async {
        print("🔄 Starting complete refresh sync (clean method)...")
        
        // Check authentication first
        guard isAuthenticated else {
            print("❌ Complete refresh sync failed: Not authenticated with GitHub")
            return
        }
        
        do {
            // Step 1: Get all GitHub files
            let gitHubFiles = try await fetchBlogFiles()
            print("📥 Found \(gitHubFiles.count) files on GitHub")
            
            // Step 2: Get all local synced posts (exclude drafts)
            let allLocalPosts = BlogStore.shared.getAllBlogs()
            let localSyncedPosts = allLocalPosts.filter { 
                !$0.isDraft && ($0.lastEdited.contains("Synced from GitHub") || $0.fileURL.path.contains("synced_"))
            }
            print("📱 Found \(localSyncedPosts.count) local synced posts")
            
            // Step 3: Create a simple map of GitHub files by SHA for quick lookup
            let gitHubBySHA = Dictionary(uniqueKeysWithValues: gitHubFiles.map { ($0.sha, $0) })
            
            // Step 4: Check each local post - if SHA doesn't match GitHub, delete it
            for localPost in localSyncedPosts {
                if gitHubBySHA[localPost.id] == nil {
                    // This post no longer exists on GitHub or SHA changed - remove it
                    print("🗑️ Removing outdated local post: \(localPost.title)")
                    BlogStore.shared.deleteBlog(id: localPost.id)
                    try? FileManager.default.removeItem(at: localPost.fileURL)
                }
            }
            
            // Step 5: For each GitHub file, ensure we have it locally with correct SHA
            for gitHubFile in gitHubFiles {
                let existingPost = localSyncedPosts.first { $0.id == gitHubFile.sha }
                
                if existingPost == nil {
                    // We don't have this exact version - download it
                    print("📥 Downloading: \(gitHubFile.name) (SHA: \(String(gitHubFile.sha.prefix(8))))")
                    
                    let newPost = try await downloadAndSavePost(gitHubFile)
                    print("💾 Downloaded post: \(newPost.title) to \(newPost.fileURL.path)")
                    
                    BlogStore.shared.saveBlog(
                        id: gitHubFile.sha,
                        title: newPost.title,
                        summary: newPost.summary,
                        date: newPost.date,
                        filepath: newPost.fileURL.path,
                        isDraft: false,
                        isArchived: newPost.isArchived,
                        originalFilename: gitHubFile.name
                    )
                    print("✅ Saved to database: \(newPost.title) with SHA \(gitHubFile.sha)")
                } else {
                    print("✅ Already up to date: \(gitHubFile.name)")
                }
            }
            
            print("🎉 Complete refresh sync finished successfully!")
            
        } catch {
            print("❌ Complete refresh sync failed: \(error.localizedDescription)")
        }
    }
    
    // Force complete re-sync: delete all synced posts and re-download everything
    func forceCompleteResync() async -> BlogSyncResult {
        var deletedPosts: [BlogPost] = []
        var newPosts: [BlogPost] = []
        var errors: [String] = []
        
        print("🔄 Starting complete re-sync (delete all and re-download)...")
        
        do {
            // Step 1: Delete all synced local posts
            let allLocalPosts = BlogStore.shared.getAllBlogs()
            let syncedLocalPosts = allLocalPosts.filter { 
                !$0.isDraft && ($0.lastEdited == "Synced from GitHub" || $0.fileURL.path.contains("remote_"))
            }
            
            print("🗑️ Deleting \(syncedLocalPosts.count) existing synced posts...")
            
            for post in syncedLocalPosts {
                BlogStore.shared.deleteBlog(id: post.id)
                try? FileManager.default.removeItem(at: post.fileURL)
                deletedPosts.append(post)
            }
            
            // Step 2: Download all posts from GitHub
            let gitHubFiles = try await fetchBlogFiles()
            print("📥 Downloading \(gitHubFiles.count) posts from GitHub...")
            
            for gitHubFile in gitHubFiles {
                guard let blogPost = parseBlogFile(gitHubFile) else {
                    errors.append("Failed to parse \(gitHubFile.name): Invalid format")
                    continue
                }
                
                BlogStore.shared.saveBlog(
                    id: gitHubFile.sha,
                    title: blogPost.title,
                    summary: blogPost.summary,
                    date: blogPost.date,
                    filepath: blogPost.fileURL.path,
                    isDraft: false,
                    isArchived: blogPost.isArchived,
                    originalFilename: gitHubFile.name
                )
                
                newPosts.append(blogPost)
            }
            
            print("🎉 Complete re-sync finished!")
            print("   🗑️ Deleted: \(deletedPosts.count)")
            print("   📥 Downloaded: \(newPosts.count)")
            
        } catch {
            print("❌ Complete re-sync failed: \(error.localizedDescription)")
            errors.append("Failed to complete re-sync: \(error.localizedDescription)")
        }
        
        return BlogSyncResult(
            syncedPosts: newPosts,
            deletedPosts: deletedPosts,
            updatedPosts: [],
            newPosts: newPosts,
            errors: errors
        )
    }
    
    // Comprehensive sync that compares all local files with GitHub repository
    func syncBlogsFromRepository(forceDeleteOrphans: Bool = false) async -> BlogSyncResult {
        print("🔄 Starting comprehensive file-based sync with GitHub...")
        
        var newPosts: [BlogPost] = []
        var updatedPosts: [BlogPost] = []
        var deletedPosts: [BlogPost] = []
        var errors: [String] = []
        
        do {
            // Step 1: Get all files from GitHub
            let gitHubFiles = try await fetchBlogFiles()
            print("📥 Found \(gitHubFiles.count) files on GitHub")
            
            // Step 2: Get all local published posts (exclude drafts but include all synced posts)
            let allLocalPosts = BlogStore.shared.getAllBlogs()
            let localPublishedPosts = allLocalPosts.filter { 
                !$0.isDraft && ($0.lastEdited.contains("Synced from GitHub") || $0.fileURL.path.contains("remote_") || $0.fileURL.path.contains("synced_"))
            }
            print("📱 Found \(localPublishedPosts.count) local published posts")
            
            // Step 3: Create maps for efficient comparison using file names
            var gitHubPostsMap: [String: GitHubFile] = [:]
            var localPostsMap: [String: BlogPost] = [:]
            
            // Map GitHub files by their name (key = filename without .md)
            for gitHubFile in gitHubFiles {
                let fileName = String(gitHubFile.name.dropLast(3)) // Remove .md
                gitHubPostsMap[fileName] = gitHubFile
            }
            
            // Map local posts by their equivalent GitHub filename
            for localPost in localPublishedPosts {
                // Extract filename from local file path or generate from title
                var fileName: String
                if localPost.fileURL.lastPathComponent.hasPrefix("synced_") {
                    // Extract original filename from synced file
                    fileName = String(localPost.fileURL.lastPathComponent.dropFirst(7).dropLast(3)) // Remove "synced_" and ".md"
                } else if localPost.fileURL.lastPathComponent.hasPrefix("remote_") {
                    // Extract original filename from remote file
                    fileName = String(localPost.fileURL.lastPathComponent.dropFirst(7).dropLast(3)) // Remove "remote_" and ".md"
                } else if let originalFilename = getOriginalFileName(from: localPost) {
                    // Use stored original filename if available
                    fileName = String(originalFilename.dropLast(3)) // Remove .md
                } else {
                    // Generate filename from title
                    fileName = generateFileName(from: localPost.title)
                }
                
                // Debug logging for empty filenames
                if fileName.isEmpty {
                    print("⚠️ Empty filename generated for post: '\(localPost.title)' (ID: \(localPost.id))")
                    fileName = "unnamed-post-\(localPost.id.prefix(8))" // Use post ID as fallback
                }
                
                localPostsMap[fileName] = localPost
            }
            
            print("🗂️ GitHub files: \(gitHubPostsMap.keys.sorted())")
            print("🗂️ Local files: \(localPostsMap.keys.sorted())")
            
            // Step 4: Find posts to delete (exist locally but not on GitHub)
            for (localFileName, localPost) in localPostsMap {
                print("🔍 Checking local file: '\(localFileName)' for post: '\(localPost.title)'")
                
                if gitHubPostsMap[localFileName] == nil {
                    // Also check by title similarity in case of filename changes
                    let titleFound = gitHubPostsMap.values.contains { gitHubFile in
                        if let gitHubPost = parseBlogFile(gitHubFile) {
                            return gitHubPost.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == 
                                   localPost.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        return false
                    }
                    
                    // Special handling for empty/unnamed posts - always delete them if not found
                    let isUnnamedPost = localFileName.isEmpty || localFileName.hasPrefix("unnamed-post-") || localFileName == "untitled-post"
                    
                    // Check if the post definitely doesn't exist on GitHub (by both filename and title)
                    let definitelyNotOnGitHub = !titleFound && gitHubPostsMap[localFileName] == nil
                    
                    if definitelyNotOnGitHub || isUnnamedPost {
                        // For posts that definitely don't exist on GitHub, check recent changes (unless force delete)
                        if isUnnamedPost || !hasRecentLocalChanges(localPost) || forceDeleteOrphans {
                            print("🗑️ Deleting local post not found on GitHub: '\(localPost.title)' (file: '\(localFileName)')")
                            if isUnnamedPost {
                                print("   📝 Reason: Unnamed/empty filename post")
                            } else {
                                print("   📝 Reason: Not found on GitHub by filename or title")
                            }
                            BlogStore.shared.deleteBlog(id: localPost.id)
                            try? FileManager.default.removeItem(at: localPost.fileURL)
                            deletedPosts.append(localPost)
                        } else {
                            print("⏭️ Skipping deletion of '\(localPost.title)' - has recent local changes (will retry next sync)")
                        }
                    } else if titleFound {
                        print("📝 Local post '\(localPost.title)' found with different filename on GitHub, will be updated")
                    }
                } else {
                    print("✅ Local file '\(localFileName)' matches GitHub file")
                }
            }
            
            // Step 5: Process GitHub files (new posts and updates)
            for (gitHubFileName, gitHubFile) in gitHubPostsMap {
                print("🔄 Processing GitHub file: \(gitHubFileName)")
                
                if let localPost = localPostsMap[gitHubFileName] {
                    // Post exists locally - check if it needs updating by comparing SHA
                    if localPost.id != gitHubFile.sha {
                        print("📝 Content changed, updating: \(localPost.title)")
                        print("   Local SHA: \(localPost.id) → GitHub SHA: \(gitHubFile.sha)")
                        
                        // Download fresh content and save locally, reusing existing file path
                        let freshPost = try await downloadAndSavePost(gitHubFile, existingFileURL: localPost.fileURL)
                        
                        // Update the existing record (don't delete/recreate to preserve mapping)
                        BlogStore.shared.saveBlog(
                            id: gitHubFile.sha, // Update to new SHA
                            title: freshPost.title,
                            summary: freshPost.summary,
                            date: freshPost.date,
                            filepath: localPost.fileURL.path, // Keep original file path
                            isDraft: false,
                            isArchived: freshPost.isArchived,
                            originalFilename: gitHubFile.name
                        )
                        
                        updatedPosts.append(freshPost)
                    } else {
                        print("✅ Up to date: \(localPost.title)")
                    }
                } else {
                    // New post from GitHub
                    print("✨ New post from GitHub: \(gitHubFileName)")
                    
                    let newPost = try await downloadAndSavePost(gitHubFile)
                    
                    BlogStore.shared.saveBlog(
                        id: gitHubFile.sha,
                        title: newPost.title,
                        summary: newPost.summary,
                        date: newPost.date,
                        filepath: newPost.fileURL.path,
                        isDraft: false,
                        isArchived: newPost.isArchived,
                        originalFilename: gitHubFile.name
                    )
                    
                    newPosts.append(newPost)
                }
            }
            
            print("🎉 Comprehensive sync complete!")
            print("   📈 New: \(newPosts.count)")
            print("   📝 Updated: \(updatedPosts.count)")
            print("   🗑️ Deleted: \(deletedPosts.count)")
            print("   ❌ Errors: \(errors.count)")
            
        } catch {
            print("❌ Sync failed: \(error.localizedDescription)")
            errors.append("Failed to sync with GitHub: \(error.localizedDescription)")
        }
        
        let allSyncedPosts = newPosts + updatedPosts
        return BlogSyncResult(
            syncedPosts: allSyncedPosts,
            deletedPosts: deletedPosts,
            updatedPosts: updatedPosts,
            newPosts: newPosts,
            errors: errors
        )
    }
    
    // Parse a GitHub file into a BlogPost
    func parseBlogFile(_ file: GitHubFile) -> BlogPost? {
        let content = file.content
        let components = content.components(separatedBy: "---")
        
        guard components.count >= 3 else { return nil }
        
        let frontMatter = components[1]
        let actualContent = components.dropFirst(2).joined(separator: "---")
        
        // Parse frontmatter
        var title = file.name.replacingOccurrences(of: ".md", with: "")
        var summary = ""
        var date = ""
        var tools: [String] = []
        var isArchived = false // This represents the "draft" field in frontmatter
        
        for line in frontMatter.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("title:") {
                title = extractValue(from: trimmed, prefix: "title:")
            } else if trimmed.hasPrefix("summary:") {
                summary = extractValue(from: trimmed, prefix: "summary:")
            } else if trimmed.hasPrefix("date:") {
                date = extractValue(from: trimmed, prefix: "date:")
            } else if trimmed.hasPrefix("tools:") {
                let toolsString = extractValue(from: trimmed, prefix: "tools:")
                tools = parseToolsArray(toolsString)
            } else if trimmed.hasPrefix("draft:") {
                let draftValue = extractValue(from: trimmed, prefix: "draft:")
                isArchived = draftValue.lowercased() == "true"
                print("📦 Parsing archive status for \(title): draft=\(draftValue) → isArchived=\(isArchived)")
            }
        }
        
        // Create a temporary file URL for the remote content
        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let remoteFileName = "remote_\(file.name)"
        let fileURL = docsURL.appendingPathComponent(remoteFileName)
        
        // Save the content to a temporary file
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        
        return BlogPost(
            id: file.sha, // Use GitHub SHA as unique ID
            title: title,
            summary: summary,
            date: date,
            lastEdited: "Synced from GitHub:\(file.name)", // Store original filename
            fileURL: fileURL,
            content: actualContent,
            tools: tools,
            isDraft: false,
            isArchived: isArchived
        )
    }
    
    // Helper to extract values from frontmatter
    private func extractValue(from line: String, prefix: String) -> String {
        let value = line.replacingOccurrences(of: prefix, with: "")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\"", with: "")
        return value
    }
    
    // Helper to parse tools array from frontmatter
    private func parseToolsArray(_ toolsString: String) -> [String] {
        // Handle both ["tool1", "tool2"] and [tool1, tool2] formats
        let cleaned = toolsString
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "\"", with: "")
        
        return cleaned.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    
    // Publish a draft to GitHub with single commit for images + blog post
    func publishDraft(_ post: BlogPost, commitMessage: String) async throws -> Bool {
        guard getStoredToken() != nil else {
            throw GitHubError.notAuthenticated
        }
        
        // Prepare content and collect images to upload
        let preparedContent = try prepareContentWithGitHubImagePaths(post.content)
        
        // Create an updated post with the new content (with GitHub image paths)
        // Preserve the original filename if this post was synced from GitHub
        var lastEditedInfo = post.lastEdited
        let allPosts = BlogStore.shared.getAllBlogs()
        if let existingPost = allPosts.first(where: { $0.id == post.id }),
           existingPost.lastEdited.hasPrefix("Synced from GitHub:") {
            lastEditedInfo = existingPost.lastEdited // Keep the original filename info
        }
        
        let updatedPost = BlogPost(
            id: post.id,
            title: post.title,
            summary: post.summary,
            date: post.date,
            lastEdited: lastEditedInfo,
            fileURL: post.fileURL,
            content: preparedContent.updatedContent,
            tools: post.tools,
            isDraft: post.isDraft,
            isArchived: post.isArchived
        )
        
        // Generate the markdown content with frontmatter
        let markdownContent = generateMarkdownContent(for: updatedPost)
        
        // Check if this is an existing post (has original filename from sync)
        var blogPath: String
        
        if let originalFileName = getOriginalFileName(from: updatedPost) {
            // This is an existing post - use original filename
            blogPath = "blog/\(originalFileName)"
            print("📝 Updating existing GitHub file: \(originalFileName)")
        } else {
            // This is a new post - generate a new filename
            let baseFileName = post.title
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
            
            let (fileName, isDuplicate) = try await generateUniqueFileName(baseTitle: baseFileName)
            blogPath = "blog/\(fileName)"
            
            // If this is a duplicate, we should warn about it
            if isDuplicate {
                print("⚠️ Warning: A blog post with similar title '\(post.title)' already exists. Creating '\(fileName)'")
            }
        }
        
        // Upload all files (images + blog post) in a single commit
        let success = try await uploadFilesInSingleCommit(
            blogPath: blogPath,
            blogContent: markdownContent,
            images: preparedContent.imagesToUpload,
            commitMessage: commitMessage
        )
        
        if success {
            // Update local database to mark as published
            BlogStore.shared.saveBlog(
                id: post.id,
                title: post.title,
                summary: post.summary,
                date: post.date,
                filepath: post.fileURL.path,
                isDraft: false
            )
            
            // Delete the original draft file to avoid duplicates
            try? FileManager.default.removeItem(at: post.fileURL)
        }
        
        return success
    }
    
    // Find local images in content and return updated content with GitHub paths (without uploading)
    func prepareContentWithGitHubImagePaths(_ content: String) throws -> (updatedContent: String, imagesToUpload: [(data: Data, filename: String, githubPath: String)]) {
        print("🔍 Scanning content for local images...")
        
        var updatedContent = content
        var imagesToUpload: [(data: Data, filename: String, githubPath: String)] = []
        
        // Find all local image references using regex
        let pattern = #"!\[([^\]]*)\]\(file://([^)]+)\)"#
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let nsString = content as NSString
        let results = regex.matches(in: content, options: [], range: NSRange(location: 0, length: nsString.length))
        
        // Process all images
        for match in results {
            let fullMatch = nsString.substring(with: match.range)
            let altText = nsString.substring(with: match.range(at: 1))
            let filePath = nsString.substring(with: match.range(at: 2))
            
            print("🖼️ Found local image: \(filePath)")
            
            // Try to read the image file
            let fileURL = URL(fileURLWithPath: filePath)
            guard let imageData = try? Data(contentsOf: fileURL) else {
                print("❌ Could not read image file: \(filePath)")
                continue
            }
            
            // Generate a filename from the original file
            let originalFilename = fileURL.lastPathComponent
            let filename = "uploaded_\(originalFilename)"
            let githubPath = "public/assets/blog/\(filename)"
            
            imagesToUpload.append((data: imageData, filename: filename, githubPath: githubPath))
            
            // Replace the local path with GitHub path in content
            let githubImageMarkdown = "![\(altText)](/assets/blog/\(filename))"
            updatedContent = updatedContent.replacingOccurrences(of: fullMatch, with: githubImageMarkdown)
        }
        
        return (updatedContent: updatedContent, imagesToUpload: imagesToUpload)
    }
    
    // Upload multiple files (images + blog post) in a single commit using GitHub's Tree API
    func uploadFilesInSingleCommit(
        blogPath: String,
        blogContent: String,
        images: [(data: Data, filename: String, githubPath: String)],
        commitMessage: String
    ) async throws -> Bool {
        guard let token = getStoredToken() else {
            throw GitHubError.notAuthenticated
        }
        
        print("🚀 Creating single commit with \(images.count) images + 1 blog post")
        
        // Step 1: Get the latest commit SHA
        let latestSHA = try await getLatestCommitSHA(token: token)
        
        // Step 2: Create blobs first, then create tree entries with blob SHAs
        var treeEntries: [[String: Any]] = []
        
        // Create blob for blog post and get SHA
        let blogContentData = blogContent.data(using: .utf8) ?? Data()
        let blogBase64 = blogContentData.base64EncodedString()
        let blogBlobSHA = try await createBlob(content: blogBase64, token: token)
        
        treeEntries.append([
            "path": blogPath,
            "mode": "100644",
            "type": "blob",
            "sha": blogBlobSHA
        ])
        
        // Create blobs for all images and get SHAs
        for image in images {
            let imageBase64 = image.data.base64EncodedString()
            let imageBlobSHA = try await createBlob(content: imageBase64, token: token)
            treeEntries.append([
                "path": image.githubPath,
                "mode": "100644", 
                "type": "blob",
                "sha": imageBlobSHA
            ])
        }
        
        // Step 3: Create the tree
        let treeSHA = try await createTree(entries: treeEntries, baseSHA: latestSHA, token: token)
        
        // Step 4: Create the commit
        let commitSHA = try await createCommit(treeSHA: treeSHA, parentSHA: latestSHA, message: commitMessage, token: token)
        
        // Step 5: Update the main branch to point to the new commit
        let success = try await updateBranchRef(commitSHA: commitSHA, token: token)
        
        if success {
            print("✅ Successfully created single commit with all files")
        }
        
        return success
    }
    
    // Get the latest commit SHA from main branch
    private func getLatestCommitSHA(token: String) async throws -> String {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/git/refs/heads/main") else {
            throw GitHubError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let object = json["object"] as? [String: Any],
              let sha = object["sha"] as? String else {
            throw GitHubError.invalidResponse
        }
        
        return sha
    }
    
    // Create a blob object in GitHub
    private func createBlob(content: String, token: String) async throws -> String {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/git/blobs") else {
            throw GitHubError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "content": content,
            "encoding": "base64"
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 201 else {
            if let errorData = String(data: data, encoding: .utf8) {
                print("❌ Create blob error: \(errorData)")
            }
            throw GitHubError.requestFailed
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = json["sha"] as? String else {
            throw GitHubError.invalidResponse
        }
        
        return sha
    }
    
    // Create a tree with multiple files
    private func createTree(entries: [[String: Any]], baseSHA: String, token: String) async throws -> String {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/git/trees") else {
            throw GitHubError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "base_tree": baseSHA,
            "tree": entries
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 201 else {
            if let errorData = String(data: data, encoding: .utf8) {
                print("❌ Create tree error: \(errorData)")
            }
            throw GitHubError.requestFailed
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = json["sha"] as? String else {
            throw GitHubError.invalidResponse
        }
        
        return sha
    }
    
    // Create a commit
    private func createCommit(treeSHA: String, parentSHA: String, message: String, token: String) async throws -> String {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/git/commits") else {
            throw GitHubError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "message": message,
            "tree": treeSHA,
            "parents": [parentSHA]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 201 else {
            if let errorData = String(data: data, encoding: .utf8) {
                print("❌ Create commit error: \(errorData)")
            }
            throw GitHubError.requestFailed
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = json["sha"] as? String else {
            throw GitHubError.invalidResponse
        }
        
        return sha
    }
    
    // Update the main branch reference to point to new commit
    private func updateBranchRef(commitSHA: String, token: String) async throws -> Bool {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/git/refs/heads/main") else {
            throw GitHubError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "sha": commitSHA
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            if let errorData = String(data: data, encoding: .utf8) {
                print("❌ Update branch ref error: \(errorData)")
            }
            throw GitHubError.requestFailed
        }
        
        return true
    }
    
    // Generate a clean filename from a title (same logic as used in publishing)
    private func generateFileName(from title: String) -> String {
        let cleaned = title
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .init(charactersIn: "-"))
        
        // If the result is empty after cleaning, use a fallback
        if cleaned.isEmpty {
            return "untitled-post"
        }
        
        return cleaned
    }
    
    // Download and save a post from GitHub with fresh content
    private func downloadAndSavePost(_ gitHubFile: GitHubFile, existingFileURL: URL? = nil) async throws -> BlogPost {
        // Since GitHubFile already contains the content, use it directly
        let freshContent = gitHubFile.content
        
        // Parse the fresh content
        let components = freshContent.components(separatedBy: "---")
        guard components.count >= 3 else {
            throw GitHubError.invalidResponse
        }
        
        let frontMatter = components[1]
        let actualContent = components.dropFirst(2).joined(separator: "---")
        
        // Parse frontmatter
        var title = gitHubFile.name.replacingOccurrences(of: ".md", with: "")
        var summary = ""
        var date = ""
        var tools: [String] = []
        var isArchived = false
        
        print("🔍 Parsing frontmatter for \(gitHubFile.name):")
        print("📝 Raw frontmatter: \(frontMatter)")
        
        for line in frontMatter.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("title:") {
                title = extractValue(from: trimmed, prefix: "title:")
                print("📄 Extracted title: '\(title)'")
            } else if trimmed.hasPrefix("summary:") {
                summary = extractValue(from: trimmed, prefix: "summary:")
                print("📄 Extracted summary: '\(summary)'")
            } else if trimmed.hasPrefix("date:") {
                date = extractValue(from: trimmed, prefix: "date:")
            } else if trimmed.hasPrefix("tools:") {
                let toolsString = extractValue(from: trimmed, prefix: "tools:")
                tools = parseToolsArray(toolsString)
            } else if trimmed.hasPrefix("draft:") {
                let draftValue = extractValue(from: trimmed, prefix: "draft:")
                isArchived = draftValue.lowercased() == "true"
            }
        }
        
        print("🎯 Final parsed values:")
        print("   Title: '\(title)'")
        print("   Summary: '\(summary)'")
        print("   Content length: \(actualContent.count) chars")
        print("   Content preview: \(String(actualContent.prefix(100)))...")
        
        // Save to local file (use existing path if provided, otherwise create new synced file)
        let localFileURL: URL
        if let existingURL = existingFileURL {
            localFileURL = existingURL
        } else {
            let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let localFileName = "synced_\(gitHubFile.name)"
            localFileURL = docsURL.appendingPathComponent(localFileName)
        }
        
        // Write the fresh content to local file
        try freshContent.write(to: localFileURL, atomically: true, encoding: String.Encoding.utf8)
        print("💾 Wrote \(freshContent.count) chars to \(localFileURL.path)")
        
        // Verify the file was written correctly
        if let verifyContent = try? String(contentsOf: localFileURL, encoding: .utf8) {
            print("✅ Verified file write: \(verifyContent.count) chars")
            print("✅ File content starts with: \(String(verifyContent.prefix(100)))...")
        } else {
            print("❌ Failed to verify file write!")
        }
        
        return BlogPost(
            id: gitHubFile.sha,
            title: title,
            summary: summary,
            date: date,
            lastEdited: "Synced from GitHub:\(gitHubFile.name)", // Store original filename
            fileURL: localFileURL,
            content: actualContent,
            tools: tools,
            isDraft: false,
            isArchived: isArchived
        )
    }
    
    // Generate unique filename by checking existing posts and adding incremental numbers
    func generateUniqueFileName(baseTitle: String) async throws -> (fileName: String, isDuplicate: Bool) {
        // Get all existing blog files from GitHub
        let existingFiles = try await fetchBlogFiles()
        let existingTitles = Set(existingFiles.map { file in
            // Extract base filename without .md extension
            let nameWithoutExtension = String(file.name.dropLast(3)) // Remove .md
            
            // Remove any trailing numbers (e.g., "sf-trip2" -> "sf-trip")
            let basePattern = nameWithoutExtension.replacingOccurrences(of: #"\d+$"#, with: "", options: .regularExpression)
            return basePattern
        })
        
        let cleanBaseTitle = baseTitle.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        
        // Check if base title already exists
        if !existingTitles.contains(cleanBaseTitle) {
            return ("\(cleanBaseTitle).md", false)
        }
        
        // Find the next available number
        var counter = 2
        var candidateTitle = "\(cleanBaseTitle)\(counter)"
        
        while existingTitles.contains(candidateTitle.replacingOccurrences(of: #"\d+$"#, with: "", options: .regularExpression)) {
            counter += 1
            candidateTitle = "\(cleanBaseTitle)\(counter)"
        }
        
        return ("\(candidateTitle).md", true)
    }
    
    // Check if a blog post with exact same title already exists
    func checkForExactDuplicateTitle(_ title: String) async throws -> [String] {
        let existingFiles = try await fetchBlogFiles()
        var duplicates: [String] = []
        
        let normalizedTitle = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        for file in existingFiles {
            if let existingPost = parseBlogFile(file) {
                let existingNormalized = existingPost.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Check for exact match only
                if existingNormalized == normalizedTitle {
                    duplicates.append(existingPost.title)
                }
            }
        }
        
        return duplicates
    }
    
    // Generate markdown content with frontmatter
    func generateMarkdownContent(for post: BlogPost) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        
        // Use original date for existing posts, current date for new posts
        let dateToUse = post.date.isEmpty ? dateFormatter.string(from: Date()) : post.date
        
        let toolsArray = post.tools.map { "\"\($0)\"" }.joined(separator: ", ")
        
        // The 'draft' field in frontmatter controls website visibility (archive vs active)
        let draftStatus = post.isArchived ? "true" : "false"
        
        print("🔧 Generating markdown: title=\(post.title), archived=\(post.isArchived), draft=\(draftStatus)")
        
        return """
        ---
        title: "\(post.title)"
        summary: "\(post.summary)"
        date: "\(dateToUse)"
        draft: \(draftStatus)
        tools: [\(toolsArray)]
        ---
        
        \(post.content)
        """
    }
    
    // Create or update a file in GitHub repository
    private func createOrUpdateFile(path: String, content: String, message: String, token: String) async throws -> Bool {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/contents/\(path)") else {
            throw GitHubError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Encode content to base64
        let contentData = content.data(using: .utf8) ?? Data()
        let base64Content = contentData.base64EncodedString()
        
        let body: [String: Any] = [
            "message": message,
            "content": base64Content,
            "branch": "main"
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubError.requestFailed
        }
        
        return httpResponse.statusCode == 201 || httpResponse.statusCode == 200
    }
    
    // Update an existing post in GitHub
    func updateExistingPost(_ post: BlogPost, commitMessage: String) async throws -> Bool {
        guard let token = getStoredToken() else {
            throw GitHubError.notAuthenticated
        }
        
        print("🔄 Updating post: \(post.title)")
        
        // Generate the markdown content with frontmatter
        let markdownContent = generateMarkdownContent(for: post)
        
        // First, try to extract original filename from lastEdited field
        var originalFileName = getOriginalFileName(from: post)
        if let fileName = originalFileName {
            print("📝 Using original filename from sync: \(fileName)")
        }
        
        // Get all blog files from GitHub
        do {
            let blogFiles = try await fetchBlogFiles()
            var targetFile: GitHubFile?
            
            if let fileName = originalFileName {
                // Try to find by original filename first
                targetFile = blogFiles.first { $0.name == fileName }
                if targetFile != nil {
                    print("✅ Found file by original name: \(fileName)")
                }
            }
            
            // If not found by filename, fall back to title matching
            if targetFile == nil {
                print("🔍 Searching by title since filename lookup failed...")
                for file in blogFiles {
                    if let parsedPost = parseBlogFile(file),
                       parsedPost.title.lowercased() == post.title.lowercased() {
                        targetFile = file
                        originalFileName = file.name // Store the found filename
                        print("✅ Found file by title match: \(file.name)")
                        
                        // Backfill the original filename for future updates
                        try await backfillOriginalFilename(postId: post.id, filename: file.name)
                        break
                    }
                }
            }
            
            guard let file = targetFile else {
                print("❌ Could not find file for post: \(post.title)")
                print("📊 Available files: \(blogFiles.map { $0.name }.joined(separator: ", "))")
                throw GitHubError.invalidResponse
            }
            
            print("📄 Updating file: \(file.name)")
            
            // Update the existing file
            let success = try await updateFile(
                path: "blog/\(file.name)",
                content: markdownContent,
                message: commitMessage,
                sha: file.sha,
                token: token
            )
            
            return success
            
        } catch {
            print("❌ Failed to update post: \(error.localizedDescription)")
            throw error
        }
    }
    
    // Backfill original filename for existing posts that don't have it
    private func backfillOriginalFilename(postId: String, filename: String) async throws {
        print("🔧 Backfilling original filename for post \(postId): \(filename)")
        
        // Get the current post from database
        let allPosts = BlogStore.shared.getAllBlogs()
        guard let existingPost = allPosts.first(where: { $0.id == postId }) else {
            print("⚠️ Could not find post to backfill")
            return
        }
        
        // Update the post with the original filename stored in the database
        BlogStore.shared.saveBlog(
            id: existingPost.id,
            title: existingPost.title,
            summary: existingPost.summary,
            date: existingPost.date,
            filepath: existingPost.fileURL.path,
            isDraft: existingPost.isDraft,
            isArchived: existingPost.isArchived,
            originalFilename: filename
        )
        
        print("✅ Backfilled filename info for \(existingPost.title)")
    }
    
    // Get SHA of existing file (required for updates)
    private func getFileSHA(path: String, token: String) async throws -> String {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/contents/\(path)") else {
            throw GitHubError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw GitHubError.requestFailed
        }
        
        guard let fileInfo = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = fileInfo["sha"] as? String else {
            throw GitHubError.invalidResponse
        }
        
        return sha
    }
    
    // Update an existing file in GitHub repository
    private func updateFile(path: String, content: String, message: String, sha: String, token: String) async throws -> Bool {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/contents/\(path)") else {
            throw GitHubError.invalidURL
        }
        
        print("🔄 Updating file at path: \(path)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Encode content to base64
        let contentData = content.data(using: .utf8) ?? Data()
        let base64Content = contentData.base64EncodedString()
        
        let body: [String: Any] = [
            "message": message,
            "content": base64Content,
            "sha": sha,
            "branch": "main"
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("❌ Invalid response type")
            throw GitHubError.requestFailed
        }
        
        print("📡 GitHub response status: \(httpResponse.statusCode)")
        
        if httpResponse.statusCode != 200 {
            // Log the error response for debugging
            if let errorData = String(data: data, encoding: .utf8) {
                print("❌ GitHub error response: \(errorData)")
            }
            throw GitHubError.requestFailed
        }
        
        return true
    }
    
    // Upload image to GitHub repository at configured image path
    func uploadImage(imageData: Data, filename: String, commitMessage: String = "") async throws -> Bool {
        guard let token = getStoredToken() else {
            print("❌ No GitHub token found for image upload")
            throw GitHubError.notAuthenticated
        }
        
        // Use the configured path for image uploads
        let path = "\(imagePath)/\(filename)"
        
        print("🖼️ Image size: \(imageData.count) bytes")
        print("🖼️ Uploading to path: \(path)")
        
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/contents/\(path)") else {
            print("❌ Invalid GitHub URL for path: \(path)")
            throw GitHubError.invalidURL
        }
        
        print("🌐 Upload URL: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Encode image data to base64
        let base64Content = imageData.base64EncodedString()
        print("🔐 Base64 content length: \(base64Content.count)")
        
        // Use custom commit message if provided, otherwise use default
        let finalCommitMessage = commitMessage.isEmpty ? "Add blog image: \(filename)" : commitMessage
        
        let body: [String: Any] = [
            "message": finalCommitMessage,
            "content": base64Content,
            "branch": "main"
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ Invalid response type")
                throw GitHubError.requestFailed
            }
            
            print("📡 GitHub API response status: \(httpResponse.statusCode)")
            
            if httpResponse.statusCode == 201 || httpResponse.statusCode == 200 {
                print("✅ Image uploaded successfully to GitHub at: \(path)")
                return true
            } else {
                // Log the full error response for debugging
                if let errorData = String(data: data, encoding: .utf8) {
                    print("❌ GitHub API error response: \(errorData)")
                }
                print("❌ Image upload failed with status: \(httpResponse.statusCode)")
                
                // Check for specific error cases
                if httpResponse.statusCode == 422 {
                    print("💡 Error 422: File might already exist or invalid content")
                } else if httpResponse.statusCode == 404 {
                    print("💡 Error 404: Repository or path might not exist")
                } else if httpResponse.statusCode == 401 {
                    print("💡 Error 401: Authentication failed - check token")
                }
                
                throw GitHubError.requestFailed
            }
        } catch {
            print("❌ Network request failed: \(error.localizedDescription)")
            throw error
        }
    }
}

// GitHub Error Types
enum GitHubError: Error, LocalizedError {
    case notAuthenticated
    case invalidURL
    case requestFailed
    case invalidResponse
    
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated with GitHub"
        case .invalidURL:
            return "Invalid GitHub URL"
        case .requestFailed:
            return "GitHub request failed"
        case .invalidResponse:
            return "Invalid response from GitHub"
        }
    }
}

// GitHub Authentication View
struct GitHubAuthenticationView: View {
    @ObservedObject var gitHubService: GitHubService
    @State private var personalAccessToken = ""
    @State private var showingTokenInput = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 60))
                    .foregroundColor(.primary)
                
                Text("GitHub Authentication")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Connect your GitHub account to sync and publish your blog posts")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                
                VStack(spacing: 12) {
                    Text("You'll need a Personal Access Token with:")
                        .font(.headline)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Contents (read/write)", systemImage: "doc.text")
                        Label("Metadata (read)", systemImage: "info.circle")
                        Label("Pull requests (write)", systemImage: "arrow.triangle.merge")
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                
                Button("Connect with Personal Access Token") {
                    showingTokenInput = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                
                Button("How to create a token?") {
                    // Open GitHub token creation page
                    if let url = URL(string: "https://github.com/settings/tokens/new") {
                        UIApplication.shared.open(url)
                    }
                }
                .foregroundColor(.accentColor)
                
                Spacer()
            }
            .padding()
            .navigationTitle("GitHub Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showingTokenInput) {
            TokenInputView(gitHubService: gitHubService, token: $personalAccessToken) {
                dismiss()
            }
        }
    }
}

// Token Input View
struct TokenInputView: View {
    @ObservedObject var gitHubService: GitHubService
    @Binding var token: String
    let onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isAuthenticating = false
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Enter your Personal Access Token")
                    .font(.headline)
                    .padding(.top)
                
                Text("Paste your GitHub Personal Access Token below. You can generate one from GitHub Settings > Developer settings > Personal access tokens.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                SecureField("ghp_xxxxxxxxxxxxxxxxxxxx", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .disabled(isAuthenticating)
                
                if showError {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                
                Button(action: authenticateUser) {
                    HStack {
                        if isAuthenticating {
                            ProgressView()
                                .scaleEffect(0.8)
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        }
                        Text(isAuthenticating ? "Authenticating..." : "Authenticate")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(token.isEmpty || isAuthenticating)
                
                Spacer()
            }
            .padding()
            .navigationTitle("Access Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isAuthenticating)
                }
            }
        }
        .onChange(of: gitHubService.connectionStatus) { _, newStatus in
            switch newStatus {
            case .connected:
                isAuthenticating = false
                dismiss()
                onComplete()
            case .error(let message):
                isAuthenticating = false
                showError = true
                errorMessage = message
            case .connecting:
                isAuthenticating = true
                showError = false
            default:
                isAuthenticating = false
            }
        }
    }
    
    private func authenticateUser() {
        isAuthenticating = true
        showError = false
        gitHubService.authenticate(with: token)
    }
}

struct ContentView: View {
    @State private var selectedTab = 0
    @State private var showNewPost = false
    @State private var showSplash = true
    @State private var showingWelcomeOnboarding = false
    @StateObject var themeManager = ThemeManager()
    @StateObject var gitHubService = GitHubService()
    @State private var searchText = ""
    @State private var blogPosts: [BlogPost] = []
    @State private var selectedPost: BlogPost? = nil
    @State private var refreshID = UUID() // Force UI refresh
    
    // Initialize BlogStore early to ensure persistence
    private let blogStore = BlogStore.shared
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // Published Tab
            NavigationStack {
                List {
                    ForEach(blogPosts.filter { !$0.isDraft }) { post in
                        BlogPostCard(post: post)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedPost = post
                            }
                            .listRowBackground(Color(.systemGroupedBackground))
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color(.systemGroupedBackground))
                .navigationTitle("My Blogs")
                .id(refreshID) // Force refresh when this changes
                .onAppear(perform: loadBlogPosts)
                .refreshable {
                    // Add delay to require more intentional pull gesture
                    try? await Task.sleep(nanoseconds: 800_000_000) // 0.8 second delay
                    await performPullToRefreshSync()
                }
                .sheet(item: $selectedPost) { post in
                    if post.isDraft {
                        // For drafts, use the full editor
                        NavigationStack {
                            NewPostView(
                                existingPost: post,
                                isDraft: post.isDraft,
                                themeManager: themeManager,
                                onSave: {
                                    loadBlogPosts()
                                    selectedPost = nil
                                }
                            )
                            .applyDarkModeSheet(themeManager: themeManager)
                        }
                    } else {
                        // For published posts, use read-only view
                        ReadOnlyBlogView(
                            post: post,
                            gitHubService: gitHubService,
                            themeManager: themeManager
                        ) {
                            loadBlogPosts()
                            selectedPost = nil
                        }
                        .applyDarkModeSheet(themeManager: themeManager)
                    }
                }
            }
            .tabItem {
                Label("Published", systemImage: "doc.text.fill")
            }
            .tag(0)
            
            // Drafts Tab
            NavigationStack {
                ZStack(alignment: .bottom) {
                    DraftsView(blogPosts: $blogPosts, showNewPost: $showNewPost, gitHubService: gitHubService)
                        .id("draftsView") // Add an ID to force refresh when needed
                    
                    // Floating action button style
                    Button(action: { showNewPost = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 20, weight: .semibold))
                            Text("New Draft")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 20)
                        .foregroundColor(.white)
                        .background(
                            Capsule()
                                .fill(Color.accentColor)
                                .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
                        )
                    }
                    .padding(.bottom, 16) // Position closer to the tab bar
                    .padding(.horizontal, 16) // Add horizontal padding to avoid edges
                }
                .sheet(isPresented: $showNewPost) {
                    NavigationStack {
                        NewPostView(
                            isDraft: true,
                            themeManager: themeManager,
                            onSave: {
                                loadBlogPosts()
                                showNewPost = false
                            }
                        )
                        .applyDarkModeSheet(themeManager: themeManager)
                    }
                }
                .background(Color(.systemGroupedBackground))
            }
            .tabItem {
                Label("Drafts", systemImage: "doc.badge.clock.fill")
            }
            .tag(1)
            
            // Settings Tab
            NavigationStack {
                SettingsView(themeManager: themeManager, gitHubService: gitHubService)
                    .navigationTitle("Settings")
                    .background(Color(.systemGroupedBackground))
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
            .tag(2)
        }
        .overlay {
            if showSplash {
                SplashScreen(showSplash: $showSplash)
                    .zIndex(2)
            }
        }
        .sheet(isPresented: $showingWelcomeOnboarding) {
            GitHubOnboardingFlow(gitHubService: gitHubService)
                .applyDarkModeSheet(themeManager: themeManager)
        }
        .preferredColorScheme(themeManager.effectiveColorScheme)
        .background(Color(.systemBackground))
        .environmentObject(themeManager)
        .onAppear {
            // Load all posts (including drafts) when app starts
            print("🚀 App starting up - loading blog posts...")
            
            // Ensure BlogStore is initialized
            _ = BlogStore.shared
            
            loadBlogPosts()
            
            // Debug: If no drafts exist, let's test persistence
            let currentDrafts = blogPosts.filter { $0.isDraft }
            if currentDrafts.isEmpty {
                print("📝 No drafts found - database and file persistence should now work correctly")
            }
            
            // Check if we need to show onboarding
            checkForOnboarding()
        }
        .onChange(of: selectedTab) { _, _ in
            // Refresh data when switching to drafts tab
            if selectedTab == 1 {
                loadBlogPosts()
            }
        }
    }
    
    func loadBlogPosts() {
        // Use BlogStore to load posts
        print("🔄 loadBlogPosts: Starting to load posts...")
        
        // Debug: Check database contents
        BlogStore.shared.dumpAllRecords()
        
        // Debug: Check documents directory
        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        print("📁 Documents directory: \(docsURL.path)")
        do {
            let files = try FileManager.default.contentsOfDirectory(at: docsURL, includingPropertiesForKeys: nil)
            let markdownFiles = files.filter { $0.pathExtension == "md" }
            print("📁 Found \(markdownFiles.count) markdown files:")
            for file in markdownFiles {
                print("   📄 \(file.lastPathComponent)")
            }
        } catch {
            print("❌ Error reading documents directory: \(error)")
        }
        
        let freshPosts = BlogStore.shared.getAllBlogs()
        print("🔄 loadBlogPosts: Found \(freshPosts.count) posts total")
        let drafts = freshPosts.filter { $0.isDraft }
        print("📝 Found \(drafts.count) drafts:")
        for draft in drafts {
            print("   📄 \(draft.title) (ID: \(String(draft.id.prefix(8))))")
        }
        blogPosts = freshPosts
    }
    
    func publishDraft(_ post: BlogPost) {
        if BlogStore.shared.publishDraft(post) {
            loadBlogPosts()
        }
    }
    
    func triggerDelete(_ post: BlogPost) {
        selectedPost = post
    }
    
    func cancelDelete() {
        selectedPost = nil
    }
    
    func checkForOnboarding() {
        // Show onboarding if user hasn't configured GitHub yet
        // Add a small delay to let the splash screen complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if !gitHubService.configManager.isConfigured {
                showingWelcomeOnboarding = true
            }
        }
    }
    
    func performDelete() {
        guard let post = selectedPost else { return }
        let fileToDelete = post.fileURL
        do {
            try FileManager.default.removeItem(at: fileToDelete)
        } catch {
            print("Error deleting post: \(error)")
        }
        // Now update state and UI
        selectedPost = nil
        loadBlogPosts()
    }
    
    func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
         .lowercased()
         .folding(options: .diacriticInsensitive, locale: .current)
    }
    
    private func formatSyncDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    private func performPullToRefreshSync() async {
        // Use a complete refresh approach - like app startup
        await gitHubService.performCompleteRefreshSync()
        
        // Small delay to ensure file system operations complete
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second
        
        await MainActor.run {
            // Simply reload the blog posts from local storage
            print("🔄 Reloading blog posts after sync...")
            let oldCount = blogPosts.count
            loadBlogPosts()
            let newCount = blogPosts.count
            print("📊 Blog posts: \(oldCount) → \(newCount)")
            print("📋 Current posts: \(blogPosts.map { "\($0.title) (SHA: \(String($0.id.prefix(8))))" })")
            
            // Force UI refresh
            refreshID = UUID()
            print("🔄 Forced UI refresh with new ID")
        }
    }
}

struct NewPostView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var themeManager: ThemeManager
    @State private var title: String
    @State private var summary: String
    @State private var content: String
    @State private var showImageInserter: Bool = false
    @State private var tempImage: UIImage? = nil
    @State private var selectedTools: [String]
    @State private var selectedDate: Date
    @State private var selectedTab: Tab = .content
    @State private var selectedRange: NSRange = NSRange(location: 0, length: 0)
    @State private var lastSaveTime = Date()
    @State private var autoSaveWorkItem: DispatchWorkItem?
    @State private var originalPost: BlogPost?
    @State private var isNewPost: Bool = false
    @State private var isDraftState: Bool


    @State private var showingCommitDialog: Bool = false
    @State private var commitMessage: String = ""
    @State private var isCommittingToGitHub: Bool = false
    @State private var commitError: String?
    @State private var showingCommitError: Bool = false
    @State private var customTool: String = ""
    @State private var duplicateWarning: [String] = []
    @State private var showingDuplicateAlert: Bool = false
    @State private var isCheckingDuplicates: Bool = false
    
    @State private var allTools = ["KiCAD", "Fusion360", "Solidworks", "RaspberryPi", "Soldering", "Arduino", "CriticalThinking", "VPSHosting"]
    

    var existingPost: BlogPost? = nil
    var isDraft: Bool
    var onSave: () -> Void
    
    // Tab: Used for the post editor's tab navigation (enum-based)
    enum Tab: String, CaseIterable, Identifiable {
        case settings = "Post Details"
        case content = "Write Content"
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .settings: return "doc.badge.gearshape"
            case .content: return "square.and.pencil"
            }
        }
    }
    
    init(existingPost: BlogPost? = nil, isDraft: Bool, themeManager: ThemeManager, onSave: @escaping () -> Void) {
        self.onSave = onSave
        self.isDraft = isDraft
        self.themeManager = themeManager
        self._originalPost = State(initialValue: existingPost)
        self._isNewPost = State(initialValue: existingPost == nil)
        self._isDraftState = State(initialValue: false) // Always default to "Active on Website" when opening editor
        
        // Initialize these state properties before trying to handle date parsing
        _title = State(initialValue: existingPost?.title ?? "")
        _summary = State(initialValue: existingPost?.summary ?? "")
        _content = State(initialValue: existingPost?.content ?? "")
        _selectedTools = State(initialValue: existingPost?.tools ?? [])
        _selectedTab = State(initialValue: existingPost != nil ? .content : .settings)
        _tempImage = State(initialValue: nil)
        _showImageInserter = State(initialValue: false)
        _lastSaveTime = State(initialValue: Date())


        
        // Always initialize with a default value first
        _selectedDate = State(initialValue: Date())
        
        // Only try to parse date if we have an existing post
        if let post = existingPost {
            print("🔄 Initializing post with date: \(post.date)")
            
            // Try multiple date formats
            let dateFormatters = [
                ISO8601DateFormatter(),  // Try ISO8601 format first
                { () -> DateFormatter in  // Medium date style (e.g., "Jun 8, 2025")
                    let formatter = DateFormatter()
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .none
                    return formatter
                }(),
                { () -> DateFormatter in  // yyyy-MM-dd format
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd"
                    return formatter
                }()
            ]
            
            // Clean up the date string - remove quotes and whitespace
            let cleanDateString = post.date
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            print("🔄 Attempting to parse date: \(cleanDateString)")
            
            // Try each formatter
            var parsedDate: Date? = nil
            
            for formatter in dateFormatters {
                if let formatter = formatter as? ISO8601DateFormatter {
                    if let date = formatter.date(from: cleanDateString) {
                        parsedDate = date
                        print("✅ Parsed with ISO8601: \(date)")
                        break
                    }
                } else if let formatter = formatter as? DateFormatter {
                    if let date = formatter.date(from: cleanDateString) {
                        parsedDate = date
                        print("✅ Parsed with formatter: \(date)")
                        break
                    }
                }
            }
            
            // If still no date, try extracting directly from content
            if parsedDate == nil, let frontMatter = post.content.components(separatedBy: "---").dropFirst().first {
                for line in frontMatter.components(separatedBy: "\n") {
                    if line.trimmingCharacters(in: .whitespaces).hasPrefix("date:") {
                        let dateString = line.components(separatedBy: ":").dropFirst().joined(separator: ":")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "\"", with: "")
                        
                        print("🔍 Extracting date from content: \(dateString)")
                        
                        // Try each formatter again with the extracted date
                        for formatter in dateFormatters.dropFirst() { // Skip ISO8601 for content
                            if let formatter = formatter as? DateFormatter {
                                if let date = formatter.date(from: dateString) {
                                    parsedDate = date
                                    print("✅ Parsed from content: \(date)")
                                    break
                                }
                            }
                        }
                        
                        if parsedDate != nil {
                            break
                        }
                    }
                }
            }
            
            // If we found a date, use it
            if let parsedDate = parsedDate {
                print("✅ Final parsed date: \(parsedDate)")
                _selectedDate = State(initialValue: parsedDate)
            } else {
                print("⚠️ Failed to parse date, using current date")
            }
        }
    }
    
    // Helper to extract front matter values
    private func extractFrontMatterValue(_ frontMatter: String, key: String) -> String? {
        for line in frontMatter.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):") {
                return line.components(separatedBy: ":").dropFirst().joined(separator: ":")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
    
    func scheduleAutoSave() {
        // Cancel any previously scheduled auto-save
        autoSaveWorkItem?.cancel()
        
        // Only schedule auto-save if we have meaningful content
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        
        // Create a new work item for auto-saving
        let workItem = DispatchWorkItem {
            Task { @MainActor in
                // Only auto-save if enough time has passed
                if Date().timeIntervalSince(self.lastSaveTime) >= 2.0 {
                    self.autoSave()
                }
            }
        }
        
        // Schedule the work item to run after a delay (increased to 3 seconds for less aggressive auto-save)
        autoSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: workItem)
    }
    
    func autoSave() {
        // Cancel any pending auto-save
        autoSaveWorkItem?.cancel()
        
        // Only auto-save if we have meaningful content
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        
        // Save without dismissing
        let fileURL = BlogStore.shared.createOrUpdateBlogFile(
            post: originalPost,
            title: title,
            summary: summary,
            date: selectedDate,
            content: content,
            tools: selectedTools,
            isDraft: originalPost?.isDraft ?? true, // Preserve original draft status
            image: nil
        )
        
        // CRITICAL FIX: Update originalPost after first save to prevent duplicates
        if originalPost == nil {
            // This was a new post, so we need to update originalPost to point to the created post
            let savedPosts = BlogStore.shared.getAllBlogs()
            if let newlyCreatedPost = savedPosts.first(where: { $0.fileURL.path == fileURL.path }) {
                originalPost = newlyCreatedPost
                isNewPost = false
                print("📝 Updated originalPost after first save - ID: \(newlyCreatedPost.id)")
            }
        }
        
        lastSaveTime = Date()
        print("📝 Auto-saved: \(title)")
    }
    
    // Fix the cursor positioning and selection formatting
    func formatSelected(_ prefix: String, _ suffix: String) {
        print("🔧 Formatting text with prefix: '\(prefix)', suffix: '\(suffix)'")
        print("📍 Current selection range: \(selectedRange)")
        
        // Get actual content
        let nsContent = NSString(string: content)
        let contentLength = nsContent.length
        
        // Validate selection range
        guard selectedRange.location >= 0,
              selectedRange.location <= contentLength,
              selectedRange.location + selectedRange.length <= contentLength else {
            print("❌ Invalid selection range, resetting to end")
            selectedRange = NSRange(location: contentLength, length: 0)
            return
        }
        
        // Check if we have valid text selection
        if selectedRange.length > 0 {
            // Text is selected, wrap it with formatting
            let selectedText = nsContent.substring(with: selectedRange)
            print("📝 Selected text: '\(selectedText)'")
            
            // Create the formatted text
            let formattedText = prefix + selectedText + suffix
            
            // Replace the selected range with the formatted text
            let mutableContent = NSMutableString(string: content)
            mutableContent.replaceCharacters(in: selectedRange, with: formattedText)
            content = String(mutableContent)
            
            // Update the selection range to be at the end of the inserted text
            let newPosition = selectedRange.location + formattedText.count
            selectedRange = NSRange(location: newPosition, length: 0)
            print("✅ New cursor position: \(newPosition)")
        } else {
            // No text selected, insert at cursor position
            let cursorPosition = selectedRange.location
            print("📍 Cursor position: \(cursorPosition)")
            
            // Ensure cursor position is valid
            let safePosition = min(cursorPosition, contentLength)
            
            // Insert at cursor position
            let beforeCursor = nsContent.substring(to: safePosition)
            let afterCursor = nsContent.substring(from: safePosition)
            content = beforeCursor + prefix + suffix + afterCursor
            
            // Position cursor between prefix and suffix
            let newPosition = safePosition + prefix.count
            selectedRange = NSRange(location: newPosition, length: 0)
            print("✅ New cursor position: \(newPosition)")
        }
        
        // Trigger a refresh to update the preview
        refreshMarkdownPreview()
    }
    
    // Add a method to trigger markdown preview refresh
    func refreshMarkdownPreview() {
        // Force the TextEditor to refresh by triggering a tiny change
        // This will be imperceptible to the user but will cause the view to update
        DispatchQueue.main.async {
            // Create a notification to refresh markdown view
            NotificationCenter.default.post(name: NSNotification.Name("RefreshMarkdownPreview"), object: nil, userInfo: ["text": content, "range": selectedRange])
        }
    }
    
    // Update the image insertion to work with the cursor position
    func insertImageAtCursor() {
        showImageInserter = true
    }
    
    func processImageInsertion(_ image: UIImage) {
        print("🖼️ Processing image insertion...")
        
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            print("❌ Failed to convert image to JPEG data")
            return
        }
        
        let imageFilename = "image_\(UUID().uuidString.prefix(8)).jpg"
        print("🖼️ Generated filename: \(imageFilename)")
        
        // Always save locally first for immediate insertion
        // Images will be uploaded to GitHub when the post is published/committed
        print("🖼️ Saving locally for optimized workflow")
        saveImageLocally(imageData: imageData, filename: imageFilename)
        
        tempImage = nil
    }
    
    private func saveImageLocally(imageData: Data, filename: String) {
        print("💾 Saving image locally: \(filename)")
        
        // Get documents directory
        let fileManager = FileManager.default
        guard let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("❌ Could not access documents directory")
            return
        }
        
        let imageURL = docsURL.appendingPathComponent(filename)
        print("💾 Save path: \(imageURL.path)")
        
        // Save image to file
        do {
            try imageData.write(to: imageURL)
            print("✅ Image saved successfully")
            
            // Always use local file path for immediate insertion
            // When publishing, the uploadLocalImagesInContent function will convert these to GitHub paths
            let imageTag = "![Image](file://\(imageURL.path))"
            
            print("📝 Inserting markdown: \(imageTag)")
            
            // Use the formatSelected method to ensure proper cursor positioning
            DispatchQueue.main.async {
                self.formatSelected(imageTag, "")
            }
        } catch {
            print("❌ Failed to save image: \(error.localizedDescription)")
        }
    }
    
    private func uploadImageToGitHub(imageData: Data, filename: String) {
        print("🚀 Starting optimized image insertion for: \(filename)")
        
        // Always save locally first for immediate insertion
        saveImageLocally(imageData: imageData, filename: filename)
        
        // Note: Images will be uploaded to GitHub when the post is published/committed
        // This ensures single commit for both images and post content
    }
    
    // Save logic - needs to handle embedded images
    func savePost() {
        // Cancel any pending auto-save
        autoSaveWorkItem?.cancel()
        
        // For published posts, we need to commit to GitHub
        if let existingPost = originalPost, !existingPost.isDraft {
            // This is an edit to a published post - show commit dialog
            print("🔄 Detected published post edit - showing commit dialog")
            showingCommitDialog = true
            return // Don't dismiss yet - wait for commit
        }
        
        // For new posts or drafts, check for duplicates first
        if isNewPost || originalPost?.isDraft == true {
            Task {
                let canProceed = await checkDuplicatesBeforeSave()
                if canProceed {
                    await MainActor.run {
                        performSave()
                    }
                }
                // If duplicates found, the alert will show and user can choose to continue
            }
        } else {
            performSave()
        }
    }
    
    // Perform the actual save operation
    func performSave() {
        print("🔄 Saving as draft/new post")
        
        // Create the post first to get the ID
        let fileURL = BlogStore.shared.createOrUpdateBlogFile(
            post: originalPost,
            title: title,
            summary: summary,
            date: selectedDate,
            content: content,
            tools: selectedTools,
            isDraft: originalPost?.isDraft ?? true, // Keep existing status or default to draft
            image: nil
        )
        
        // Update originalPost if this was a new post
        if originalPost == nil {
            let savedPosts = BlogStore.shared.getAllBlogs()
            if let newlyCreatedPost = savedPosts.first(where: { $0.fileURL.path == fileURL.path }) {
                originalPost = newlyCreatedPost
                isNewPost = false
                print("📝 Updated originalPost after manual save - ID: \(newlyCreatedPost.id)")
            }
        }
        
        lastSaveTime = Date()
        onSave() // This will trigger the dismissal for drafts only
    }
    
    // Perform GitHub commit for published posts
    func commitToGitHub() {
        isCommittingToGitHub = true
        
        guard let existingPost = originalPost else { return }
        
        // Create an updated BlogPost with new content (for debugging/validation)
        let _ = BlogPost(
            id: existingPost.id,
            title: title,
            summary: summary,
            date: existingPost.date,
            lastEdited: existingPost.lastEdited,
            fileURL: existingPost.fileURL,
            content: content,
            tools: selectedTools,
            isDraft: false, // This is a published post
            isArchived: isDraftState // isDraftState controls archive status
        )
        
        print("🔧 Creating updated post: archived=\(isDraftState)")
        
        Task {
            do {
                // Create a single GitHub service instance for all operations
                let gitHubService = GitHubService()
                
                // Prepare content and collect images to upload
                let preparedContent = try gitHubService.prepareContentWithGitHubImagePaths(content)
                
                // Create updated post with GitHub image paths
                let finalUpdatedPost = BlogPost(
                    id: existingPost.id,
                    title: title,
                    summary: summary,
                    date: existingPost.date,
                    lastEdited: existingPost.lastEdited,
                    fileURL: existingPost.fileURL,
                    content: preparedContent.updatedContent, // Use updated content with GitHub image paths
                    tools: selectedTools,
                    isDraft: false, // This is a published post
                    isArchived: isDraftState // isDraftState controls archive status
                )
                
                // Save locally with the updated content
                _ = BlogStore.shared.createOrUpdateBlogFile(
                    post: originalPost,
                    title: title,
                    summary: summary,
                    date: selectedDate,
                    content: preparedContent.updatedContent, // Save with GitHub image paths
                    tools: selectedTools,
                    isDraft: false, // Keep as published in local DB
                    image: nil
                )
                
                // For updating existing posts, we need to use the single commit approach if there are images
                let success: Bool
                if preparedContent.imagesToUpload.isEmpty {
                    // No images, use the regular update method
                    success = try await gitHubService.updateExistingPost(finalUpdatedPost, commitMessage: commitMessage)
                } else {
                    // Images present, need to find the existing blog file and use single commit
                    
                    // First, try to extract original filename from lastEdited field
                    let originalFileName = gitHubService.getOriginalFileName(from: existingPost)
                    if let fileName = originalFileName {
                        print("📝 Using original filename from sync: \(fileName)")
                    }
                    
                    let blogFiles = try await gitHubService.fetchBlogFiles()
                    var targetFileName: String?
                    
                    if let fileName = originalFileName {
                        // Try to find by original filename first
                        if blogFiles.contains(where: { $0.name == fileName }) {
                            targetFileName = fileName
                            print("✅ Found file by original name: \(fileName)")
                        }
                    }
                    
                    // If not found by filename, fall back to title matching
                    if targetFileName == nil {
                        print("🔍 Searching by title since filename lookup failed...")
                        for file in blogFiles {
                            if let parsedPost = gitHubService.parseBlogFile(file),
                               parsedPost.title.lowercased() == title.lowercased() {
                                targetFileName = file.name
                                print("✅ Found file by title match: \(file.name)")
                                break
                            }
                        }
                    }
                    
                    if let fileName = targetFileName {
                        let blogPath = "blog/\(fileName)"
                        let markdownContent = gitHubService.generateMarkdownContent(for: finalUpdatedPost)
                        
                        success = try await gitHubService.uploadFilesInSingleCommit(
                            blogPath: blogPath,
                            blogContent: markdownContent,
                            images: preparedContent.imagesToUpload,
                            commitMessage: commitMessage
                        )
                    } else {
                        // Fallback to regular update if we can't find the file
                        success = try await gitHubService.updateExistingPost(finalUpdatedPost, commitMessage: commitMessage)
                    }
                }
                
                await MainActor.run {
                    isCommittingToGitHub = false
                    if success {
                        onSave()
                    } else {
                        // Show error
                        commitError = "Failed to commit to GitHub"
                        showingCommitError = true
                    }
                }
            } catch {
                await MainActor.run {
                    isCommittingToGitHub = false
                    commitError = error.localizedDescription
                    showingCommitError = true
                }
            }
        }
    }
    
    // Check for duplicate titles during save
    func checkDuplicatesBeforeSave() async -> Bool {
        guard !title.isEmpty else { return true }
        
        do {
            let gitHubService = GitHubService()
            let duplicates = try await gitHubService.checkForExactDuplicateTitle(title)
            
            if !duplicates.isEmpty {
                await MainActor.run {
                    duplicateWarning = duplicates
                    showingDuplicateAlert = true
                }
                return false // Don't proceed with save
            }
            return true // No duplicates, proceed with save
        } catch {
            print("❌ Failed to check for duplicates: \(error)")
            return true // On error, proceed with save
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Modern segmented control for tabs with consistent styling
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Tab.allCases) { tab in
                        Button(action: {
                            withAnimation {
                                selectedTab = tab
                            }
                        }) {
                            VStack(spacing: 4) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 16))
                                Text(tab.rawValue)
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                Rectangle()
                                    .fill(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                            )
                            .foregroundColor(selectedTab == tab ? .accentColor : .gray)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .background(Color(.systemBackground))
                
                // Active tab indicator
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 1)
                    
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: UIScreen.main.bounds.width / CGFloat(Tab.allCases.count), height: 2)
                        .offset(x: selectedTab == .settings ? 0 : UIScreen.main.bounds.width / 2)
                }
            }
            
            // Content for both tabs with a consistent background
            if selectedTab == .settings {
                PostSettingsView(
                    title: $title,
                    summary: $summary,
                    selectedDate: $selectedDate,
                    isDraftState: $isDraftState,
                    selectedTools: $selectedTools,
                    allTools: $allTools
                )
            } else {
                // Content tab - Enhanced editor
                VStack(alignment: .center, spacing: 0) {
                    // Improved formatting toolbar
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 20) {
                            FormatButton(icon: "bold", action: { formatSelected("**", "**") })
                            FormatButton(icon: "italic", action: { formatSelected("*", "*") })
                            FormatButton(text: "H1", action: { formatSelected("# ", "") })
                            FormatButton(text: "H2", action: { formatSelected("## ", "") })
                            FormatButton(icon: "text.quote", action: { formatSelected("> ", "") })
                            FormatButton(icon: "list.bullet", action: { formatSelected("- ", "") })
                            FormatButton(icon: "list.number", action: { formatSelected("1. ", "") })
                            FormatButton(icon: "chevron.left.slash.chevron.right", action: { formatSelected("`", "`") })
                            FormatButton(icon: "photo", action: insertImageAtCursor)
                            FormatButton(icon: "link", action: { formatSelected("[", "](url)") })
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .background(Color(.systemBackground))
                    
                    Divider()
                    
                    // Use MarkdownTextView for better cursor control
                    MarkdownTextView(text: $content, selectedRange: $selectedRange)
                        .id("markdownEditor")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.systemBackground))
                }
                .background(Color(.systemBackground))
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(isNewPost ? "New Post" : "Edit Post")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isNewPost ? "Create" : "Save") {
                    savePost()
                    // Don't auto-dismiss - let savePost handle it
                }
                .fontWeight(.semibold)
                .foregroundColor(.accentColor)
            }
        }
        .sheet(isPresented: $showImageInserter) {
            ImagePicker(image: $tempImage, themeManager: themeManager)
                .applyDarkModeSheet(themeManager: themeManager)
                .onDisappear {
                    if let image = tempImage {
                        processImageInsertion(image)
                    }
                }
        }
        .onChange(of: title) { _, newValue in 
            scheduleAutoSave()
        }
        .onChange(of: summary) { _, _ in scheduleAutoSave() }
        .onChange(of: content) { _, _ in scheduleAutoSave() }
        .onChange(of: selectedTools) { _, _ in scheduleAutoSave() }
        .onChange(of: selectedDate) { _, _ in scheduleAutoSave() }
        .onChange(of: isDraftState) { _, _ in scheduleAutoSave() }
        .onDisappear {
            if !isNewPost {
                autoSaveWorkItem?.cancel()
                if Date().timeIntervalSince(lastSaveTime) >= 1.0 {
                    autoSave()
                }
            }
        }
        .alert("Commit to GitHub", isPresented: $showingCommitDialog) {
            TextField("Commit message", text: $commitMessage)
            Button("Cancel", role: .cancel) { }
            Button("Commit Changes") {
                commitToGitHub()
            }
            .disabled(commitMessage.isEmpty || isCommittingToGitHub)
        } message: {
            Text("This post is published. Changes will be committed directly to your GitHub repository.")
        }
        .alert("Commit Error", isPresented: $showingCommitError) {
            Button("OK") { }
        } message: {
            if let error = commitError {
                Text(error)
            }
        }
        .alert("Duplicate Title Warning", isPresented: $showingDuplicateAlert) {
            Button("Continue Anyway") { 
                performSave()
            }
            Button("Change Title", role: .cancel) { }
        } message: {
            if duplicateWarning.count == 1 {
                Text("A blog post with the exact same title already exists:\n\n\"\(duplicateWarning[0])\"\n\nYour post will be saved with a numbered suffix (e.g., \"\(title)2\").")
            } else {
                Text("Blog posts with the exact same title already exist:\n\n\(duplicateWarning.map { "\"\($0)\"" }.joined(separator: "\n"))\n\nYour post will be saved with a numbered suffix.")
            }
        }
        .onAppear {
            if let existingPost = originalPost, !existingPost.isDraft {
                commitMessage = "Update blog post: \(existingPost.title)"
            }
        }
    }
}

// Custom CardGroupBoxStyle for consistent card styling
struct CardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
                .padding(.horizontal, 4)
            
            configuration.content
                .padding(.top, 2)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.03), radius: 3, x: 0, y: 1)
        )
    }
}

// Helper view for formatting buttons
struct FormatButton: View {
    var icon: String? = nil
    var text: String? = nil
    var action: () -> Void
    
    var body: some View {
        Button(action: action) {
            if let iconName = icon {
                Image(systemName: iconName)
                    .font(.system(size: 18))
                    .frame(width: 32, height: 32)
            } else if let buttonText = text {
                Text(buttonText)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
        }
        .foregroundColor(.primary)
    }
}



// Separate view for post settings to break down complex expressions
struct PostSettingsView: View {
    @Binding var title: String
    @Binding var summary: String
    @Binding var selectedDate: Date
    @Binding var isDraftState: Bool
    @Binding var selectedTools: [String]
    @Binding var allTools: [String]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 24) {
                // Title and Summary card
                TitleSummaryCard(title: $title, summary: $summary)
                
                // Publication Date Section
                PublicationDateSection(selectedDate: $selectedDate)
                
                // Archive Status Section
                ArchiveStatusSection(isDraftState: $isDraftState)
                
                // Tools Section
                ToolsSection(
                    selectedTools: $selectedTools,
                    allTools: $allTools
                )
            }
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground))
    }
}

// Title and Summary Card Component
struct TitleSummaryCard: View {
    @Binding var title: String
    @Binding var summary: String
    
    var body: some View {
        VStack(spacing: 16) {
            TextField("Title", text: $title)
                .font(.largeTitle.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.top, 20)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.words)
            
            TextField("Summary", text: $summary)
                .font(.title3)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.sentences)
        }
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.03), radius: 3, x: 0, y: 1)
        )
        .padding(.horizontal)
        .padding(.top, 16)
    }
}

// Publication Date Section Component
struct PublicationDateSection: View {
    @Binding var selectedDate: Date
    
    var body: some View {
        GroupBox(label:
            Label("Publication Date", systemImage: "calendar")
                .font(.headline)
        ) {
            DatePicker("", selection: $selectedDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(.vertical, 8)
        }
        .groupBoxStyle(CardGroupBoxStyle())
        .padding(.horizontal)
    }
}

// Archive Status Section Component
struct ArchiveStatusSection: View {
    @Binding var isDraftState: Bool
    
    private var statusColor: Color {
        isDraftState ? .purple : .green
    }
    
    private var statusText: String {
        isDraftState ? "Archived" : "Active"
    }
    
    var body: some View {
        GroupBox(label:
            HStack {
                Label("Website Visibility", systemImage: "eye")
                    .font(.headline)
                Spacer()
                Text(statusText)
                    .font(.subheadline)
                    .foregroundColor(statusColor)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        Capsule()
                            .fill(statusColor.opacity(0.1))
                    )
            }
        ) {
            Toggle(isOn: $isDraftState) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isDraftState ? "Archived" : "Active on Website")
                            .fontWeight(.medium)
                        
                        Text(isDraftState ? "Hidden from website visitors" : "Visible to all website visitors")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
            }
            .padding(.vertical, 10)
            .toggleStyle(SwitchToggleStyle(tint: statusColor))
        }
        .groupBoxStyle(CardGroupBoxStyle())
        .padding(.horizontal)
    }
}

// Native iOS-style Tools Section Component (like Contacts app)
struct ToolsSection: View {
    @Binding var selectedTools: [String]
    @Binding var allTools: [String]
    @State private var newToolName: String = ""
    @State private var showingAddTool: Bool = false
    
    var body: some View {
        GroupBox(label:
            Label("Tools & Technologies", systemImage: "wrench.and.screwdriver")
                .font(.headline)
        ) {
            VStack(spacing: 0) {
                // Selected Tools List (native iOS style)
                ForEach(selectedTools.indices, id: \.self) { index in
                    HStack {
                        Text(selectedTools[index])
                            .font(.body)
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        Button(action: {
                            selectedTools.remove(at: index)
                        }) {
                            Image(systemName: "minus.circle.fill")
                                .font(.title3)
                                .foregroundColor(.red)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 4)
                    
                    if index < selectedTools.count - 1 {
                        Divider()
                            .padding(.leading, 4)
                    }
                }
                
                // Add separator if there are selected tools
                if !selectedTools.isEmpty && !availableTools.isEmpty {
                    Divider()
                        .padding(.leading, 4)
                }
                
                // Available Tools to Add (native iOS style)
                ForEach(availableTools, id: \.self) { tool in
                    HStack {
                        Button(action: {
                            selectedTools.append(tool)
                        }) {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                                    .foregroundColor(.green)
                                
                                Text("add \(tool)")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                
                                Spacer()
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 4)
                    
                    if tool != availableTools.last {
                        Divider()
                            .padding(.leading, 4)
                    }
                }
                
                // Add custom tool option
                if !availableTools.isEmpty || !selectedTools.isEmpty {
                    Divider()
                        .padding(.leading, 4)
                }
                
                Button(action: { showingAddTool = true }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundColor(.green)
                        
                        Text("add custom tool")
                            .font(.body)
                            .foregroundColor(.primary)
                        
                        Spacer()
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.vertical, 12)
                .padding(.horizontal, 4)
            }
            .padding(.vertical, 8)
        }
        .groupBoxStyle(CardGroupBoxStyle())
        .padding(.horizontal)
        .alert("Add Custom Tool", isPresented: $showingAddTool) {
            TextField("Tool name", text: $newToolName)
            Button("Cancel", role: .cancel) { 
                newToolName = ""
            }
            Button("Add") {
                if !newToolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let toolName = newToolName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !allTools.contains(toolName) {
                        allTools.append(toolName)
                    }
                    if !selectedTools.contains(toolName) {
                        selectedTools.append(toolName)
                    }
                }
                newToolName = ""
            }
            .disabled(newToolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Enter the name of the tool you'd like to add.")
        }
    }
    
    // Computed property for available tools (not selected)
    private var availableTools: [String] {
        allTools.filter { !selectedTools.contains($0) }
    }
}





// FlowLayout to display tags in a flowing grid
struct FlowLayout: Layout {
    var spacing: CGFloat = 10
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        var height: CGFloat = 0
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        
        for (index, size) in sizes.enumerated() {
            if rowWidth + size.width > containerWidth {
                // Move to next row
                height += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                // Stay in current row
                rowWidth += size.width + (index > 0 ? spacing : 0)
                rowHeight = max(rowHeight, size.height)
            }
        }
        
        // Add the last row's height
        height += rowHeight
        
        return CGSize(width: containerWidth, height: height)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        
        var rowX: CGFloat = bounds.minX
        var rowY: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        
        for (index, size) in sizes.enumerated() {
            if rowX + size.width > bounds.maxX {
                // Move to next row
                rowX = bounds.minX
                rowY += rowHeight + spacing
                rowHeight = 0
            }
            
            subviews[index].place(
                at: CGPoint(x: rowX, y: rowY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            
            rowX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct ImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @ObservedObject var themeManager: ThemeManager
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
            provider.loadObject(ofClass: UIImage.self) { image, _ in
                DispatchQueue.main.async {
                    self.parent.image = image as? UIImage
                }
            }
        }
    }
}

struct SplashScreen: View {
    @Binding var showSplash: Bool
    @State private var showLogo = false
    @State private var showText = false
    @State private var logoScale: CGFloat = 0.3
    
    var personalizedGreeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour > 5 && hour < 12 {
            return "Good Morning"
        } else if hour < 18 {
            return "Good Afternoon"
        } else {
            return "Good Evening"
        }
    }
    
    var body: some View {
        ZStack {
            // Clean, elegant dark background - no animation
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: Color.black, location: 0.0),
                    .init(color: Color(red: 0.02, green: 0.02, blue: 0.08), location: 0.4),
                    .init(color: Color(red: 0.05, green: 0.05, blue: 0.15), location: 0.8),
                    .init(color: Color(red: 0.08, green: 0.08, blue: 0.18), location: 1.0)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 40) {
                // Logo with modern design
                ZStack {
                    // Glow effect
                    Circle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    Color.blue.opacity(0.3),
                                    Color.clear
                                ]),
                                center: .center,
                                startRadius: 10,
                                endRadius: 50
                            )
                        )
                        .frame(width: 100, height: 100)
                        .opacity(showLogo ? 0.8 : 0)
                    
                    // Main logo icon
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, Color.blue.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .scaleEffect(logoScale)
                        .opacity(showLogo ? 1 : 0)
                }
                .padding(.bottom, 20)
                
                VStack(spacing: 12) {
                    // Greeting
                    Text(personalizedGreeting)
                        .font(.system(size: 28, weight: .light, design: .rounded))
                        .foregroundColor(.white)
                        .opacity(showText ? 1 : 0)
                        .offset(y: showText ? 0 : 30)
                    
                    // App name/branding
                    Text("Kirusha's Blog")
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.8))
                        .opacity(showText ? 1 : 0)
                        .offset(y: showText ? 0 : 30)
                    
                    // Subtle tagline
                    Text("Mindful space for blog writing")
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))
                        .opacity(showText ? 1 : 0)
                        .offset(y: showText ? 0 : 30)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            // Logo animation - smooth spring entrance
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7).delay(0.2)) {
                showLogo = true
                logoScale = 1.0
            }
            
            // Text animation - staggered entrance
            withAnimation(.easeOut(duration: 0.8).delay(0.6)) {
                showText = true
            }
            
            // Auto-dismiss after a reasonable time
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                withAnimation(.easeOut(duration: 0.6)) {
                    showSplash = false
                }
            }
        }
        .transition(.opacity)
    }
}

struct BlogPostCard: View {
    let post: BlogPost
    

    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(post.title)
                            .font(.title2).bold()
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        // Status indicator
                        if post.isDraft {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.badge.clock")
                                    .font(.caption)
                                Text("Draft")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(8)
                        } else if post.isArchived {
                            HStack(spacing: 4) {
                                Image(systemName: "archivebox.fill")
                                    .font(.caption)
                                Text("Archived")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.purple.opacity(0.15))
                            .foregroundColor(.purple)
                            .cornerRadius(8)
                        } else {
                            // All published posts (non-draft, non-archived) show as "Active"
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                Text("Active")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.15))
                            .foregroundColor(.green)
                            .cornerRadius(8)
                        }
                    }
                    
                    Text(post.summary)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            
            HStack {
                if post.isDraft {
                    Text("Last Edited: \(post.lastEdited)")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Spacer()
                }
                Text(post.date)
                    .font(.caption)
                    .foregroundColor(.gray)
                if !post.isDraft {
                    Spacer()
                }
            }
            
            // Tools preview (if any) - Better UI
            if !post.tools.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("Tools")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    
                    // Modern flow layout for tools
                    LazyVStack(alignment: .leading, spacing: 4) {
                        let rows = post.tools.chunked(into: 2)
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 6) {
                                ForEach(row, id: \.self) { tool in
                                    Text(tool)
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            Capsule()
                                                .fill(Color.accentColor.opacity(0.15))
                                        )
                                        .foregroundColor(.accentColor)
                                }
                                Spacer()
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: Color(.black).opacity(0.04), radius: 6, x: 0, y: 2)
                .overlay(
                    // Add a subtle border for active posts
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(!post.isDraft && !post.isArchived ? Color.green.opacity(0.3) : Color.clear, lineWidth: 1)
                )
        )
    }
}

struct DraftsView: View {
    @Binding var blogPosts: [BlogPost]
    @State private var isSelecting = false
    @State private var selectedDrafts: Set<String> = []
    @State private var draftToDelete: BlogPost? = nil
    @State private var showDeleteConfirmation = false
    @State private var selectedDraft: BlogPost? = nil
    @State private var showingPublishSuccess = false
    @State private var publishCount = 0
    @State private var isPublishingBatch = false
    @Binding var showNewPost: Bool
    @EnvironmentObject var themeManager: ThemeManager
    @State private var draftToPublish: BlogPost? = nil
    @State private var showingPublishView = false
    @ObservedObject var gitHubService: GitHubService
    
    var body: some View {
        let drafts = blogPosts.filter { $0.isDraft }
        
        Group {
            if drafts.isEmpty {
                // Empty state
                VStack(spacing: 20) {
                    Spacer()
                    
                    Image(systemName: "doc.badge.clock")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    
                    Text("No Drafts Yet")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    Text("Start writing your first blog post by tapping the \"New Draft\" button below.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
            } else {
                List {
                    ForEach(drafts, id: \.id) { post in
                        if isSelecting {
                            HStack {
                                Image(systemName: selectedDrafts.contains(post.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedDrafts.contains(post.id) ? .accentColor : .gray)
                                    .font(.title2)
                                    .padding(.trailing, 8)
                                BlogPostCard(post: post)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    toggleSelection(for: post)
                                }
                            }
                            .listRowBackground(Color(.systemGroupedBackground))
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        } else {
                            BlogPostCard(post: post)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedDraft = post
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        draftToDelete = post
                                        showDeleteConfirmation = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        draftToPublish = post
                                        showingPublishView = true
                                    } label: {
                                        Label("Publish", systemImage: "paperplane")
                                    }
                                    .tint(.green)
                                }
                                .listRowBackground(Color(.systemGroupedBackground))
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        }
                    }
                    
                    // Empty row for spacing at the bottom to accommodate the FAB
                    if !isSelecting {
                        Color.clear
                            .frame(height: 60)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color(.systemGroupedBackground))
                .animation(.easeInOut(duration: 0.2), value: isSelecting)
                .animation(.easeInOut(duration: 0.2), value: selectedDrafts.count)
            }
        }
        .navigationTitle(isSelecting ? (selectedDrafts.isEmpty ? "Select Drafts" : "\(selectedDrafts.count) Selected") : "My Drafts")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isSelecting ? "Cancel" : "Select") {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        isSelecting.toggle()
                        if !isSelecting {
                            selectedDrafts.removeAll()
                        }
                    }
                }
                .disabled(drafts.isEmpty) // Disable selection when no drafts
            }
            
            // Add publish button to the toolbar when in selection mode
            if isSelecting {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: publishSelected) {
                        HStack(spacing: 5) {
                            if isPublishingBatch {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .progressViewStyle(CircularProgressViewStyle(tint: .accentColor))
                            } else {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 16))
                            }
                            Text(isPublishingBatch ? "Publishing..." : "Publish")
                                .fontWeight(.medium)
                        }
                        .foregroundColor(selectedDrafts.isEmpty || isPublishingBatch ? .gray : .accentColor)
                    }
                    .disabled(selectedDrafts.isEmpty || isPublishingBatch)
                    .opacity(selectedDrafts.isEmpty || isPublishingBatch ? 0.6 : 1.0)
                }
            }
        }
        .overlay {
            if showingPublishSuccess {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 20))
                        Text("\(publishCount) \(publishCount == 1 ? "draft" : "drafts") published")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(Color(.systemBackground))
                            .shadow(color: Color.black.opacity(0.1), radius: 5, x: 0, y: 2)
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 100)
                }
                .animation(.spring(response: 0.4), value: showingPublishSuccess)
            }
        }
        .sheet(item: $selectedDraft) { draft in
            NavigationStack {
                NewPostView(
                    existingPost: draft,
                    isDraft: draft.isDraft,
                    themeManager: themeManager,
                    onSave: {
                        // Reload blog posts to refresh the list
                        loadBlogPosts()
                        selectedDraft = nil
                    }
                )
                .applyDarkModeSheet(themeManager: themeManager)
            }
        }
        .sheet(isPresented: $showingPublishView) {
            if let draft = draftToPublish {
                PublishDraftView(
                    draft: draft,
                    gitHubService: gitHubService
                ) {
                    // On successful publish, reload data
                    loadBlogPosts()
                    draftToPublish = nil
                }
                .applyDarkModeSheet(themeManager: themeManager)
            }
        }
        .alert("Delete Draft", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                draftToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let draft = draftToDelete {
                    deleteDraft(draft)
                }
                draftToDelete = nil
            }
        } message: {
            if let draft = draftToDelete {
                Text("Are you sure you want to delete \"\(draft.title)\"?\nThis action cannot be undone.")
            }
        }
    }
    
    private func toggleSelection(for post: BlogPost) {
        if selectedDrafts.contains(post.id) {
            selectedDrafts.remove(post.id)
        } else {
            selectedDrafts.insert(post.id)
        }
    }
    
    private func publishSelected() {
        guard !isPublishingBatch else { return }
        
        let draftsToPublish = blogPosts.filter { selectedDrafts.contains($0.id) }
        publishCount = draftsToPublish.count
        isPublishingBatch = true
        
        // Publish each draft to GitHub
        Task {
            for draft in draftsToPublish {
                do {
                    let commitMessage = "Publish blog post: \(draft.title)"
                    _ = try await gitHubService.publishDraft(draft, commitMessage: commitMessage)
                } catch {
                    print("Error publishing \(draft.title): \(error)")
                }
            }
            
            await MainActor.run {
                isPublishingBatch = false
                
                // Show a success message
                showingPublishSuccess = true
                
                // Delay the exit from selection mode for a smoother experience
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        selectedDrafts.removeAll()
                        isSelecting = false
                    }
                    
                    // Reload posts to reflect changes
                    loadBlogPosts()
                    
                    // Hide the success message after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showingPublishSuccess = false
                    }
                }
            }
        }
    }
    
    private func deleteDraft(_ draft: BlogPost) {
        let fileToDelete = draft.fileURL
        do {
            try FileManager.default.removeItem(at: fileToDelete)
            // Also remove from database
            BlogStore.shared.deleteBlog(id: draft.id)
            // Reload the posts
            loadBlogPosts()
        } catch {
            print("Error deleting draft: \(error)")
        }
    }
    
    private func loadBlogPosts() {
        // Get fresh data from the store
        blogPosts = BlogStore.shared.getAllBlogs()
    }
}

// MARK: - Read-Only Blog View
struct ReadOnlyBlogView: View {
    let post: BlogPost
    @ObservedObject var gitHubService: GitHubService
    @ObservedObject var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var showingEditConfirmation = false
    @State private var showingEditView = false
    let onUpdate: () -> Void
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(alignment: .leading, spacing: 12) {
                        Text(post.title)
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.leading)
                        
                        Text(post.summary)
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(post.date)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Spacer()
                                
                                // Archive Status
                                HStack(spacing: 4) {
                                    Image(systemName: post.isArchived ? "archivebox.fill" : "eye.fill")
                                        .font(.caption)
                                    Text(post.isArchived ? "Archived" : "Active")
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(post.isArchived ? Color.purple.opacity(0.15) : Color.green.opacity(0.15))
                                .foregroundColor(post.isArchived ? .purple : .green)
                                .cornerRadius(8)
                            }
                            
                            // Tools Section - Enhanced Design
                            if !post.tools.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Image(systemName: "wrench.and.screwdriver.fill")
                                            .font(.subheadline)
                                            .foregroundColor(.accentColor)
                                        Text("Tools & Technologies")
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.primary)
                                        Spacer()
                                    }
                                    
                                    // Enhanced tools flow layout
                                    LazyVStack(alignment: .leading, spacing: 8) {
                                        let rows = post.tools.chunked(into: 2)
                                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                            HStack(spacing: 8) {
                                                ForEach(row, id: \.self) { tool in
                                                    HStack(spacing: 6) {
                                                        Image(systemName: "checkmark.circle.fill")
                                                            .font(.caption)
                                                            .foregroundColor(.green)
                                                        Text(tool)
                                                            .font(.subheadline)
                                                            .fontWeight(.medium)
                                                    }
                                                    .padding(.horizontal, 12)
                                                    .padding(.vertical, 8)
                                                    .background(
                                                        RoundedRectangle(cornerRadius: 8)
                                                            .fill(Color.accentColor.opacity(0.1))
                                                            .overlay(
                                                                RoundedRectangle(cornerRadius: 8)
                                                                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                                                            )
                                                    )
                                                    .foregroundColor(.accentColor)
                                                }
                                                Spacer()
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color(.systemGray6))
                                )
                            }
                        }
                        
                        // Read-only indicator
                        HStack {
                            Image(systemName: "lock.circle.fill")
                                .foregroundColor(.orange)
                            Text("Read-only (synced from GitHub)")
                                .font(.caption)
                                .foregroundColor(.orange)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                    }
                    
                    Divider()
                    
                    // Content
                    Text(post.content)
                        .font(.body)
                        .lineSpacing(6)
                        .multilineTextAlignment(.leading)
                    
                    Spacer(minLength: 100)
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingEditConfirmation = true
                    } label: {
                        Image(systemName: "pencil.circle")
                    }
                }
            }
        }
        .alert("Edit Published Post", isPresented: $showingEditConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Edit & Commit to GitHub") {
                showingEditView = true
            }
        } message: {
            Text("This will allow you to edit '\(post.title)' and automatically commit changes to your GitHub repository.\n\nAre you sure you want to proceed?")
        }
        .sheet(isPresented: $showingEditView) {
            NavigationStack {
                NewPostView(
                    existingPost: post,
                    isDraft: false, // This is a published post
                    themeManager: themeManager,
                    onSave: {
                        onUpdate()
                        showingEditView = false
                    }
                )
                .applyDarkModeSheet(themeManager: themeManager)
            }
        }
    }
}


// MARK: - Publish Draft View
struct PublishDraftView: View {
    let draft: BlogPost
    @ObservedObject var gitHubService: GitHubService
    @Environment(\.dismiss) private var dismiss
    @State private var commitMessage: String = ""
    @State private var isPublishing = false
    @State private var publishError: String?
    @State private var showingError = false
    let onSuccess: () -> Void
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "paperplane.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.accentColor)
                    
                    Text("Publish to GitHub")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("Ready to publish \"\(draft.title)\" to your blog?")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                }
                
                // Draft Preview
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Draft Preview")
                            .font(.headline)
                        Spacer()
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(draft.title)
                            .font(.title3)
                            .fontWeight(.semibold)
                        
                        Text(draft.summary)
                            .font(.body)
                            .foregroundColor(.secondary)
                        
                        if !draft.tools.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: "wrench.and.screwdriver.fill")
                                        .font(.caption)
                                        .foregroundColor(.accentColor)
                                    Text("Tools:")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                
                                // Clean tools display
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    let rows = draft.tools.chunked(into: 3)
                                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                        HStack(spacing: 6) {
                                            ForEach(row, id: \.self) { tool in
                                                Text(tool)
                                                    .font(.caption2)
                                                    .fontWeight(.medium)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 3)
                                                    .background(
                                                        Capsule()
                                                            .fill(Color.accentColor.opacity(0.15))
                                                    )
                                                    .foregroundColor(.accentColor)
                                            }
                                            Spacer()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                }
                
                // Commit Message
                VStack(alignment: .leading, spacing: 8) {
                    Text("Commit Message")
                        .font(.headline)
                    
                    TextField("Add new blog post: \(draft.title)", text: $commitMessage, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...6)
                }
                
                // Repository Info
                HStack {
                    Image(systemName: "folder.circle")
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading) {
                        Text("Publishing to:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("kvasilev/kvasilev_tech → /blog")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal)
                
                Spacer()
                
                // Action Buttons
                VStack(spacing: 12) {
                    Button(action: publishDraft) {
                        HStack {
                            if isPublishing {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            }
                            Text(isPublishing ? "Publishing..." : "Publish Draft")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(commitMessage.isEmpty ? Color.gray : Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(commitMessage.isEmpty || isPublishing)
                    
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.secondary)
                }
            }
            .padding()
            .navigationTitle("Publish Draft")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(isPublishing)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !isPublishing {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .alert("Publish Error", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            if let error = publishError {
                Text(error)
            }
        }
        .onAppear {
            if commitMessage.isEmpty {
                commitMessage = "Add new blog post: \(draft.title)"
            }
        }
    }
    
    private func publishDraft() {
        guard !isPublishing else { return }
        isPublishing = true
        
        Task {
            do {
                let success = try await gitHubService.publishDraft(draft, commitMessage: commitMessage)
                
                await MainActor.run {
                    isPublishing = false
                    if success {
                        onSuccess()
                        dismiss()
                    } else {
                        publishError = "Failed to publish draft. Please try again."
                        showingError = true
                    }
                }
            } catch {
                await MainActor.run {
                    isPublishing = false
                    publishError = error.localizedDescription
                    showingError = true
                }
            }
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var themeManager: ThemeManager
    @ObservedObject var gitHubService: GitHubService
    @State private var showingGitHubAuth = false
    @State private var showingOnboarding = false
    @State private var showingConfiguration = false

    
    var body: some View {
        List {
            // GitHub Integration Section
            Section(header: Text("GitHub Integration")) {
                HStack {
                    Image(systemName: "globe")
                        .foregroundColor(.primary)
                        .frame(width: 30)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Repository Connection")
                            .font(.body)
                        
                        HStack(spacing: 8) {
                            Circle()
                                .fill(gitHubService.connectionStatus.color)
                                .frame(width: 8, height: 8)
                            Text(gitHubService.connectionStatus.displayText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        if gitHubService.isAuthenticated && gitHubService.configManager.isConfigured, let username = gitHubService.username {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connected as @\(username)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let config = gitHubService.configManager.userConfig {
                                    Text("Repository: \(config.selectedRepository.name)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        } else if gitHubService.isAuthenticated && !gitHubService.configManager.isConfigured {
                            Text("Setup incomplete")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    
                    Spacer()
                    
                    if gitHubService.isAuthenticated && gitHubService.configManager.isConfigured {
                        Menu {
                            Button("Configure") {
                                showingConfiguration = true
                            }
                            Button("Disconnect", role: .destructive) {
                                gitHubService.disconnect()
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundColor(.accentColor)
                        }
                    } else {
                        Button("Setup") {
                            showingOnboarding = true
                        }
                        .foregroundColor(.accentColor)
                        .font(.caption)
                    }
                }
                
                if gitHubService.isAuthenticated && gitHubService.configManager.isConfigured {
                    Button(action: { showingConfiguration = true }) {
                        HStack {
                            Image(systemName: "folder")
                                .foregroundColor(.secondary)
                                .frame(width: 30)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Repository")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                Text(gitHubService.configManager.fullRepositoryName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    
                    // Show configured paths - tappable to configure
                    Button(action: { showingConfiguration = true }) {
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundColor(.secondary)
                                .frame(width: 30)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Blog Path")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                Text(gitHubService.configManager.blogDirectoryPath)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { showingConfiguration = true }) {
                        HStack {
                            Image(systemName: "photo")
                                .foregroundColor(.secondary)
                                .frame(width: 30)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Image Path")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                Text(gitHubService.configManager.imageDirectoryPath)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    
                    // Simple sync info
                    HStack {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.blue)
                            .frame(width: 30)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Auto Sync")
                                .font(.body)
                            
                            Text("Pull down on Published tab to sync with GitHub")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "hand.point.down.fill")
                            .foregroundColor(.blue)
                            .font(.caption)
                    }
                    .padding(.vertical, 8)
                }
            }
            
            Section(header: Text("Appearance")) {
                ForEach(AppTheme.allCases) { theme in
                    Button(action: {
                        themeManager.currentTheme = theme
                    }) {
                        HStack {
                            Image(systemName: theme.iconName)
                                .foregroundColor(theme == .light ? .orange : (theme == .dark ? .indigo : .gray))
                                .frame(width: 30)
                            
                            Text(theme.rawValue)
                            
                            Spacer()
                            
                            if themeManager.currentTheme == theme {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            
            Section(header: Text("About")) {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("1.0.0")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Visit the website!")
                    Spacer()
                    Text("kvasilev.tech")
                        .foregroundColor(.accentColor)
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingGitHubAuth) {
            GitHubAuthenticationView(gitHubService: gitHubService)
                .applyDarkModeSheet(themeManager: themeManager)
        }
        .sheet(isPresented: $showingOnboarding) {
            GitHubOnboardingFlow(gitHubService: gitHubService)
                .applyDarkModeSheet(themeManager: themeManager)
        }
        .sheet(isPresented: $showingConfiguration) {
            GitHubConfigurationView(gitHubService: gitHubService)
                .applyDarkModeSheet(themeManager: themeManager)
        }

    }
    

    

    

}

#Preview {
    ContentView()
}

