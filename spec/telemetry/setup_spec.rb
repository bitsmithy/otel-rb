# frozen_string_literal: true

require 'opentelemetry/sdk'

RSpec.describe Telemetry::Setup do
  let(:config) { Telemetry::Config.new(service_name: 'test-service') }
  subject(:result) { described_class.call(config) }

  it 'returns a shutdown proc' do
    expect(result[:shutdown]).to be_a(Proc)
  end

  it 'returns a tracer' do
    expect(result[:tracer]).to respond_to(:in_span)
  end

  it 'sets the global tracer provider' do
    result
    expect(OpenTelemetry.tracer_provider).not_to be_a(OpenTelemetry::Internal::ProxyTracerProvider)
  end

  it 'sets the W3C composite propagator' do
    result
    expect(OpenTelemetry.propagation).to be_a(OpenTelemetry::Context::Propagation::CompositeTextMapPropagator)
  end

  context 'with explicit endpoint' do
    let(:config) { Telemetry::Config.new(service_name: 'test-service', endpoint: 'http://localhost:4318') }

    it 'does not raise during setup (exporter is lazy)' do
      expect { result }.not_to raise_error
    end
  end

  context 'when metrics SDK is unavailable' do
    it 'returns nil meter gracefully' do
      # Hide MeterProvider so setup_metrics raises NameError, which falls through to nil
      allow(OpenTelemetry::SDK::Metrics::MeterProvider).to receive(:new).and_raise(LoadError)
      expect(result[:meter]).to be_nil
    end
  end

  describe 'shutdown proc' do
    it 'calls shutdown on the tracer provider' do
      tracer_provider = instance_double(
        OpenTelemetry::SDK::Trace::TracerProvider,
        shutdown: nil,
        add_span_processor: nil,
        tracer: double(in_span: nil)
      )
      allow(OpenTelemetry::SDK::Trace::TracerProvider).to receive(:new).and_return(tracer_provider)
      result[:shutdown].call
      expect(tracer_provider).to have_received(:shutdown)
    end
  end
end
