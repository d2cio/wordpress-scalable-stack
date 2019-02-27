vcl 4.0;

import directors;
import std;

backend default {
  .host = "{{=service('balancer').getAppAlias()}}";
  .port = "{{=service('balancer').getMainPort()}}";
  .max_connections = 800;          # That's it
  .first_byte_timeout = 300s;      # How long to wait before we receive a first byte from our backend?
  .connect_timeout = 300s;         # How long to wait for a backend connection?
  .between_bytes_timeout = 300s;   # How long to wait between bytes received from our backend?
}

sub vcl_init {
    new backends = directors.round_robin();
    backends.add_backend(default);
}

acl purge {
    "172.16.0.0/16";
    "127.0.0.1";
    "localhost";
}

# Regex purging
# Treat the request URL as a regular expression.
sub purge_regex {
    ban("obj.http.X-VC-Req-URL ~ " + req.url + " && obj.http.X-VC-Req-Host == " + req.http.host);
}

# Exact purging
# Use the exact request URL (including any query params)
sub purge_exact {
    ban("obj.http.X-VC-Req-URL == " + req.url + " && obj.http.X-VC-Req-Host == " + req.http.host);
}

# Page purging (default)
# Use the exact request URL, but ignore any query params
sub purge_page {
    set req.url = regsub(req.url, "\?.*$", "");
    ban("obj.http.X-VC-Req-URL-Base == " + req.url + " && obj.http.X-VC-Req-Host == " + req.http.host);
}

# The purge behavior can be controlled with the X-VC-Purge-Method header.
#
# Setting the X-VC-Purge-Method header to contain "regex" or "exact" will use
# those respective behaviors.  Any other value for the X-Purge header will
# use the default ("page") behavior.
#
# The X-VC-Purge-Method header is not case-sensitive.
#
# If no X-VC-Purge-Method header is set, the request url is inspected to attempt
# a best guess as to what purge behavior is expected.  This should work for
# most cases, although if you want to guarantee some behavior you should
# always set the X-VC-Purge-Method header.

sub vcl_recv {
    set req.backend_hint = backends.backend();
    set req.http.X-VC-My-Purge-Key = "";
    if (req.method == "PURGE") {
        if (req.http.X-VC-Purge-Key == req.http.X-VC-My-Purge-Key) {
            set req.http.X-VC-Purge-Key-Auth = "true";
        } else {
            set req.http.X-VC-Purge-Key-Auth = "false";
        }
        if (client.ip !~ purge && req.http.X-VC-Purge-Key-Auth != "true") {
            return (synth(405, "Not allowed from " + client.ip));
        }

        if (req.http.X-VC-Purge-Method) {
            if (req.http.X-VC-Purge-Method ~ "(?i)regex") {
                call purge_regex;
            } elsif (req.http.X-VC-Purge-Method ~ "(?i)exact") {
                call purge_exact;
            } else {
                call purge_page;
            }
        } else {
            # No X-VC-Purge-Method header was specified.
            # Do our best to figure out which one they want.
            if (req.url ~ "\.\*" || req.url ~ "^\^" || req.url ~ "\$$" || req.url ~ "\\[.?*+^$|()]") {
                call purge_regex;
            } elsif (req.url ~ "\?") {
                call purge_exact;
            } else {
                call purge_page;
            }
        }
        return (synth(200,"Purged " + req.url + " " + req.http.host));
    }
    unset req.http.X-VC-My-Purge-Key;
    # unset Varnish Caching custom headers from client
    unset req.http.X-VC-Cacheable;
    unset req.http.X-VC-Debug;
}

sub vcl_backend_response {
    set beresp.http.X-VC-Req-Host = bereq.http.host;
    set beresp.http.X-VC-Req-URL = bereq.url;
    set beresp.http.X-VC-Req-URL-Base = regsub(bereq.url, "\?.*$", "");
}

sub vcl_deliver {
    unset resp.http.X-VC-Req-Host;
    unset resp.http.X-VC-Req-URL;
    unset resp.http.X-VC-Req-URL-Base;
    if (obj.hits > 0) {
        set resp.http.X-VC-Cache = "HIT";
    } else {
        set resp.http.X-VC-Cache = "MISS";
    }

    if (req.http.X-VC-Debug ~ "true" || resp.http.X-VC-Debug ~ "true") {
        set resp.http.X-VC-Hash = req.http.hash;
        if (req.http.X-VC-DebugMessage) {
            set resp.http.X-VC-DebugMessage = req.http.X-VC-DebugMessage;
        }
    } else {
        unset resp.http.X-VC-Enabled;
        unset resp.http.X-VC-Cache;
        unset resp.http.X-VC-Debug;
        unset resp.http.X-VC-DebugMessage;
        unset resp.http.X-VC-Cacheable;
        unset resp.http.X-VC-Purge-Key-Auth;
        unset resp.http.X-VC-TTL;
    }
}

