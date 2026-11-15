# Personal review is independent of bank confirmation and statement matching.
# Database invalidation also covers rules/imports using update_all or bulk SQL.
class AddPersonalTransactionReview < ActiveRecord::Migration[8.1]
  def up
    add_column :entries, :reviewed_at, :datetime
    add_index :entries, :account_id, where: "reviewed_at IS NULL AND entryable_type = 'Transaction'", name: "idx_entries_needing_personal_review"
    execute <<~SQL
      CREATE FUNCTION sure_review_entry_changed() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF (OLD.entryable_type = 'Transaction' OR NEW.entryable_type = 'Transaction')
           AND ROW(NEW.account_id, NEW.date, NEW.amount, NEW.currency, NEW.name, NEW.entryable_id, NEW.entryable_type, NEW.excluded, NEW.parent_entry_id)
             IS DISTINCT FROM ROW(OLD.account_id, OLD.date, OLD.amount, OLD.currency, OLD.name, OLD.entryable_id, OLD.entryable_type, OLD.excluded, OLD.parent_entry_id) THEN
          NEW.reviewed_at := NULL;
        END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER sure_review_entry_changed BEFORE UPDATE ON entries
        FOR EACH ROW EXECUTE FUNCTION sure_review_entry_changed();
    SQL
    # Freeze the installed pending-flag semantics into this migration. Unrelated
    # sync metadata does not clear review; a pending/posted transition does.
    providers = %w[simplefin plaid lunchflow enable_banking akahu up monobank mercury redbark financekit]
    false_values = ['', '0', 'f', 'F', 'false', 'FALSE', 'off', 'OFF'].map { |v| connection.quote(v) }.join(', ')
    pending = ->(record) { '(' + providers.map { |p| "COALESCE(#{record}.extra -> '#{p}' ->> 'pending', '') NOT IN (#{false_values})" }.join(' OR ') + ')' }
    execute <<~SQL
      CREATE FUNCTION sure_review_transaction_changed() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF ROW(NEW.category_id, NEW.merchant_id, NEW.kind, NEW.budget_included)
             IS DISTINCT FROM ROW(OLD.category_id, OLD.merchant_id, OLD.kind, OLD.budget_included)
           OR #{pending.call('NEW')} IS DISTINCT FROM #{pending.call('OLD')} THEN
          UPDATE entries SET reviewed_at = NULL, updated_at = CURRENT_TIMESTAMP
            WHERE entryable_type = 'Transaction' AND entryable_id = NEW.id AND reviewed_at IS NOT NULL;
        END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER sure_review_transaction_changed AFTER UPDATE ON transactions
        FOR EACH ROW EXECUTE FUNCTION sure_review_transaction_changed();
    SQL
  end

  def down
    execute "DROP TRIGGER sure_review_transaction_changed ON transactions; DROP FUNCTION sure_review_transaction_changed();"
    execute "DROP TRIGGER sure_review_entry_changed ON entries; DROP FUNCTION sure_review_entry_changed();"
    remove_index :entries, name: "idx_entries_needing_personal_review"
    remove_column :entries, :reviewed_at
  end
end
