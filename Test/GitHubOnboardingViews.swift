import SwiftUI

// MARK: - Main Onboarding Flow

struct GitHubOnboardingFlow: View {
    @ObservedObject var gitHubService: GitHubService
    @Environment(\.dismiss) private var dismiss
    @State private var currentStep: OnboardingStep = .welcome
    @State private var isCompleted = false
    @State private var selectedRepository: GitHubRepository?
    
    enum OnboardingStep: CaseIterable {
        case welcome
        case authentication
        case repositorySelection
        case pathConfiguration
        case completion
        
        var title: String {
            switch self {
            case .welcome: return "Welcome to GitHub Integration"
            case .authentication: return "Connect Your Account"
            case .repositorySelection: return "Choose Your Repository"
            case .pathConfiguration: return "Configure Paths"
            case .completion: return "Setup Complete"
            }
        }
        
        var stepNumber: Int {
            switch self {
            case .welcome: return 1
            case .authentication: return 2
            case .repositorySelection: return 3
            case .pathConfiguration: return 4
            case .completion: return 5
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Progress indicator
                OnboardingProgressBar(currentStep: currentStep.stepNumber, totalSteps: OnboardingStep.allCases.count)
                    .padding(.horizontal)
                    .padding(.top)
                
                // Step content
                TabView(selection: $currentStep) {
                    WelcomeStepView(onNext: { currentStep = .authentication })
                        .tag(OnboardingStep.welcome)
                    
                    AuthenticationStepView(gitHubService: gitHubService, onNext: { currentStep = .repositorySelection })
                        .tag(OnboardingStep.authentication)
                    
                    RepositorySelectionStepView(gitHubService: gitHubService, selectedRepository: $selectedRepository, onNext: { currentStep = .pathConfiguration })
                        .tag(OnboardingStep.repositorySelection)
                    
                    PathConfigurationStepView(gitHubService: gitHubService, selectedRepository: selectedRepository, onNext: { currentStep = .completion })
                        .tag(OnboardingStep.pathConfiguration)
                    
                    CompletionStepView(gitHubService: gitHubService, onComplete: {
                        isCompleted = true
                        dismiss()
                    })
                        .tag(OnboardingStep.completion)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: currentStep)
            }
            .navigationTitle(currentStep.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(!isCompleted)
    }
}

// MARK: - Progress Bar

struct OnboardingProgressBar: View {
    let currentStep: Int
    let totalSteps: Int
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                ForEach(1...totalSteps, id: \.self) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 12, height: 12)
                        .scaleEffect(step == currentStep ? 1.2 : 1.0)
                        .animation(.easeInOut(duration: 0.3), value: currentStep)
                    
