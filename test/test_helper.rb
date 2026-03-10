# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/reporters'
require 'opentelemetry/sdk'
require 'telemetry'

Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new

# One call disables at_exit and installs auto-reset before every test.
Telemetry.test_mode!
