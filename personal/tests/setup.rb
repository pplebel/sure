raise "Wrong fictional database" unless ActiveRecord::Base.connection_db_config.database == "sure_review_test"
ActiveJob::Base.queue_adapter = :test
ActiveRecord::Schema.verbose = false
load Rails.root.join("db/schema.rb")
load Rails.root.join("db/migrate/20261113140000_add_budget_inclusion_preferences.rb")
AddBudgetInclusionPreferences.new.migrate(:up)
load Rails.root.join("db/migrate/20261113160000_add_personal_transaction_review.rb")
AddPersonalTransactionReview.new.migrate(:up)
puts "Fictional schema ready"
