vcl 4.0;

import std;
import directors;

backend server1 {
  	.host = "127.0.0.1";
  	.port = "8080";
	.max_connections = 300;
	.first_byte_timeout = 300s;
	.connect_timeout = 5s;
	.between_bytes_timeout = 2s;
}

sub vcl_init {
	new vdir = directors.round_robin();
	vdir.add_backend(server1);
}

acl purge {
	"localhost";
	"127.0.0.1";
	"::1";
}

sub vcl_recv {
	set req.backend_hint = vdir.backend(); # send all traffic to the vdir director
	
	if (req.url ~ "^/admin"){
		return (pass);
	}

	if (req.restarts == 0) {
		if (req.http.X-Forwarded-For) { # set or append the client.ip to X-Forwarded-For header
			set req.http.X-Forwarded-For = req.http.X-Forwarded-For + ", " + client.ip;
		} else {
			set req.http.X-Forwarded-For = client.ip;
		}
	}
	set req.http.Host = regsub(req.http.Host, ":[0-9]+", "");
	set req.url = std.querysort(req.url);
	if (req.method == "PURGE") {
		if (!client.ip ~ purge) { # purge is the ACL defined at the begining
			return (synth(405, "This IP is not allowed to send PURGE requests."));
		}
		return (purge);
	}

	if (req.method != "GET" &&
		req.method != "HEAD" &&
		req.method != "PUT" &&
		req.method != "POST" &&
		req.method != "TRACE" &&
		req.method != "OPTIONS" &&
		req.method != "PATCH" &&
		req.method != "DELETE") {
		return (pipe);
	}

	if (req.http.Upgrade ~ "(?i)websocket") {
		return (pipe);
	}

	if (req.method != "GET" && req.method != "HEAD") {
		return (pass);
	}

	if (req.url ~ "(\?|&)(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=") {
		set req.url = regsuball(req.url, "&(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=([A-z0-9_\-\.%25]+)", "");
		set req.url = regsuball(req.url, "\?(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=([A-z0-9_\-\.%25]+)", "?");
		set req.url = regsub(req.url, "\?&", "?");
		set req.url = regsub(req.url, "\?$", "");
	}

	if (req.url ~ "\#") {
		set req.url = regsub(req.url, "\#.*$", "");
	}

	if (req.url ~ "\?$") {
		set req.url = regsub(req.url, "\?$", "");
	}

	set req.http.Cookie = regsuball(req.http.Cookie, "has_js=[^;]+(; )?", "");

	set req.http.Cookie = regsuball(req.http.Cookie, "__utm.=[^;]+(; )?", "");
	set req.http.Cookie = regsuball(req.http.Cookie, "_ga=[^;]+(; )?", "");
	set req.http.Cookie = regsuball(req.http.Cookie, "utmctr=[^;]+(; )?", "");
	set req.http.Cookie = regsuball(req.http.Cookie, "utmcmd.=[^;]+(; )?", "");
	set req.http.Cookie = regsuball(req.http.Cookie, "utmccn.=[^;]+(; )?", "");

	set req.http.Cookie = regsuball(req.http.Cookie, "__gads=[^;]+(; )?", "");

	set req.http.Cookie = regsuball(req.http.Cookie, "__qc.=[^;]+(; )?", "");

	set req.http.Cookie = regsuball(req.http.Cookie, "__atuv.=[^;]+(; )?", "");

	set req.http.Cookie = regsuball(req.http.Cookie, "^;\s*", "");

	if (req.http.cookie ~ "^\s*$") {
		unset req.http.cookie;
	}

	if (req.http.Accept-Encoding) {
		if (req.url ~ "\.(jpg|png|gif|gz|tgz|bz2|tbz|mp3|ogg)$") {
			unset req.http.Accept-Encoding;
		} elsif (req.http.Accept-Encoding ~ "gzip") {
			set req.http.Accept-Encoding = "gzip";
		} elsif (req.http.Accept-Encoding ~ "deflate") {
			set req.http.Accept-Encoding = "deflate";
		} else {
			unset req.http.Accept-Encoding;
		}
	}

	if (req.http.Cache-Control ~ "(?i)no-cache") {
		if (! (req.http.Via || req.http.User-Agent ~ "(?i)bot" || req.http.X-Purge)) {
			return(purge); # Couple this with restart in vcl_purge and X-Purge header to avoid loops
		}
	}

	if (req.url ~ "^[^?]*\.(mp[34]|rar|tar|tgz|gz|wav|zip|bz2|xz|7z|avi|mov|ogm|mpe?g|mk[av])(\?.*)?$") {
		unset req.http.Cookie;
		return (hash);
	}

	if (req.url ~ "^[^?]*\.(bmp|bz2|css|doc|eot|flv|gif|gz|ico|jpeg|jpg|js|less|pdf|png|rtf|swf|txt|woff|xml)(\?.*)?$") {
		unset req.http.Cookie;
		return (hash);
	}
	
	set req.http.Surrogate-Capability = "key=ESI/1.0";

	if (req.http.Authorization) {
		return (pass);
	}

	return (hash);
}

