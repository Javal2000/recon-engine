# frozen_string_literal: true

require "net/http"
require "uri"

module ReconEngine
  module LLM
    # Shared HTTP behaviour for the hosted providers. Subclasses supply the
    # endpoint, the request body, and how to pull text and token counts out of
    # the response; timeouts, retries, usage accounting and error wrapping
    # happen here.
    class HttpProvider < Client
      OPEN_TIMEOUT = 10
      READ_TIMEOUT = 60
      MAX_ATTEMPTS = 6
      MAX_WAIT     = 60.0
      RETRIABLE    = [Net::HTTPTooManyRequests, Net::HTTPServerError].freeze

      # Consecutive failed calls before the provider is treated as down for the
      # rest of the run.
      BREAKER_THRESHOLD = 3

      # Once the breaker trips, every remaining cluster degrades immediately
      # instead of spending minutes retrying a provider that isn't coming back.
      def complete(system:, transcript:)
        raise ProviderError, "#{name}: not called, #{@breaker}" if @breaker

        response = call_model(system, transcript)
        @failures_in_a_row = 0
        response
      rescue QuotaExhausted
        @breaker ||= "its quota ran out earlier in this run"
        raise
      rescue ProviderError
        @failures_in_a_row = @failures_in_a_row.to_i + 1
        @breaker ||= "#{BREAKER_THRESHOLD} calls in a row failed" if @failures_in_a_row >= BREAKER_THRESHOLD
        raise
      end

      private

      def call_model(system, transcript)
        @waited_ms = 0
        started    = monotonic_ms
        response   = post(endpoint, request_body(system, transcript), request_headers)
        payload    = JSON.parse(response.body)
        elapsed    = monotonic_ms - started

        @usage += usage_from(payload).with(calls: 1, latency_ms: [elapsed - @waited_ms, 0].max, wait_ms: @waited_ms)
        extract_text(payload)
      rescue JSON::ParserError => e
        raise ProviderError, "#{name}: response was not JSON (#{e.message})"
      end

      # --- subclass hooks ----------------------------------------------------

      def endpoint                      = raise(NotImplementedError)
      def request_headers               = { "content-type" => "application/json" }
      def request_body(_system, _script) = raise(NotImplementedError)
      def extract_text(_payload)        = raise(NotImplementedError)
      def usage_from(_payload)          = Usage.zero

      def read_timeout = READ_TIMEOUT

      # Providers that need a key override this; Ollama does not.
      def api_key_env = nil

      def api_key
        return nil if api_key_env.nil?

        ENV[api_key_env] || raise(ProviderError, "#{api_key_env} is not set. " \
                                                 "Export it, or run with --provider offline.")
      end

      # --- transport ---------------------------------------------------------

      def post(url, body, headers)
        uri     = URI(url)
        attempt = 0

        begin
          attempt += 1
          response = perform(uri, body, headers)
          return response if response.is_a?(Net::HTTPSuccess)
          raise QuotaExhausted, "#{name}: #{exhausted_quota(response)}" if exhausted_quota(response)

          if retriable?(response) && attempt < MAX_ATTEMPTS
            pause(retry_delay(response, attempt))
            raise Retry
          end

          raise ProviderError, "#{name}: HTTP #{response.code}: #{error_message(response)}"
        rescue Retry
          retry
        rescue Timeout::Error, Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError => e
          raise ProviderError, "#{name}: #{e.class}: #{e.message}" if attempt >= MAX_ATTEMPTS

          pause(backoff(attempt))
          retry
        end
      end

      class Retry < StandardError
      end

      def perform(uri, body, headers)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = read_timeout
        request = Net::HTTP::Post.new(uri)
        headers.each { |k, v| request[k] = v }
        request.body = JSON.generate(body)
        http.request(request)
      end

      def retriable?(response)
        RETRIABLE.any? { |klass| response.is_a?(klass) }
      end

      # Free tiers enforce per-minute limits and say how long to wait, either in
      # a Retry-After header or, for Google, in a RetryInfo block in the body.
      # Guessing instead of asking turns one throttled call into a failed one.
      def retry_delay(response, attempt)
        [server_delay(response) || backoff(attempt), MAX_WAIT].min
      end

      def server_delay(response)
        header = response["retry-after"].to_s
        return Float(header) if header.match?(/\A\d+(\.\d+)?\z/)

        details = parse_error(response).fetch("details", [])
        hint    = details.find { |detail| detail.is_a?(Hash) && detail["retryDelay"] }
        seconds = hint && hint["retryDelay"].to_s[/\A(\d+(?:\.\d+)?)s\z/, 1]
        seconds && Float(seconds)
      end

      # A daily quota won't reset for hours, so waiting it out would only stall
      # the run. Google names the quota in a QuotaFailure block; OpenAI uses an
      # insufficient_quota error code.
      def exhausted_quota(response)
        return nil unless response.is_a?(Net::HTTPTooManyRequests)

        error = parse_error(response)
        return "quota exhausted (#{error["message"]})" if error["code"] == "insufficient_quota"

        violation = error.fetch("details", []).grep(Hash).flat_map { |d| Array(d["violations"]) }
                         .find { |v| v["quotaId"].to_s.include?("PerDay") }
        violation && "daily quota used up (#{violation["quotaId"]}, limit #{violation["quotaValue"]})"
      end

      # Exponential with full jitter, so separate processes hitting the same
      # limit spread their retries out instead of retrying in step.
      def backoff(attempt)
        base = 2.0 * (2**(attempt - 1))
        base * (0.5 + (rand * 0.5))
      end

      def pause(seconds)
        @waited_ms = @waited_ms.to_i + (seconds * 1000).round
        sleep(seconds)
      end

      def error_message(response)
        message = parse_error(response)["message"] || response.body
        truncate(message.to_s.gsub(/\s+/, " ").strip)
      end

      def parse_error(response)
        error = JSON.parse(response.body.to_s)["error"]
        error.is_a?(Hash) ? error : {}
      rescue JSON::ParserError
        {}
      end

      def monotonic_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round

      def truncate(text, limit = 300)
        text.to_s[0, limit]
      end

      # Flattens the transcript into a single user turn for providers whose
      # chat format we do not need the full fidelity of.
      def flatten(transcript)
        transcript.map { |turn| "#{turn[:role].upcase}:\n#{turn[:content]}" }.join("\n\n")
      end
    end
  end
end
