# Standalone tests use the installed SDK but never boot Rails or contact Plaid.
require "bundler/setup"
require "minitest/autorun"
require "active_support"
require "active_support/core_ext"
require "plaid"

module Rails
  def self.env
    ActiveSupport::StringInquirer.new("production")
  end
end
class Provider; end
load ENV.fetch("PROVIDER_SOURCE", "/rails/app/models/provider/plaid.rb")

class ConsentPayloadTest < Minitest::Test
  def payload(region: :us, **options)
    provider = Provider::Plaid.new(Plaid::Configuration.new, region: region)
    captured = nil
    provider.client.define_singleton_method(:link_token_create) do |request|
      captured = request.to_hash
      :synthetic_response
    end
    result = provider.get_link_token(
      user_id: "synthetic-user", webhooks_url: "https://example.com/webhooks",
      redirect_url: "https://example.com/accounts", **options
    )
    assert_equal :synthetic_response, result
    captured
  end

  def test_mixed_depository_connection_collects_liability_consent
    request = payload(accountable_type: "Depository")
    assert_equal ["transactions"], request[:products]
    assert_equal ["investments"], request[:additional_consented_products]
    assert_equal({days_requested: 730}, request[:transactions])
  end

  def test_investment_connection_keeps_only_investments_required
    request = payload(accountable_type: "Investment")
    assert_equal ["investments"], request[:products]
    assert_equal ["transactions"], request[:additional_consented_products]
    assert_empty request[:products] & request[:additional_consented_products]
  end

  def test_credit_card_optional_liabilities_and_loan_primary_liabilities
    card = payload(accountable_type: "CreditCard")
    assert_equal ["transactions"], card[:products]
    assert_equal ["liabilities"], card[:optional_products]
    assert_equal ["investments"], card[:additional_consented_products]
    loan = payload(accountable_type: "Loan")
    assert_equal ["liabilities"], loan[:products]
    assert_equal ["transactions", "investments"], loan[:additional_consented_products]
  end

  def test_reconnect_preserves_existing_item_without_requesting_new_products
    request = payload(access_token: "synthetic-existing-token")
    assert_equal "synthetic-existing-token", request[:access_token]
    refute request.key?(:additional_consented_products)
    refute request.key?(:products)
    refute request.key?(:transactions)
    refute request.key?(:update)
  end

  def test_add_accounts_keeps_account_selection_without_expanding_product_consent
    request = payload(access_token: "synthetic-existing-token", account_selection_enabled: true)
    assert_equal({account_selection_enabled: true}, request[:update])
    refute request.key?(:additional_consented_products)
    refute request.key?(:products)
    refute request.key?(:transactions)
  end

  def test_explicit_scotia_liabilities_upgrade_keeps_existing_item
    request = payload(access_token: "synthetic-scotia-token", additional_consented_products: ["liabilities"])
    assert_equal "synthetic-scotia-token", request[:access_token]
    assert_equal ["liabilities"], request[:additional_consented_products]
    refute request.key?(:products)
    refute request.key?(:transactions)
  end

  def test_explicit_consent_keeps_add_accounts_selection
    request = payload(access_token: "synthetic-token", account_selection_enabled: true,
      additional_consented_products: ["liabilities", "liabilities"])
    assert_equal({account_selection_enabled: true}, request[:update])
    assert_equal ["liabilities"], request[:additional_consented_products]
  end

  def test_explicit_unknown_product_is_rejected_before_client_call
    assert_raises(ArgumentError) do
      payload(access_token: "synthetic-token", additional_consented_products: ["unknown"])
    end
  end

  def test_european_flows_do_not_request_us_products
    request = payload(region: :eu, accountable_type: "CreditCard")
    assert_equal ["transactions"], request[:products]
    assert_empty request[:additional_consented_products]
    request = payload(region: :eu, access_token: "synthetic-eu-token")
    refute request.key?(:additional_consented_products)
    refute request.key?(:products)
  end

  def test_required_http_loopback_callback_suppression
    previous = ENV["PLAID_LOCAL_DESKTOP_TEST"]
    ENV["PLAID_LOCAL_DESKTOP_TEST"] = "1"
    %w[http://localhost:3000/accounts http://127.0.0.1:3000/webhooks http://[::1]:3000/accounts].each do |url|
      request = payload(access_token: "synthetic-token", webhooks_url: url, redirect_url: url)
      refute request.key?(:redirect_uri)
      refute request.key?(:webhook)
    end
  ensure
    ENV["PLAID_LOCAL_DESKTOP_TEST"] = previous
  end

  def test_https_external_and_opt_out_callbacks_are_retained
    previous = ENV["PLAID_LOCAL_DESKTOP_TEST"]
    ENV["PLAID_LOCAL_DESKTOP_TEST"] = "1"
    %w[https://localhost/accounts http://example.invalid/accounts https://example.invalid/accounts].each do |url|
      request = payload(access_token: "synthetic-token", webhooks_url: url, redirect_url: url)
      assert_equal url, request[:redirect_uri]
      assert_equal url, request[:webhook]
    end
    ENV.delete("PLAID_LOCAL_DESKTOP_TEST")
    url = "http://localhost:3000/accounts"
    assert_equal url, payload(access_token: "synthetic-token", redirect_url: url)[:redirect_uri]
  ensure
    ENV["PLAID_LOCAL_DESKTOP_TEST"] = previous
  end
end
