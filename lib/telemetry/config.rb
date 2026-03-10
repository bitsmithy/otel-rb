# frozen_string_literal: true

module Telemetry
  class Config
    attr_reader :service_name, :service_namespace, :service_version,
                :endpoint, :integrate_tracing_logger

    def initialize(
      service_name: nil,
      service_namespace: nil,
      service_version: nil,
      endpoint: nil,
      integrate_tracing_logger: false
    )
      @service_name             = service_name      || default_service_name
      @service_namespace        = service_namespace || default_service_namespace
      @service_version          = service_version   || default_service_version
      @endpoint                 = endpoint
      @integrate_tracing_logger = integrate_tracing_logger
    end

    private

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
