#ifndef CIRIS_SIGNALS_H
#define CIRIS_SIGNALS_H

/// The CLI's handler for SIGINT, SIGTERM and SIGHUP (#463 decision 16, #510). It only counts the
/// delivery and, once exit-now has asked, puts SIGINT back to its default: async-signal-safe C, so
/// nothing in it can allocate, lock or retain.
void iris_stop_signal_handler(int signal);

/// SIGINT goes back to its default once `count` stopping signals have been delivered: at once if
/// they have, otherwise from the handler of the one still on its way.
void iris_reset_interrupt_once_delivered(long count);

#endif
