class Nightmare::Poll::Client < Nightmare::ClientBase
  include Nightmare::Poll::Base
  Upstream = Nightmare::Poll::Upstream

  def dispatch
    POLLSET.delete(self)
    Nightmare.MOAR! do
      Upstream.start(UPSTREAMS[0])
    end.evloop_once(self, @parser.env, @input)
  end
end
