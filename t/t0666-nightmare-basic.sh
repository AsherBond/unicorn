#!/bin/sh
. ./test-lib.sh
t_plan 32 "basic Nightmare upstream tests"

t_begin "setup and start" && {
	unicorn_setup
	rtmpfiles curl_err
	echo 'Nightmare!' >> $unicorn_config
	unicorn -E deployment -D -c $unicorn_config nightmare-upstream.ru
	random_blob_sha1=$(rsha1 < random_blob)
	random_blob_sha1_1m=$(dd if=random_blob bs=1M count=1 | rsha1)
	unicorn_wait_start
}

t_begin "dying backend gives 502" && {
	curl -sSfv http://$listen/die/now 2>$curl_err || echo ok > $ok
	test x"$(cat $ok)" = xok
	grep '\<502\>' < $curl_err
}

t_begin "burst pipelining PUT requests" && {
	expect=$(printf 'Hello\n' |rsha1)
	first='PUT /sha1 HTTP/1.1\r\nHost: example.com\r\n'
	input='Content-Length: 6\r\n\r\nHello\n'
	req="$first$input$first"'Connection: close\r\n'"$input"
	(
		cat $fifo > $tmp &
		printf "$req"
		wait
		echo ok > $ok
	) | socat - TCP:$listen > $fifo
        test 2 -eq $(grep "^${expect}$" $tmp | wc -l)
}

t_begin "small upload is read correctly" && {
	curl -T nightmare-upstream.ru -sSvf -H Expect: \
	  http://$listen/sha1 > $tmp 2>$curl_err
	test x"$(cat $tmp)" = x"$(rsha1 < nightmare-upstream.ru)"
}

t_begin "small chunked upload is read correctly" && {
	curl -T- < nightmare-upstream.ru -sSvf -H Expect: \
	  http://$listen/sha1 > $tmp 2>$curl_err
	test x"$(cat $tmp)" = x"$(rsha1 < nightmare-upstream.ru)"
}

t_begin "1M chunked upload is read correctly" && {
	dd if=random_blob bs=1M count=1 | \
	  curl -T- --trace-ascii /tmp/foo -sSf -H Expect: \
	  http://$listen/sha1 > $tmp 2>$curl_err
	test x"$(cat $tmp)" = x"$random_blob_sha1_1m"
}

t_begin "pipelining partial requests" && {
	req='GET /env HTTP/1.1\r\nHost: example.com\r\n'
	(
		cat $fifo > $tmp &
		printf "$req"'\r\n'"$req"
		sleep 1
		printf 'Connection: close\r\n\r\n'
		wait
		echo ok > $ok
	) | socat - TCP:$listen > $fifo
}
dbgcat tmp

t_begin "two HTTP/1.1 responses" && {
	test 2 -eq $(grep '^HTTP/1.1' $tmp | wc -l)
}

t_begin "two HTTP/1.1 200 OK responses" && {
	test 2 -eq $(grep '^HTTP/1.1 200 OK' $tmp | wc -l)
}

t_begin 'one "Connection: keep-alive" response' && {
	test 1 -eq $(grep '^Connection: keep-alive' $tmp | wc -l)
}

t_begin 'one "Connection: close" response' && {
	test 1 -eq $(grep '^Connection: close' $tmp | wc -l)
}

t_begin 'check subshell success' && {
	test x"$(cat $ok)" = xok
}

t_begin "check stderr" && {
	check_stderr
}

t_begin "burst pipelining requests" && {
	req='GET /env HTTP/1.1\r\nHost: example.com\r\n'
	(
		cat $fifo > $tmp &
		printf "$req"'\r\n'"$req"'Connection: close\r\n\r\n'
		wait
		echo ok > $ok
	) | socat - TCP:$listen > $fifo
}

dbgcat tmp
dbgcat r_err

t_begin "got 2 HTTP/1.1 responses from pipelining" && {
	test 2 -eq $(grep '^HTTP/1.1' $tmp | wc -l)
}

