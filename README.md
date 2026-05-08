# Counted

Exact row counts for large PostgreSQL tables using database triggers.

No more `SELECT COUNT(*) FROM table` scanning billions of rows. Counted maintains exact row counts in a metadata table via PostgreSQL triggers — instant results, 100% accurate.

## How it works

- Creates a `counted_metadata` table in each database
- Sets up `AFTER INSERT / DELETE / TRUNCATE` triggers on tracked tables
- Each trigger atomically increments/decrements the stored count
- `Model.count` reads from metadata instead of scanning the table

Supports **multi-database** and **multi-schema** Rails applications out of the box.

## Installation

Add to your Gemfile:

```ruby
gem "counted"
```

Then run:

```
$ bundle install
$ rake counted:setup
```

That's it. `rake counted:setup` automatically discovers all databases and schemas from your `config/database.yml`, creates the metadata table, sets up triggers, and counts all rows.

## Usage

### Setup

```bash
# Set up all tables across all databases
rake counted:setup

# Check status
rake counted:status

# Re-sync counts (e.g., after restoring from backup)
rake counted:sync

# Stop tracking a table
rake counted:untrack[users]
```

### In models

```ruby
class User < ApplicationRecord
  counted
end

User.count           # => instant, reads from counted_metadata
User.where(active: true).count  # => standard COUNT(*) (with conditions)
User.count(:id)      # => standard COUNT(*) (with arguments)
```

### Programmatic API

```ruby
Counted.track!("users")
Counted.untrack!("users")
Counted.fetch_count("users")           # => 12543122
Counted.sync!("users")                 # re-count from scratch
Counted.track!("products", schema: "store")
```

## Multi-database support

Counted automatically discovers all databases configured in `config/database.yml`:

```yaml
development:
  primary:
    database: my_app_development
  analytics:
    database: my_app_analytics
```

Running `rake counted:setup` will set up triggers in both databases.

## Multi-schema support

Tables in custom PostgreSQL schemas are fully supported:

```ruby
Counted.track!("matches", schema: "wyscout")
Counted.fetch_count("matches", schema: "wyscout")  # => 125654
```

## Drift detection

On application boot, Counted checks for desynchronization and logs warnings:

```
[counted] data_lake_wyscout wyscout.match_events — not tracked (run `rake counted:setup`)
[counted] data_lake_rustat public.matches — metadata exists but trigger is missing
```

Three types of drift are detected:
- **Untracked** — table exists but no trigger set up
- **Missing triggers** — metadata exists but trigger was dropped
- **Stale metadata** — metadata refers to a table that was dropped

## Performance

| Operation | Time |
|---|---|
| `Model.count` (counted) | ~0.05ms |
| `Model.count` (standard, 1B rows) | minutes |
| INSERT/DELETE overhead | ~50μs per row |

## Configuration

```ruby
# config/initializers/counted.rb
Counted.configure do |c|
  c.metadata_table_name = "counted_metadata"  # default
  c.override_count = true                      # default, overrides Model.count
end
```

## Requirements

- Ruby >= 3.0
- ActiveRecord >= 6.1
- PostgreSQL

## Author

Oleg Orlov (orelcokolov@gmail.com)

## License

MIT
