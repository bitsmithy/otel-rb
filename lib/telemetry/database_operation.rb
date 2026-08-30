# frozen_string_literal: true

module Telemetry
  module DatabaseOperation
    IGNORED_EVENT_NAMES = %w[SCHEMA TRANSACTION].freeze
    TRANSACTION_OPERATIONS = %w[BEGIN COMMIT RELEASE ROLLBACK SAVEPOINT].freeze
    KNOWN_OPERATIONS = %w[ALTER CREATE DELETE DROP INSERT SELECT TRUNCATE UPDATE UPSERT WITH].freeze
    SQL_KEYWORD_PATTERN = %r{\A\s*(?:/\*.*?\*/\s*)*([A-Za-z]+)}m

    module_function

    def ignored?(payload)
      payload[:cached] || IGNORED_EVENT_NAMES.include?(payload[:name]) ||
        TRANSACTION_OPERATIONS.include?(name(payload[:sql]))
    end

    def attributes(payload)
      {
        'db.system.name' => system(payload[:connection]),
        'db.operation.name' => name(payload[:sql])
      }
    end

    def system(connection)
      adapter = connection&.adapter_name.to_s.downcase
      return 'postgresql' if adapter.include?('postgres')
      return 'sqlite' if adapter.include?('sqlite')
      return 'mysql' if adapter.include?('mysql')

      'other_sql'
    end

    def name(sql)
      match = sql.to_s.match(SQL_KEYWORD_PATTERN)
      keyword = match&.captures&.first
      keyword = keyword.upcase if keyword
      KNOWN_OPERATIONS.include?(keyword) ? keyword : 'OTHER'
    end
  end
end
