# -*- encoding: binary -*-
# :enddoc:
# this module extends Kgio::TCPServer or Kgio::UNIXServer
module Nightmare::PublicListener
  attr_accessor :client_class
  FLAGS = Kgio::SOCK_NONBLOCK | Kgio::SOCK_CLOEXEC

  def evloop_run
    while client = kgio_tryaccept(@client_class, FLAGS)
      client.evloop_once
    end
    rescue Errno::EMFILE, Errno::ENFILE, Errno::ENOBUFS, Errno::ENOMEM => e
      Nightmare.expire!(e)
      # not retrying, letting other workers or machines take it
  end
end
