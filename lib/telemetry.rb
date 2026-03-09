# frozen_string_literal: true

require 'telemetry/version'
require 'telemetry/config'
require 'telemetry/setup'
require 'telemetry/middleware'
require 'telemetry/trace_formatter'

# Telemetry — thin, opinionated OpenTelemetry setup for Ruby/Rails.
#
# Mirrors bitsmithy/go-otel: one call wires traces, metrics, and (optionally)
# logs over OTLP/HTTP and returns the handles you need.
#
# @example Minimal setup (all defaults, reads OTEL_* env vars)
#   result = Telemetry.setup
#   at_exit { result[:shutdown].call }
#
# @example Rails initializer (config/initializers/telemetry.rb)
#   result = Telemetry.setup(
#     Telemetry::Config.new(
#       service_name:      "our_neat_link",
#       service_namespace: "bitsmithy",
#       service_version:   ENV.fetch("GIT_COMMIT_SHA", "unknown"),
#     )
#   )
#   Rails.logger.formatter = Telemetry::TraceFormatter.new
#   at_exit { result[:shutdown].call }
#
#   # config/application.rb
#   config.middleware.use Telemetry::Middleware, result[:tracer], result[:meter]
module Telemetry
  # @param config [Telemetry::Config]
  # @return [Hash{Symbol => Object}] :shutdown (Proc), :tracer, :meter (nil if metrics unavailable)
  def self.setup(config = Config.new)
    Setup.call(config)
  end
end
