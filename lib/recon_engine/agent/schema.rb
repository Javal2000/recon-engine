# frozen_string_literal: true

module ReconEngine
  module Agent
    # The contract between the engine and whatever model is on the other end.
    #
    # Model output is a string until this file says otherwise: one place parses,
    # one place validates, and nothing downstream sees an unvalidated hash. It's
    # hand-written rather than a JSON Schema gem so the error messages can go
    # straight back to the model as a repair prompt.
    module Schema
      CLASSIFICATIONS = %w[
        TIMING_DIFFERENCE
        ROUNDING
        DUPLICATE_IN_TARGET
        MISSING_IN_TARGET
        SCHEMA_DRIFT
        GENUINE_DISCREPANCY
        UNKNOWN
      ].freeze

      ACTIONS = %w[use_tool classify].freeze

      module_function

      # @return [Array(Hash, Array<String>)] the normalized step and any errors.
      #   Errors non-empty means the step must not be acted on.
      def parse_step(raw, tool_names:)
        payload = parse_json(raw)
        return [nil, ["output was not valid JSON: #{payload}"]] if payload.is_a?(String)
        return [nil, ["output must be a JSON object, got #{payload.class}"]] unless payload.is_a?(Hash)

        step = normalize(payload)
        errors = case step["action"]
                 when "use_tool" then validate_tool_call(step, tool_names)
                 when "classify" then validate_classification(step)
                 else ["\"action\" must be one of #{ACTIONS.join(', ')}"]
                 end

        [errors.empty? ? step : nil, errors]
      end

      # Models often wrap JSON in ```json fences. Stripping them saves a retry.
      def parse_json(raw)
        text = raw.to_s.strip
        text = Regexp.last_match(1).strip if text =~ /\A```(?:json)?\s*(.*?)\s*```\z/m
        JSON.parse(text)
      rescue JSON::ParserError => e
        e.message
      end

      # Accept the two shapes models actually emit: the documented one, and the
      # one where the model skipped `action` and went straight to a verdict.
      # Being liberal here and strict everywhere else is a deliberate trade.
      def normalize(payload)
        step = payload.transform_keys(&:to_s)
        step["action"] ||= step.key?("tool") ? "use_tool" : "classify"
        step["arguments"] = {} if step["action"] == "use_tool" && step["arguments"].nil?
        step
      end

      def validate_tool_call(step, tool_names)
        errors = []
        tool = step["tool"]
        errors << "\"tool\" must be one of #{tool_names.join(', ')}, got #{tool.inspect}" unless tool_names.include?(tool)
        errors << "\"arguments\" must be a JSON object" unless step["arguments"].is_a?(Hash)
        errors
      end

      def validate_classification(step)
        errors = []

        unless CLASSIFICATIONS.include?(step["classification"])
          errors << "\"classification\" must be one of #{CLASSIFICATIONS.join(', ')}, got #{step['classification'].inspect}"
        end

        confidence = step["confidence"]
        unless confidence.is_a?(Numeric) && confidence.between?(0, 1)
          errors << "\"confidence\" must be a number between 0 and 1, got #{confidence.inspect}"
        end

        evidence = step["evidence"]
        if !evidence.is_a?(Array) || evidence.empty? || !evidence.all?(String)
          errors << "\"evidence\" must be a non-empty array of strings"
        end

        %w[explanation suggested_action].each do |field|
          value = step[field]
          errors << "\"#{field}\" must be a non-empty string" unless value.is_a?(String) && !value.strip.empty?
        end

        errors
      end
    end
  end
end
