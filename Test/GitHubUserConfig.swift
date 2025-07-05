import Foundation

// User's GitHub configuration
struct GitHubUserConfig: Codable {
    let username: String
    let selectedRepository: GitHubRepository
    let blogPath: String // e.g., "blog", "posts", "content/blog"
    let imagePath: String // e.g., "public/images", "assets/images", "static/images"
    let dateCreated: Date
    let lastUpdated: Date
    
    init(username: String, selectedRepository: GitHubRepository, blogPath: String, imagePath: String) {
        self.username = username
        self.selectedRepository = selectedRepository
        self.blogPath = blogPath
        self.imagePath = imagePath
        self.dateCreated = Date()
        self.lastUpdated = Date()
    }
}

// GitHub repository information
struct GitHubRepository: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let fullName: String // owner/repo
    let owner: String
    let description: String?
    let isPrivate: Bool
    let defaultBranch: String
    let hasPages: Bool
    let language: String?
    let htmlUrl: String
    
    var displayName: String {
        return fullName
    }
    
    var shortDescription: String {
        return description ?? "No description"
    }
}

// Configuration manager for GitHub user settings
class GitHubConfigManager: ObservableObject {
    @Published var userConfig: GitHubUserConfig?
    @Published var isConfigured: Bool = false
    
    private let configKey = "github_user_config"
    
    init() {
        loadConfiguration()
    }
    
    func saveConfiguration(_ config: GitHubUserConfig) {
        do {
            let data = try JSONEncoder().encode(config)
            UserDefaults.standard.set(data, forKey: configKey)
            
            DispatchQueue.main.async {
                self.userConfig = config
                self.isConfigured = true
            }
            
            print("✅ GitHub configuration saved for user: \(config.username)")
        } catch {
            print("❌ Failed to save GitHub configuration: \(error)")
        }
    }
    
    func loadConfiguration() {
        guard let data = UserDefaults.standard.data(forKey: configKey) else {
            isConfigured = false
            return
        }
        
        do {
            let config = try JSONDecoder().decode(GitHubUserConfig.self, from: data)
            userConfig = config
            isConfigured = true
            print("✅ GitHub configuration loaded for user: \(config.username)")
        } catch {
            print("❌ Failed to load GitHub configuration: \(error)")
            isConfigured = false
        }
    }
    
    func updateConfiguration(blogPath: String? = nil, imagePath: String? = nil) {
        guard let currentConfig = userConfig else { return }
        
        let newBlogPath = blogPath ?? currentConfig.blogPath
        let newImagePath = imagePath ?? currentConfig.imagePath
        
        let updatedConfig = GitHubUserConfig(
            username: currentConfig.username,
            selectedRepository: currentConfig.selectedRepository,
            blogPath: newBlogPath,
            imagePath: newImagePath
        )
        
        saveConfiguration(updatedConfig)
    }
    
    func updateRepository(_ repository: GitHubRepository) {
        guard let currentConfig = userConfig else { return }
        
        let updatedConfig = GitHubUserConfig(
            username: currentConfig.username,
            selectedRepository: repository,
            blogPath: currentConfig.blogPath,
            imagePath: currentConfig.imagePath
        )
        
        saveConfiguration(updatedConfig)
    }
    
    func clearConfiguration() {
        UserDefaults.standard.removeObject(forKey: configKey)
        userConfig = nil
        isConfigured = false
        print("🗑️ GitHub configuration cleared")
    }
    
    // Helper computed properties
    var repositoryName: String {
        return userConfig?.selectedRepository.name ?? ""
    }
    
    var repositoryOwner: String {
        return userConfig?.selectedRepository.owner ?? ""
    }
    
    var fullRepositoryName: String {
        return userConfig?.selectedRepository.fullName ?? ""
    }
    
    var blogDirectoryPath: String {
        return userConfig?.blogPath ?? "blog"
    }
    
    var imageDirectoryPath: String {
        return userConfig?.imagePath ?? "public/images"
    }
}

// Common path suggestions for different types of repositories
struct PathSuggestions {
    static let blogPaths = [
        "blog",
        "posts",
        "content/blog",
        "content/posts",
        "src/content/blog",
        "_posts",
        "articles"
    ]
    
    static let imagePaths = [
        "public/images",
        "public/assets/images",
        "static/images",
        "assets/images",
        "images",
        "public/img",
        "assets/img",
        "img"
    ]
    
    static func getRecommendedPaths(for repository: GitHubRepository) -> (blogPath: String, imagePath: String) {
        let repoName = repository.name.lowercased()
        let language = repository.language?.lowercased() ?? ""
        
        // Detect common frameworks and suggest appropriate paths
        if language.contains("javascript") || language.contains("typescript") {
            if repoName.contains("next") || repoName.contains("gatsby") || repoName.contains("nuxt") {
                return ("content/blog", "public/images")
            } else if repoName.contains("astro") {
                return ("src/content/blog", "public/images")
            } else {
                return ("blog", "public/images")
            }
        } else if language.contains("ruby") {
            // Jekyll
            return ("_posts", "assets/images")
        } else if language.contains("go") {
            // Hugo
            return ("content/posts", "static/images")
        } else {
            // Default
            return ("blog", "public/images")
        }
    }
} 