### WordPress-specific config ###
sub vcl_recv {
  if (req.method !~ "^GET|HEAD|PUT|POST|TRACE|OPTIONS|DELETE$") {
    return(pipe);
  }
  # TURN OFF CACHE when needed (just uncomment this only when needed)
  # return(pass);

  ### Do not Cache: special cases
  # don't cache ajax requests
  if (req.http.X-Requested-With == "XMLHttpRequest") {
    set req.http.X-VC-Cacheable = "NO:Requested with: XMLHttpRequest";
    return(pass);
  }

  # don't cache logged-in users. you can set users `logged in cookie` name in settings
  if (req.http.Cookie ~ "wordpress_logged_in_") {
      set req.http.X-VC-Cacheable = "NO:Found logged in cookie";
      return(pass);
  }

  ### looks like we might actually cache it!
  # fix up the request
  set req.url = regsub(req.url, "\?replytocom=.*$", "");

  # never cache anything except GET/HEAD
  if (req.method != "GET" && req.method != "HEAD") {
    set req.http.X-VC-Cacheable = "NO:Request method:" + req.method;
    return(pass);
  }

  # Don't cache feed
  if (req.url ~ "/feed") {
    return (pass);
  }

  if (req.url ~ "/wp-cron.php" || req.url ~ "preview=true") {
    return (pass);
  }

  # Woocommerce
  if (req.url ~ "(cart|my-account|checkout|addons)") {
    return (pass);
  }
  if ( req.url ~ "\?add-to-cart=" ) {
    return (pass);
  }

  # Remove any Google Analytics based cookies
  set req.http.Cookie = regsuball(req.http.Cookie, "__utm.=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "_ga=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "_gat=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "_gid=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "utmctr=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "utmcmd.=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "utmccn.=[^;]+(; )?", "");

  # Remove the Quant Capital cookies (added by some plugin, all __qca)
  set req.http.Cookie = regsuball(req.http.Cookie, "__qc.=[^;]+(; )?", "");

  # Remove the wp-settings cookie
  set req.http.Cookie = regsuball(req.http.Cookie, "wp-settings-\d+=[^;]+(; )?", "");

  # Remove the wp-settings-time cookie
  set req.http.Cookie = regsuball(req.http.Cookie, "wp-settings-time-\d+=[^;]+(; )?", "");

  # Remove the wp test cookie
  set req.http.Cookie = regsuball(req.http.Cookie, "wordpress_test_cookie=[^;]+(; )?", "");

  # Remove has_js and Cloudflare/Google Analytics __* cookies.
  set req.http.Cookie = regsuball(req.http.Cookie, "(^|;\s*)(_[_a-z]+|has_js)=[^;]*", "");

  # Yandex metrica cookies
  set req.http.Cookie = regsuball(req.http.Cookie, "_ym[_a-z0-9]+=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "yabs-sid=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "yp=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "metrics_token=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "yandexuid=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "sync_cookie_csrf=[^;]+(; )?", "");

  # Carrotquest cookies
  set req.http.Cookie = regsuball(req.http.Cookie, "carrotquest[_a-z]+=[^;]+(; )?", "");

  # Remove a ";" prefix, if present.
  set req.http.Cookie = regsuball(req.http.Cookie, "^;\s*", "");

  # Remove the cloudflare cookie
  set req.http.Cookie = regsuball(req.http.Cookie, "__cfduid=[^;]+(; )?", "");

  # Remove the PHPSESSID in members area cookie
  set req.http.Cookie = regsuball(req.http.Cookie, "PHPSESSID=[^;]+(; )?", "");

  # Remove DoubleClick offensive cookies
  set req.http.Cookie = regsuball(req.http.Cookie, "__gads=[^;]+(; )?", "");

  # Remove the AddThis cookies
  set req.http.Cookie = regsuball(req.http.Cookie, "__atuv.=[^;]+(; )?", "");

  # Are there cookies left with only spaces or that are empty?
  if (req.http.Cookie ~ "^\s*$") {
    unset req.http.Cookie;
  }

  # Normalize the query arguments.
  # Note: Placing this above the "do not cache" section breaks some WP theme elements and admin functionality.
  set req.url = std.querysort(req.url);

  # Cache all others requests.
  return (hash);
}

sub vcl_hash {
    set req.http.hash = req.url;
    if (req.http.host) {
        set req.http.hash = req.http.hash + "#" + req.http.host;
    } else {
        set req.http.hash = req.http.hash + "#" + server.ip;
    }
}

sub vcl_backend_response {
    # make sure grace is at least N minutes
    if (beresp.grace < 2m) {
        set beresp.grace = 2m;
    }

    # overwrite ttl with X-VC-TTL
    if (beresp.http.X-VC-TTL) {
        set beresp.ttl = std.duration(beresp.http.X-VC-TTL + "s", 0s);
    }

    # catch obvious reasons we can't cache
    if (beresp.http.Set-Cookie ~ "wordpress_logged_in_") {
        set beresp.ttl = 0s;
    }

    # Don't cache object as instructed by header bereq.X-VC-Cacheable
    if (bereq.http.X-VC-Cacheable ~ "^NO") {
        set beresp.http.X-VC-Cacheable = bereq.http.X-VC-Cacheable;
        set beresp.uncacheable = true;
        set beresp.ttl = 120s;

    # Varnish determined the object is not cacheable
    } else if (beresp.ttl <= 0s) {
        if (!beresp.http.X-VC-Cacheable) {
            set beresp.http.X-VC-Cacheable = "NO:Not cacheable, ttl: "+ beresp.ttl;
        }
        set beresp.uncacheable = true;
        set beresp.ttl = 120s;
    # Cache object
    } else if (beresp.http.X-VC-Enabled ~ "true") {
        if (!beresp.http.X-VC-Cacheable) {
            set beresp.http.X-VC-Cacheable = "YES:Is cacheable, ttl: " + beresp.ttl;
        }

    # Do not cache object
    } else if (beresp.http.X-VC-Enabled ~ "false") {
        if (!beresp.http.X-VC-Cacheable) {
            set beresp.http.X-VC-Cacheable = "NO:Disabled";
        }
        set beresp.ttl = 0s;
    }

    # Avoid caching error responses
    if (beresp.status == 404 || beresp.status >= 500) {
        set beresp.ttl   = 0s;
        set beresp.grace = 15s;
    }

    # Deliver the content
    return(deliver);
}

sub vcl_synth {
    if (resp.status == 750) {
        set resp.http.Location = req.http.X-VC-Redirect;
        set resp.status = 302;
        return(deliver);
    }
}
