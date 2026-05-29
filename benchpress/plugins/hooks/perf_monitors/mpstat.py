#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-unsafe

import subprocess

from . import Monitor


class MPStat(Monitor):
    def __init__(self, interval, job_uuid):
        super(MPStat, self).__init__(interval, "mpstat", job_uuid)
        self.headers = []

    def run(self):
        args = ["mpstat", "-u", f"{self.interval}"]
        self.proc = subprocess.Popen(args, stdout=subprocess.PIPE, encoding="utf-8")
        super(MPStat, self).run()

    def process_output(self, line):
        """
        Process mpstat output line by line. The leading timestamp depends on
        the locale: 12-hour with a separate AM/PM token ("01:14:56 PM") or
        24-hour with no token ("13:14:56"), so the "CPU"/"all" marker is not at
        a fixed column. We locate the marker token instead. Example output:
        ```
        Linux 5.12.0-xxxxxx (server.hostname)  10/24/2023    _x86_64_        (32 CPU)

        01:14:56 PM  CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
        01:14:57 PM  all    2.80    0.00    2.61    0.00    0.00    0.06    0.06    0.00    0.00   94.47
        01:14:58 PM  all    5.14    0.00    2.02    0.03    0.00    0.06    0.06    0.00    0.00   92.68
        ```
        With a 24-hour locale the same rows read "13:14:56  CPU ..." /
        "13:14:57  all ..." (one fewer leading token).
        """
        cells = line.split()
        if len(cells) < 2:
            return
        # The trailing "Average:" line mpstat prints on exit also carries an
        # "all" token but no real timestamp -- skip it.
        if cells[0].startswith("Average"):
            return
        if "CPU" in cells:
            if len(self.headers) == 0:
                self.headers = cells[cells.index("CPU") + 1:]
        elif "all" in cells:
            idx = cells.index("all")
            values = cells[idx + 1:]
            if len(self.headers) == 0 or len(values) != len(self.headers):
                return
            obj = {"timestamp": " ".join(cells[:idx])}
            for i in range(len(self.headers)):
                obj[self.headers[i]] = float(values[i])
            self.res.append(obj)
