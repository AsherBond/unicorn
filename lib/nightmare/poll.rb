# -*- encoding: binary -*-
# this is used to extend Unicorn::HttpServer
module Nightmare::Poll
  include Nightmare::Worker
  POLLSET = {}
  POLLSET.compare_by_identity if POLLSET.respond_to?(:compare_by_identity)

  POLL = if Kgio.respond_to?(:poll)
    Kgio.method(:poll)
  else
    require "nightmare/poll/fake_poll"
    FakePoll
  end

  def self.expire!
    POLLSET.delete_if { |sock,_| yield(sock) }
  end

  def worker_loop(worker) # overrides Unicorn::HttpServer#worker_loop
    init_worker_process(worker)
    listeners = public_listeners # becomes empty from SIGQUIT
    keepalive_expiry_threshold = Nightmare.keepalive_expiry_threshold
    timeout = (@timeout * 1000).to_i # poll(2) takes milliseconds
    begin
      Nightmare.expire! if POLLSET.size >= keepalive_expiry_threshold
      r = POLL.call(POLLSET.merge(listeners), timeout) or next
      Nightmare.now!
      r.each_key { |sock| sock.evloop_run }
      while r = Nightmare::RE_RUN.shift
        r.evloop_run
      end
    rescue => e
      if (IOError === e || Errno::EBADF === e) && listeners.empty?
        Nightmare.expire!(:QUIT)
      else
        Unicorn.log_error(@logger, "Nightmare::Poll", e)
      end
    end until listeners.empty? && POLLSET.empty?
  end
  # :enddoc:
end

require "nightmare/poll/base"
require "nightmare/poll/upstream"
require "nightmare/poll/client"
