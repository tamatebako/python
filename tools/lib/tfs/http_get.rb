# frozen_string_literal: true

require "net/http"
require "uri"

module Tfs
  # Minimal plain-text GET with redirect following (official listings).
  class HttpGet
    # Raised when the URL cannot be fetched.
    class Error < StandardError; end

    MAX_REDIRECTS = 5

    def self.body(url)
      uri = URI.parse(url)
      MAX_REDIRECTS.times do
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          response = http.request(Net::HTTP::Get.new(uri))
          case response
          when Net::HTTPSuccess
            return response.body
          when Net::HTTPRedirection
            uri = URI.parse(response.fetch("location"))
          else
            raise Error, "HTTP #{response.code} from #{uri}"
          end
        end
      end
      raise Error, "too many redirects from #{url}"
    rescue SystemCallError, SocketError, Timeout::Error => e
      raise Error, "cannot fetch #{url}: #{e.message}"
    end
  end
end
