import SwiftUI

// MARK: - Repository Selection View for Settings

struct RepositorySelectionView: View {
    @ObservedObject var gitHubService: GitHubService
    @Environment(\.dismiss) private var dismiss
    
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var selectedRepository: GitHubRepository?
    
    var filteredRepositories: [GitHubRepository] {
        if searchText.isEmpty {
            return gitHubService.userRepositories
        } else {
            return gitHubService.userRepositories.filter { repo in
                repo.name.localizedCaseInsensitiveContains(searchText) ||
                repo.description?.localizedCaseInsensitiveContains(searchText) == true
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Loading repositories...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if gitHubService.userRepositories.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        
                        Text("No repositories found")
                            .font(.headline)
                        
                        Text("Make sure you have repositories in your GitHub account.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button("Retry") {
                            loadRepositories()
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 16) {
                        SearchBar(text: $searchText)
                            .padding(.horizontal)
                        
                        List(filteredRepositories) { repository in
                            RepositoryRowSelectable(
                                repository: repository,
                                isSelected: selectedRepository?.id == repository.id,
                                isCurrent: gitHubService.configManager.userConfig?.selectedRepository.id == repository.id
                            ) {
                                selectedRepository = repository
                            }
                        }
                        .listStyle(.plain)
                    }
                }
                
                if showError {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .navigationTitle("Select Repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveSelectedRepository()
                    }
                    .disabled(selectedRepository == nil)
                }
            }
        }
        .onAppear {
            loadCurrentSelection()
            if gitHubService.userRepositories.isEmpty {
                loadRepositories()
            }
        }
    }
    
    private func loadCurrentSelection() {
        selectedRepository = gitHubService.configManager.userConfig?.selectedRepository
    }
    
    private func loadRepositories() {
        isLoading = true
        showError = false
        
        Task {
            do {
                _ = try await gitHubService.fetchUserRepositories()
                await MainActor.run {
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    showError = true
                    errorMessage = "Failed to load repositories: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func saveSelectedRepository() {
        guard let repository = selectedRepository else {
            return
        }
        
        gitHubService.configManager.updateRepository(repository)
        dismiss()
    }
}

struct RepositoryRowSelectable: View {
    let repository: GitHubRepository
    let isSelected: Bool
    let isCurrent: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(repository.name)
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        if repository.isPrivate {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        if isCurrent {
                            Text("Current")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.2))
                                .foregroundColor(.accentColor)
                                .cornerRadius(4)
                        }
                        
                        Spacer()
                    }
                    
                    Text(repository.shortDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    
                    HStack {
                        if let language = repository.language {
                            Label(language, systemImage: "circle.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        if repository.hasPages {
                            Label("Pages", systemImage: "globe")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                        
                        Spacer()
                    }
                }
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(8)
    }
}

// MARK: - Path Configuration View for Settings

struct PathConfigurationView: View {
    @ObservedObject var gitHubService: GitHubService
    @Environment(\.dismiss) private var dismiss
    
    @State private var blogPath = ""
    @State private var imagePath = ""
    @State private var isValidating = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var validationResults: (blogExists: Bool, imageExists: Bool) = (false, false)
    
    var hasChanges: Bool {
        guard let config = gitHubService.configManager.userConfig else { return false }
        return blogPath != config.blogPath || imagePath != config.imagePath
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 16) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 50))
                        .foregroundColor(.accentColor)
                    
                    Text("Configure Paths")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("Specify where to store your blog posts and images in the repository.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }
                .padding(.top)
                
                if let repository = gitHubService.configManager.userConfig?.selectedRepository {
                    VStack(spacing: 20) {
                        // Repository info
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Repository")
                                .font(.headline)
                            
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(.accentColor)
                                Text(repository.displayName)
                                    .font(.subheadline)
                                Spacer()
                            }
                            .padding()
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                        }
                        
                        // Path configuration
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Directory Paths")
                                .font(.headline)
                            
                            VStack(alignment: .leading, spacing: 12) {
                                PathInputSection(
                                    title: "Blog Posts Directory",
                                    placeholder: "blog",
                                    text: $blogPath,
                                    suggestions: PathSuggestions.blogPaths,
                                    icon: "doc.text",
                                    exists: validationResults.blogExists
                                )
                                
                                PathInputSection(
                                    title: "Images Directory",
                                    placeholder: "public/images",
                                    text: $imagePath,
                                    suggestions: PathSuggestions.imagePaths,
                                    icon: "photo",
                                    exists: validationResults.imageExists
                                )
                            }
                        }
                        
                        // Smart suggestions
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Quick Options:")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            Button("Reset to Recommended") {
                                let recommended = PathSuggestions.getRecommendedPaths(for: repository)
                                blogPath = recommended.blogPath
                                imagePath = recommended.imagePath
                                validatePaths()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        
                        if isValidating {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Validating paths...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if showError {
                            Text(errorMessage)
                                .foregroundColor(.red)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal)
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Path Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveConfiguration()
                    }
                    .disabled(!hasChanges || blogPath.isEmpty || imagePath.isEmpty || isValidating)
                }
            }
        }
        .onAppear {
            loadCurrentPaths()
        }
        .onChange(of: blogPath) { _, _ in validatePaths() }
        .onChange(of: imagePath) { _, _ in validatePaths() }
    }
    
    private func loadCurrentPaths() {
        guard let config = gitHubService.configManager.userConfig else { return }
        blogPath = config.blogPath
        imagePath = config.imagePath
        validatePaths()
    }
    
    private func validatePaths() {
        guard !blogPath.isEmpty && !imagePath.isEmpty,
              let repository = gitHubService.configManager.userConfig?.selectedRepository else { return }
        
        isValidating = true
        showError = false
        
        Task {
            do {
                let blogExists = try await gitHubService.checkRepositoryStructure(repository: repository, blogPath: blogPath)
                let imageExists = try await gitHubService.checkRepositoryStructure(repository: repository, blogPath: imagePath)
                
                await MainActor.run {
                    validationResults = (blogExists, imageExists)
                    isValidating = false
                }
            } catch {
                await MainActor.run {
                    isValidating = false
                    showError = true
                    errorMessage = "Failed to validate paths: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func saveConfiguration() {
        gitHubService.configManager.updateConfiguration(blogPath: blogPath, imagePath: imagePath)
        dismiss()
    }
}

// MARK: - GitHub Configuration Management View

struct GitHubConfigurationView: View {
    @ObservedObject var gitHubService: GitHubService
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingRepositorySelection = false
    @State private var showingPathConfiguration = false
    @State private var showingResetConfirmation = false
    
    var body: some View {
        NavigationStack {
            List {
                if let config = gitHubService.configManager.userConfig {
                    Section(header: Text("Current Configuration")) {
                        ConfigurationDetailRow(
                            icon: "person.circle",
                            title: "GitHub User",
                            value: "@\(config.username)",
                            showChevron: false
                        )
                        
                        Button(action: { showingRepositorySelection = true }) {
                            ConfigurationDetailRow(
                                icon: "folder",
                                title: "Repository",
                                value: config.selectedRepository.displayName,
                                showChevron: true
                            )
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: { showingPathConfiguration = true }) {
                            VStack(spacing: 8) {
                                ConfigurationDetailRow(
                                    icon: "doc.text",
                                    title: "Blog Path",
                                    value: config.blogPath,
                                    showChevron: true
                                )
                                
                                Divider()
                                    .padding(.leading, 40)
                                
                                ConfigurationDetailRow(
                                    icon: "photo",
                                    title: "Image Path",
                                    value: config.imagePath,
                                    showChevron: false
                                )
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Section(header: Text("Information")) {
                        HStack {
                            Image(systemName: "calendar")
                                .foregroundColor(.secondary)
                                .frame(width: 20)
                            Text("Setup Date")
                            Spacer()
                            Text(config.dateCreated, style: .date)
                                .foregroundColor(.secondary)
                        }
                        
                        if config.lastUpdated != config.dateCreated {
                            HStack {
                                Image(systemName: "clock")
                                    .foregroundColor(.secondary)
                                    .frame(width: 20)
                                Text("Last Updated")
                                Spacer()
                                Text(config.lastUpdated, style: .date)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    Section {
                        Button("Reset Configuration") {
                            showingResetConfirmation = true
                        }
                        .foregroundColor(.red)
                    }
                } else {
                    Section {
                        Text("No configuration found")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("GitHub Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showingRepositorySelection) {
            RepositorySelectionView(gitHubService: gitHubService)
        }
        .sheet(isPresented: $showingPathConfiguration) {
            PathConfigurationView(gitHubService: gitHubService)
        }
        .alert("Reset Configuration", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                gitHubService.configManager.clearConfiguration()
                dismiss()
            }
        } message: {
            Text("This will clear your GitHub configuration. You'll need to set it up again to sync with GitHub.")
        }
    }
}

struct ConfigurationDetailRow: View {
    let icon: String
    let title: String
    let value: String
    let showChevron: Bool
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 20)
            
            Text(title)
                .font(.body)
            
            Spacer()
            
            Text(value)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
            
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
} 