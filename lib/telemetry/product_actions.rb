# frozen_string_literal: true

module Telemetry
  class ProductActions
    ACTION_COUNT = 'app.user.action.count'
    AFFECTED_ITEMS = 'app.user.action.affected_items'
    EVENT_NAME = 'app.user.action'
    ACTORS = %w[anonymous cook guest].freeze
    OUTCOMES = %w[error rejected success].freeze
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
      actor = options.fetch(:actor)
      outcome = options.fetch(:outcome)
      changed = options[:changed]
      affected_items = options[:affected_items]
      validate_affected_items!(affected_items)
      attributes = attributes_for(name, actor, outcome, changed, options[:error_type])
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

    def validate_affected_items!(affected_items)
      return if affected_items.nil? || (affected_items.is_a?(Integer) && affected_items.positive?)

      raise ConfigurationError, 'Product Action affected_items must be a positive integer or nil'
    end

    def attributes_for(name, actor, outcome, changed, error_type)
      raise ConfigurationError, "invalid Product Action name: #{name}" unless ACTION_NAME_PATTERN.match?(name)
      raise ConfigurationError, "invalid Product Action actor: #{actor}" unless ACTORS.include?(actor)
      raise ConfigurationError, "invalid Product Action outcome: #{outcome}" unless OUTCOMES.include?(outcome)
      unless changed.nil? || changed == true || changed == false
        raise ConfigurationError, 'Product Action changed must be true, false, or nil'
      end

      {
        'app.user.action.name' => name,
        'app.user.type' => actor,
        'app.user.action.outcome' => outcome,
        'app.user.action.changed' => changed,
        'error.type' => error_type
      }.compact
    end
  end
end
