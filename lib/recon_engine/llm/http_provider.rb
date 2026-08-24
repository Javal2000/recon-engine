# frozen_string_literal: true

require "net/http"
require "uri"

module ReconEngine
  module LLM
    # Shared HTTP behaviour for the hosted providers. Subclasses supply the
    # endpoint, the request body, and how to pull text out of the response;
    # timeouts, retries with backoff, and error wrapping happen here.
    class HttpProvider < Client
      OPEN_TIMEOUT = 10
      READ_TIMEOUT = 60
      MAX_ATTEMPTS = 3
      RETRIABLE    = [Net::HTTPTooManyRequests, Net::HTTPServerError].freeze

      def complete(system:, transcript:)
        response = post(endpoint, request_body(system, transcript), request_headers)
        extract_text(JSON.parse(response.body))
      rescue JSON::ParserError => e
        raise ProviderError, "#{name}: response was not JSON (#{e.message})"
      end

      private

      # --- subclass hooks ----------------------------------------------------

      def endpoint                      = raise(NotImplementedError)
      def request_headers               = { "content-type" => "application/json" }
      def request_body(_system, _script) = raise(NotImplementedError)
      def extract_text(_payload)        = raise(NotImplementedError)

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

          if retriable?(response) && attempt < MAX_ATTEMPTS
            sleep(backoff(attempt))
            raise Retry
          end

          raise ProviderError, "#{name}: HTTP #{response.code}: #{truncate(response.body)}"
        rescue Retry
          retry
        rescue Timeout::Error, Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError => e
          raise ProviderError, "#{name}: #{e.class}: #{e.message}" if attempt >= MAX_ATTEMPTS

          sleep(backoff(attempt))
          retry
        end
      end

      Retry = Class.new(StandardError)

      def perform(uri, body, headers)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl     = uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT
        request = Net::HTTP::Post.new(uri)
        headers.each { |k, v| request[k] = v }
        request.body = JSON.generate(body)
        http.request(request)
      end

      def retriable?(response)
        RETRIABLE.any? { |klass| response.is_a?(klass) }
      end

      # Full jitter, so a fleet of workers hitting a rate limit does not
      # synchronise its retries into a second thundering herd.
      def backoff(attempt)
        base = 0.5 * (2**(attempt - 1))
        base * (0.5 + (Random.new(attempt).rand * 0.5))
      end

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
