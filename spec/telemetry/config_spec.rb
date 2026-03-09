# frozen_string_literal: true

RSpec.describe Telemetry::Config do
  describe 'defaults' do
    subject(:config) { described_class.new }

    it 'sets service_name from $PROGRAM_NAME' do
      expect(config.service_name).to eq(File.basename($PROGRAM_NAME, '.*'))
    end

    it 'defaults log_level to :info' do
      expect(config.log_level).to eq(:info)
    end

    it 'leaves endpoint nil so OTEL env vars apply' do
      expect(config.endpoint).to be_nil
    end
  end

  describe 'explicit values' do
    subject(:config) do
      described_class.new(
        service_name: 'my-service',
        service_namespace: 'my-org',
        service_version: '1.2.3',
        endpoint: 'http://localhost:4318',
        log_level: :debug
      )
    end

    it 'stores all provided values' do
      expect(config.service_name).to      eq('my-service')
      expect(config.service_namespace).to eq('my-org')
      expect(config.service_version).to   eq('1.2.3')
      expect(config.endpoint).to          eq('http://localhost:4318')
      expect(config.log_level).to         eq(:debug)
    end
  end
end
