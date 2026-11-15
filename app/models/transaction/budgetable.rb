module Transaction::Budgetable
  extend ActiveSupport::Concern

  included do
    validates :budget_inclusion, inclusion: { in: %w[category include exclude] }
    scope :included_in_budget, -> {
      where(Arel.sql(budget_inclusion_sql)).where.not(kind: Transaction::BUDGET_EXCLUDED_KINDS)
    }
  end

  class_methods do
    def budget_inclusion_sql(table = "transactions")
      raise ArgumentError, "Invalid SQL alias" unless /\A[a-z_]+\z/.match?(table)

      "COALESCE(#{table}.budget_included, " \
        "(SELECT budget_category.budget_default_included FROM categories budget_category " \
        "WHERE budget_category.id = #{table}.category_id), TRUE)"
    end
  end

  def budget_inclusion
    @invalid_budget_inclusion || (budget_included.nil? ? "category" : budget_included ? "include" : "exclude")
  end

  def budget_inclusion=(value)
    @invalid_budget_inclusion = nil
    case value
    when nil, "", "category" then self.budget_included = nil
    when "include" then self.budget_included = true
    when "exclude" then self.budget_included = false
    else @invalid_budget_inclusion = value.to_s
    end
  end

  def included_in_budget?
    return false if Transaction::BUDGET_EXCLUDED_KINDS.include?(kind)

    budget_included.nil? ? category&.budget_default_included != false : budget_included
  end
end
