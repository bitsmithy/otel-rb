# frozen_string_literal: true

require 'opentelemetry/sdk'
require 'logger'

RSpec.describe Telemetry::TraceFormatter do
  let(:formatter) { described_class.new }

  context 'when no span is active' do
    it 'formats without trace suffix' do
      output = formatter.call('INFO', Time.now, 'app', 'hello')
      expect(output).not_to include('trace_id=')
      expect(output).not_to include('span_id=')
    end
  end

  context 'when a span is active' do
    let(:tracer_provider) { OpenTelemetry::SDK::Trace::TracerProvider.new }
    let(:tracer)          { tracer_provider.tracer('test') }

    it 'appends trace_id and span_id to the log line' do
      tracer.in_span('test-span') do
        output = formatter.call('INFO', Time.now, 'app', 'hello')
        expect(output).to match(/trace_id=[0-9a-f]{32}/)
        expect(output).to match(/span_id=[0-9a-f]{16}/)
      end
    end

    it 'does not append trace info after the span ends' do
      tracer.in_span('test-span') {} # span finished
      output = formatter.call('INFO', Time.now, 'app', 'hello')
      expect(output).not_to include('trace_id=')
    end
  end
end
