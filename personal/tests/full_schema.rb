# Full-suite workers must inherit PostgreSQL review triggers as well as columns.
# This initializer is copied only into the disposable developer test image.
if ENV["PERSONAL_FULL_TEST_SQL"] == "1"
  raise "Wrong full-suite database" unless Rails.env.test? && ENV["POSTGRES_DB"] == "sure_fork_full_test"
  Rails.application.config.active_record.schema_format = :sql
  ActiveRecord.schema_format = :sql
end
