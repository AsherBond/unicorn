# -*- encoding: binary -*-
module Nightmare::Poll::Base
  POLLSET = Nightmare::Poll::POLLSET
  attr_reader :expire_at

  # yields request processing to another client
  def nm_yield(symbol, timeout_param)
    @expire_at = Nightmare.expiry_for(timeout_param)
    POLLSET[self] = symbol
  end

  def done
    POLLSET.delete(self)
    close
  end
end
