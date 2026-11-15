require "minitest/autorun"

class SureBudgetInclusionTest < Minitest::Test
  def setup
    raise "Wrong synthetic database" unless ActiveRecord::Base.connection_db_config.database == "sure_review_test"
    ActiveRecord::Base.connection.begin_transaction(joinable: false)
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @family = Family.create!(name: "Fictional shared budget", currency: "CAD")
    @user = @family.users.create!(first_name: "Fictional", email: "budget@example.invalid", password: "fictional-password-2026", role: :admin, onboarded_at: Time.current)
    Current.session = @user.sessions.create!
    @account = @family.accounts.create!(name: "Fictional checking", currency: "CAD", balance: 1000, accountable: Depository.new, status: :active, owner: @user)
    @groceries = @family.categories.create!(name: "Groceries", color: "#6172F3")
    @shared = @family.categories.create!(name: "Shared share", color: "#6172F3", budget_default_included: false)
    @date = Date.current.beginning_of_month + 1.day
  end

  def teardown
    ActiveRecord::Base.connection.rollback_transaction
    Current.reset
  end

  def entry(amount, category: @groceries, preference: "category", kind: "standard")
    @account.entries.create!(name: "Fictional purchase", date: @date, amount: amount, currency: "CAD",
      entryable: Transaction.new(category: category, budget_inclusion: preference, kind: kind))
  end

  def budget
    Budget.new(family: @family, start_date: @date.beginning_of_month, end_date: @date.end_of_month, currency: "CAD", budgeted_spending: 500)
  end

  def report_expense
    IncomeStatement.new(@family, user: @user).expense_totals(period: budget.period).total.to_d
  end

  def test_default_keeps_existing_behavior_and_balances
    e = entry(40)
    assert_nil e.transaction.budget_included
    assert e.transaction.included_in_budget?
    assert_equal 40.to_d, budget.actual_spending.to_d
    assert_equal 40.to_d, report_expense
    before = e.attributes
    e.transaction.update!(budget_inclusion: "exclude")
    assert_equal 0.to_d, budget.actual_spending.to_d
    assert_equal 40.to_d, report_expense
    assert_equal before.except("updated_at"), e.reload.attributes.except("updated_at")
    assert_equal 1000.to_d, @account.reload.balance
  end

  def test_groceries_split_counts_only_personal_share_and_keeps_full_report
    parent = entry(200)
    children = parent.split!([
      { name: "My groceries", amount: 100, category_id: @groceries.id, budget_inclusion: "include" },
      { name: "Shared groceries", amount: 100, category_id: @shared.id, budget_inclusion: "category" }
    ])
    assert parent.reload.excluded?
    assert_equal 200.to_d, children.sum(&:amount)
    assert_equal 100.to_d, budget.actual_spending.to_d
    assert_equal 200.to_d, report_expense
    assert children.first.transaction.reload.included_in_budget?
    refute children.last.transaction.reload.included_in_budget?
    assert_equal 200.to_d, parent.amount
  end

  def test_split_can_keep_same_category_with_one_excluded_share
    parent = entry(200)
    children = parent.split!([
      { name: "Mine", amount: 100, category_id: @groceries.id, budget_inclusion: "include" },
      { name: "Shared", amount: 100, category_id: @groceries.id, budget_inclusion: "exclude" }
    ])
    assert_equal [true, false], children.map { |e| e.transaction.budget_included }
    assert_equal 100.to_d, budget.actual_spending.to_d
    assert_equal 200.to_d, report_expense
    assert_equal children.first.entryable_id, budget.transactions.first.id
    refute_includes budget.transactions.pluck(:id), children.last.entryable_id
  end

  def test_reimbursement_offsets_annick_share_without_becoming_budget_income
    entry(100, category: @shared)
    entry(-100, category: @shared)
    assert_equal 0.to_d, budget.actual_spending.to_d
    assert_equal 0.to_d, budget.actual_income.to_d
    totals = IncomeStatement.new(@family).totals(date_range: budget.period.date_range)
    assert_equal 2, totals.transactions_count
    assert_equal 0.to_d, @family.entries.sum(:amount)
  end

  def test_explicit_override_wins_and_return_to_category_works
    e = entry(25, category: @shared, preference: "include")
    assert_equal 25.to_d, budget.actual_spending.to_d
    @shared.update!(budget_default_included: true)
    e.transaction.update!(budget_inclusion: "exclude")
    assert_equal 0.to_d, budget.actual_spending.to_d
    e.transaction.update!(budget_inclusion: "category")
    assert_nil e.transaction.reload.budget_included
    assert_equal 25.to_d, budget.actual_spending.to_d
    assert_equal 25.to_d, report_expense
  end

  def test_interest_exclusion_does_not_reclassify_credit_or_loan_payments
    interest = @family.categories.create!(name: "Interest", color: "#6172F3", budget_default_included: false)
    charge = entry(40, category: interest)
    payment = entry(300, kind: "loan_payment")
    card = entry(90, preference: "include", kind: "cc_payment")
    assert_equal 300.to_d, budget.actual_spending.to_d
    assert_equal 340.to_d, report_expense
    assert_equal "standard", charge.transaction.reload.kind
    assert_equal "loan_payment", payment.transaction.reload.kind
    refute card.transaction.included_in_budget?
  end

  def test_invalid_override_is_rejected_without_changing_existing_preference
    e = entry(25, preference: "exclude")
    refute e.transaction.update(budget_inclusion: "anything")
    assert_includes e.transaction.errors.attribute_names, :budget_inclusion
    assert_equal false, e.transaction.reload.budget_included
    assert_raises(ArgumentError) { Transaction.budget_inclusion_sql("t; DROP TABLE entries") }
  end

  def test_statistics_and_rollover_inputs_use_budget_only_filter
    entry(100)
    entry(100, category: @shared)
    b = IncomeStatement.new(@family, budget_only: true)
    r = IncomeStatement.new(@family)
    assert_equal 100.to_d, b.median_expense.to_d
    assert_equal 200.to_d, r.median_expense.to_d
    assert_equal 0.to_d, b.avg_expense(category: @shared).to_d
    assert_equal 100.to_d, r.avg_expense(category: @shared).to_d
    assert_equal 100.to_d, b.net_category_totals(period: budget.period).total_net_expense.to_d
  end

  def test_category_change_invalidates_budget_cache_but_preserves_reports
    entry(40)
    assert_equal 40.to_d, budget.actual_spending.to_d
    @groceries.update!(budget_default_included: false)
    assert_equal 0.to_d, budget.actual_spending.to_d
    assert_equal 40.to_d, report_expense
  end

  def test_uncategorized_and_subcategory_defaults_are_explicit
    e = entry(20, category: nil)
    assert e.transaction.included_in_budget?
    child = @family.categories.create!(name: "Shared child", color: "#6172F3", parent: @shared)
    entry(30, category: child)
    assert_equal 50.to_d, budget.actual_spending.to_d
    child.update!(budget_default_included: false)
    assert_equal 20.to_d, budget.actual_spending.to_d
  end

  def test_resplit_preserves_explicit_preferences_and_unsplit_restores_original
    parent = entry(200)
    children = parent.split!([
      { name: "Mine", amount: 100, category_id: @groceries.id, budget_inclusion: "include" },
      { name: "Shared", amount: 100, category_id: @groceries.id, budget_inclusion: "exclude" }
    ])
    parent.resplit!(children.map { |e| { name: e.name, amount: e.amount, category_id: e.transaction.category_id, budget_inclusion: e.transaction.budget_inclusion } })
    assert_equal 100.to_d, budget.actual_spending.to_d
    parent.unsplit!
    assert_equal 200.to_d, budget.actual_spending.to_d
    assert_equal 200.to_d, parent.reload.amount
  end

  def test_budget_preference_edit_does_not_require_balance_sync
    e = entry(40)
    e.update!(entryable_attributes: { id: e.entryable_id, budget_inclusion: "exclude" })
    refute e.saved_changes_affect_balances?
    assert_equal 40.to_d, e.reload.amount
  end
end

class SureBudgetInclusionTest
  def test_daily_series_uses_separate_budget_and_report_cache_entries
    entry(40)
    entry(60, category: @shared)
    report = IncomeStatement.new(@family)
    filtered = IncomeStatement.new(@family, budget_only: true)
    assert_equal 100.to_d, report.daily_expense_series(period: budget.period).sum { |row| row.total.to_d }
    assert_equal 40.to_d, filtered.daily_expense_series(period: budget.period).sum { |row| row.total.to_d }
    assert_empty filtered.daily_expense_category_ids(period: budget.period) & [@shared.id]
    assert_equal 100.to_d, report_expense
  end

  def test_invalid_split_preference_is_atomic_and_never_hides_original
    parent = entry(200)
    assert_raises(ActiveRecord::RecordInvalid) do
      parent.split!([
        { name: "Mine", amount: 100, budget_inclusion: "include" },
        { name: "Shared", amount: 100, budget_inclusion: "invalid" }
      ])
    end
    refute parent.reload.excluded?
    assert_empty parent.child_entries
    assert_equal 200.to_d, budget.actual_spending.to_d
  end
end
