# frozen_string_literal: true

require 'test_helper'
require 'rack/test'
require 'rack/mock_request'
require 'opentelemetry-metrics-sdk'

class MiddlewareTest < Minitest::Test
  include Rack::Test::Methods

  def setup
    @exporter  = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    @processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(@exporter)

    OpenTelemetry::SDK.configure do |c|
      c.add_span_processor(@processor)
    end

    Telemetry.reset!

    @tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new.tap do |tp|
      tp.add_span_processor(@processor)
    end
    OpenTelemetry.tracer_provider = @tracer_provider
    OpenTelemetry.propagation = OpenTelemetry::Context::Propagation::CompositeTextMapPropagator.compose_propagators(
      [OpenTelemetry::Trace::Propagation::TraceContext.text_map_propagator,
       OpenTelemetry::Baggage::Propagation::TextMapPropagator.new]
    )

    @tracer = @tracer_provider.tracer('test')
    # Inject tracer directly — Middleware reads Telemetry.tracer at request time
    Telemetry.instance_variable_set(:@tracer, @tracer)

    @inner_app  = ->(_env) { [200, { 'content-type' => 'text/plain' }, ['OK']] }
    @middleware = Telemetry::Middleware.new(@inner_app)
  end

  # Builds a fresh middleware wired to a real in-memory MeterProvider.
  # Returns [middleware, metric_exporter] so callers can read recorded data.
  def middleware_with_metrics(inner_app = @inner_app)
    metric_exporter = OpenTelemetry::SDK::Metrics::Export::InMemoryMetricPullExporter.new
    meter_provider  = OpenTelemetry::SDK::Metrics::MeterProvider.new
    meter_provider.add_metric_reader(metric_exporter)
    OpenTelemetry.meter_provider = meter_provider
    Telemetry.instance_variable_set(:@meter, meter_provider.meter('test'))

    [Telemetry::Middleware.new(inner_app), metric_exporter, meter_provider]
  end

  def app = @middleware

  def finished_spans = @exporter.finished_spans

  # --- Span behaviour ---

  def test_creates_span
    get '/users'
    assert_equal 1, finished_spans.length
  end

  def test_span_name_method_path
    get '/users'
    assert_equal 'GET /users', finished_spans.first.name
  end

  def test_span_name_uses_route_template
    inner = lambda { |env|
      env['action_dispatch.route_uri_pattern'] = '/users/:id'
      [200, {}, ['OK']]
    }
    Rack::MockRequest.new(Telemetry::Middleware.new(inner)).get('/users/42')
    assert_equal 'GET /users/:id', finished_spans.first.name
  end

  def test_response_status_attribute
    get '/users'
    assert_equal 200, finished_spans.first.attributes['http.response.status_code']
  end

  def test_request_method_span_attribute
    get '/users'
    assert_equal 'GET', finished_spans.first.attributes['http.request.method']
  end

  def test_route_span_attribute
    get '/users'
    assert_equal '/users', finished_spans.first.attributes['http.route']
  end

  def test_server_address_span_attribute
    get '/users'
    refute_nil finished_spans.first.attributes['server.address']
  end

  def test_server_port_span_attribute
    get '/users'
    refute_nil finished_spans.first.attributes['server.port']
  end

  def test_4xx_not_error
    inner_404 = ->(_env) { [404, {}, ['Not Found']] }
    Rack::MockRequest.new(Telemetry::Middleware.new(inner_404)).get('/missing')
    refute_equal OpenTelemetry::Trace::Status::ERROR, finished_spans.first.status.code
  end

  def test_5xx_is_error
    inner_500 = ->(_env) { [500, {}, ['Error']] }
    Rack::MockRequest.new(Telemetry::Middleware.new(inner_500)).get('/boom')
    assert_equal OpenTelemetry::Trace::Status::ERROR, finished_spans.first.status.code
  end

  def test_w3c_propagation
    traceparent = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
    get '/users', {}, { 'HTTP_TRACEPARENT' => traceparent }
    assert_equal '4bf92f3577b34da6a3ce929d0e0e4736', finished_spans.first.hex_trace_id
  end

  # --- Metric instrument calls do not raise ---
  # These guard against incorrect attribute passing (e.g. **splat vs attributes: keyword).

  def test_metrics_do_not_raise_on_successful_request
    mw, = middleware_with_metrics
    assert_silent { Rack::MockRequest.new(mw).get('/ping') }
  end

  def test_metrics_do_not_raise_on_4xx
    inner_404 = ->(_env) { [404, {}, ['Not Found']] }
    mw, = middleware_with_metrics(inner_404)
    assert_silent { Rack::MockRequest.new(mw).get('/missing') }
  end

  def test_metrics_do_not_raise_on_5xx
    inner_500 = ->(_env) { [500, {}, ['Error']] }
    mw, = middleware_with_metrics(inner_500)
    assert_silent { Rack::MockRequest.new(mw).get('/boom') }
  end

  # --- Metric data points are recorded with correct attributes ---

  def test_request_count_metric_recorded
    mw, _exporter, meter_provider = middleware_with_metrics
    Rack::MockRequest.new(mw).get('/ping')

    streams = metric_streams(meter_provider)
    count_stream = streams.find { |s| s.instance_variable_get(:@name) == Telemetry::Middleware::HTTP_SERVER_REQUEST_COUNT }
    refute_nil count_stream, 'http.server.request.count stream not found'

    data_points = count_stream.instance_variable_get(:@data_points)
    assert_equal 1, data_points.length
    attrs = data_points.keys.first
    assert_equal 'GET', attrs['http.request.method']
    assert_equal '/ping', attrs['http.route']
    assert_equal '200', attrs['http.response.status_code']
  end

  def test_request_duration_metric_recorded
    mw, _exporter, meter_provider = middleware_with_metrics
    Rack::MockRequest.new(mw).get('/ping')

    streams = metric_streams(meter_provider)
    dur_stream = streams.find { |s| s.instance_variable_get(:@name) == Telemetry::Middleware::HTTP_SERVER_REQUEST_DURATION }
    refute_nil dur_stream, 'http.server.request.duration stream not found'

    data_points = dur_stream.instance_variable_get(:@data_points)
    assert_equal 1, data_points.length
    attrs = data_points.keys.first
    assert_equal 'GET', attrs['http.request.method']
  end

  def test_request_duration_recorded_in_milliseconds
    inner = lambda { |_env|
      sleep 0.05
      [200, {}, ['OK']]
    }
    mw, _exporter, meter_provider = middleware_with_metrics(inner)
    Rack::MockRequest.new(mw).get('/ping')

    streams = metric_streams(meter_provider)
    dur_stream = streams.find { |s| s.instance_variable_get(:@name) == Telemetry::Middleware::HTTP_SERVER_REQUEST_DURATION }
    data_point = dur_stream.instance_variable_get(:@data_points).values.first

    assert_in_delta 50, data_point.sum, 25
  end

  def test_controller_and_action_attributes_on_rails_request
    inner = lambda { |env|
      env[Telemetry::Middleware::PATH_PARAMETERS_KEY] = { controller: 'users', action: 'show' }
      [200, {}, ['OK']]
    }
    mw, _exporter, meter_provider = middleware_with_metrics(inner)
    Rack::MockRequest.new(mw).get('/users/1')

    streams = metric_streams(meter_provider)
    dur_stream = streams.find { |s| s.instance_variable_get(:@name) == Telemetry::Middleware::HTTP_SERVER_REQUEST_DURATION }
    attrs = dur_stream.instance_variable_get(:@data_points).keys.first
    assert_equal 'users', attrs['rails.controller']
    assert_equal 'show',  attrs['rails.action']
  end

  def test_controller_and_action_absent_outside_rails
    # No PATH_PARAMETERS_KEY set — non-Rails Rack app
    mw, _exporter, meter_provider = middleware_with_metrics
    Rack::MockRequest.new(mw).get('/ping')

    streams = metric_streams(meter_provider)
    dur_stream = streams.find { |s| s.instance_variable_get(:@name) == Telemetry::Middleware::HTTP_SERVER_REQUEST_DURATION }
    attrs = dur_stream.instance_variable_get(:@data_points).keys.first
    refute attrs.key?('rails.controller'), 'rails.controller should be absent without Rails routing'
    refute attrs.key?('rails.action'),     'rails.action should be absent without Rails routing'
  end

  def test_active_requests_metric_recorded
    mw, _exporter, meter_provider = middleware_with_metrics
    Rack::MockRequest.new(mw).get('/ping')

    streams = metric_streams(meter_provider)
    active_stream = streams.find { |s| s.instance_variable_get(:@name) == Telemetry::Middleware::HTTP_SERVER_ACTIVE_REQUESTS }
    refute_nil active_stream, 'http.server.active_requests stream not found'

    data_points = active_stream.instance_variable_get(:@data_points)
    assert_equal 1, data_points.length
    attrs = data_points.keys.first
    assert_equal 'GET', attrs['http.request.method']
  end

  private

  # Walk the MeterProvider's internal registry to collect all MetricStream objects.
  def metric_streams(meter_provider)
    meter_provider
      .instance_variable_get(:@meter_registry)
      .values
      .flat_map { |meter| meter.instance_variable_get(:@instrument_registry).values }
      .flat_map { |instrument| instrument.instance_variable_get(:@metric_streams) }
  end
end
