require "minitest/autorun"
require "action_dispatch/testing/integration"

class SurePersonalReviewTest < Minitest::Test
  def setup
    raise "Wrong fictional database" unless ActiveRecord::Base.connection_db_config.database == "sure_review_test"
    ActiveRecord::Base.connection.begin_transaction(joinable: false)
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @family = Family.create!(name: "Fictional review", currency: "CAD")
    @user = @family.users.create!(first_name: "Fictional", email: "review@example.invalid", password: "fictional-password-2026", role: :admin, onboarded_at: Time.current)
    Current.session = @user.sessions.create!
    @account = @family.accounts.create!(name: "Fictional checking", currency: "CAD", balance: 1000, accountable: Depository.new, status: :active, owner: @user)
    @cat = @family.categories.create!(name: "Groceries", color: "#6172F3")
    @other = @family.categories.create!(name: "Other", color: "#6172F3")
    @entry = @account.entries.create!(name: "Fictional groceries", date: Date.current, amount: 20, currency: "CAD", entryable: Transaction.new(category: @cat))
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  def teardown
    ActiveRecord::Base.connection.rollback_transaction
    Current.reset
  end

  def mark(entry = @entry)
    entry.update!(reviewed_at: Time.current)
    assert entry.reload.reviewed?
  end

  def assert_reset
    mark
    yield
    refute @entry.reload.reviewed?
  end

  def test_default_is_needs_review_and_setting_changes_no_financial_fields
    refute @entry.reviewed?
    before = @entry.attributes.except("reviewed_at", "updated_at")
    transaction_before = @entry.transaction.attributes
    mark
    assert_equal before, @entry.attributes.except("reviewed_at", "updated_at")
    assert_equal transaction_before, @entry.transaction.reload.attributes
    assert_equal 1000.to_d, @account.reload.balance
    assert_empty ActiveJob::Base.queue_adapter.enqueued_jobs
    refute @entry.saved_changes_affect_balances?
    @entry.update!(reviewed_at: nil)
    refute @entry.reload.reviewed?
  end

  def test_category_change_resets_even_through_update_all
    assert_reset { Transaction.where(id: @entry.entryable_id).update_all(category_id: @other.id) }
  end

  def test_rule_style_bulk_category_change_resets
    mark
    Entry.where(id: @entry.id).bulk_update!({category_id: @other.id})
    refute @entry.reload.reviewed?
    assert_equal @other.id, @entry.transaction.category_id
  end

  def test_unchanged_category_and_sync_metadata_preserve
    mark
    @entry.transaction.update!(category_id: @cat.id, extra: {"plaid" => {"pending" => false, "last_seen" => "fictional"}})
    @entry.update!(external_id: "fictional-provider-id", source: "plaid", notes: "A note")
    assert @entry.reload.reviewed?
    @entry.transaction.update!(extra: {"plaid" => {"pending" => false, "last_seen" => "later"}})
    assert @entry.reload.reviewed?
  end

  def test_amount_change_resets
    assert_reset { Entry.where(id: @entry.id).update_all(amount: 21) }
  end

  def test_date_change_resets
    assert_reset { @entry.update!(date: Date.current - 1.day) }
  end

  def test_account_change_resets
    second = @family.accounts.create!(name: "Other checking", currency: "CAD", balance: 1, accountable: Depository.new, status: :active, owner: @user)
    assert_reset { @entry.update!(account: second) }
  end

  def test_description_currency_and_kind_changes_reset
    assert_reset { @entry.update!(name: "Changed description") }
    assert_reset { @entry.update!(currency: "USD") }
    assert_reset { @entry.transaction.update!(kind: "one_time") }
  end

  def test_budget_treatment_change_resets_without_budget_corruption
    assert_reset { @entry.transaction.update!(budget_inclusion: "exclude") }
    refute @entry.transaction.included_in_budget?
  end

  def test_pending_posted_transition_resets
    @entry.transaction.update!(extra: {"plaid" => {"pending" => true}})
    assert_reset { @entry.transaction.update!(extra: {"plaid" => {"pending" => false}}) }
  end

  def test_rolled_back_edit_keeps_review
    mark
    Entry.transaction(requires_new: true) do
      @entry.transaction.update!(category: @other)
      raise ActiveRecord::Rollback
    end
    assert @entry.reload.reviewed?
    assert_equal @cat.id, @entry.transaction.category_id
  end

  def test_splits_start_unreviewed_and_unsplit_requires_review
    mark
    children = @entry.split!([{name: "Mine", amount: 10, category_id: @cat.id}, {name: "Shared", amount: 10, category_id: @cat.id}])
    refute @entry.reload.reviewed?
    assert children.all? { |c| !c.reviewed? }
    mark(children.first)
    refute children.last.reload.reviewed?
    @entry.unsplit!
    refute @entry.reload.reviewed?
    assert_equal 20.to_d, @entry.amount
  end

  def test_resplit_clears_old_reviews
    children = @entry.split!([{name: "Mine", amount: 10}, {name: "Shared", amount: 10}])
    children.each { |c| mark(c) }
    @entry.resplit!([{name: "Mine", amount: 15}, {name: "Shared", amount: 5}])
    assert @entry.reload.child_entries.all? { |c| !c.reviewed? }
  end

  def search(status)
    Transaction::Search.new(@family, filters: {review_status: status}, accessible_account_ids: [@account.id]).transactions_scope
  end

  def test_search_and_count_follow_review_without_changing_totals
    assert_equal [@entry.entryable_id], search("unreviewed").pluck(:id)
    assert_empty search("reviewed")
    assert_equal 20.to_d, Transaction::Search.new(@family).totals.expense_money.amount.to_d
    mark
    assert_equal [@entry.entryable_id], search("reviewed").pluck(:id)
    assert_empty search("unreviewed")
    assert_equal [@entry.id], @account.entries.search({review_status: "reviewed"}, @family).pluck(:id)
    assert_equal 20.to_d, Transaction::Search.new(@family).totals.expense_money.amount.to_d
    assert_equal 1, search("invalid").count
  end

  def client
    ApplicationController.allow_forgery_protection = false # isolated fictional tests only
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! "localhost"
    session.https!
    session.post "/sessions", params: {email: @user.email, password: "fictional-password-2026"}
    assert_includes [302, 303], session.response.status, session.response.body[0,200]
    session
  end

  def test_http_single_and_bulk_reviews_and_unreview
    second = @account.entries.create!(name: "Second", date: Date.current, amount: 30, currency: "CAD", entryable: Transaction.new(category: @cat))
    c = client
    c.post "/transactions/review", params: {review: {reviewed: "1", entry_ids: [@entry.id, second.id]}}
    assert_includes [302, 303], c.response.status, c.response.body[0,200]
    assert @entry.reload.reviewed?
    assert second.reload.reviewed?
    c.post "/transactions/review", params: {review: {reviewed: "0", entry_ids: [@entry.id]}}
    refute @entry.reload.reviewed?
    assert second.reload.reviewed?
    c.get "/transactions", params: {q: {review_status: "unreviewed"}, clear_filters: true}
    assert_equal 200, c.response.status
    assert_includes c.response.body, "Needs review (1)"
    assert_includes c.response.body, "Reviewed: Fictional groceries"
    refute_includes c.response.body, "Reviewed: Second"
  end

  def test_http_rejects_forged_scope_and_bad_values_atomically
    foreign = Family.create!(name: "Unrelated fictional household", currency: "CAD")
    a = foreign.accounts.create!(name: "Foreign", currency: "CAD", balance: 1, accountable: Depository.new, status: :active)
    e = a.entries.create!(name: "Foreign", date: Date.current, amount: 1, currency: "CAD", entryable: Transaction.new)
    c = client
    c.post "/transactions/review", params: {review: {reviewed: "1", entry_ids: [@entry.id, e.id]}}
    assert_equal 404, c.response.status, "Unexpected redirect: #{c.response.location}"
    refute @entry.reload.reviewed?
    refute e.reload.reviewed?
    c.post "/transactions/review", params: {review: {reviewed: "garbage", entry_ids: [@entry.id]}}
    assert_equal 422, c.response.status
    refute @entry.reload.reviewed?
  end

  def test_split_parent_is_not_reviewable_as_a_whole
    @entry.split!([{name: "A", amount: 10}, {name: "B", amount: 10}])
    c = client
    c.post "/transactions/review", params: {review: {reviewed: "1", entry_ids: [@entry.id]}}
    assert_equal 404, c.response.status, "Unexpected redirect: #{c.response.location}"
    refute @entry.reload.reviewed?
  end
  def test_read_write_shared_account_cannot_be_marked_reviewed
    other_user = @family.users.create!(first_name: "Other", email: "other-review@example.invalid", password: "fictional-password-2026", role: :member, onboarded_at: Time.current)
    other_account = @family.accounts.create!(name: "Shared", currency: "CAD", balance: 1, accountable: Depository.new, status: :active, owner: other_user)
    other_account.share_with!(@user, permission: "read_write")
    e = other_account.entries.create!(name: "Shared expense", date: Date.current, amount: 1, currency: "CAD", entryable: Transaction.new)
    c = client
    c.post "/transactions/review", params: {review: {reviewed: "1", entry_ids: [@entry.id, e.id]}}
    assert_equal 404, c.response.status
    refute @entry.reload.reviewed?
    refute e.reload.reviewed?
  end

  def test_guest_cannot_review
    @user.update!(role: :guest)
    c = client
    c.post "/transactions/review", params: {review: {reviewed: "1", entry_ids: [@entry.id]}}
    assert_includes [302, 303, 403], c.response.status
    refute @entry.reload.reviewed?
  end

  def test_direct_drawer_review_returns_to_real_list
    c = client
    c.post "/transactions/review", params: {review: {reviewed: "1", entry_ids: [@entry.id]}}, headers: {"HTTP_REFERER" => "https://localhost/transactions/#{@entry.id}"}
    assert_equal 303, c.response.status
    assert_equal "https://localhost/transactions", c.response.location
    assert @entry.reload.reviewed?
  end

end
