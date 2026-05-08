require "counted/version"
require "counted/configuration"
require "counted/adapters/postgresql_adapter"
require "counted/model"

module Counted
  class Error < StandardError; end

  class << self
    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def register(table_name, connection: nil)
      conn = connection || ActiveRecord::Base.connection
      registered_tables.add([conn.pool.db_config.database, table_name])
    end

    def registered?(table_name, connection: nil)
      conn = connection || ActiveRecord::Base.connection
      registered_tables.include?([conn.pool.db_config.database, table_name])
    end

    def track!(table_name, schema: "public", connection: nil)
      adapter_for(connection).track!(table_name, schema: schema)
    end

    def untrack!(table_name, schema: "public", connection: nil)
      conn = connection || ActiveRecord::Base.connection
      registered_tables.delete([conn.pool.db_config.database, table_name])
      adapter_for(connection).untrack!(table_name, schema: schema)
    end

    def fetch_count(table_name, schema: "public", connection: nil)
      a = adapter_for(connection)
      a.ensure_infrastructure!
      a.fetch_count(table_name, schema: schema)
    end

    def sync!(table_name, schema: "public", connection: nil)
      adapter_for(connection).sync!(table_name, schema: schema)
    end

    def sync_all!(connection: nil)
      adapter_for(connection).sync_all!
    end

    def tracked?(table_name, schema: "public", connection: nil)
      adapter_for(connection).tracked?(table_name, schema: schema)
    end

    def status(connection: nil)
      adapter_for(connection).status.to_a
    end

    def setup_all!
      results = []
      each_database_connection do |conn, db_name|
        puts "[counted] Connecting to #{db_name}..."
        a = Adapters::PostgresqlAdapter.new(conn)
        a.ensure_infrastructure!
        tables = a.discover_tables
        puts "[counted] #{db_name}: Found #{tables.size} table(s)"
        tables.each do |table_name, schema|
          $stdout.print "[counted] #{db_name} #{schema}.#{table_name} ... "
          $stdout.flush
          count = a.track!(table_name, schema: schema)
          puts number_with_delimiter(count)
          results << { database: db_name, schema: schema, table: table_name, count: count }
        end
      rescue => e
        warn "[counted] Skipping database #{db_name}: #{e.class}: #{e.message}"
        logger&.warn("[counted] Skipping database #{db_name}: #{e.message}")
      end
      if results.any?
        db_count = results.map { |r| r[:database] }.uniq.size
        total_rows = results.sum { |r| r[:count] }
        puts "\n[counted] Done. #{results.size} table(s) across #{db_count} database(s), #{number_with_delimiter(total_rows)} total rows tracked."
      else
        puts "[counted] No tables found."
      end
      results
    end

    def check_drift!
      all_results = {}
      each_database_connection do |conn, db_name|
        a = Adapters::PostgresqlAdapter.new(conn)
        result = check_drift_for_adapter!(a, db_name)
        all_results[db_name] = result
      rescue => e
        logger&.error("[counted] #{db_name}: Failed to check drift: #{e.message}")
        all_results[db_name] = { untracked: [], missing_triggers: [], stale_metadata: [] }
      end
      all_results
    end

    def reset!(connection: nil)
      adapter_for(connection).reset!
    end

    def number_with_delimiter(n)
      n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    end

    def logger
      defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : nil
    end

    private

    def check_drift_for_adapter!(a, db_name)
      unless a.infrastructure_exists?
        tables = a.discover_tables
        untracked = tables.map { |t, s| { table: t, schema: s } }
        if untracked.any?
          logger&.warn("[counted] #{db_name}: Not initialized. Run `rake counted:setup` to track #{untracked.size} table(s)")
        end
        return { untracked: untracked, missing_triggers: [], stale_metadata: [] }
      end

      result = a.drift
      messages = []

      if result[:untracked].any?
        result[:untracked].each do |r|
          messages << "[counted] #{db_name} #{r[:schema]}.#{r[:table]} — not tracked (run `rake counted:setup`)"
        end
      end
      if result[:missing_triggers].any?
        result[:missing_triggers].each do |r|
          messages << "[counted] #{db_name} #{r[:schema]}.#{r[:table]} — metadata exists but trigger is missing"
        end
      end
      if result[:stale_metadata].any?
        result[:stale_metadata].each do |r|
          messages << "[counted] #{db_name} #{r[:schema]}.#{r[:table]} — metadata exists but table was dropped"
        end
      end

      logger&.warn(messages.join("\n")) if messages.any?
      result
    end

    def each_database_connection
      if defined?(Rails)
        configs = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env)
        original_config = ActiveRecord::Base.connection.pool.db_config.configuration_hash

        configs.each do |config|
          begin
            ActiveRecord::Base.establish_connection(config.configuration_hash)
            conn = ActiveRecord::Base.connection
            db_name = conn.pool.db_config.database
            yield conn, db_name
          rescue => e
            warn "[counted] Cannot connect to #{config.name}: #{e.message}"
          end
        end

        ActiveRecord::Base.establish_connection(original_config)
      else
        yield ActiveRecord::Base.connection, ActiveRecord::Base.connection.pool.db_config.database
      end
    end

    def registered_tables
      @registered_tables ||= Set.new
    end

    def adapter_for(connection = nil)
      conn = connection || ActiveRecord::Base.connection
      db_name = conn.pool.db_config.database
      @adapters ||= {}
      @adapters[db_name] ||= Adapters::PostgresqlAdapter.new(conn)
    end
  end
end

require "counted/railtie" if defined?(Rails)
