require "active_record"
require "counted"

ActiveRecord::Base.establish_connection(
  adapter: "postgresql",
  database: ENV.fetch("PG_DATABASE", "counted_test"),
  host: ENV.fetch("PG_HOST", "localhost"),
  username: ENV.fetch("PG_USER", "root"),
  password: ENV.fetch("PG_PASSWORD", "dummy")
)

require "minitest/autorun"

class CountedTest < Minitest::Test
  def setup
    connection = ActiveRecord::Base.connection

    connection.execute("DROP TABLE IF EXISTS test_items CASCADE")
    connection.execute("DROP TABLE IF EXISTS public.counted_metadata CASCADE")
    connection.execute("DROP FUNCTION IF EXISTS counted_trigger_fn() CASCADE")
    connection.execute("DROP FUNCTION IF EXISTS counted_truncate_fn() CASCADE")

    connection.execute(<<~SQL)
      CREATE TABLE test_items (
        id bigserial PRIMARY KEY,
        name text
      )
    SQL

    Counted.instance_variable_set(:@adapters, nil)
    Counted.instance_variable_set(:@registered_tables, nil)
    Counted.instance_variable_set(:@configuration, nil)
    Counted::Adapters::PostgresqlAdapter.ready.clear
  end

  def test_track_creates_metadata_and_triggers
    5.times { ActiveRecord::Base.connection.execute("INSERT INTO test_items (name) VALUES ('x')") }

    count = Counted.track!("test_items")

    assert_equal 5, count
    assert_equal 5, Counted.fetch_count("test_items")
  end

  def test_trigger_maintains_count_on_insert
    Counted.track!("test_items")

    10.times { ActiveRecord::Base.connection.execute("INSERT INTO test_items (name) VALUES ('a')") }

    assert_equal 10, Counted.fetch_count("test_items")
  end

  def test_trigger_maintains_count_on_delete
    Counted.track!("test_items")
    5.times { ActiveRecord::Base.connection.execute("INSERT INTO test_items (name) VALUES ('a')") }

    ActiveRecord::Base.connection.execute("DELETE FROM test_items WHERE id <= 2")

    assert_equal 3, Counted.fetch_count("test_items")
  end

  def test_truncate_resets_count
    Counted.track!("test_items")
    10.times { ActiveRecord::Base.connection.execute("INSERT INTO test_items (name) VALUES ('a')") }

    ActiveRecord::Base.connection.execute("TRUNCATE test_items")

    assert_equal 0, Counted.fetch_count("test_items")
  end

  def test_untrack_removes_trigger
    Counted.track!("test_items")
    assert Counted.tracked?("test_items")

    Counted.untrack!("test_items")
    refute Counted.tracked?("test_items")

    ActiveRecord::Base.connection.execute("INSERT INTO test_items (name) VALUES ('a')")
    assert_nil Counted.fetch_count("test_items")
  end

  def test_sync_updates_count
    Counted.track!("test_items")
    3.times { ActiveRecord::Base.connection.execute("INSERT INTO test_items (name) VALUES ('a')") }

    result = Counted.sync!("test_items")
    assert_equal 3, result
  end

  def test_track_is_idempotent
    Counted.track!("test_items")
    count1 = Counted.track!("test_items")

    5.times { ActiveRecord::Base.connection.execute("INSERT INTO test_items (name) VALUES ('a')") }
    count2 = Counted.track!("test_items")

    assert_equal 5, count2
    assert_equal 5, Counted.fetch_count("test_items")
  end

  def test_schema_support
    conn = ActiveRecord::Base.connection
    conn.execute("DROP SCHEMA IF EXISTS test_schema CASCADE")
    conn.execute("CREATE SCHEMA test_schema")
    conn.execute(<<~SQL)
      CREATE TABLE test_schema.products (
        id bigserial PRIMARY KEY,
        name text
      )
    SQL

    3.times { conn.execute("INSERT INTO test_schema.products (name) VALUES ('p')") }

    count = Counted.track!("products", schema: "test_schema")
    assert_equal 3, count

    conn.execute("INSERT INTO test_schema.products (name) VALUES ('p')")
    assert_equal 4, Counted.fetch_count("products", schema: "test_schema")
  ensure
    ActiveRecord::Base.connection.execute("DROP SCHEMA IF EXISTS test_schema CASCADE")
  end

  def test_status_returns_tracked_tables
    Counted.track!("test_items")
    status = Counted.status

    assert_kind_of Array, status
    row = status.find { |r| r["table_name"] == "test_items" }
    assert row
    assert_equal "public", row["schema_name"]
  end

  def test_discover_tables_finds_application_tables
    adapter = Counted.send(:adapter_for)
    tables = adapter.discover_tables
    table_names = tables.map(&:first)

    assert_includes table_names, "test_items"
    refute_includes table_names, "schema_migrations"
    refute_includes table_names, "counted_metadata"
  end

  def test_setup_all_tracks_all_tables
    results = Counted.setup_all!
    table_names = results.map { |r| r[:table] }

    assert_includes table_names, "test_items"
    result = results.find { |r| r[:table] == "test_items" }
    assert_equal 0, result[:count]
    assert result[:database]
  end

  def test_drift_detects_untracked
    result = Counted.check_drift!
    db = result.values.first
    untracked_names = db[:untracked].map { |r| r[:table] }

    assert_includes untracked_names, "test_items"
  end

  def test_drift_empty_when_all_tracked
    Counted.setup_all!
    result = Counted.check_drift!
    db = result.values.first

    assert_empty db[:untracked]
    assert_empty db[:missing_triggers]
    assert_empty db[:stale_metadata]
  end

  def test_drift_detects_missing_trigger
    Counted.track!("test_items")
    conn = ActiveRecord::Base.connection
    conn.execute("DROP TRIGGER IF EXISTS counted_row_trigger ON public.test_items")
    conn.execute("DROP TRIGGER IF EXISTS counted_truncate_trigger ON public.test_items")

    result = Counted.check_drift!
    db = result.values.first
    missing = db[:missing_triggers].map { |r| r[:table] }

    assert_includes missing, "test_items"
  end

  def test_drift_detects_stale_metadata
    Counted.track!("test_items")
    ActiveRecord::Base.connection.execute("DROP TABLE test_items CASCADE")

    result = Counted.check_drift!
    db = result.values.first
    stale = db[:stale_metadata].map { |r| r[:table] }

    assert_includes stale, "test_items"
  end

  def test_model_counted_returns_exact_count
    item_class = Class.new(ActiveRecord::Base) do
      self.table_name = "test_items"
      include Counted::Model
    end

    Counted.track!("test_items")
    3.times { ActiveRecord::Base.connection.execute("INSERT INTO test_items (name) VALUES ('a')") }

    assert_equal 3, item_class.counted
  end

  def test_model_counted_returns_nil_when_not_tracked
    item_class = Class.new(ActiveRecord::Base) do
      self.table_name = "test_items"
      include Counted::Model
    end

    3.times { ActiveRecord::Base.connection.execute("INSERT INTO test_items (name) VALUES ('a')") }

    assert_nil item_class.counted
  end

  def test_model_count_still_works_normally
    item_class = Class.new(ActiveRecord::Base) do
      self.table_name = "test_items"
      include Counted::Model
    end

    3.times { ActiveRecord::Base.connection.execute("INSERT INTO test_items (name) VALUES ('a')") }

    assert_equal 3, item_class.count
  end

  private

  def assert_nil(value)
    assert value.nil?, "Expected nil, got #{value.inspect}"
  end
end
