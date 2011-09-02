# -*- encoding: binary -*-
class Nightmare::StreamFile
  def initialize(strbuf)
    @tmpio = Unicorn::TmpIO.new
    @tmpio.write(strbuf)
    @offset = 0
    @count = nil # becomes an Integer when @tmpio is completely buffered
  end

  def <<(strbuf)
    @tmpio.write(strbuf)
  end

  def write_eof!
    @count = @tmpio.size
  end

  def stream_to(io)
    case rv = io.kgio_trysendfile(@tmpio, @offset, @count)
    when Integer
      @count == (@offset += rv) and return @tmpio.close # (nil)
      # else continue looping
    when nil
      return @count ? @tmpio.close : :yield
    when Symbol
      return rv
    end while true
  end
end
