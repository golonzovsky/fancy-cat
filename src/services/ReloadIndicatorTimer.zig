const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Config = @import("../config/Config.zig");
const Event = @import("../Context.zig").Event;

const c = struct {
    pub const timespec = extern struct {
        tv_sec: c_long,
        tv_nsec: c_long,
    };
    pub extern "c" fn nanosleep(req: *const timespec, rem: ?*timespec) c_int;
};

fn sleepNanos(ns: u64) void {
    var req = c.timespec{
        .tv_sec = @intCast(ns / std.time.ns_per_s),
        .tv_nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = c.nanosleep(&req, null);
}

should_quit: std.atomic.Value(bool),
pending: std.atomic.Value(bool),
generation: std.atomic.Value(usize),
last_change_ns: std.atomic.Value(i64),
thread: ?std.Thread,
loop: ?*vaxis.Loop(Event),
reload_indicator_duration_ns: u64,
config: *Config,

fn nowNs() i64 {
    var ts: c.timespec = undefined;
    const clock_fn = struct {
        pub extern "c" fn clock_gettime(clk: c_int, ts: *c.timespec) c_int;
    };
    const CLOCK_MONOTONIC: c_int = 6;
    _ = clock_fn.clock_gettime(CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * std.time.ns_per_s + @as(i64, ts.tv_nsec);
}

pub fn init(config: *Config) Self {
    return .{
        .should_quit = .init(false),
        .pending = .init(false),
        .generation = .init(0),
        .last_change_ns = .init(0),
        .thread = null,
        .loop = null,
        .reload_indicator_duration_ns = 0,
        .config = config,
    };
}

pub fn deinit(self: *Self) void {
    self.should_quit.store(true, .release);
    if (self.thread) |thread| {
        thread.join();
        self.thread = null;
    }
}

pub fn start(self: *Self, loop: ?*vaxis.Loop(Event)) !void {
    self.reload_indicator_duration_ns = @as(u64, @intFromFloat(@as(f32, self.config.file_monitor.reload_indicator_duration) * std.time.ns_per_s));
    self.loop = loop;
    self.last_change_ns.store(nowNs(), .release);

    if (self.thread == null) {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }
}

fn run(self: *Self) void {
    const check_interval_ns: u64 = @max(self.reload_indicator_duration_ns / 4, std.time.ns_per_ms * 100);
    while (!self.should_quit.load(.acquire)) {
        sleepNanos(check_interval_ns);
        if (!self.pending.load(.acquire)) continue;
        const elapsed = nowNs() - self.last_change_ns.load(.acquire);
        if (elapsed >= @as(i64, @intCast(self.reload_indicator_duration_ns))) {
            const gen = self.generation.load(.acquire);
            if (self.loop) |loop| loop.postEvent(.{ .reload_done = gen }) catch {};
            self.pending.store(false, .release);
        }
    }
}

pub fn notifyChange(self: *Self) void {
    _ = self.generation.fetchAdd(1, .release);
    self.last_change_ns.store(nowNs(), .release);
    self.pending.store(true, .release);
}
