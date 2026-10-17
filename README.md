# StreamVibes

A native macOS app for tracking movies, series, anime, and telenovelas with your partner. Built with SwiftUI, backed by PostgreSQL, and enhanced with AI-powered autofill.

![macOS](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Status: Usable

StreamVibes is usable for its core catalog and shared watch-tracking workflows.
Configure your own PostgreSQL database; AI and movie metadata providers are optional.
Developer downloads are available from [GitHub Releases](https://github.com/bujosa/stream-vibes/releases).
They are ad-hoc signed, not Apple Developer ID signed or notarized. macOS can block
the first launch; read the release notes before installing. Broader end-to-end
checks remain separate release work.

## Download

Download the versioned macOS DMG and `SHA256SUMS.txt` from the release page.
The universal app supports Apple Silicon and Intel Macs running macOS 14+.
Open the DMG and drag StreamVibes to Applications. Configure your own database
when launching for the first time. These are macOS downloads, not Windows or Linux apps.

See [Apple's guidance on opening downloaded apps](https://support.apple.com/en-us/102445)
for Gatekeeper messages. Only install a build whose source and checksum you trust;
do not disable Gatekeeper globally.

[Watch the shared-catalog walkthrough](https://github.com/bujosa/stream-vibes/releases/download/v1.0.0/StreamVibes-Walkthrough.mp4)
(edited real-app captures, fictional data, English narration, English/Spanish subtitles).

## Features

### Catalog Management
- Add movies, series, anime, and telenovelas with poster images, genres, year, and overviews
- Browse by category (Anime, Movie, Series, Telenovela) with dedicated category pages
- Full-text fuzzy search powered by PostgreSQL `pg_trgm` trigram indexing
- AI-powered search: when local results come up empty, query AI to discover new items
- Filter by genre, watched status, and category
- Context menus for quick actions (mark watched, edit, delete)
- Recently viewed items carousel on the home dashboard

### Watch Lists
- Create shared watch lists with your partner
- Track progress with watched/unwatched counts and progress bars
- List cover images with AI-generated suggestions
- Close and reopen seasons (mark lists as completed or active)
- Creator metadata and creation date tracking

### Season Tracking
- Add seasons to series, anime, and telenovelas within watch lists
- Track watched/unwatched status per season with timestamps
- Season-level trailer URLs
- AI-generated season metadata (poster, overview, trailer)

### Ratings & Reviews
- Rate items on a 0-10 scale with star display
- Write detailed reviews with expand/collapse support
- View your partner's ratings and reviews side by side
- Like and reply to reviews
- Color-coded score badges (green 8+, yellow 6+, orange 4+, red <4)

### Comments
- Standalone comment system on items
- Like comments and add emoji reactions
- Reply threads on comments
- Expand/collapse for managing long discussions
- Delete your own comments with confirmation

### Trailer Playback
- Attach YouTube or direct video URLs to items
- In-app YouTube playback via embedded WebKit player
- Supports YouTube standard URLs, shorts, and embed formats
- Playback block detection with browser fallback
- Fullscreen toggle support

### AI Integration
- Auto-populate item details (poster, year, genre, overview, trailer) using AI
- AI-generated cover image suggestions for watch lists
- AI-powered catalog search: discover new items when local search yields no results
- AI-generated season metadata
- Image URL validation with automatic fallback to alternative URLs
- Supports 5 providers:

| Provider | Type | Configuration |
|----------|------|---------------|
| Claude CLI | Local CLI | Path to `claude` binary |
| Ollama | Local CLI | Path to `ollama` binary |
| Anthropic API | Cloud API | API key |
| OpenAI API | Cloud API | API key |
| Gemini API | Cloud API | API key |

### UI/UX
- Netflix-inspired dark theme with category accent colors (Anime: purple, Movie: blue, Series: green, Telenovela: pink)
- Animated splash screen with auto-connection
- Hero banner featuring top-rated items on the home dashboard
- Statistics bar (watched, pending, total counts)
- Carousel rows for pending, watched, top-rated, and recently viewed items
- Item cards with hover effects and smooth animations
- Animated AI loading indicators during AI searches
- Multi-user support with user switching
- Tabbed settings navigation (General, AI, Maintenance, About)
- Auto-refresh every 30 seconds for shared catalog and list-summary updates
- Keyboard shortcut (Cmd+R) for manual refresh

## Credentials and privacy

Add your own database connection in the setup screen. The connection URL and
API keys are saved in macOS Keychain; legacy plaintext preferences are removed
only after migration is verified. No credentials or personal catalog are bundled.
See [SECURITY.md](SECURITY.md) for local storage and provider trust boundaries.

OMDb and TMDB integrations are optional. Configure your own keys in Settings → AI;
without a key, that provider is skipped and other available sources still work.
Movie images and metadata remain subject to their providers' terms.

## Requirements

- macOS 14.0+ and Xcode 16+
- [Tuist](https://tuist.dev) 4.x
- PostgreSQL with verified TLS, permission to create tables and the `pg_trgm` extension

## Getting Started

### Database setup

Create a dedicated, empty PostgreSQL database for the shared catalog. Use a role
with permission to create tables and install `pg_trgm`. The app applies migrations
automatically; back up an existing catalog before connecting a newer build.

Enter your PostgreSQL URL in the setup screen. TLS 1.2+ with certificate and
hostname verification is required. Keep `sslmode=verify-full` or omit `sslmode`;
`sslmode=require` also uses full verification. Plaintext and unverified modes are
rejected. Local/self-hosted servers need a trusted certificate or an explicit
`sslrootcert` path to their CA certificate. Never include a real URL in an issue.

Profiles share the database role's access; the user switcher is for attribution,
not separate authorization. See [SECURITY.md](SECURITY.md).

For a hosted setup with a partner or friends, see
[Shared catalog and Neon setup](docs/shared-catalog.md).

### 1. Install dependencies

```bash
make install
```

### 2. Generate the Xcode project

```bash
make generate
```

### 3. Build

```bash
make build XCODEBUILD_FLAGS=CODE_SIGNING_ALLOWED=NO
```

### 4. Run

```bash
make run
```

### Create a DMG

```bash
make dmg
```

The DMG will be created at `executables/StreamVibes.dmg`.

## Project Structure

```
StreamVibes/
  Sources/
    Models/
      Models.swift           # AppUser, WatchList, WatchItem, ListEntry,
                             # Rating, RatingReply, ItemComment, reactions
    Services/
      DatabaseService.swift  # PostgreSQL connection, migrations (v1-v21),
                             # CRUD operations, search, auto-refresh
      AIService.swift        # 5 AI providers, autofill, search,
                             # CLI & API integration
    Theme/
      Theme.swift            # Netflix-inspired design tokens, colors, sizing
    Views/
      Home/
        HomeView.swift       # Dashboard, hero banner, stats, carousels
      Catalog/
        CatalogView.swift        # Full catalog grid, search, filters, AI search
        CategoryPageView.swift   # Category browsing (Anime/Movie/Series/Telenovela)
      Items/
        ItemDetailPageView.swift # Item detail: ratings, reviews, comments,
                                 # trailer, metadata, delete flow
        AddItemView.swift        # New/existing item form with AI autofill & AI search
        ItemDetailView.swift     # Reusable item info display component
      Lists/
        ListsBrowserView.swift   # All lists, active/completed, search
        ListDetailView.swift     # List detail, entries, close/reopen season
        ItemCardView.swift       # Reusable item card with hover effects
      Components/
        TrailerPlayerView.swift    # YouTube embed + direct video player
        RatingView.swift           # Star display, score badges
        AIFetchOverlayView.swift   # AI processing overlay
      Settings/
        SettingsView.swift       # Tabbed settings: General, AI, Maintenance, About
      Sidebar/
        SidebarView.swift        # Navigation, list management, categories
    ContentView.swift            # App entry: splash, setup, main layout
    StreamVibesApp.swift         # @main, window config, keyboard shortcuts
  Resources/
    Assets.xcassets/             # App icons and image assets
```

## Database

StreamVibes uses PostgreSQL with 21 versioned migrations:

| Migration | Description |
|-----------|-------------|
| v1 | Initial schema: users, watch_lists, watch_items, list_entries, ratings |
| v2 | Watched status tracking (is_watched, watched_at) |
| v3 | Added-by tracking, trigram search index (pg_trgm) |
| v4 | Genre column for categorization |
| v5 | Rating likes and replies |
| v6 | Trailer URL support |
| v7 | List cover images and creator metadata |
| v8 | Standalone item comments with likes, reactions, and replies |
| v9 | Comment likes and emoji reactions |
| v10 | Comment reply threads |
| v11 | Seasons table and season tracking on list entries |
| v12 | Season trailer URLs |
| v13 | Recently viewed items tracking |
| v14 | Season watch status and timestamps |
| v15 | Watch-list banner images |
| v16 | Season ranking |
| v17 | Episodes and progress tracking |
| v18 | Episode ratings, comments and favorites |
| v19 | External ratings and platform availability |
| v20 | Season reviews |
| v21 | Telenovela category compatibility |

The app applies pending migrations when you connect. A new database starts with
an empty catalog; create a profile and add your own titles. No watch history is bundled.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| **UI** | SwiftUI (native macOS) |
| **Database** | PostgreSQL via [PostgresNIO](https://github.com/vapor/postgres-nio) |
| **TLS** | [NIOSSL](https://github.com/apple/swift-nio-ssl) |
| **Project** | [Tuist](https://tuist.dev) |
| **Trailer** | WebKit (YouTube embeds) + AVKit (direct video) |
| **Search** | PostgreSQL pg_trgm extension |
| **CI/CD** | GitHub Actions (source checks and manual/tagged release workflow) |

## Validation

```bash
swift test
make build XCODEBUILD_FLAGS=CODE_SIGNING_ALLOWED=NO
```

Security tests use an in-memory backend and isolated test preferences; they do
not access your database or saved credentials. Builds target macOS 14 for both
the app and its dependencies and explicitly link the TLS library's C++ runtime.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on how to contribute.

### AI model selection

Settings includes current text-model presets, a custom model ID, and a separate saved selection for each provider. Existing pinned models are preserved; select Recommended to adopt the current default. CLI providers can use their own configured default, and Ollama accepts an installed model name. Account access and inference charges depend on your provider.

The curated catalog was checked on 2026-10-16 against [OpenAI](https://developers.openai.com/api/docs/guides/latest-model), [Anthropic](https://platform.claude.com/docs/en/models/overview), and [Gemini](https://ai.google.dev/gemini-api/docs/models). OpenAI defaults to Luna for focused tasks; other tiers remain selectable.
