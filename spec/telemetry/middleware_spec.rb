# frozen_string_literal: true

require 'rack/test'
require 'opentelemetry/sdk'

RSpec.describe Telemetry::Middleware do
  include Rack::Test::Methods

  # Set up in-memory span exporter
  let(:exporter)  { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:processor) { OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter) }

  let(:tracer_provider) do
    OpenTelemetry::SDK::Trace::TracerProvider.new.tap { |tp| tp.add_span_processor(processor) }
  end
  let(:tracer) { tracer_provider.tracer('test') }
  let(:meter)  { nil } # metrics tested separately

  let(:inner_app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['OK']] } }
  let(:app)       { described_class.new(inner_app, tracer, meter) }

  def finished_spans = exporter.finished_spans

  it 'creates a span for each request' do
    get '/users'
    expect(finished_spans.length).to eq(1)
  end

  it 'names the span METHOD PATH' do
    get '/users'
    expect(finished_spans.first.name).to eq('GET /users')
  end

  it 'uses route template when action_dispatch key is present' do
    inner = lambda { |env|
      env['action_dispatch.route_uri_pattern'] = '/users/:id'
      [200, {}, ['OK']]
    }
    Rack::MockRequest.new(described_class.new(inner, tracer, meter)).get('/users/42')
    expect(finished_spans.first.name).to eq('GET /users/:id')
  end

  it 'sets http.response.status_code attribute' do
    get '/users'
    expect(finished_spans.first.attributes['http.response.status_code']).to eq(200)
  end

  it 'does not mark 4xx responses as span errors' do
    inner_404 = ->(_env) { [404, {}, ['Not Found']] }
    Rack::MockRequest.new(described_class.new(inner_404, tracer, meter)).get('/missing')
    expect(finished_spans.first.status.code).not_to eq(OpenTelemetry::Trace::Status::ERROR)
  end

  it 'marks 5xx responses as span errors' do
    inner_500 = ->(_env) { [500, {}, ['Error']] }
    Rack::MockRequest.new(described_class.new(inner_500, tracer, meter)).get('/boom')
    expect(finished_spans.first.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
  end

  it 'propagates W3C traceparent header into span context' do
    traceparent = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
    get '/users', {}, { 'HTTP_TRACEPARENT' => traceparent }
    span = finished_spans.first
    expect(span.hex_trace_id).to eq('4bf92f3577b34da6a3ce929d0e0e4736')
  end
end
