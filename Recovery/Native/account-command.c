#define _GNU_SOURCE
#include "account-command.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static double monotonic_time(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec / 1000000000.0;
}

/* No controlling terminal: dscl's password prompt must read the supplied pipe.
 * Credentials are never argv or environment values. Capture is bounded and the
 * child is always reaped, including launch, timeout and output-limit failures. */
int omarchy_account_command(const char *path, const char *const *arguments,
                            const unsigned char *input, long input_size,
                            unsigned char **output, long *output_size,
                            unsigned timeout_seconds)
{
    int in[2] = {-1, -1}, out[2] = {-1, -1};
    int status = -1, failure = 0;
    pid_t child = -1;
    sigset_t pipe_signal, old_signals, pending;
    sigemptyset(&pipe_signal);
    sigaddset(&pipe_signal, SIGPIPE);
    sigpending(&pending);
    int had_pipe_signal = sigismember(&pending, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &pipe_signal, &old_signals);
    *output = NULL;
    *output_size = 0;
    if (input_size < 0 || input_size > 8192 || !timeout_seconds || timeout_seconds > 90) {
        failure = 1;
        goto cleanup;
    }
    if (pipe(in) || pipe(out)) {
        failure = 1;
        goto cleanup;
    }
    for (unsigned i = 0; i < 2; i++) {
        fcntl(in[i], F_SETFD, FD_CLOEXEC);
        fcntl(out[i], F_SETFD, FD_CLOEXEC);
    }
    child = fork();
    if (child < 0) {
        failure = 1;
        goto cleanup;
    }
    if (child == 0) {
        if (setsid() < 0 || dup2(in[0], STDIN_FILENO) < 0 ||
            dup2(out[1], STDOUT_FILENO) < 0 || dup2(out[1], STDERR_FILENO) < 0)
            _exit(126);
        close(in[0]); close(in[1]); close(out[0]); close(out[1]);
        sigprocmask(SIG_SETMASK, &old_signals, NULL);
        execve(path, (char *const *)arguments, environ);
        _exit(127);
    }
    close(in[0]); in[0] = -1;
    close(out[1]); out[1] = -1;
    fcntl(in[1], F_SETFL, O_NONBLOCK);
    fcntl(out[0], F_SETFL, O_NONBLOCK);
    double deadline = monotonic_time() + timeout_seconds;
    size_t sent = 0, capacity = 0;
    int eof = 0, exited = 0;
    while (!eof || !exited) {
        if (monotonic_time() > deadline) { failure = 1; break; }
        if (in[1] >= 0 && sent < (size_t)input_size) {
            ssize_t count = write(in[1], input + sent, input_size - sent);
            if (count > 0) sent += (size_t)count;
            else if (count < 0 && errno == EPIPE) { close(in[1]); in[1] = -1; }
            else if (count < 0 && errno != EAGAIN && errno != EINTR) { failure = 1; break; }
        }
        if (in[1] >= 0 && sent == (size_t)input_size) { close(in[1]); in[1] = -1; }
        unsigned char buffer[16384];
        ssize_t count;
        while ((count = read(out[0], buffer, sizeof(buffer))) > 0) {
            size_t needed = *output_size + (size_t)count;
            if (needed > 4 * 1024 * 1024) { failure = 1; break; }
            if (needed > capacity) {
                capacity = needed + 16384;
                unsigned char *grown = realloc(*output, capacity);
                if (!grown) { failure = 1; break; }
                *output = grown;
            }
            memcpy(*output + *output_size, buffer, (size_t)count);
            *output_size = needed;
        }
        if (failure) break;
        if (count == 0) eof = 1;
        else if (count < 0 && errno != EAGAIN && errno != EINTR) { failure = 1; break; }
        if (!exited) {
            pid_t result = waitpid(child, &status, WNOHANG);
            if (result == child) exited = 1;
            else if (result < 0 && errno != EINTR) { failure = 1; break; }
        }
        if (!eof || !exited) {
            struct pollfd descriptor = {out[0], POLLIN | POLLHUP, 0};
            poll(&descriptor, 1, 20);
        }
    }
    if (failure) {
        kill(-child, SIGKILL);
        if (!exited) {
            kill(child, SIGKILL);
            while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
        }
    }
cleanup:
    for (unsigned i = 0; i < 2; i++) {
        if (in[i] >= 0) close(in[i]);
        if (out[i] >= 0) close(out[i]);
    }
    sigpending(&pending);
    if (!had_pipe_signal && sigismember(&pending, SIGPIPE)) {
        int signal_number;
        sigwait(&pipe_signal, &signal_number);
    }
    pthread_sigmask(SIG_SETMASK, &old_signals, NULL);
    return failure || !WIFEXITED(status) ? -1 : WEXITSTATUS(status);
}

void omarchy_account_free(void *buffer) { free(buffer); }
