# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/reporters'
require 'opentelemetry/sdk'
require 'telemetry'

Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new

# One call disables at_exit and installs auto-reset before every test.
Telemetry.test_mode!

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
