const std = @import("std");

// std.time lost sleep/timestamp helpers with the 0.16 Io rework; call libc directly.
const c = struct {
    pub const timespec = extern struct {
        tv_sec: c_long,
        tv_nsec: c_long,
    };
    pub extern "c" fn clock_gettime(clk: c_int, ts: *timespec) c_int;
    pub extern "c" fn nanosleep(req: *const timespec, rem: ?*timespec) c_int;
};

const CLOCK_MONOTONIC: c_int = 6; // macOS values
const CLOCK_REALTIME: c_int = 0;

pub fn nowNs() i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * std.time.ns_per_s + @as(i64, ts.tv_nsec);
}

pub fn nowRealSeconds() i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(CLOCK_REALTIME, &ts);
    return @as(i64, ts.tv_sec);
}

pub fn milliTimestamp() i64 {
    return @divTrunc(nowNs(), std.time.ns_per_ms);
}

pub fn sleep(ns: u64) void {
    var req = c.timespec{
        .tv_sec = @intCast(ns / std.time.ns_per_s),
        .tv_nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = c.nanosleep(&req, null);
}
