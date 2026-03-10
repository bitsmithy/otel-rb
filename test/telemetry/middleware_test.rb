# frozen_string_literal: true

require 'test_helper'
require 'rack/test'
require 'rack/mock_request'

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

  def app = @middleware

  def finished_spans = @exporter.finished_spans

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
end
