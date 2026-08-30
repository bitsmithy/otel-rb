# frozen_string_literal: true

require 'opentelemetry-metrics-sdk'
require 'test_helper'

class ProductActionsTest < Minitest::Test
  def setup
    @span_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(@span_exporter)
    tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    tracer_provider.add_span_processor(processor)
    @meter_provider = OpenTelemetry::SDK::Metrics::MeterProvider.new
    @meter_provider.add_metric_reader(OpenTelemetry::SDK::Metrics::Export::InMemoryMetricPullExporter.new)

    Telemetry.instance_variable_set(:@tracer, tracer_provider.tracer('test'))
    Telemetry.instance_variable_set(:@meter, @meter_provider.meter('test'))
    Telemetry.configure_product_actions { nil }
    Telemetry::ControllerInstrumentation.install
  end

  def test_records_one_product_action_metric_and_span_event
    Telemetry.tracer.in_span('request') do
      Telemetry.action('recipe.import.request', actor: 'cook', outcome: 'success', changed: true)
    end

    assert_equal [1, ['app.user.action']], [action_count, @span_exporter.finished_spans.first.events.map(&:name)]
  end

  def test_records_only_the_bounded_product_action_attributes
    Telemetry.tracer.in_span('request') do
      Telemetry.action('recipe.import.request', actor: 'cook', outcome: 'success', changed: false)
    end
    event_attributes = @span_exporter.finished_spans.first.events.first.attributes

    expected = {
      'app.user.action.name' => 'recipe.import.request',
      'app.user.type' => 'cook',
      'app.user.action.outcome' => 'success',
      'app.user.action.changed' => false
    }

    assert_equal expected, event_attributes
  end

  def test_rejects_an_unknown_actor_before_recording
    assert_raises(Telemetry::ConfigurationError) do
      Telemetry.action('recipe.import.request', actor: 'operator', outcome: 'success')
    end
  end

  def test_bulk_action_records_one_action_and_its_affected_items
    Telemetry.action('shopping.purchase.mark', actor: 'cook', outcome: 'success', changed: true, affected_items: 10)

    assert_equal [1, 10], [action_count, affected_item_sum]
  end

  def test_action_wrapper_preserves_the_application_result
    result = Telemetry.action('recipe.import.request', actor: 'cook', outcome: 'success') do
      :application_result
    end

    assert_equal :application_result, result
  end

  def test_action_wrapper_records_and_preserves_the_application_exception
    error = RuntimeError.new('application failed')
    raised = assert_raises(RuntimeError) do
      Telemetry.action('recipe.import.request', actor: 'cook', outcome: 'success') { raise error }
    end

    assert_equal [error, 'error'], [raised, action_attributes.fetch('app.user.action.outcome')]
  end

  def test_rejects_a_nonpositive_affected_item_count
    assert_raises(Telemetry::ConfigurationError) do
      Telemetry.action('shopping.purchase.mark', actor: 'cook', outcome: 'success', affected_items: 0)
    end
  end

  def test_declarative_catalog_records_a_controller_product_action
    Telemetry.configure_product_actions do |catalog|
      catalog.action 'RecipesController#create', name: 'recipe.create', actor: 'cook'
    end
    ActiveSupport::Notifications.instrument(
      'process_action.action_controller', controller: 'RecipesController', action: 'create', status: 201
    ) { nil }

    assert_equal 'recipe.create', action_attributes.fetch('app.user.action.name')
  end

  def test_declarative_catalog_can_exclude_an_automatic_request
    Telemetry.configure_product_actions do |catalog|
      catalog.action(
        'RecipesController#update',
        name: 'recipe.update', actor: 'cook', condition: ->(payload) { payload.fetch(:format) != :json }
      )
    end
    ActiveSupport::Notifications.instrument(
      'process_action.action_controller', controller: 'RecipesController', action: 'update', status: 200, format: :json
    ) { nil }

    assert_equal false, action_recorded?
  end

  def test_declarative_catalog_rejects_an_unknown_static_actor
    assert_raises(Telemetry::ConfigurationError) do
      Telemetry.configure_product_actions do |catalog|
        catalog.action 'RecipesController#create', name: 'recipe.create', actor: 'operator'
      end
    end
  end

  def test_reports_explicit_action_exclusions_as_classified
    Telemetry.configure_product_actions do |catalog|
      catalog.exclude 'CookingParticipantPresencesController#update', reason: 'automatic heartbeat'
    end

    assert_equal true, Telemetry.product_action_classified?('CookingParticipantPresencesController#update')
  end

  def test_catalog_resolves_bounded_dynamic_action_values
    Telemetry.configure_product_actions do |catalog|
      catalog.action(
        'ShoppingContributionPurchasesController#create_all',
        name: ->(_) { 'shopping.purchase.mark' }, actor: ->(_) { 'cook' },
        changed: ->(_) { true }, affected_items: ->(payload) { payload.fetch(:affected_items) }
      )
    end
    ActiveSupport::Notifications.instrument(
      'process_action.action_controller',
      controller: 'ShoppingContributionPurchasesController', action: 'create_all', status: 200, affected_items: 4
    ) { nil }

    assert_equal ['shopping.purchase.mark', 4],
                 [action_attributes.fetch('app.user.action.name'), affected_item_sum]
  end

  private

  def action_count
    stream = metric_streams.find { |candidate| candidate.instance_variable_get(:@name) == 'app.user.action.count' }
    stream.instance_variable_get(:@data_points).values.first.value
  end

  def action_attributes
    stream = metric_streams.find { |candidate| candidate.instance_variable_get(:@name) == 'app.user.action.count' }
    stream.instance_variable_get(:@data_points).keys.first
  end

  def action_recorded?
    metric_streams.any? { |candidate| candidate.instance_variable_get(:@name) == 'app.user.action.count' }
  end

  def affected_item_sum
    stream = metric_streams.find do |candidate|
      candidate.instance_variable_get(:@name) == 'app.user.action.affected_items'
    end
    stream.instance_variable_get(:@data_points).values.first.sum
  end

  def metric_streams
    @meter_provider
      .instance_variable_get(:@meter_registry)
      .values
      .flat_map { |meter| meter.instance_variable_get(:@instrument_registry).values }
      .flat_map { |instrument| instrument.instance_variable_get(:@metric_streams) }
  end
end