t_begin "got 2 HTTP/1.1 200 OK responses" && {
	test 2 -eq $(grep '^HTTP/1.1 200 OK' $tmp | wc -l)
}

t_begin "one keepalive connection" && {
	test 1 -eq $(grep '^Connection: keep-alive' $tmp | wc -l)
}

t_begin "second request closes connection" && {
	test 1 -eq $(grep '^Connection: close' $tmp | wc -l)
}

t_begin "subshell exited correctly" && {
	test x"$(cat $ok)" = xok
}

t_begin "stderr log has no errors" && {
	check_stderr
}

t_begin "HTTP/0.9 request should not return headers" && {
	(
		printf 'GET /env\r\n'
		cat $fifo > $tmp &
		wait
		echo ok > $ok
	) | socat - TCP:$listen > $fifo
}

dbgcat tmp
dbgcat r_err

t_begin "env.inspect should've put everything on one line" && {
	test 1 -eq $(wc -l < $tmp)
}

t_begin "no headers in output" && {
	if grep ^Connection: $tmp
	then
		die "Connection header found in $tmp"
	elif grep ^HTTP/ $tmp
	then
		die "HTTP/ found in $tmp"
	fi
}

t_begin "new X-Forwarded-For set" && {
	curl -sSfv 2> $curl_err http://$listen/env | \
	  grep -F '"HTTP_X_FORWARDED_FOR"=>"127.0.0.1"'
}

t_begin "existing X-Forwarded-For preserved" && {
	curl -sSfv -H X-Forwarded-For:0.6.6.6 2> $curl_err \
	  http://$listen/env | \
	  grep -F '"HTTP_X_FORWARDED_FOR"=>"0.6.6.6,127.0.0.1"'
}

t_begin "keepalive works" && {
	curl -sSfv 2>$curl_err http://$listen/time http://$listen/time
	grep 'Re-using existing connection' $curl_err
}

t_begin "random_blob transferred correctly at full speed" && {
	got_sha1=$(curl -sSfv 2> $curl_err http://$listen/random_blob | rsha1)
	test x"$got_sha1" = x"$random_blob_sha1"
}

t_begin "2x random_blob transferred correctly at full speed" && {
	got_sha1=$(curl -sSfv 2> $curl_err \
           http://$listen/random_blob http://$listen/random_blob | rsha1)
	test x"$got_sha1" = x"$(cat random_blob random_blob | rsha1)"
}

t_begin "other requests succeed during rate-limited random_blob download" && {
	rtmpfiles a b c d e
	delay=1
	for i in a b c d e
	do
		delay=$(($delay + 1))
		(
			eval 'out=$'$i
			sleep $delay
			curl -sSf http://$listen/time > $out
		) &
	done

	got_sha1=$(time curl -sSfv --limit-rate 1M 2> $curl_err \
	           http://$listen/random_blob | rsha1)
	test x"$got_sha1" = x"$random_blob_sha1"
	before=$($RUBY -e "puts Time.now.to_i")
	wait
	after=$($RUBY -e "puts Time.now.to_i")
	diff=$(($after - $before))
	test $diff -le 1

	for i in a b c d e
	do
		eval 'out=$'$i
		# t_info "$i: $(( $before - $(cat $out) ))"
		test $(cat $out) -lt $before
	done
}

t_begin "graceful shutdown succeeds while random_blob is transferred" && {
	(
		sleep 2
		kill -QUIT $unicorn_pid
	) &
	got_sha1=$(time curl -sSfv 2> $curl_err --limit-rate 5M \
	           http://$listen/random_blob | rsha1)
	test x"$got_sha1" = x"$random_blob_sha1"
	wait
}

t_begin "gracefully shut down correctly" && {
	sleep 1
	if kill -0 $unicorn_pid >/dev/null 2>&1
	then
		die "$unicorn_pid is still running"
	fi
}

t_begin "check stderr has no errors" && {
	check_stderr
}

t_done
