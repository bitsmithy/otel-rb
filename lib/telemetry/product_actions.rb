# frozen_string_literal: true

module Telemetry
  class ProductActions
    ACTION_COUNT = 'app.user.action.count'
    AFFECTED_ITEMS = 'app.user.action.affected_items'
    EVENT_NAME = 'app.user.action'
    ACTORS = %w[anonymous cook guest].freeze
    OUTCOMES = %w[error rejected success].freeze
    VARIANTS = %w[all apple email empty google import passkey starter write].freeze
    OPTIONS = %i[actor outcome changed variant affected_items error_type].freeze
    ACTION_NAME_PATTERN = /\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+\z/

    attr_reader :meter

    def initialize(meter)
      @meter = meter
      @action_count = meter&.create_counter(ACTION_COUNT, unit: '{action}', description: 'Product Actions')
      @affected_items = meter&.create_histogram(
        AFFECTED_ITEMS, unit: '{item}', description: 'Items affected by one Product Action'
      )
    end

    def record(name, **options)
      validate_options!(options)
      affected_items = options[:affected_items]
      validate_affected_items!(affected_items)
      attributes = attributes_for(name, options)
      @action_count&.add(1, attributes: attributes)
      @affected_items&.record(affected_items, attributes: attributes) if affected_items
      span = OpenTelemetry::Trace.current_span
      span.add_event(EVENT_NAME, attributes: attributes) if span.recording?
      nil
    rescue ConfigurationError
      raise
    rescue StandardError => e
      warn "[Telemetry] Product Action recording failed (#{e.class})"
      nil
    end

    private

    def validate_options!(options)
      unknown_options = options.keys - OPTIONS
      raise ConfigurationError, "unknown Product Action options: #{unknown_options.join(', ')}" if unknown_options.any?

      options.fetch(:actor)
      options.fetch(:outcome)
    end

    def validate_affected_items!(affected_items)
      return if affected_items.nil? || (affected_items.is_a?(Integer) && affected_items.positive?)

      raise ConfigurationError, 'Product Action affected_items must be a positive integer or nil'
    end

    def attributes_for(name, options)
      validate_name!(name)
      validate_actor!(options.fetch(:actor))
      validate_outcome!(options.fetch(:outcome))
      validate_changed!(options[:changed])
      validate_variant!(options[:variant])

      {
        'app.user.action.name' => name,
        'app.user.type' => options.fetch(:actor),
        'app.user.action.outcome' => options.fetch(:outcome),
        'app.user.action.changed' => options[:changed],
        'app.user.action.variant' => options[:variant],
        'error.type' => options[:error_type]
      }.compact
    end

    def validate_name!(name)
      raise ConfigurationError, "invalid Product Action name: #{name}" unless ACTION_NAME_PATTERN.match?(name)
    end

    def validate_actor!(actor)
      raise ConfigurationError, "invalid Product Action actor: #{actor}" unless ACTORS.include?(actor)
    end

    def validate_outcome!(outcome)
      raise ConfigurationError, "invalid Product Action outcome: #{outcome}" unless OUTCOMES.include?(outcome)
    end

    def validate_changed!(changed)
      return if changed.nil? || changed == true || changed == false

      raise ConfigurationError, 'Product Action changed must be true, false, or nil'
    end

    def validate_variant!(variant)
      return if variant.nil? || VARIANTS.include?(variant)

      raise ConfigurationError, "invalid Product Action variant: #{variant}"
    end
  end
end
