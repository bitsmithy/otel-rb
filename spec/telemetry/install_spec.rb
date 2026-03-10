# frozen_string_literal: true

require "opentelemetry/sdk"

RSpec.describe "Telemetry.install" do
  # Minimal Rails stub — no actual Rails dependency required.
  let(:middleware_stack) { double("middleware_stack") }
  let(:app_config)       { double("config", middleware: middleware_stack) }
  let(:rails_app)        { double("Rails.application", config: app_config) }
  let(:rails_logger)     { double("Rails.logger", formatter: nil, "formatter=" => nil) }

  let(:fake_rails) do
    Module.new do
      def self.application; end
      def self.logger;      end
    end
  end

  before do
    stub_const("Rails", fake_rails)
    allow(Rails).to receive(:application).and_return(rails_app)
    allow(Rails).to receive(:logger).and_return(rails_logger)
    allow(middleware_stack).to receive(:use)
  end

  let(:config) { Telemetry::Config.new(service_name: "test-service") }

  it "returns the result hash with tracer and shutdown" do
    result = Telemetry.install(config)
    expect(result[:tracer]).to respond_to(:in_span)
    expect(result[:shutdown]).to be_a(Proc)
  end

  it "inserts Telemetry::Middleware into the Rails middleware stack" do
    result = Telemetry.install(config)
    expect(middleware_stack).to have_received(:use).with(
      Telemetry::Middleware, result[:tracer], result[:meter]
    )
  end

  it "assigns TraceFormatter to Rails.logger.formatter" do
    Telemetry.install(config)
    expect(rails_logger).to have_received(:formatter=).with(an_instance_of(Telemetry::TraceFormatter))
  end

  context "when a non-TraceFormatter formatter is already set" do
    let(:existing_formatter) { double("CustomFormatter") }
    let(:rails_logger) { double("Rails.logger", formatter: existing_formatter, "formatter=" => nil) }

    before { allow(existing_formatter).to receive(:class).and_return("CustomFormatter") }

    it "warns about the replacement" do
      expect { Telemetry.install(config) }.to output(/replacing existing logger formatter/).to_stderr
    end
  end

  context "when formatter is nil" do
    it "does not warn" do
      expect { Telemetry.install(config) }.not_to output.to_stderr
    end
  end

  context "when formatter is already a TraceFormatter" do
    let(:rails_logger) do
      double("Rails.logger", formatter: Telemetry::TraceFormatter.new, "formatter=" => nil)
    end

    it "does not warn" do
      expect { Telemetry.install(config) }.not_to output.to_stderr
    end
  end
end
