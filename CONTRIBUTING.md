# Contributing to StreamVibes

Thanks for your interest in contributing to StreamVibes! Here's how to get started.

## Development Setup

1. **Fork & clone** the repository
2. Install [Tuist](https://tuist.dev):
   ```bash
   brew tap tuist/tuist
   brew install tuist
   ```
3. Install dependencies and generate the project:
   ```bash
   make install
   make generate
   ```
4. Open `StreamVibes.xcworkspace` in Xcode

## Making Changes

1. Create a branch from `main`:
   ```bash
   git checkout -b bujosa/my-feature
   ```
2. Make your changes
3. Build and verify:
   ```bash
   swift test
   make build XCODEBUILD_FLAGS=CODE_SIGNING_ALLOWED=NO
   ```
4. Use Conventional Commits with a clear description of **what** and **why**
5. Push and open a Pull Request

## Code Style

- Follow existing patterns in the codebase
- Use SwiftUI idioms (`@Observable`, `@Environment`, `@AppStorage`)
- Keep views focused — extract subviews when they get large
- Use `SVTheme` for all colors and styling constants
- Database changes require a new migration (increment the version number)
- Use `async/await` for all asynchronous operations
- Handle errors with user-friendly messages displayed in the UI

## Project Structure

- **Models** go in `StreamVibes/Sources/Models/`
- **Services** go in `StreamVibes/Sources/Services/`
- **Views** are organized by feature under `StreamVibes/Sources/Views/`
- **Reusable components** go in `StreamVibes/Sources/Views/Components/`
- **Theme tokens** go in `StreamVibes/Sources/Theme/`

## Database Migrations

The app uses versioned migrations. If your change requires a schema update:

1. Add a new migration case in `DatabaseService.runMigrations()`
2. Use `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` for additive changes
3. Use `CREATE TABLE IF NOT EXISTS` for new tables
4. Update all affected CRUD methods (`fetchCatalog`, `fetchEntries`, `searchItems`, etc.)
5. Update the corresponding model struct in `Models.swift`
6. Update the migration table in `README.md`

## AI Providers

When adding a new AI provider:

1. Add a case to the `AIProvider` enum in `Services/ModelConfiguration/AIProvider.swift`
2. Implement the provider's request/response handling
3. Add configuration UI in `SettingsView.swift`
4. Test with both CLI and API-based providers as applicable

## Reporting Issues

- Use [GitHub Issues](https://github.com/bujosa/stream-vibes/issues)
- Include macOS version and steps to reproduce
- Screenshots should use synthetic data; redact credentials, connection URLs and personal catalog data

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
