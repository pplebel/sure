class AddBudgetInclusionPreferences < ActiveRecord::Migration[8.1]
  def change
    add_column :categories, :budget_default_included, :boolean, default: true, null: false
    add_column :transactions, :budget_included, :boolean
  end
end
