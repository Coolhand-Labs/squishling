# frozen_string_literal: true

require "net/http"

module Squishling
  module Adapters
    # The HTTP exchange of Adapters::OpenAICompatible, kept apart so the limits sit in one place: one POST whose
    # response is read in chunks, with a cap on its size (the declared length, then the bytes actually received, for an
    # error body too) and on the total time it may take, which read_timeout alone doesn't bound (it restarts at every
    # read, so a slow drip can hold a worker thread for as long as the server likes). Compression is refused, not
    # inflated: the request asks for an identity encoding, and a response that comes back encoded anyway is dropped, so
    # a small body can't expand past the cap. Redirects aren't followed: the next hop could be another host, and the
    # Authorization header would go with it. A limit that is hit raises a Refused, whose message names the limit and
    # never carries the URL, a header, or any of the response.
    class OpenAITransport
      class Refused < StandardError; end
      class ResponseTooLarge < Refused; end
      class DeadlineExceeded < Refused; end
      class UnexpectedEncoding < Refused; end

      # What is left of a response once it has been read: its status (a String, as Net::HTTPResponse has it), whole
      # body, and Retry-After header.
      Reply = Struct.new(:code, :body, :retry_after) do
        def success?
          code.start_with?("2")
        end
      end

      MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      private_constant :MONOTONIC

      def initialize(endpoint:, open_timeout:, read_timeout:, total_timeout:, max_response_bytes:, clock: MONOTONIC)
        @endpoint = endpoint
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @total_timeout = total_timeout
        @max_response_bytes = max_response_bytes
        @clock = clock
      end

      # total_timeout and the byte cap apply per call, so each retry gets its own.
      def post(body, headers)
        deadline = @clock.call + @total_timeout
        perform(body, headers, deadline)
      rescue Timeout::Error
        expired! if @clock.call >= deadline

        raise
      end

      private

      def perform(body, headers, deadline)
        http = connection
        http.open_timeout = [@open_timeout, @total_timeout].min
        request = Net::HTTP::Post.new(@endpoint.request_uri, headers)
        request.body = body
        reply = nil
        http.start do
          http.read_timeout = http.write_timeout = read_budget(deadline)
          http.request(request) { |response| reply = read(http, response, deadline) }
        end
        reply
      end

      def connection
        Net::HTTP.new(@endpoint.hostname, @endpoint.port).tap do |http|
          http.use_ssl = @endpoint.scheme == "https"
          http.read_timeout = http.write_timeout = @read_timeout
        end
      end

      def read(http, response, deadline)
        check_headers(response)
        body = String.new(encoding: Encoding::BINARY)
        response.read_body do |chunk|
          too_large! if body.bytesize + chunk.bytesize > @max_response_bytes
          body << chunk
          http.read_timeout = read_budget(deadline)
        end
        Reply.new(response.code, body, response["retry-after"])
      end

      def check_headers(response)
        encoding = response["content-encoding"].to_s.strip.downcase
        unless encoding.empty? || encoding == "identity"
          raise UnexpectedEncoding, "the response was compressed although the request asked for none"
        end

        length = response["content-length"].to_s.strip
        too_large! if length.match?(/\A\d+\z/) && length.to_i > @max_response_bytes
      end

      def too_large!
        raise ResponseTooLarge, "the response was larger than max_response_bytes (#{@max_response_bytes})"
      end

      # The time one more read may take: read_timeout, or what is left of the deadline if that is less.
      def read_budget(deadline)
        left = deadline - @clock.call
        expired! unless left.positive?

        [@read_timeout, left].min
      end

      def expired!
        raise DeadlineExceeded, "the request ran past total_timeout (#{@total_timeout}s)"
      end
    end
  end
end
