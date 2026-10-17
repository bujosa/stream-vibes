-- StreamVibes Database Migration
-- Legacy initial schema reference only. The app applies the complete versioned migrations.

-- Users (each partner)
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(100) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Watch lists (seasons)
CREATE TABLE IF NOT EXISTS watch_lists (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(200) NOT NULL,
    description TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Watch items (individual movies/series/anime/telenovelas)
CREATE TABLE IF NOT EXISTS watch_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title VARCHAR(300) NOT NULL,
    image_url TEXT,
    category VARCHAR(50) NOT NULL CHECK (category IN ('anime', 'movie', 'series', 'novela')),
    year INTEGER,
    overview TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Junction: items in lists
CREATE TABLE IF NOT EXISTS list_entries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    list_id UUID NOT NULL REFERENCES watch_lists(id) ON DELETE CASCADE,
    item_id UUID NOT NULL REFERENCES watch_items(id) ON DELETE CASCADE,
    is_watched BOOLEAN DEFAULT FALSE,
    watched_at TIMESTAMPTZ,
    position INTEGER DEFAULT 0,
    added_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(list_id, item_id)
);

-- Ratings
CREATE TABLE IF NOT EXISTS ratings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    item_id UUID NOT NULL REFERENCES watch_items(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id),
    score DECIMAL(3,1) NOT NULL CHECK (score >= 0 AND score <= 10),
    comment TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(item_id, user_id)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_list_entries_list_id ON list_entries(list_id);
CREATE INDEX IF NOT EXISTS idx_list_entries_item_id ON list_entries(item_id);
CREATE INDEX IF NOT EXISTS idx_ratings_item_id ON ratings(item_id);
CREATE INDEX IF NOT EXISTS idx_ratings_user_id ON ratings(user_id);
CREATE INDEX IF NOT EXISTS idx_watch_items_category ON watch_items(category);
CREATE INDEX IF NOT EXISTS idx_watch_lists_is_active ON watch_lists(is_active);
