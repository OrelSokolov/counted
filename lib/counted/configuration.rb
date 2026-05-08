module Counted
  class Configuration
    attr_accessor :metadata_table_name, :override_count

    def initialize
      @metadata_table_name = "counted_metadata"
      @override_count = true
    end
  end
end
