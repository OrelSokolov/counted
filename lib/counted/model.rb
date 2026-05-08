module Counted
  module Model
    extend ActiveSupport::Concern

    class_methods do
      def counted
        Counted.fetch_count(table_name, schema: counted_schema, connection: self.connection)
      end

      private

      def counted_schema
        return @counted_schema if defined?(@counted_schema)

        @counted_schema = self.connection.select_value(<<~SQL) || "public"
          SELECT n.nspname
          FROM pg_class c
          JOIN pg_namespace n ON c.relnamespace = n.oid
          WHERE c.oid = '#{self.connection.quote_string(table_name)}'::regclass
        SQL
      end
    end
  end
end
