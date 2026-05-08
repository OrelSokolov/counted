module Counted
  module Adapters
    class PostgresqlAdapter
      @ready = Set.new

      class << self
        attr_reader :ready
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

      def setup_schema!(schema)
        ensure_trigger_functions!
        ensure_metadata_table!(schema)
      end

      def track!(table_name, schema: "public")
        setup_schema!(schema)
        conn = @connection
        quoted_fqtn = fqtn(table_name, schema)
        current_count = nil

        conn.transaction do
          conn.execute("LOCK TABLE #{quoted_fqtn} IN EXCLUSIVE MODE")

          current_count = conn.select_value("SELECT COUNT(*) FROM #{quoted_fqtn}").to_i

          conn.execute(<<~SQL)
            INSERT INTO #{metadata_table(schema)} (table_name, row_count, created_at, updated_at)
            VALUES (
              #{conn.quote(table_name)},
              #{current_count},
              NOW(),
              NOW()
            )
            ON CONFLICT (table_name) DO UPDATE
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
          DELETE FROM #{metadata_table(schema)}
          WHERE table_name = #{conn.quote(table_name)}
        SQL
      end

      def fetch_count(table_name, schema: "public")
        setup_schema!(schema)
        conn = @connection
        result = conn.select_value(<<~SQL)
          SELECT row_count FROM #{metadata_table(schema)}
          WHERE table_name = #{conn.quote(table_name)}
        SQL
        result&.to_i
      end

      def tracked?(table_name, schema: "public")
        setup_schema!(schema)
        conn = @connection
        conn.select_value(<<~SQL).present?
          SELECT 1 FROM #{metadata_table(schema)}
          WHERE table_name = #{conn.quote(table_name)}
        SQL
      end

      def sync!(table_name, schema: "public")
        setup_schema!(schema)
        conn = @connection
        quoted_fqtn = fqtn(table_name, schema)

        current_count = conn.select_value("SELECT COUNT(*) FROM #{quoted_fqtn}").to_i

        conn.execute(<<~SQL)
          INSERT INTO #{metadata_table(schema)} (table_name, row_count, created_at, updated_at)
          VALUES (
            #{conn.quote(table_name)},
            #{current_count},
            NOW(),
            NOW()
          )
          ON CONFLICT (table_name) DO UPDATE
          SET row_count = EXCLUDED.row_count,
              updated_at = NOW()
        SQL

        current_count
      end

      def sync_all!
        schemas = discover_schemas_with_metadata
        results = []
        schemas.each do |schema|
          conn = @connection
          rows = conn.select_all(<<~SQL)
            SELECT table_name FROM #{metadata_table(schema)}
          SQL
          rows.each do |row|
            count = sync!(row["table_name"], schema: schema)
            results << { schema: schema, table: row["table_name"], count: count }
          end
        end
        results
      end

      def status
        schemas = discover_schemas_with_metadata
        all_rows = []
        schemas.each do |schema|
          rows = @connection.select_all(<<~SQL)
            SELECT '#{schema}' AS schema_name, table_name, row_count, updated_at
            FROM #{metadata_table(schema)}
            ORDER BY table_name
          SQL
          all_rows.concat(rows.to_a)
        end
        all_rows
      end

      def reset!
        schemas = discover_schemas_with_metadata
        schemas.each do |schema|
          @connection.execute("DELETE FROM #{metadata_table(schema)}")
        end

        triggers = @connection.select_values(<<~SQL)
          SELECT DISTINCT trigger_schema || '.' || event_object_table
          FROM information_schema.triggers
          WHERE trigger_name IN ('counted_row_trigger', 'counted_truncate_trigger')
        SQL

        triggers.each do |fqtn|
          @connection.execute("DROP TRIGGER IF EXISTS counted_row_trigger ON #{fqtn}")
          @connection.execute("DROP TRIGGER IF EXISTS counted_truncate_trigger ON #{fqtn}")
        end
      end

      def full_reset!
        schemas = discover_schemas_with_metadata
        schemas.each do |schema|
          @connection.execute("DROP TABLE IF EXISTS #{metadata_table(schema)} CASCADE")
          self.class.ready.delete(ready_key(schema))
        end

        triggers = @connection.select_values(<<~SQL)
          SELECT DISTINCT trigger_schema || '.' || event_object_table
          FROM information_schema.triggers
          WHERE trigger_name IN ('counted_row_trigger', 'counted_truncate_trigger')
        SQL

        triggers.each do |fqtn|
          @connection.execute("DROP TRIGGER IF EXISTS counted_row_trigger ON #{fqtn}")
          @connection.execute("DROP TRIGGER IF EXISTS counted_truncate_trigger ON #{fqtn}")
        end

        @connection.execute("DROP FUNCTION IF EXISTS counted_trigger_fn() CASCADE")
        @connection.execute("DROP FUNCTION IF EXISTS counted_truncate_fn() CASCADE")
        self.class.ready.delete("#{database_name}:__functions__")
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
        schemas = discover_schemas_with_metadata
        db_tables = discover_tables

        all_untracked = []
        all_missing_triggers = []
        all_stale = []

        schemas.each do |schema|
          conn = @connection
          meta_rows = conn.select_all(<<~SQL)
            SELECT table_name FROM #{metadata_table(schema)}
          SQL
          meta_set = meta_rows.map { |r| [r["table_name"], schema] }.to_set

          trigger_rows = conn.select_all(<<~SQL)
            SELECT event_object_table, trigger_schema
            FROM information_schema.triggers
            WHERE trigger_name IN ('counted_row_trigger', 'counted_truncate_trigger')
              AND trigger_schema = #{conn.quote(schema)}
          SQL
          trigger_set = trigger_rows.map { |r| [r["event_object_table"], r["trigger_schema"]] }.to_set

          schema_tables = db_tables.select { |_, s| s == schema }
          untracked = schema_tables.reject { |t, s| meta_set.include?([t, s]) }
          missing = meta_set.reject { |t, s| trigger_set.include?([t, s]) }
          stale = meta_set.reject { |t, s| db_tables.any? { |dt, ds| dt == t && ds == s } }

          all_untracked.concat(untracked.map { |t, s| { table: t, schema: s } })
          all_missing_triggers.concat(missing.map { |t, s| { table: t, schema: s } })
          all_stale.concat(stale.map { |t, s| { table: t, schema: s } })
        end

        {
          untracked: all_untracked,
          missing_triggers: all_missing_triggers,
          stale_metadata: all_stale
        }
      end

      def infrastructure_exists?(schema: "public")
        @connection.table_exists?("#{schema}.#{Counted.configuration.metadata_table_name}")
      end

      def discover_schemas_with_metadata
        conn = @connection
        meta_table = Counted.configuration.metadata_table_name

        conn.select_values(<<~SQL)
          SELECT DISTINCT table_schema
          FROM information_schema.tables
          WHERE table_name = #{conn.quote(meta_table)}
            AND table_schema NOT IN (#{EXCLUDED_SCHEMAS.map { |s| conn.quote(s) }.join(', ')})
        SQL
      end

      private

      def ready_key(schema)
        "#{database_name}:#{schema}"
      end

      def ensure_trigger_functions!
        key = "#{database_name}:__functions__"
        return if self.class.ready.include?(key)

        create_trigger_functions!
        self.class.ready.add(key)
      end

      def ensure_metadata_table!(schema)
        key = ready_key(schema)
        return if self.class.ready.include?(key)
        return if @connection.table_exists?("#{schema}.#{Counted.configuration.metadata_table_name}").tap { |exists| self.class.ready.add(key) if exists }

        with_advisory_lock do
          return if self.class.ready.include?(key)
          create_metadata_table!(schema)
          self.class.ready.add(key)
        end
      end

      def with_advisory_lock
        @connection.execute("SELECT pg_advisory_lock(#{advisory_lock_id})")
        yield
      ensure
        @connection&.execute("SELECT pg_advisory_unlock(#{advisory_lock_id})")
      end

      def advisory_lock_id
        Zlib.crc32("counted_infrastructure_#{@connection.pool.db_config.database}")
      end

      def create_metadata_table!(schema)
        @connection.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS #{metadata_table(schema)} (
            id bigserial PRIMARY KEY,
            table_name text NOT NULL,
            row_count bigint NOT NULL DEFAULT 0,
            created_at timestamp NOT NULL DEFAULT NOW(),
            updated_at timestamp NOT NULL DEFAULT NOW(),
            UNIQUE (table_name)
          )
        SQL
      end

      def create_trigger_functions!
        @connection.execute(<<~SQL)
          CREATE OR REPLACE FUNCTION counted_trigger_fn()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          BEGIN
            IF TG_OP = 'INSERT' THEN
              EXECUTE format(
                'INSERT INTO %I.#{Counted.configuration.metadata_table_name} (table_name, row_count, created_at, updated_at)
                 VALUES ($1, 1, NOW(), NOW())
                 ON CONFLICT (table_name) DO UPDATE
                 SET row_count = #{Counted.configuration.metadata_table_name}.row_count + 1, updated_at = NOW()',
                TG_TABLE_SCHEMA
              ) USING TG_TABLE_NAME;
              RETURN NEW;
            ELSIF TG_OP = 'DELETE' THEN
              EXECUTE format(
                'UPDATE %I.#{Counted.configuration.metadata_table_name}
                 SET row_count = row_count - 1, updated_at = NOW()
                 WHERE table_name = $1',
                TG_TABLE_SCHEMA
              ) USING TG_TABLE_NAME;
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
            EXECUTE format(
              'UPDATE %I.#{Counted.configuration.metadata_table_name}
               SET row_count = 0, updated_at = NOW()
               WHERE table_name = $1',
              TG_TABLE_SCHEMA
            ) USING TG_TABLE_NAME;
            RETURN NULL;
          END;
          $$;
        SQL
      end

      def fqtn(table_name, schema)
        conn = @connection
        "#{conn.quote_table_name(schema)}.#{conn.quote_table_name(table_name)}"
      end

      def metadata_table(schema)
        table = Counted.configuration.metadata_table_name
        @connection.quote_table_name(schema) + "." + @connection.quote_table_name(table)
      end
    end
  end
end
