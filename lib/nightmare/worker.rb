# -*- encoding: binary -*-
#
# common to Nightmare::Poll
module Nightmare::Worker
  def init_worker_process(worker)
    generic_worker_init("nightmare[#{worker.nr}]")
    Worker.user(*@user) if Array === @user
    trap(:QUIT) do
      Nightmare::HttpParser.quit
      Nightmare::PUBLIC_LISTENERS.each { |l,_| l.close rescue nil }.clear
    end
    trap(:USR1) { reopen_worker_logs(worker.nr) }
    @user = @after_fork = @orig_app = @app = @config = nil
    Nightmare::ClientBase.setup
    @timeout /= 2.0
  end

  def public_listeners
    mod = Nightmare.const_get(Nightmare.use)
    Nightmare::PUBLIC_LISTENERS.each { |sock,_|
      sock.client_class = mod::Client
    }
  end
end
