# -*- encoding: binary -*-
# For MRI 1.8, where Kgio.poll isn't supported
module Nightmare::Poll
  FakePoll = lambda do |pollset, timeout|
    tmp = { :wait_readable => [], :wait_writable => [] }
    pollset.each { |io,val| tmp[val] << io }
    timeout /= 1000.0 # Kgio.poll uses milliseconds, IO.select uses seconds
    if rv = IO.select(tmp[:wait_readable], tmp[:wait_writable], nil, timeout)
      pollset.clear
      rv.flatten!.each { |io| pollset[io] = false }
      return pollset
    end
  end
end