sub vcl_pipe {
	if (req.http.upgrade) {
		set bereq.http.upgrade = req.http.upgrade;
	}

	return (pipe);
}

sub vcl_pass {
	
}

sub vcl_hash {
	hash_data(req.url);

	if (req.http.host) {
		hash_data(req.http.host);
	} else {
		hash_data(server.ip);
	}

	if (req.http.Cookie) {
		hash_data(req.http.Cookie);
	}
}

sub vcl_hit {
	if (obj.ttl >= 0s) {
		return (deliver);
	}

	if (std.healthy(req.backend_hint)) {
		if (obj.ttl + 10s > 0s) {
			return (deliver);
		} else {
			return(fetch);
		}
	} else {
		if (obj.ttl + obj.grace > 0s) {
			return (deliver);
		} else {
			return (fetch);
		}
	}

	return (fetch); # Dead code, keep as a safeguard
}

sub vcl_miss {
	
}

sub vcl_backend_response {
	if (beresp.http.Surrogate-Control ~ "ESI/1.0") {
		unset beresp.http.Surrogate-Control;
		set beresp.do_esi = true;
	}

	if (bereq.url ~ "^[^?]*\.(bmp|bz2|css|doc|eot|flv|gif|gz|ico|jpeg|jpg|js|less|mp[34]|pdf|png|rar|rtf|swf|tar|tgz|txt|wav|woff|xml|zip)(\?.*)?$") {
		unset beresp.http.set-cookie;
	}

	if (bereq.url ~ "^[^?]*\.(mp[34]|rar|tar|tgz|gz|wav|zip|bz2|xz|7z|avi|mov|ogm|mpe?g|mk[av])(\?.*)?$") {
		unset beresp.http.set-cookie;
		set beresp.do_stream = true;  # Check memory usage it'll grow in fetch_chunksize blocks (128k by default) if
		set beresp.do_gzip = false; # Don't try to compress it for storage
	}

	if (beresp.status == 301 || beresp.status == 302) {
		set beresp.http.Location = regsub(beresp.http.Location, ":[0-9]+", "");
	}

	if (beresp.ttl <= 0s || beresp.http.Set-Cookie || beresp.http.Vary == "*") {
		set beresp.ttl = 120s; # Important, you shouldn't rely on this, SET YOUR HEADERS in the backend
		set beresp.uncacheable = true;
		return (deliver);
	}

	set beresp.grace = 6h;

	return (deliver);
}

sub vcl_deliver {
	if (obj.hits > 0) { # Add debug header to see if it's a HIT/MISS and the number of hits, disable when not needed
		set resp.http.X-Cache = "HIT";
	} else {
		set resp.http.X-Cache = "MISS";
	}

	set resp.http.X-Cache-Hits = obj.hits;

	unset resp.http.X-Powered-By;

	unset resp.http.Server;
	unset resp.http.X-Drupal-Cache;
	unset resp.http.X-Varnish;
	unset resp.http.Via;
	unset resp.http.Link;
	unset resp.http.X-Generator;

	return (deliver);
}

sub vcl_purge {
	if (req.method != "PURGE") {
		set req.http.X-Purge = "Yes";
		return(restart);
	}
}

sub vcl_synth {
	if (resp.status == 720) {
		set resp.status = 301;
		set resp.http.Location = resp.reason;
		return (deliver);
	} elseif (resp.status == 721) {
		set resp.status = 302;
		set resp.http.Location = resp.reason;
		return (deliver);
	}

	return (deliver);
}


sub vcl_fini {
	return (ok);
}