# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'telemetry/test'

# Per-test OTel isolation: reset the SDK and re-run Telemetry.setup so each
# test starts with fresh tracer/meter/logger state.
Minitest::Test.prepend(Module.new do
  def before_setup
    OpenTelemetry::SDK.configure
    Telemetry.setup
    super
  end
end)

module Minitest
  class Test
    private

    def stub_const(name, value)
      was_defined = Object.const_defined?(name)
      Object.const_set(name, value)
      yield
    ensure
      Object.send(:remove_const, name) if Object.const_defined?(name) && !was_defined
    end
  end
end
