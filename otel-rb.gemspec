# frozen_string_literal: true

require_relative 'lib/telemetry/version'

Gem::Specification.new do |spec|
  spec.name          = 'otel-rb'
  spec.version       = Telemetry::VERSION
  spec.authors       = ['bitsmithy']
  spec.summary       = 'Thin, opinionated OpenTelemetry setup for Ruby/Rails'
  spec.description   = 'One-call OTLP/HTTP wiring for traces, metrics, and logs. ' \
                       'Rack middleware for HTTP instrumentation. ' \
                       'Logger formatter for trace-log correlation.'
  spec.homepage      = 'https://github.com/bitsmithy/otel-rb'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.2'

  spec.files         = Dir['lib/**/*', 'README.md', 'LICENSE']
  spec.require_paths = ['lib']

  # Ruby 4.0+ no longer bundles logger in default gems
  spec.add_dependency 'logger', '~> 1.6'

  # Core OTel — always required
  spec.add_dependency 'opentelemetry-api',           '~> 1.0'
  spec.add_dependency 'opentelemetry-exporter-otlp', '~> 0.28'
  spec.add_dependency 'opentelemetry-sdk',           '~> 1.0'

  # Metrics — declared as required; graceful LoadError in setup if somehow missing
  spec.add_dependency 'opentelemetry-exporter-otlp-metrics', '~> 0.1'
  spec.add_dependency 'opentelemetry-metrics-api',           '~> 0.1'
  spec.add_dependency 'opentelemetry-metrics-sdk',           '~> 0.1'

  # Semantic conventions
  spec.add_dependency 'opentelemetry-semantic_conventions', '~> 1.0'

  # Logs — intentionally NOT listed; loaded only if present at runtime

  spec.add_development_dependency 'minitest',           '~> 5.25'
  spec.add_development_dependency 'minitest-reporters', '~> 1.7'
  spec.add_development_dependency 'rack',               '~> 3.0'
  spec.add_development_dependency 'rack-test',          '~> 2.0'
  spec.add_development_dependency 'rubocop',            '~> 1.65'
  spec.metadata['rubygems_mfa_required'] = 'true'
end
