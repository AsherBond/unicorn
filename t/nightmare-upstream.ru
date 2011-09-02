require "digest/sha1"
class NmTestUpstream
  class Blob
    def initialize(delay, bs = 16384)
      @delay = delay
      @bs = bs
      @io = File.open('random_blob', 'rb')
    end

    def each
      buf = ""
      while @io.read(@bs, buf)
        yield buf
        sleep(@delay) if @delay > 0.0
      end
    end

    def close
      @io.close
    end
  end

  def call(env)
    case env["PATH_INFO"]
    when "/time"
      [ 200, {}, [ "#{Time.now.to_i}\n" ] ]
    when "/env"
      [ 200, {}, [ "#{env.inspect}\n" ] ]
    when "/random_blob"
      random_blob(env)
    when "/sha1"
      sha1(env)
    when %r{\A/sleep/(\d+)\z}
      delay = $1.to_f
      sleep(delay)
      [ 200, {}, [ "slept #{delay}s\n" ] ]
    else
      [ 404, {}, [] ]
    end
  end

  def sha1(env)
    # /\A100-continue\z/i =~ env['HTTP_EXPECT'] and return [ 100, {}, [] ]
    digest = Digest::SHA1.new
    input = env['rack.input']
    warn "input.size=#{input.size}"
    buf = ""
    while input.read(16384, buf)
      digest.update(buf)
    end
    [ 200, {}, [ digest.hexdigest << "\n" ] ]
  end

  def random_blob(env)
    q = Rack::Request.new(env).params
    pre_sleep = q["pre_sleep"] and sleep(pre_sleep.to_f)
    body = Blob.new((q["delay"] || 0.0).to_f)
    [ 200, { "Content-Type" => "application/octet-stream" }, body ]
  end
end

use Rack::Chunked
use Rack::ContentType, "text/plain"
run NmTestUpstream.new
