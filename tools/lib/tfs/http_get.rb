# frozen_string_literal: true

require "net/http"
require "uri"

module Tfs
  # Minimal HTTP probes with redirect following (official listings).
  class HttpGet
    # Raised when the URL cannot be fetched.
    class Error < StandardError; end

    MAX_REDIRECTS = 5

    # The plain-text body of a GET (official listings).
    def self.body(url)
      uri, response = terminal(url, Net::HTTP::Get)
      return response.body if response.is_a?(Net::HTTPSuccess)

      raise Error, "HTTP #{response.code} from #{uri}"
    end

    # Existence probe (HEAD — no body transfer): true on 2xx, false when
    # the server answers 404 (the resource is definitively absent). Any
    # other terminal status is a named Error — a probe that cannot decide
    # never silently answers either way.
    def self.exists?(url)
      uri, response = terminal(url, Net::HTTP::Head)
      case response
      when Net::HTTPSuccess then true
      when Net::HTTPNotFound then false
      else raise Error, "HTTP #{response.code} from #{uri}"
      end
    end

    # Follows redirects (up to MAX_REDIRECTS) and returns
    # [terminal uri, terminal response] with whatever status the terminal
    # response carries — the caller classifies it.
    def self.terminal(url, request_class)
      uri = URI.parse(url)
      MAX_REDIRECTS.times do
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          response = http.request(request_class.new(uri))
          return [uri, response] unless response.is_a?(Net::HTTPRedirection)

          uri = URI.parse(response.fetch("location"))
        end
      end
      raise Error, "too many redirects from #{url}"
    rescue SystemCallError, SocketError, Timeout::Error => e
      raise Error, "cannot fetch #{url}: #{e.message}"
    end
    private_class_method :terminal
  end
end
