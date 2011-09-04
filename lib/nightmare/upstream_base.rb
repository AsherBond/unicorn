# -*- encoding: binary -*-
require "kcar"
# :stopdoc:
# base class for connecting to the upstream proxy
class Nightmare::UpstreamBase < Kgio::Socket
  RBUF = Nightmare::RBUF
  USCORE = "_"
  DASH = "-"
  REQUEST_METHOD = "REQUEST_METHOD"
  REQUEST_URI = "REQUEST_URI"
  CONTENT_TYPE = "CONTENT_TYPE"
  CONTENT_LENGTH = "CONTENT_LENGTH"
  CRLF = "\r\n"
  HTTP_X_FORWARDED_FOR = "HTTP_X_FORWARDED_FOR".freeze
  REMOTE_ADDR = "REMOTE_ADDR"
  HTTP_VERSION = "HTTP_VERSION"
  HTTP_1_0 = "HTTP/1.0"
  Connection = "Connection"
  KeepAlive = "keep-alive"
  Close = "close"

  attr_reader :client

  def env_to_headers(env, input)
    req = "#{env[REQUEST_METHOD]} " \
          "#{env[REQUEST_URI]} #{env[HTTP_VERSION] || HTTP_1_0}\r\n" \
          "Connection: close\r\n"

    if xff = env[HTTP_X_FORWARDED_FOR]
      xff << ",#{client.kgio_addr}"
    else
      env[HTTP_X_FORWARDED_FOR] = client.kgio_addr
    end

    env.each do |key, value|
      /\AHTTP_(\w+)\z/ =~ key or next
      key = $1
      /\A(?:VERSION|EXPECT|TRANSFER_ENCODING|CONNECTION|KEEP_ALIVE)\z/ =~
        key and next

      key.tr!(USCORE, DASH)
      req << "#{key}: #{value}\r\n"
    end
    if input
      req << "Content-Length: #{input.size}\r\n"
      ct = env[CONTENT_TYPE] and req << "Content-Type: #{ct}\r\n"
    end
    req << CRLF
  end

  def response_headers(status, headers)
    parser = @client.parser
    return "" unless parser.headers?
    headers[Connection] = parser.keepalive? ? KeepAlive : Close
    buf = "HTTP/1.1 #{status}\r\n"
    headers.each do |key, value|
      if /\n/ =~ value
        # avoiding blank, key-only cookies with /\n+/
        buf << value.split(/\n+/).map! { |v| "#{key}: #{v}\r\n" }.join
      else
        buf << "#{key}: #{value}\r\n"
      end
    end
    buf << CRLF
  end

  # @state values
  # - String (upstream request headers)
  # - StringIO, Unicorn::TmpIO (upstream request body)
  # - nil (done writing, waiting on upstream to respond)
  # - Nightmare::StreamFile (upstream response buffer (shared with @client))
  def evloop_once(client, env, input)
    @client = client
    @input = input
    @state = env_to_headers(env, input)
    @parser = Kcar::Parser.new
    @rbuf = "" # private
    @response = {} # becomes (Array === [ status, headers ]) later
    @expire_at = nil
    evloop_writable
  end

  def evloop_run
    return if closed?
    @expire_at = nil
    case @state
    when String, Unicorn::TmpIO, StringIO
      evloop_writable
    else # nil or Nightmare::StreamFile
      evloop_readable
    end
  end

  def evloop_writable
    case @state
    when String # upstream request buffer
      case rv = kgio_trywrite(@state)
      when :wait_writable # no SSL upstreams
        @state = @state.dup # could be global RBUF, but always a string
        return nm_yield(rv, :@proxy_send_timeout)
      when String
        @state = rv # retry, socket buffers grow
      when nil
        @state = @input # fall through on outer loop to retry
        break # from inner loop
      end while true
    when Unicorn::TmpIO, StringIO
      @state = @state.read(0x4000, RBUF) # retry with String === @state
    when nil # @state=nil set when @state.read returns nil
      # wait on upstream app to respond
      return nm_yield(:wait_readable, :@proxy_read_timeout)
    end while true
  rescue => e
    upstream_fail(e)
  end

  def evloop_readable
    case @state
    when nil # initial state when upstream app responds
      case rv = kgio_tryread(0x4000, RBUF)
      when String
        if Hash === @response
          if rv = @parser.headers(@response, @rbuf << rv)
            status, headers = @response = rv
            # @rbuf contains leftover response body slop from the header read
            rv = response_headers(status, headers) << @rbuf
          end
        end

        if Array === @response # [ status, headers ]
          # drain upstream while writing to minimize client-visible latency
          case client_rv = @client.kgio_trywrite(rv)
          when Symbol # :wait_writable or :wait_readable (SSL)
            # if we blocked on writing to the client, we buffer
            # the response to free the Unicorn worker up ASAP
            # write_blocked will also call drain_upstream in turn
            return @client.write_blocked(self, client_rv, rv.dup)
          when String
            rv = client_rv # partial write: retry, socket buffer may grow
          when nil
            break # read next chunk in outer loop
          end while true
        end
      when nil # EOF
        done
        return Hash === @response ?
               @client.upstream_fail(nil) : @client.on_response_done
      when :wait_readable # we do not support SSL upstreams
        return nm_yield(rv, :@proxy_read_timeout)
      end
    when Nightmare::StreamFile
      return if closed? # we could get closed in @client.write_blocked
      # once we started draining, we won't stop until upstream is done
      drain_upstream(@state)
    end while true
  rescue => e
    upstream_fail(e)
  end

  # drains the response from an upstream (Unicorn worker) as fast as possible
  def drain_upstream(stream_file)
    @state = stream_file
    case rv = kgio_tryread(0x4000, RBUF)
    when String
      stream_file << rv
    when nil
      stream_file.write_eof!
      return done
    when :wait_readable # no SSL, so no chance of :wait_writable
      return nm_yield(rv, :@proxy_read_timeout)
    end while true
  end

  def close
    super
    @input.close if @input
  end

  # called if the client connection is terminated
  def client_fail(e)
    done unless closed?
  end

  # called if the upstream connection is terminated
  def upstream_fail(e)
    client_fail(e)
    @client.upstream_fail(e)
  end

  def idle?
    false
  end
end
