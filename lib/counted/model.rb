module Counted
  module Model
    extend ActiveSupport::Concern

    class_methods do
      def counted
        Counted.fetch_count(table_name, connection: self.connection)
      end
    end
  end
end
