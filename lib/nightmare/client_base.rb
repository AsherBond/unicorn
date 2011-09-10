# -*- encoding: binary -*-
# :enddoc:
require "sendfile"
class Nightmare::ClientBase < Kgio::Socket
  HttpParser = Nightmare::HttpParser
  RBUF = Nightmare::RBUF
  UPSTREAMS = []
  Z = ""

  attr_reader :parser

  def self.setup
    UPSTREAMS.replace(Unicorn::HttpServer::LISTENERS.map { |s| s.getsockname })
  end

  # @state values
  # - :headers (client request)
  # - :body (client request)
  # - :trailers (client request)
  # - Nightmare::StreamFile (upstream response buffer (shared with upstream))

  def evloop_once
    @parser = HttpParser.new
    @state = :headers
    @expire_at = @input = @upstream = nil
    evloop_readable
  end

  def evloop_run
    return if closed?
    @expire_at = nil
    Symbol === @state ? evloop_readable : evloop_writable
  end

  def request_fully_buffered?(rv)
    case @state
    when :headers
      if @parser.add_parse(rv)
        return true if 0 == (length = @parser.content_length)
        prepare_request_body(length) # continue looping
        return body_done?(Z)
      end
    when :body
      return body_done?(rv)
    when :trailers
      return trailers_done?(rv)
    end
    false
  end

  def evloop_readable
    return dispatch if request_fully_buffered?(Z)
    case rv = kgio_tryread(0x4000, RBUF)
    when String
      return dispatch if request_fully_buffered?(rv)
    when Symbol # :wait_readable, possibly :wait_writable if SSL
      return nm_yield(rv, :@keepalive_timeout) if idle?
      return nm_yield(rv, :body == @state ? :@client_body_timeout :
                                            :@client_header_timeout)
    when nil # client terminated connection
      return done
    end while true
  rescue => e
    client_fail(e)
  end

  def evloop_writable
    case rv = @state.stream_to(self)
    when nil
      on_response_done
    when :yield
      @upstream.nm_yield(:wait_readable, :@proxy_read_timeout)
    when Symbol # :wait_writable (or :wait_readable if SSL)
      nm_yield(rv, :@client_send_timeout)
    end
  rescue => e
    client_fail(e)
  end

  def expect_100_ok?(env)
    /\A100-continue\z/i =~ env[Unicorn::Const::HTTP_EXPECT] or return true

    buf = Unicorn::Const::EXPECT_100_RESPONSE
    case rv = kgio_trywrite(buf)
    when nil
      env.delete(Unicorn::Const::HTTP_EXPECT)
      return true
    when String # highly unlikely
      buf = rv # retry, this is terrible!
    when Symbol # highly unlikely
      # totally failed?  OK, we don't /have/ to send a response
      if buf == Unicorn::Const::EXPECT_100_RESPONSE
        env.delete(Unicorn::Const::HTTP_EXPECT)
        return true
      end

      # we sent a partial response, just kill the client, it's
      # not worth it for such a corner case
      return done
    end while true
  end

  def prepare_request_body(length)
    expect_100_ok?(@parser.env) or return
    # FIXME: reject big requests
    @state = :body
    @buf2 = ""
    @input = if length && length < Unicorn::TeeInput.client_body_buffer_size
      StringIO.new("")
    else
      Nightmare.MOAR! { Unicorn::TmpIO.new }
    end
  end

  # returns true or false to determine whether or not to continue the read loop
  def body_done?(data)
    @parser.filter_body(@buf2, @parser.buf << data)
    @input << @buf2
    if @parser.body_eof?
      if @parser.content_length
        @input.rewind
        true # dispatch
      else
        @state = :trailers
        trailers_done?("")
      end
    else
      false
    end
  end

  # returns true or false to determine whether or not to continue the read loop
  def trailers_done?(data)
    @parser.add_parse(data) or return false
    @input.rewind
    true
  end

  def write_blocked(upstream, sym, strbuf)
    @upstream = upstream
    upstream.drain_upstream(@state = Nightmare::StreamFile.new(strbuf))
    # sym == :wait_writable (or :wait_readable if SSL)
    nm_yield(sym, :@client_send_timeout)
  end

  def on_response_done # called by Upstream, too
    return done unless @parser.next?

    @state = :headers
    @input = nil
    Nightmare::RE_RUN << self
  end

  def idle?
    :headers == @state && 0 == @parser.buf.size
  end

  # called on client failure
  def client_fail(e)
    done unless closed?
    @upstream.client_fail(e) if @upstream
  end

  # called on upstream failure when upstream dies
  def upstream_fail(_)
    return if closed?
    kgio_trywrite("HTTP/1.1 502 Bad Gateway\r\n\r\n") rescue nil
    done
  end

  alias kgio_trysendfile trysendfile
end
