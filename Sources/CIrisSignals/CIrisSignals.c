#include "CIrisSignals.h"
#include <signal.h>
#include <stdatomic.h>

static _Atomic long deliveries = 0;
/// 0 until exit-now asks.
static _Atomic long interrupt_default_at = 0;

/// Only our own catch is reset: an inherited ignore (plan note 16) stays ignored.
static void restore_interrupt_default(void) {
    struct sigaction now;
    if (sigaction(SIGINT, NULL, &now) != 0) return;
    if (now.sa_handler == SIG_DFL || now.sa_handler == SIG_IGN) return;
    struct sigaction dfl = {0};
    dfl.sa_handler = SIG_DFL;
    sigemptyset(&dfl.sa_mask);
    sigaction(SIGINT, &dfl, NULL);
}

void iris_stop_signal_handler(int signal) {
    (void)signal;
    long delivered = atomic_fetch_add(&deliveries, 1) + 1;
    long at = atomic_load(&interrupt_default_at);
    if (at > 0 && delivered >= at) restore_interrupt_default();
}

void iris_reset_interrupt_once_delivered(long count) {
    atomic_store(&interrupt_default_at, count);
    if (atomic_load(&deliveries) >= count) restore_interrupt_default();
}
