module Counted
  class Railtie < Rails::Railtie
    initializer "counted.model" do
      ActiveSupport.on_load(:active_record) do
        ActiveRecord::Base.include(Counted::Model)
      end
    end

    rake_tasks do
      load "tasks/counted.rake"
    end

    config.after_initialize do
      Counted.check_drift!
    end
  end
end
