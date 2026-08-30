# frozen_string_literal: true

module Telemetry
  module ProductActionAPI
    # Replaces the declarative Rails Product Action catalog.
    def configure_product_actions
      @product_action_catalog = ProductActionCatalog.new
      yield @product_action_catalog if block_given?
      @product_action_catalog
    end

    # Reports whether a Rails controller action is tracked or explicitly excluded.
    def product_action_classified?(controller_action)
      product_action_catalog.classified?(controller_action)
    end

    # Records the configured Product Action for a completed Rails action.
    def record_configured_action(payload)
      definition = product_action_catalog.resolve(payload)
      action(definition.fetch(:name), **definition.except(:name)) if definition
    end

    # Records one deliberate user intent as a Product Action metric and span event.
    def action(name, actor:, outcome:, changed: nil, affected_items: nil)
      return product_actions.record(name, actor:, outcome:, changed:, affected_items:) unless block_given?

      result = yield
      product_actions.record(name, actor:, outcome:, changed:, affected_items:)
      result
    rescue StandardError => e
      product_actions.record(
        name, actor:, outcome: 'error', changed:, affected_items:, error_type: e.class.name
      )
      raise
    end

    private

    def product_actions
      raise NotSetupError, :action unless @meter

      @product_actions = ProductActions.new(@meter) unless @product_actions&.meter.equal?(@meter)
      @product_actions
    end

    def product_action_catalog
      @product_action_catalog ||= ProductActionCatalog.new
    end
  end
end
