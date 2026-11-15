# Run with rails runner in the disposable, internal-only synthetic test database.
require "minitest/autorun"
require "ostruct"

# Turn the production processor's soft exception reporting into a test failure.
# This prevents a passing importer test from hiding a broken ledger import.
Sentry.define_singleton_method(:capture_exception) { |error, **_options, &_block| raise error }

class PartialLiabilitiesSyncTest < Minitest::Test
  class FakeProvider
    attr_accessor :liabilities_error, :transactions_error, :accounts_error
    attr_reader :liability_calls

    def initialize
      @liability_calls = 0
      @liabilities_error = Plaid::ApiError.new(code: 500, response_body: {
        error_code: "INTERNAL_SERVER_ERROR", request_id: "synthetic-request-123",
        error_message: "DO_NOT_COPY_RAW_PROVIDER_MESSAGE"
      }.to_json)
    end

    def get_item(_token)
      OpenStruct.new(item: Plaid::Item.new(item_id: "synthetic-item",
        institution_id: "synthetic-institution", available_products: [],
        billed_products: %w[transactions liabilities], consented_products: %w[transactions liabilities]))
    end

    def get_institution(_id)
      OpenStruct.new(institution: Plaid::Institution.new(institution_id: "synthetic-institution",
        name: "Synthetic Bank", url: "https://example.com", primary_color: "#000000"))
    end

    def get_item_accounts(_token)
      raise accounts_error if accounts_error
      OpenStruct.new(accounts: [
        Plaid::AccountBase.new(account_id: "synthetic-checking", name: "Synthetic Chequing",
          type: "depository", subtype: "checking", mask: "0001",
          balances: Plaid::AccountBalance.new(current: 500, available: 500, iso_currency_code: "CAD")),
        Plaid::AccountBase.new(account_id: "synthetic-credit", name: "Synthetic Credit",
          type: "credit", subtype: "credit card", mask: "0002",
          balances: Plaid::AccountBalance.new(current: 100, available: 900, iso_currency_code: "CAD"))
      ])
    end

    def get_transactions(_token, next_cursor:)
      raise transactions_error if transactions_error
      transactions = %w[synthetic-checking synthetic-credit].map.with_index do |id, i|
        Plaid::Transaction.new(account_id: id, transaction_id: "synthetic-tx-#{i}",
          amount: 12 + i, date: Date.new(2026, 10, 20), name: "Synthetic purchase #{i}",
          merchant_name: "Synthetic Merchant #{i}", original_description: "Synthetic purchase #{i}",
          iso_currency_code: "CAD", pending: false, payment_channel: "in store")
      end
      OpenStruct.new(added: transactions, modified: [], removed: [], cursor: "synthetic-cursor")
    end

    def get_item_liabilities(_token)
      @liability_calls += 1
      raise liabilities_error if liabilities_error
      Plaid::LiabilitiesObject.new(credit: [Plaid::CreditCardLiability.new(
        account_id: "synthetic-credit", minimum_payment_amount: 25,
        aprs: [Plaid::APR.new(apr_percentage: 19.5, apr_type: "purchase_apr")])],
        mortgage: [], student: [])
    end
  end

  def setup
    raise "Wrong test database" unless ActiveRecord::Base.connection_db_config.database == "sure_review_test"
    ActiveRecord::Base.connection.begin_transaction(joinable: false)
    @family = Family.create!(name: "Synthetic partial-sync family", currency: "CAD")
    @user = @family.users.create!(first_name: "Synthetic", email: "partial-sync@example.invalid",
      password: "synthetic-test-password-123", role: :admin, onboarded_at: Time.current)
    @item = @family.plaid_items.create!(name: "Synthetic Bank", plaid_id: "synthetic-item",
      access_token: "synthetic-not-a-real-token", owner: @user,
      billed_products: %w[transactions liabilities], available_products: [])
    @provider = FakeProvider.new
    provider = @provider
    @item.define_singleton_method(:plaid_provider) { provider }
  end

  def teardown
    ActiveRecord::Base.connection.rollback_transaction
    Current.reset
  end

  def import
    PlaidItem::Importer.new(@item, plaid_provider: @provider).import
  end

  def test_liability_failure_commits_accounts_transaction_snapshots_and_cursor_once
    warnings = import
    assert_equal 2, @item.plaid_accounts.count
    assert_equal "synthetic-cursor", @item.reload.next_cursor
    assert_equal 1, @provider.liability_calls
    assert_equal 1, warnings.size
    assert_equal "liabilities_unavailable", warnings.first[:category]
    refute_includes warnings.to_json, "DO_NOT_COPY_RAW_PROVIDER_MESSAGE"
    @item.plaid_accounts.each do |account|
      assert_equal 1, account.raw_transactions_payload.fetch("added").size
      assert_empty account.raw_liabilities_payload
    end
  end

  def test_successful_core_sync_persists_warning_and_creates_real_domain_transactions
    sync = @item.syncs.create!(status: :syncing)
    PlaidItem::Syncer.new(@item).perform_sync(sync)
    assert_equal 2, @item.plaid_accounts.count
    assert_equal 2, @item.plaid_accounts.filter_map(&:current_account).size
    ids = @item.plaid_accounts.map { |a| a.current_account.id }
    assert_equal 2, Entry.where(account_id: ids, entryable_type: "Transaction").count
    assert_equal 1, sync.reload.sync_stats.fetch("data_warnings")
    assert_equal "warning", sync.sync_stats.fetch("data_quality_details").first.fetch("severity")
    assert_equal 0, sync.sync_stats.fetch("total_errors")
    html = ApplicationController.render(ProviderSyncSummary.new(stats: sync.sync_stats, provider_item: @item), layout: false)
    assert_includes html, "Liabilities details could not be refreshed"
    assert_equal 1, @provider.liability_calls
  end

  def test_prior_liabilities_are_preserved_and_next_sync_recovers_without_duplicates
    @provider.liabilities_error = nil
    first_sync = @item.syncs.create!(status: :syncing)
    PlaidItem::Syncer.new(@item).perform_sync(first_sync)
    credit = @item.plaid_accounts.find_by!(plaid_id: "synthetic-credit")
    before = credit.raw_liabilities_payload
    assert_equal 25, before.dig("credit", "minimum_payment_amount")
    @provider.liabilities_error = FakeProvider.new.liabilities_error
    @item.reload
    second_sync = @item.syncs.create!(status: :syncing)
    PlaidItem::Syncer.new(@item).perform_sync(second_sync)
    assert_empty credit.reload.raw_liabilities_payload
    assert_equal 25, credit.current_account.accountable.minimum_payment
    assert_equal 1, second_sync.reload.sync_stats.fetch("data_warnings")
    @provider.liabilities_error = nil
    @item.reload
    third_sync = @item.syncs.create!(status: :syncing)
    PlaidItem::Syncer.new(@item).perform_sync(third_sync)
    assert_equal 0, third_sync.reload.sync_stats.fetch("data_warnings")
    assert_empty third_sync.sync_stats.fetch("data_quality_details")
    assert_equal 2, @item.plaid_accounts.count
    assert_equal 2, @family.accounts.count
    assert_equal 2, @family.entries.where(entryable_type: "Transaction").count
    assert_equal 3, @provider.liability_calls
  end

  def test_authentication_errors_still_propagate_from_snapshot
    ["ITEM_LOGIN_REQUIRED", "INVALID_ACCESS_TOKEN", "INVALID_API_KEYS"].each do |code|
      @provider.liabilities_error = Plaid::ApiError.new(code: 400, response_body: {error_code: code}.to_json)
      snapshot = PlaidItem::AccountsSnapshot.new(@item, plaid_provider: @provider)
      assert_raises(Plaid::ApiError) { snapshot.get_account_data("synthetic-credit") }
      assert_empty snapshot.warnings
    end
  end

  def test_accounts_and_transactions_errors_still_abort_import
    @provider.transactions_error = Plaid::ApiError.new(code: 500, response_body: {error_code: "INTERNAL_SERVER_ERROR"}.to_json)
    assert_raises(Plaid::ApiError) { import }
    assert_equal 0, @item.plaid_accounts.count
    assert_nil @item.reload.next_cursor
    @provider.transactions_error = nil
    @provider.accounts_error = @provider.liabilities_error
    assert_raises(Plaid::ApiError) { import }
    assert_equal 0, @item.plaid_accounts.count
  end

  def test_login_error_marks_reconnect_and_propagates_through_full_sync_without_processing
    # Both banks currently fail authentication before a fresh account snapshot.
    error = Plaid::ApiError.new(code: 400, response_body: {error_code: "ITEM_LOGIN_REQUIRED"}.to_json)
    @provider.accounts_error = error
    sync = @item.syncs.create!(status: :syncing)
    @item.define_singleton_method(:process_accounts) { raise "Must not process after login failure" }
    caught = assert_raises(Plaid::ApiError) { PlaidItem::Syncer.new(@item).perform_sync(sync) }
    assert_same error, caught
    assert @item.reload.requires_update?
    assert_equal 0, @item.plaid_accounts.count
    assert_equal 0, @family.entries.count
    assert_nil @item.next_cursor
    assert_equal 1, sync.reload.sync_stats.fetch("total_errors")
  end

  def test_login_error_preserves_original_error_in_warning_pipeline
    error = Plaid::ApiError.new(code: 400, response_body: {error_code: "ITEM_LOGIN_REQUIRED"}.to_json)
    @provider.accounts_error = error
    sync = @item.syncs.create!(status: :syncing)
    caught = assert_raises(Plaid::ApiError) { PlaidItem::Syncer.new(@item).perform_sync(sync) }
    assert_same error, caught
    assert @item.reload.requires_update?
    assert_equal 1, sync.reload.sync_stats.fetch("total_errors")
  end

  def test_successful_import_clears_reconnect_after_authentication_is_restored
    @item.update!(status: :requires_update)
    @provider.liabilities_error = nil
    assert_empty import
    assert @item.reload.good?
  end

  def test_liabilities_login_error_remains_fatal_in_full_sync
    error = Plaid::ApiError.new(code: 400, response_body: {error_code: "ITEM_LOGIN_REQUIRED"}.to_json)
    @provider.liabilities_error = error
    sync = @item.syncs.create!(status: :syncing)
    caught = assert_raises(Plaid::ApiError) { PlaidItem::Syncer.new(@item).perform_sync(sync) }
    assert_same error, caught
    assert @item.reload.requires_update?
    assert_equal 0, @item.plaid_accounts.count
    assert_equal 0, @family.entries.count
    assert_nil @item.next_cursor
  end

  def test_item_and_family_forward_only_explicit_consent_products
    captured = []
    provider = Object.new
    provider.define_singleton_method(:get_link_token) do |**kwargs|
      captured << kwargs
      OpenStruct.new(link_token: "synthetic-link-token")
    end
    family = @item.family
    family.define_singleton_method(:plaid) { |_region| provider }
    @item.define_singleton_method(:family) { family }
    args = {webhooks_url: "https://example.invalid/webhooks", redirect_url: "https://example.invalid/accounts"}
    assert_equal "synthetic-link-token", @item.get_update_link_token(**args)
    assert_empty captured.last.fetch(:additional_consented_products)
    assert_equal "synthetic-link-token", @item.get_update_link_token(**args,
      account_selection_enabled: true, additional_consented_products: ["liabilities"])
    assert_equal ["liabilities"], captured.last.fetch(:additional_consented_products)
    assert captured.last.fetch(:account_selection_enabled)
    assert_equal @item.access_token, captured.last.fetch(:access_token)
  end

  def test_unrelated_programming_error_is_not_hidden
    @provider.liabilities_error = RuntimeError.new("synthetic coding error")
    assert_raises(RuntimeError) { import }
    assert_equal 0, @item.plaid_accounts.count
  end

  def test_non_json_liabilities_api_error_can_be_reported_without_raw_payload
    @provider.liabilities_error = Plaid::ApiError.new(code: 502, response_body: "DO_NOT_COPY_RAW_PROVIDER_MESSAGE")
    warnings = import
    assert_equal 2, @item.plaid_accounts.count
    assert_equal 1, warnings.size
    refute_includes warnings.to_json, "DO_NOT_COPY_RAW_PROVIDER_MESSAGE"
  end
  def set_products(billed:, consented:)
    @provider.define_singleton_method(:get_item) do |_token|
      OpenStruct.new(item: Plaid::Item.new(item_id: "synthetic-item", institution_id: "synthetic-institution",
        available_products: ["liabilities"], billed_products: billed, consented_products: consented))
    end
  end

  def test_no_liabilities_call_without_consent
    set_products(billed: ["transactions"], consented: ["transactions"])
    PlaidItem::Syncer.new(@item).perform_sync(@item.syncs.create!(status: :syncing))
    assert_equal 0, @provider.liability_calls
    assert_equal 2, @family.accounts.count
  end

  def test_optional_unsupported_liabilities_do_not_block_import
    set_products(billed: ["transactions"], consented: %w[transactions liabilities])
    @provider.liabilities_error = Plaid::ApiError.new(code: 400, response_body: {error_code: "PRODUCTS_NOT_SUPPORTED"}.to_json)
    PlaidItem::Syncer.new(@item).perform_sync(@item.syncs.create!(status: :syncing))
    assert_equal 2, @family.accounts.count
    assert_equal 2, @family.entries.where(entryable_type: "Transaction").count
    assert_equal 1, @provider.liability_calls
  end

  def test_missing_new_liabilities_preserves_domain_terms_without_replaying_old_raw_snapshot
    @provider.liabilities_error = nil
    PlaidItem::Syncer.new(@item).perform_sync(@item.syncs.create!(status: :syncing))
    credit = @item.plaid_accounts.find_by!(plaid_id: "synthetic-credit")
    details = credit.current_account.accountable
    assert_equal 25, details.minimum_payment
    details.update!(minimum_payment: 39)
    set_products(billed: ["transactions"], consented: ["transactions"])
    @item.reload # Each real SyncJob loads its Item afresh.
    PlaidItem::Syncer.new(@item).perform_sync(@item.syncs.create!(status: :syncing))
    assert_equal 39, details.reload.minimum_payment
    assert_empty credit.reload.raw_liabilities_payload
  end


  def test_edit_controller_requests_only_explicit_allowlisted_consent
    controller = PlaidItemsController.new
    controller.instance_variable_set(:@plaid_item, @item)
    controller.define_singleton_method(:plaid_us_webhooks_url) { "https://example.invalid/webhook" }
    controller.define_singleton_method(:accounts_url) { "https://example.invalid/accounts" }
    captured = []
    @item.define_singleton_method(:get_update_link_token) { |**args| captured << args; "synthetic-link" }
    controller.params = ActionController::Parameters.new
    controller.edit
    assert_empty captured.last.fetch(:additional_consented_products)
    refute captured.last.fetch(:account_selection_enabled)
    controller.params = ActionController::Parameters.new(add_accounts: "true", consent_products: ["liabilities", "unknown", "liabilities"])
    controller.edit
    assert_equal ["liabilities"], captured.last.fetch(:additional_consented_products)
    assert captured.last.fetch(:account_selection_enabled)
  end

  def test_partial_failure_does_not_replay_a_variable_mortgage_rate
    @provider.liabilities_error = nil
    PlaidItem::Syncer.new(@item).perform_sync(@item.syncs.create!(status: :syncing))
    pa = @item.plaid_accounts.find_by!(plaid_id: "synthetic-credit")
    account = pa.current_account
    account.update!(accountable: Loan.new(rate_type: "variable", interest_rate: 4.5, start_date: Date.new(2020,1,1)))
    pa.update!(plaid_type: "loan", plaid_subtype: "mortgage", raw_liabilities_payload: {
      "mortgage" => {"interest_rate" => {"type" => "variable", "percentage" => 5.2}}
    })
    reader = @provider.method(:get_item_accounts)
    @provider.define_singleton_method(:get_item_accounts) do |token|
      result = reader.call(token)
      result.accounts.last.type = "loan"
      result.accounts.last.subtype = "mortgage"
      result
    end
    loan = account.reload.loan
    prior = loan.variable_rate_schedule.deep_dup
    @item.reload
    @provider.liabilities_error = FakeProvider.new.liabilities_error
    PlaidItem::Syncer.new(@item).perform_sync(@item.syncs.create!(status: :syncing))
    assert_empty pa.reload.raw_liabilities_payload
    assert_equal prior, loan.reload.variable_rate_schedule
    assert_equal 4.5, loan.interest_rate.to_f
  end

  def test_http401_liabilities_is_fatal_even_without_known_error_code
    @provider.liabilities_error = Plaid::ApiError.new(code: 401, response_body: {error_code: "UNKNOWN_AUTH"}.to_json)
    assert_raises(Plaid::ApiError) { import }
    assert_equal 0, @item.plaid_accounts.count
  end

  def test_core_non_json_error_keeps_original_provider_exception
    error = Plaid::ApiError.new(code: 502, response_body: "synthetic non-JSON core error")
    @provider.accounts_error = error
    assert_same error, assert_raises(Plaid::ApiError) { import }
  end

end
