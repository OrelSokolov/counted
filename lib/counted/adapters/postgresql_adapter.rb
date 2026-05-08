module Counted
  module Adapters
    class PostgresqlAdapter
      @ready_databases = Set.new

      class << self
        attr_reader :ready_databases
      end

      EXCLUDED_TABLES = %w[
        schema_migrations
        ar_internal_metadata
      ].freeze

      EXCLUDED_SCHEMAS = %w[
        pg_catalog
        information_schema
      ].freeze

      def initialize(connection)
        @connection = connection
      end

      def database_name
        @connection.pool.db_config.database
      end

      def track!(table_name, schema: "public")
        ensure_infrastructure!
        conn = @connection
        quoted_fqtn = fqtn(table_name, schema)
        current_count = nil

        conn.transaction do
          conn.execute("LOCK TABLE #{quoted_fqtn} IN EXCLUSIVE MODE")

          current_count = conn.select_value("SELECT COUNT(*) FROM #{quoted_fqtn}").to_i

          conn.execute(<<~SQL)
            INSERT INTO #{metadata_table} (schema_name, table_name, row_count, created_at, updated_at)
            VALUES (
              #{conn.quote(schema)},
              #{conn.quote(table_name)},
              #{current_count},
              NOW(),
              NOW()
            )
            ON CONFLICT (schema_name, table_name) DO UPDATE
            SET row_count = EXCLUDED.row_count,
                updated_at = NOW()
          SQL

          conn.execute(<<~SQL)
            DROP TRIGGER IF EXISTS counted_row_trigger ON #{quoted_fqtn};
            CREATE TRIGGER counted_row_trigger
              AFTER INSERT OR DELETE ON #{quoted_fqtn}
              FOR EACH ROW EXECUTE FUNCTION counted_trigger_fn()
          SQL

          conn.execute(<<~SQL)
            DROP TRIGGER IF EXISTS counted_truncate_trigger ON #{quoted_fqtn};
            CREATE TRIGGER counted_truncate_trigger
              AFTER TRUNCATE ON #{quoted_fqtn}
              FOR EACH STATEMENT EXECUTE FUNCTION counted_truncate_fn()
          SQL
        end

        current_count
      end

      def untrack!(table_name, schema: "public")
        conn = @connection
        quoted_fqtn = fqtn(table_name, schema)

        conn.execute("DROP TRIGGER IF EXISTS counted_row_trigger ON #{quoted_fqtn}")
        conn.execute("DROP TRIGGER IF EXISTS counted_truncate_trigger ON #{quoted_fqtn}")

        conn.execute(<<~SQL)
          DELETE FROM #{metadata_table}
          WHERE schema_name = #{conn.quote(schema)}
            AND table_name = #{conn.quote(table_name)}
        SQL
      end

      def fetch_count(table_name, schema: "public")
        ensure_infrastructure!
        conn = @connection
        result = conn.select_value(<<~SQL)
          SELECT row_count FROM #{metadata_table}
          WHERE schema_name = #{conn.quote(schema)}
            AND table_name = #{conn.quote(table_name)}
        SQL
        result&.to_i
      end

      def tracked?(table_name, schema: "public")
        ensure_infrastructure!
        conn = @connection
        conn.select_value(<<~SQL).present?
          SELECT 1 FROM #{metadata_table}
          WHERE schema_name = #{conn.quote(schema)}
            AND table_name = #{conn.quote(table_name)}
        SQL
      end

      def sync!(table_name, schema: "public")
        ensure_infrastructure!
        conn = @connection
        quoted_fqtn = fqtn(table_name, schema)

        current_count = conn.select_value("SELECT COUNT(*) FROM #{quoted_fqtn}").to_i

        conn.execute(<<~SQL)
          INSERT INTO #{metadata_table} (schema_name, table_name, row_count, created_at, updated_at)
          VALUES (
            #{conn.quote(schema)},
            #{conn.quote(table_name)},
            #{current_count},
            NOW(),
            NOW()
          )
          ON CONFLICT (schema_name, table_name) DO UPDATE
          SET row_count = EXCLUDED.row_count,
              updated_at = NOW()
        SQL

        current_count
      end

      def sync_all!
        ensure_infrastructure!
        conn = @connection
        rows = conn.select_all(<<~SQL)
          SELECT schema_name, table_name FROM #{metadata_table}
        SQL
        rows.map do |row|
          sync!(row["table_name"], schema: row["schema_name"])
        end
      end

      def status
        ensure_infrastructure!
        @connection.select_all(<<~SQL)
          SELECT schema_name, table_name, row_count, updated_at
          FROM #{metadata_table}
          ORDER BY schema_name, table_name
        SQL
      end

      def reset!
        ensure_infrastructure!
        conn = @connection
        conn.execute("DELETE FROM #{metadata_table}")

        triggers = conn.select_values(<<~SQL)
          SELECT DISTINCT trigger_schema || '.' || event_object_table
          FROM information_schema.triggers
          WHERE trigger_name IN ('counted_row_trigger', 'counted_truncate_trigger')
        SQL

        triggers.each do |fqtn|
          conn.execute("DROP TRIGGER IF EXISTS counted_row_trigger ON #{fqtn}")
          conn.execute("DROP TRIGGER IF EXISTS counted_truncate_trigger ON #{fqtn}")
        end
      end

      def discover_tables
        conn = @connection
        meta_table = Counted.configuration.metadata_table_name

        conn.select_all(<<~SQL).map { |row| [row["table_name"], row["table_schema"]] }
          SELECT table_schema, table_name
          FROM information_schema.tables
          WHERE table_type = 'BASE TABLE'
            AND table_schema NOT IN (#{EXCLUDED_SCHEMAS.map { |s| conn.quote(s) }.join(', ')})
            AND table_name NOT IN (#{(EXCLUDED_TABLES + [meta_table]).map { |t| conn.quote(t) }.join(', ')})
          ORDER BY table_schema, table_name
        SQL
      end

      def drift
        ensure_infrastructure!
        conn = @connection
        db_tables = discover_tables
        meta_rows = conn.select_all(<<~SQL)
          SELECT schema_name, table_name, row_count FROM #{metadata_table}
        SQL
        meta_set = meta_rows.map { |r| [r["table_name"], r["schema_name"]] }.to_set

        trigger_rows = conn.select_all(<<~SQL)
          SELECT trigger_schema, event_object_table, trigger_name
          FROM information_schema.triggers
          WHERE trigger_name IN ('counted_row_trigger', 'counted_truncate_trigger')
        SQL
        trigger_set = trigger_rows.map { |r| [r["event_object_table"], r["trigger_schema"]] }.to_set

        untracked = db_tables.reject { |t, s| meta_set.include?([t, s]) }
        missing_triggers = meta_set.reject { |t, s| trigger_set.include?([t, s]) }
        stale_metadata = meta_set.reject { |t, s| db_tables.any? { |dt, ds| dt == t && ds == s } }

        {
          untracked: untracked.map { |t, s| { table: t, schema: s } },
          missing_triggers: missing_triggers.map { |t, s| { table: t, schema: s } },
          stale_metadata: stale_metadata.map { |t, s| { table: t, schema: s } }
        }
      end

      def infrastructure_exists?
        @connection.table_exists?(Counted.configuration.metadata_table_name)
      end

      def ensure_infrastructure!
        db = database_name
        return if self.class.ready_databases.include?(db)
        return if @connection.table_exists?(Counted.configuration.metadata_table_name) && self.class.ready_databases.add(db)

        with_advisory_lock do
          return if self.class.ready_databases.include?(db)
          create_metadata_table!
          create_trigger_functions!
          self.class.ready_databases.add(db)
        end
      end

      private

      def with_advisory_lock
        @connection.execute("SELECT pg_advisory_lock(#{advisory_lock_id})")
        yield
      ensure
        @connection&.execute("SELECT pg_advisory_unlock(#{advisory_lock_id})")
      end

      def advisory_lock_id
        Zlib.crc32("counted_infrastructure_#{@connection.pool.db_config.database}")
      end

      def create_metadata_table!
        @connection.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS #{metadata_table} (
            id bigserial PRIMARY KEY,
            schema_name text NOT NULL DEFAULT 'public',
            table_name text NOT NULL,
            row_count bigint NOT NULL DEFAULT 0,
            created_at timestamp NOT NULL DEFAULT NOW(),
            updated_at timestamp NOT NULL DEFAULT NOW(),
            UNIQUE (schema_name, table_name)
          )
        SQL
      end

      def create_trigger_functions!
        mt = metadata_table

        @connection.execute(<<~SQL)
          CREATE OR REPLACE FUNCTION counted_trigger_fn()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          BEGIN
            IF TG_OP = 'INSERT' THEN
              INSERT INTO #{mt} (schema_name, table_name, row_count, created_at, updated_at)
              VALUES (TG_TABLE_SCHEMA, TG_TABLE_NAME, 1, NOW(), NOW())
              ON CONFLICT (schema_name, table_name) DO UPDATE
              SET row_count = #{mt}.row_count + 1, updated_at = NOW();
              RETURN NEW;
            ELSIF TG_OP = 'DELETE' THEN
              UPDATE #{mt}
              SET row_count = row_count - 1, updated_at = NOW()
              WHERE schema_name = TG_TABLE_SCHEMA AND table_name = TG_TABLE_NAME;
              RETURN OLD;
            END IF;
            RETURN NULL;
          END;
          $$;
        SQL

        @connection.execute(<<~SQL)
          CREATE OR REPLACE FUNCTION counted_truncate_fn()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          BEGIN
            UPDATE #{mt}
            SET row_count = 0, updated_at = NOW()
            WHERE schema_name = TG_TABLE_SCHEMA AND table_name = TG_TABLE_NAME;
            RETURN NULL;
          END;
          $$;
        SQL
      end

      def fqtn(table_name, schema)
        conn = @connection
        "#{conn.quote_table_name(schema)}.#{conn.quote_table_name(table_name)}"
      end

      def metadata_table
        @connection.quote_table_name(Counted.configuration.metadata_table_name)
      end
    end
  end
end
