raise "Wrong fictional database" unless ActiveRecord::Base.connection_db_config.database == "sure_review_test"
ActiveJob::Base.queue_adapter = :test
Rails.logger.level = Logger::ERROR
load Rails.root.join("personal/tests/review_test.rb")
load Rails.root.join("personal/tests/budget_test.rb")
load Rails.root.join("personal/tests/provider_test.rb")
ActiveSupport::ExecutionContext.nestable = false
ActiveSupport::ExecutionContext.clear
ok = Minitest.run
STDOUT.flush; STDERR.flush
Process.exit!(ok ? 0 : 1)
