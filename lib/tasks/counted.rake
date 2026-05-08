namespace :counted do
  desc "Set up exact count tracking for all tables across all databases"
  task setup: :environment do
    Counted.setup_all!
  end

  desc "Stop tracking exact count for TABLE. Usage: rake counted:untrack[users]"
  task :untrack, [:table] => :environment do |_t, args|
    table = args[:table]
    abort "Usage: rake counted:untrack[table_name]" unless table

    Counted.untrack!(table)
    puts "Stopped tracking '#{table}'"
  end

  desc "Re-sync exact count for all tracked tables across all databases"
  task sync: :environment do
    Counted.send(:each_database_connection) do |conn, db_name|
      a = Counted::Adapters::PostgresqlAdapter.new(conn)
      results = a.sync_all!
      results.each do |r|
        puts "[counted] #{db_name} #{r[:schema]}.#{r[:table]}: #{r[:count]}"
      end
    rescue => e
      warn "[counted] Skipping #{db_name}: #{e.message}"
    end
  end

  desc "Show status of all tracked tables across all databases"
  task status: :environment do
    Counted.send(:each_database_connection) do |conn, db_name|
      a = Counted::Adapters::PostgresqlAdapter.new(conn)
      rows = a.status.to_a
      next if rows.empty?

      puts "\n=== #{db_name} ==="
      rows.each do |row|
        puts "  %-10s %-40s %15s  %s" % [
          row["schema_name"],
          row["table_name"],
          row["row_count"].to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse,
          row["updated_at"]
        ]
      end
    rescue => e
      warn "[counted] Skipping #{db_name}: #{e.message}"
    end
  end
end
