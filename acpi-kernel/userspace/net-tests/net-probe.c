// Boot with a virtio-net NIC. The kernel self-test (NTST) resolves the
// gateway through ARP, pings 10.0.2.3 before it is resolved (so the request
// waits in the ARP queue) and 10.0.2.2, and answers an injected echo request
// and UDP datagram, and gets port unreachable for UDP to the host's
// discard port. Everything is driven by the MSI-X vector. This program
// only has to exit; the serial log carries the result.
// net
// expect: virtio-net MAC=52:54:00:12:34:56
// expect: virtio-net gateway 10.0.2.2 is 52:55:0a:00:02:02
// expect: virtio-net ping 10.0.2.3 seq=1 time=
// expect: virtio-net ping 10.0.2.2 seq=2 time=
// expect: virtio-net answered an echo request and a closed UDP port
// expect: virtio-net UDP to 10.0.2.2:9 got port unreachable
#include <stdio.h>

int main(void)
{
    puts("PASS");
    return 0;
}
