# -*- encoding: binary -*-

# This middleware forces the underlying Rack application to stream
# responses with "Transfer-Encoding: chunked" while dechunking
# transparently for nginx (which, as of 1.0.4, only consumes
# unchunked HTTP/1.0 responses).
#
# Rack applications (e.g. Rails 3.1+) may not stream for HTTP/1.0
# (or HTTP/0.9) responses because those HTTP versions do not
# (officially) support persistent connections.
#
# This middleware relies on nginx streaming responses to the client (we
# force this via "X-Accel-Buffering: no" in the response header).
#
# Include this at the top of your middleware stack, before any
# middleware is loaded to ensure the Rack application chunks the
# response so this middleware can properly dechunk it.
#
# We rely on the Rack server *not* supporting persistent HTTP connections
# in any form for this middleware to work reliably with nginx.
#
# This middleware should be used with \Unicorn if and only if your
# responses are small enough to fit into socket buffers without blocking.
#
# This middleware should be used with \Rainbows! with only the
# experimental StreamResponseEpoll concurrency option.  This is
# not supported with any other concurrency models \Rainbows! supports.
#
# === Usage
#
# In your Rack config.ru
#
#   use Unicorn::ForceStreaming
#   ...
#   run YourApp.new
#
class Unicorn::ForceStreaming

  # :stopdoc:
  # garbage avoidance
  TransferEncoding = "Transfer-Encoding"
  XAccelBuffering = "X-Accel-Buffering"
  No = "no"
  HTTP_VERSION = "HTTP_VERSION".freeze
  HTTP_1_1 = "HTTP/1.1"
  # :startdoc:

  # standard Rack middleware initialization
  def initialize(app)
    @app = app
    @parser = Unicorn::HttpParser.new
  end

  def call(env)
    case env[HTTP_VERSION]
    when "HTTP/1.0", nil
      # tell the app we're HTTP/1.1 since we'll dechunk
      env[HTTP_VERSION] = HTTP_1_1
      status, headers, body = orig = @app.call(env)

      # Rails and Rack::Chunked will never use non-standard header-casing,
      # so avoid the HeaderHash overhead
      headers = Rack::Utils::HeaderHash.new(headers) unless Hash === headers

      case headers.delete(TransferEncoding)
      when "chunked"
        @body = body
        headers[XAccelBuffering] = No # this forces nginx to stream
        [ status, headers, self ] # orig may be array, don't modify
      else
        # nobody in their right mind sets "Transfer-Encoding: identity"
        orig
      end
    else
      @app.call(env)
    end
  end

  def respond_to?(m) # :nodoc:
    @body.respond_to?(m)
  end

  def each # :nodoc:
    parser = @parser.dechunk!
    buf = parser.buf
    @body.each do |chunk|
      parser.filter_body(buf, chunk)
      yield buf
    end
  end

  # Unicorn won't get here unless respond_to? succeeded
  def close # :nodoc:
    @body.close
  end
end
