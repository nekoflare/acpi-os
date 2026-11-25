// ACPI OS defaults for Alpine's firefox-esr, installed beside Alpine's
// vendor.js in browser/defaults/preferences.

// The kernel has no IPv6. Firefox connects to a host's AAAA address first,
// and socket(AF_INET6) failing with EAFNOSUPPORT ends the load with "Firefox
// doesn't know how to communicate with the server" instead of trying IPv4.
pref("network.dns.disableIPv6", true);

// HTTP/3 (QUIC over UDP) fails to start a session here (Http3Session::Init
// returns NS_ERROR_UNEXPECTED) and Firefox then fails the request instead of
// retrying over TCP. Sites that advertise h3 in their DNS HTTPS record, which
// is most large ones, never loaded. Use HTTP/1.1 and HTTP/2 over TCP.
pref("network.http.http3.enable", false);
