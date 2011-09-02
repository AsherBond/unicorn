# -*- encoding: binary -*-
require "kcar"
require "fcntl"

# Nightmare is NOT intended as a development API.  It's internal
# API will evolve and change in undocumented ways to discourage
# developers from having application logic rely on it.  Application
# logic goes in Rack applications, not Nightmare.  Nightmare is
# a buffering layer.
module Nightmare
  # :enddoc:
  RBUF = "" # global, we are always single-threaded
  RE_RUN = []
  PUBLIC_LISTENERS = {} # what Nightmare binds to

  @client_max_body_size = 1024 * 1024 # same as nginx
  @worker_processes = 1
  @use = :Poll
  @internal_listeners = 1
  @keepalive_expiry_threshold = nil

  # all timeouts should match nginx
  @keepalive_timeout = 75.0
  @client_header_timeout = 60.0
  @client_body_timeout = 60.0
  @client_send_timeout = 60.0 # not in nginx AFAIK
  @proxy_read_timeout = 60.0
  @proxy_send_timeout = 60.0 # also used for proxy_connect_timeout
  @now = Time.now.to_f

  class << self
    attr_accessor :client_max_body_size
    attr_accessor :worker_processes
    attr_accessor :internal_listeners
    attr_accessor :use
    attr_accessor :keepalive_timeout
    attr_accessor :client_header_timeout
    attr_accessor :client_body_timeout
    attr_accessor :client_send_timeout
    attr_accessor :proxy_read_timeout
    attr_accessor :proxy_send_timeout
  end

  def self.expiry_for(ivar)
    @now + instance_variable_get(ivar)
  end

  def self.now!
    @now = Time.now.to_f
  end

  def self.keepalive_expiry_threshold
    @keepalive_expiry_threshold ||
      (Process.getrlimit(Process::RLIMIT_NOFILE)[0] / 2)
  end

  # this is like GC on idle sockets
  def self.expire!(reason = nil)
    limit = @keepalive_timeout
    killed = []
    begin
      old = now! - limit
      Nightmare.const_get(@use).expire! do |sock|
        expire_at = sock.expire_at
        if expire_at &&
           (expire_at < old) || (:QUIT == reason && sock.idle?)
          sock.close unless sock.closed?
          killed << sock # true
        else
          false
        end
      end
    end while killed.empty? && Exception === reason && (limit -= 1) >= 0

    if killed.empty?
      raise reason if Exception === reason
    else
      RE_RUN.replace(RE_RUN - killed)
    end
  end

  # wrap fd-allocating blocks with this to trigger fd expiry
  def self.MOAR!
    begin
      yield
    rescue Errno::EMFILE, Errno::ENFILE, Errno::ENOBUFS, Errno::ENOMEM => e
      expire!(e) # re-raises if it can't expire anything
      retry
    end
  end

  def init_nightmare!
    replace_listeners!
    mod = Nightmare.const_get(Nightmare.use)
    (@extra_worker_processes = Nightmare.worker_processes).times do |i|
      Unicorn::HttpServer::WORKER_EXTRA[i] = mod
    end
  end

  # we setup private listeners.
  def replace_listeners! # :nodoc:
    privsocks = (1..Nightmare.internal_listeners).map do
      tmp = Unicorn::TmpIO.new
      old_umask = File.umask(0000)
      privsock = Kgio::UNIXServer.new(tmp.path)
      File.umask(old_umask)
      privsock.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
      privsock.listen(Unicorn::SocketHelper::DEFAULTS[:backlog])
      tmp.close
      privsock
    end

    listeners = Unicorn::HttpServer::LISTENERS
    listeners.each do |l|
      l.extend(Nightmare::PublicListener)
      Nightmare::PUBLIC_LISTENERS[l] = :wait_readable
    end
    listeners.clear.concat(privsocks)
  end
end
require "nightmare/worker"
require "nightmare/http_parser"
require "nightmare/client_base"
require "nightmare/upstream_base"
require "nightmare/http_parser"
require "nightmare/stream_file"
require "nightmare/public_listener"
require "nightmare/poll"
