#ifndef AMLAOT_ST_POLL_H
#define AMLAOT_ST_POLL_H

#include <errno.h>
#include <poll.h>
#include <sys/select.h>

/* st only waits on the X connection and the terminal stream. */
static int
guest_pselect(int nfds, fd_set *reads, fd_set *writes, fd_set *errors,
              const struct timespec *timeout, const sigset_t *mask)
{
    struct pollfd descriptors[2];
    nfds_t count = 0;
    if (nfds < 0 || nfds > FD_SETSIZE || errors) {
        errno = EINVAL;
        return -1;
    }
    for (int fd = 0; fd < nfds; ++fd) {
        short events = 0;
        if (reads && FD_ISSET(fd, reads))
            events |= POLLIN;
        if (writes && FD_ISSET(fd, writes))
            events |= POLLOUT;
        if (!events)
            continue;
        if (count == sizeof(descriptors) / sizeof(descriptors[0])) {
            errno = EINVAL;
            return -1;
        }
        descriptors[count++] = (struct pollfd){.fd = fd, .events = events};
    }

    int result = ppoll(descriptors, count, timeout, mask);
    if (result < 0)
        return -1;
    if (reads)
        FD_ZERO(reads);
    if (writes)
        FD_ZERO(writes);
    result = 0;
    for (nfds_t i = 0; i < count; ++i) {
        struct pollfd entry = descriptors[i];
        if (entry.revents & POLLNVAL) {
            errno = EBADF;
            return -1;
        }
        if ((entry.events & POLLIN) && (entry.revents & (POLLIN | POLLERR | POLLHUP))) {
            FD_SET(entry.fd, reads);
            ++result;
        }
        if ((entry.events & POLLOUT) && (entry.revents & (POLLOUT | POLLERR | POLLHUP))) {
            FD_SET(entry.fd, writes);
            ++result;
        }
    }
    return result;
}

#define pselect guest_pselect
#endif
