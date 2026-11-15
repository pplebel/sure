class Transactions::ReviewsController < ApplicationController
  before_action :require_non_guest!

  def create
    data = params.require(:review).permit(:reviewed, entry_ids: [])
    return head(:unprocessable_entity) unless %w[0 1].include?(data[:reviewed])

    ids = Array(data[:entry_ids]).map(&:to_s).uniq
    return head(:unprocessable_entity) unless ids.size.between?(1, 1000)

    eligible = Current.family.entries.transactions.excluding_split_parents
                      .where(account_id: Account.writable_by(Current.user).select(:id))
    Entry.transaction do
      entries = eligible.where(id: ids).order(:id).lock.to_a
      raise ActiveRecord::RecordNotFound unless entries.size == ids.size

      at = data[:reviewed] == "1" ? Time.current : nil
      entries.each { |entry| entry.update!(reviewed_at: at) }
    end
    redirect_to review_return_path, status: :see_other,
      notice: "#{ids.size} #{ids.one? ? 'transaction' : 'transactions'} marked #{data[:reviewed] == '1' ? 'reviewed' : 'as needing review'}."
  end

  private
    # A standalone drawer URL has no ledger behind it. Return to a real list
    # instead of revisiting a drawer Turbo has just closed.
    def review_return_path
      uri = URI.parse(request.referer.to_s)
      if uri.path == transactions_path || %r{\A/accounts/[0-9a-f-]{36}\z}.match?(uri.path.to_s)
        uri.request_uri
      else
        transactions_path
      end
    rescue URI::InvalidURIError
      transactions_path
    end
end
