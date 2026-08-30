# frozen_string_literal: true

module Telemetry
  class ProductActionCatalog
    Definition = Data.define(:name, :actor, :condition, :outcome, :changed, :variant, :affected_items)
    ACTION_OPTIONS = %i[name actor condition outcome changed variant affected_items].freeze

    attr_reader :definitions, :exclusions

    def initialize
      @definitions = {}
      @exclusions = {}
    end

    def action(controller_action, **options)
      validate_controller_action!(controller_action)
      ensure_unclassified!(controller_action)
      validate_action_options!(options)
      @definitions[controller_action] = Definition.new(
        name: options.fetch(:name),
        actor: options.fetch(:actor),
        condition: options[:condition],
        outcome: options[:outcome],
        changed: options[:changed],
        variant: options[:variant],
        affected_items: options[:affected_items]
      )
    end

    def exclude(controller_action, reason:)
      validate_controller_action!(controller_action)
      ensure_unclassified!(controller_action)
      raise ConfigurationError, 'Product Action exclusion reason is required' if reason.to_s.empty?

      @exclusions[controller_action] = reason
    end

    def classified?(controller_action)
      definitions.key?(controller_action) || exclusions.key?(controller_action)
    end

    def resolve(payload)
      definition = definitions[controller_action(payload)]
      return unless definition
      return if definition.condition && !definition.condition.call(payload)

      {
        name: resolve_value(definition.name, payload),
        actor: resolve_value(definition.actor, payload),
        outcome: resolve_value(definition.outcome, payload) || inferred_outcome(payload),
        changed: resolve_value(definition.changed, payload),
        variant: resolve_value(definition.variant, payload),
        affected_items: resolve_value(definition.affected_items, payload)
      }
    end

    private

    def controller_action(payload)
      "#{payload.fetch(:controller)}##{payload.fetch(:action)}"
    end

    def inferred_outcome(payload)
      return 'error' if payload[:exception_object] || payload.fetch(:status, 200) >= 500
      return 'rejected' if payload.fetch(:status, 200) >= 400

      'success'
    end

    def resolve_value(value, payload)
      value.respond_to?(:call) ? value.call(payload) : value
    end

    def validate_controller_action!(controller_action)
      return if controller_action.match?(/\A[A-Z][A-Za-z0-9:]*Controller#[a-z][a-z0-9_]*\z/)

      raise ConfigurationError, "invalid controller action: #{controller_action}"
    end

    def ensure_unclassified!(controller_action)
      return unless classified?(controller_action)

      raise ConfigurationError, "duplicate Product Action classification: #{controller_action}"
    end

    def validate_action_options!(options)
      unknown_options = options.keys - ACTION_OPTIONS
      raise ConfigurationError, "unknown Product Action options: #{unknown_options.join(', ')}" if unknown_options.any?

      validate_static_name!(options.fetch(:name))
      validate_static_actor!(options.fetch(:actor))
      validate_static_outcome!(options[:outcome])
      validate_static_changed!(options[:changed])
      validate_static_variant!(options[:variant])
      validate_static_affected_items!(options[:affected_items])
    end

    def validate_static_name!(name)
      return if name.respond_to?(:call) || ProductActions::ACTION_NAME_PATTERN.match?(name)

      raise ConfigurationError, "invalid Product Action name: #{name}"
    end

    def validate_static_actor!(actor)
      return if actor.respond_to?(:call) || ProductActions::ACTORS.include?(actor)

      raise ConfigurationError, "invalid Product Action actor: #{actor}"
    end

    def validate_static_outcome!(outcome)
      return if outcome.respond_to?(:call) || outcome.nil? || ProductActions::OUTCOMES.include?(outcome)

      raise ConfigurationError, "invalid Product Action outcome: #{outcome}"
    end

    def validate_static_changed!(changed)
      return if changed.respond_to?(:call) || changed.nil? || changed == true || changed == false

      raise ConfigurationError, 'Product Action changed must be true, false, or nil'
    end

    def validate_static_variant!(variant)
      return if variant.respond_to?(:call) || variant.nil? || ProductActions::VARIANTS.include?(variant)

      raise ConfigurationError, "invalid Product Action variant: #{variant}"
    end

    def validate_static_affected_items!(affected_items)
      return if affected_items.respond_to?(:call) || affected_items.nil? ||
                (affected_items.is_a?(Integer) && affected_items.positive?)

      raise ConfigurationError, 'Product Action affected_items must be a positive integer or nil'
    end
  end
end
