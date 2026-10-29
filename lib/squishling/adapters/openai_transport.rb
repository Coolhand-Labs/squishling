# frozen_string_literal: true

require "net/http"
require "timeout"

module Squishling
  module Adapters
    # The HTTP exchange of Adapters::OpenAICompatible, kept apart so the limits sit in one place: one POST whose
    # response is read in chunks, with a cap on its size (the declared length, then the bytes actually received, for an
    # error body too) and on the total time it may take, which read_timeout alone doesn't bound (it restarts at every
    # read, so a slow drip of headers or body can hold a worker thread for as long as the server likes). Compression
    # is refused, not inflated: the request asks for an identity encoding, and a response that comes back encoded
    # anyway is dropped, so a small body can't expand past the cap. Redirects aren't followed: the next hop could be
    # another host, and the Authorization header would go with it. A limit that is hit raises a Refused, whose
    # message names the limit and never carries the URL, a header, or any of the response.
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
      rescue DeadlineExceeded
        # Net::HTTP re-raises what interrupts a connect with the host and port in the message; ours is built afresh.
        expired!
      rescue Timeout::Error
        expired! if @clock.call >= deadline

        raise
      end

      private

      # Net::HTTP reads the status line and headers before it yields the response, with read_timeout restarting at every
      # byte, so the deadline can't be checked there: a Timeout cuts the whole exchange off at total_timeout instead.
      # The connection is dropped whichever way the block ends, so nothing is left half-used. The deadline is checked
      # again at each chunk, which also stops a body that arrives in time but whose clock says otherwise.
      def perform(body, headers, deadline)
        request = Net::HTTP::Post.new(@endpoint.request_uri, headers)
        request.body = body
        http = connection
        Timeout.timeout(@total_timeout, DeadlineExceeded, expired_message) do
          http.start { http.request(request) { |response| return read(response, deadline) } }
        end
      end

      def connection
        Net::HTTP.new(@endpoint.hostname, @endpoint.port).tap do |http|
          http.use_ssl = @endpoint.scheme == "https"
          http.open_timeout = @open_timeout
          http.read_timeout = http.write_timeout = @read_timeout
        end
      end

      def read(response, deadline)
        check_headers(response)
        body = String.new(encoding: Encoding::BINARY)
        response.read_body do |chunk|
          expired! unless @clock.call < deadline
          too_large! if body.bytesize + chunk.bytesize > @max_response_bytes
          body << chunk
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

      def expired!
        raise DeadlineExceeded, expired_message
      end

      def expired_message
        "the request ran past total_timeout (#{@total_timeout}s)"
      end
    end
  end
end
