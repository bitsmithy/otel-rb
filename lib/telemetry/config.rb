# frozen_string_literal: true

require 'uri'

module Telemetry
  class Config
    OPTIONS = %i[
      service_name service_namespace service_version deployment_environment endpoint
      correlate_logs integrate_tracing_logger require_endpoint
    ].freeze

    attr_reader :service_name, :service_namespace, :service_version,
                :deployment_environment, :endpoint, :correlate_logs,
                :integrate_tracing_logger

    def initialize(**options)
      unknown_options = options.keys - OPTIONS
      raise ArgumentError, "unknown keywords: #{unknown_options.join(', ')}" if unknown_options.any?

      @service_name = options[:service_name] || default_service_name
      @service_namespace = options[:service_namespace] || default_service_namespace
      @service_version = options[:service_version] || default_service_version
      @deployment_environment = options[:deployment_environment]
      @endpoint = options[:endpoint]
      @correlate_logs = options.fetch(:correlate_logs, false)
      @integrate_tracing_logger = options.fetch(:integrate_tracing_logger, false)
      validate_endpoint!
      validate_required_endpoint! if options.fetch(:require_endpoint, false)
    end

    private

    def configured_endpoint
      endpoint || ENV.fetch('OTEL_EXPORTER_OTLP_ENDPOINT', nil)
    end

    def validate_endpoint!
      return unless configured_endpoint

      uri = URI.parse(configured_endpoint)
      valid = %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo
      raise ConfigurationError, 'OTLP endpoint must be an HTTP URL without credentials' unless valid
    rescue URI::InvalidURIError
      raise ConfigurationError, 'OTLP endpoint must be an HTTP URL without credentials'
    end

    def validate_required_endpoint!
      return if configured_endpoint && !configured_endpoint.empty?

      raise ConfigurationError, 'OTLP endpoint is required'
    end

    def default_service_name
      File.basename($PROGRAM_NAME, '.*')
    end

    def default_service_namespace
      File.basename(File.dirname(File.expand_path($PROGRAM_NAME)))
    end

    def default_service_version
      ENV.fetch('SERVICE_VERSION', 'unknown')
    end
  end
end