                    if step < totalSteps {
                        Rectangle()
                            .fill(step < currentStep ? Color.accentColor : Color.gray.opacity(0.3))
                            .frame(height: 2)
                            .animation(.easeInOut(duration: 0.3), value: currentStep)
                    }
                }
            }
            
            Text("Step \(currentStep) of \(totalSteps)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Welcome Step

struct WelcomeStepView: View {
    let onNext: () -> Void
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            
            VStack(spacing: 20) {
                Image(systemName: "globe.badge.chevron.backward")
                    .font(.system(size: 80))
                    .foregroundColor(.accentColor)
                
                Text("Personalize Your Blog")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                
                Text("Connect your GitHub account to sync and publish blog posts to your own repository with your preferred folder structure.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }
            
            VStack(spacing: 16) {
                FeatureRow(icon: "person.crop.circle.badge.checkmark", title: "Your GitHub Account", description: "Connect securely with a personal access token")
                FeatureRow(icon: "folder.badge.gearshape", title: "Choose Your Repository", description: "Select any repository where you want to store your blog")
                FeatureRow(icon: "doc.text.magnifyingglass", title: "Configure Paths", description: "Set custom paths for blog posts and images")
            }
            .padding(.horizontal)
            
            Spacer()
            
            Button("Get Started") {
                withAnimation(.easeInOut) {
                    onNext()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
        }
        .padding()
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(.accentColor)
                .frame(width: 40)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Authentication Step

struct AuthenticationStepView: View {
    @ObservedObject var gitHubService: GitHubService
    let onNext: () -> Void
    
    @State private var token = ""
    @State private var isAuthenticating = false
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            
            VStack(spacing: 20) {
                Image(systemName: "key.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.accentColor)
                
                Text("Connect Your GitHub Account")
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                
                Text("We'll need a Personal Access Token to securely connect to your GitHub account.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }
            
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Required Permissions:")
                        .font(.headline)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        PermissionRow(icon: "info.circle", title: "Repo", description: "Access files, create commits, and manage repository contents")
                        
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                
                Button("Create Token on GitHub") {
                    if let url = URL(string: "https://github.com/settings/tokens/new") {
                        UIApplication.shared.open(url)
                    }
                }
                .foregroundColor(.accentColor)
                
                VStack(spacing: 12) {
                    SecureField("Paste your token here", text: $token)
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
                }
            }
            .padding(.horizontal)
            
            Spacer()
            
            Button(action: authenticateUser) {
                HStack {
                    if isAuthenticating {
                        ProgressView()
                            .scaleEffect(0.8)
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    }
                    Text(isAuthenticating ? "Connecting..." : "Connect Account")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(token.isEmpty || isAuthenticating)
            .padding(.horizontal)
        }
        .padding()
        .onChange(of: gitHubService.connectionStatus) { _, newStatus in
            switch newStatus {
            case .connected:
                isAuthenticating = false
                withAnimation(.easeInOut) {
                    onNext()
                }
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

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
}

// MARK: - Repository Selection Step

struct RepositorySelectionStepView: View {
    @ObservedObject var gitHubService: GitHubService
    @Binding var selectedRepository: GitHubRepository?
    let onNext: () -> Void
    
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var showError = false
    @State private var errorMessage = ""
    
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
        VStack(spacing: 20) {
            VStack(spacing: 16) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 50))
                    .foregroundColor(.accentColor)
                
                Text("Choose Your Repository")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Select the repository where you want to store your blog posts.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }
            .padding(.top)
            
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading your repositories...")
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
                    
                    List(filteredRepositories) { repository in
                        RepositoryRow(
                            repository: repository,
                            isSelected: selectedRepository?.id == repository.id
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
            
            Button("Continue") {
                if let repo = selectedRepository {
                    // Save the selected repository temporarily
                    // We'll create the full config in the next step
                    withAnimation(.easeInOut) {
                        onNext()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selectedRepository == nil)
            .padding(.horizontal)
        }
        .padding()
        .onAppear {
            loadRepositories()
        }
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
}

struct SearchBar: View {
    @Binding var text: String
    
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField("Search repositories...", text: $text)
                .textFieldStyle(.plain)
            
            if !text.isEmpty {
                Button("Clear") {
                    text = ""
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}

struct RepositoryRow: View {
    let repository: GitHubRepository
    let isSelected: Bool
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

// MARK: - Path Configuration Step

struct PathConfigurationStepView: View {
    @ObservedObject var gitHubService: GitHubService
    let selectedRepository: GitHubRepository?
    let onNext: () -> Void
    @State private var blogPath = ""
    @State private var imagePath = ""
    @State private var isValidating = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var validationResults: (blogExists: Bool, imageExists: Bool) = (false, false)
    
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 16) {
                Image(systemName: "doc.text.magnifyingglass")
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
            
            if let repository = selectedRepository {
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
                    if let recommendedPaths = getRecommendedPaths(for: repository) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recommended for this repository:")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            Button("Use Recommended Paths") {
                                blogPath = recommendedPaths.blogPath
                                imagePath = recommendedPaths.imagePath
                                validatePaths()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
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
            
            Button("Complete Setup") {
                saveConfiguration()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(blogPath.isEmpty || imagePath.isEmpty || isValidating)
            .padding(.horizontal)
        }
        .padding()
        .onAppear {
            loadSelectedRepository()
            setDefaultPaths()
        }
        .onChange(of: blogPath) { _, _ in validatePaths() }
        .onChange(of: imagePath) { _, _ in validatePaths() }
    }
    
    private func loadSelectedRepository() {
        // Repository is now passed from the previous step
        // No need to load it here
    }
    
    private func setDefaultPaths() {
        guard let repository = selectedRepository else { return }
        let recommended = PathSuggestions.getRecommendedPaths(for: repository)
        blogPath = recommended.blogPath
        imagePath = recommended.imagePath
        validatePaths()
    }
    
    private func getRecommendedPaths(for repository: GitHubRepository) -> (blogPath: String, imagePath: String)? {
        return PathSuggestions.getRecommendedPaths(for: repository)
    }
    
    private func validatePaths() {
        guard !blogPath.isEmpty && !imagePath.isEmpty,
              let repository = selectedRepository else { return }
        
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
        guard let repository = selectedRepository,
              let username = gitHubService.username else { return }
        
        let config = GitHubUserConfig(
            username: username,
            selectedRepository: repository,
            blogPath: blogPath,
            imagePath: imagePath
        )
        
        gitHubService.configManager.saveConfiguration(config)
        
        withAnimation(.easeInOut) {
            onNext()
        }
    }
}

struct PathInputSection: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let suggestions: [String]
    let icon: String
    let exists: Bool
    
    @State private var showingSuggestions = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                    .frame(width: 20)
                
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                if !text.isEmpty {
                    Image(systemName: exists ? "checkmark.circle.fill" : "questionmark.circle.fill")
                        .foregroundColor(exists ? .green : .orange)
                        .font(.caption)
                }
            }
            
            HStack {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                
                Button(action: { showingSuggestions.toggle() }) {
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(showingSuggestions ? 180 : 0))
                }
            }
            
            if !text.isEmpty && !exists {
                Text("Directory doesn't exist - it will be created when you publish your first post")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            
            if showingSuggestions {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) {
                            text = suggestion
                            showingSuggestions = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.caption)
                    }
                }
                .padding(.top, 4)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showingSuggestions)
    }
}

// MARK: - Completion Step

struct CompletionStepView: View {
    @ObservedObject var gitHubService: GitHubService
    let onComplete: () -> Void
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.green)
                
                Text("Setup Complete!")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("You are good to go!")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }
            
            if let config = gitHubService.configManager.userConfig {
                VStack(spacing: 16) {
                    ConfigurationSummaryCard(config: config)
                }
                .padding(.horizontal)
            }
            
            VStack(spacing: 16) {
                Text("What's Next?")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 12) {
                    NextStepRow(icon: "plus.circle", title: "Create Your First Post", description: "Start writing in the Drafts tab")
                    NextStepRow(icon: "paperplane", title: "Publish to GitHub", description: "Sync your posts to your repository")
                    NextStepRow(icon: "arrow.trianglehead.2.clockwise.rotate.90", title: "Repeat", description: "Enjoy Blogging!")
                }
            }
            .padding(.horizontal)
            
            Spacer()
            
            Button("Start Blogging") {
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
        }
        .padding()
    }
}

struct ConfigurationSummaryCard: View {
    let config: GitHubUserConfig
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration Summary")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 8) {
                SummaryRow(icon: "person.circle", title: "GitHub User", value: "@\(config.username)")
                SummaryRow(icon: "folder", title: "Repository", value: config.selectedRepository.displayName)
                SummaryRow(icon: "doc.text", title: "Blog Path", value: config.blogPath)
                SummaryRow(icon: "photo", title: "Image Path", value: config.imagePath)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

struct SummaryRow: View {
    let icon: String
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 20)
            
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
        }
    }
}

struct NextStepRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.accentColor)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
} 