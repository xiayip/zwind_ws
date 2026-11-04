#!/usr/bin/env python3
"""Check FIFO 50 permission for the current user without starting ROS/hardware."""

import json
import os
import resource
import sys


def main():
    result = {
        "uid": os.getuid(),
        "rtprio_soft_hard": resource.getrlimit(resource.RLIMIT_RTPRIO),
        "requested_priority": 50,
    }
    policy = os.sched_getscheduler(0)
    priority = os.sched_getparam(0)
    changed = False
    try:
        os.sched_setscheduler(0, os.SCHED_FIFO, os.sched_param(50))
        changed = True
        result["fifo_verified"] = (
            os.sched_getscheduler(0) == os.SCHED_FIFO
            and os.sched_getparam(0).sched_priority == 50
        )
    except OSError as error:
        result["fifo_verified"] = False
        result["error"] = str(error)
    finally:
        if changed:
            os.sched_setscheduler(0, policy, priority)
    # Do all output after restoring the original scheduling policy.
    print(json.dumps(result))
    return 0 if result["fifo_verified"] else 1


if __name__ == "__main__":
    sys.exit(main())
