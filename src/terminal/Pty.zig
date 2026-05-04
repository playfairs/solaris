const std = @import("std");
const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("sys/types.h");
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("errno.h");
});


allocator: std.mem.Allocator,
master_fd: c_int,
slave_fd: c_int,
child_pid: std.c.pid_t,
pollfd: std.os.poll.fd,

const Self = @This();

pub const PtyError = error{
    OpenFailed,
    GrantFailed,
    UnlockFailed,
    ForkFailed,
    ExecFailed,
    IoctlFailed,
    WindowSizeFailed,
};

pub fn open(allocator: std.mem.Allocator, shell_path: []const u8, cols: u16, rows: u16) !Self {
    var master: c_int = undefined;
    var slave: c_int = undefined;

    if (c.openpty(&master, &slave, null, null, null) != 0) {
        std.log.err("openpty failed: {s}", .{std.c.strerror(std.c._errno().*)});
        return error.OpenFailed;
    }

    const flags = c.fcntl(master, c.F_GETFL, 0);
    _ = c.fcntl(master, c.F_SETFL, flags | c.O_NONBLOCK);

    var ws: c.winsize = .{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    _ = c.ioctl(master, c.TIOCSWINSZ, &ws);

    const pid = std.c.fork();
    if (pid < 0) {
        return error.ForkFailed;
    }

    if (pid == 0) {
        _ = c.close(master);
        _ = c.setsid();
        _ = c.ioctl(slave, c.TIOCSCTTY, 0);

        _ = c.dup2(slave, c.STDIN_FILENO);
        _ = c.dup2(slave, c.STDOUT_FILENO);
        _ = c.dup2(slave, c.STDERR_FILENO);

        if (slave > c.STDERR_FILENO) {
            _ = c.close(slave);
        }

        const shell_z = try allocator.dupeZ(u8, shell_path);
        defer allocator.free(shell_z);

        const args = [_:null]?[*:0]const u8{
            shell_z,
            null,
        };

        _ = c.execvp(shell_z, &args);
        std.c.exit(1);
    }

    _ = c.close(slave);

    return .{
        .allocator = allocator,
        .master_fd = master,
        .slave_fd = -1,
        .child_pid = pid,
        .pollfd = .{
            .fd = master,
            .events = std.c.POLL.IN,
            .revents = 0,
        },
    };
}

pub fn close(self: *Self) void {
    if (self.master_fd >= 0) {
        _ = std.c.close(self.master_fd);
        self.master_fd = -1;
    }
}

pub fn write(self: *Self, data: []const u8) !void {
    if (self.master_fd < 0) return error.NotOpen;

    var total_written: usize = 0;
    while (total_written < data.len) {
        const written = std.c.write(self.master_fd, data[total_written..].ptr, data.len - total_written);
        if (written < 0) {
            const errno = std.c._errno().*;
            if (errno == c.EAGAIN or errno == c.EINTR) {
                std.time.sleep(1_000_000);
                continue;
            }
            return error.WriteFailed;
        }
        total_written += @intCast(written);
    }
}

pub fn read(self: *Self, buffer: []u8) !usize {
    if (self.master_fd < 0) return error.NotOpen;

    const n = std.c.read(self.master_fd, buffer.ptr, buffer.len);
    if (n < 0) {
        const errno = std.c._errno().*;
        if (errno == c.EAGAIN or errno == c.EINTR) {
            return 0;
        }
        if (errno == c.EIO) {
            return 0;
        }
        return error.ReadFailed;
    }
    return @intCast(n);
}

pub fn hasData(self: *Self) !bool {
    if (self.master_fd < 0) return false;

    var pollfd_copy = self.pollfd;
    const ready = std.c.poll(&pollfd_copy, 1, 0);
    if (ready < 0) {
        const errno = std.c._errno().*;
        if (errno == c.EINTR) return false;
        return error.PollFailed;
    }
    return ready > 0 and (pollfd_copy.revents & std.c.POLL.IN) != 0;
}

pub fn setWindowSize(self: *Self, cols: u16, rows: u16) !void {
    if (self.master_fd < 0) return error.NotOpen;

    var ws: c.winsize = .{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    if (c.ioctl(self.master_fd, c.TIOCSWINSZ, &ws) != 0) {
        return error.WindowSizeFailed;
    }
}

pub fn isRunning(self: *Self) bool {
    if (self.child_pid <= 0) return false;

    var status: c_int = 0;
    const result = std.c.waitpid(self.child_pid, &status, std.c.W.WNOHANG);
    if (result < 0) return false;
    if (result == 0) return true;

    self.child_pid = 0;
    return false;
}

pub fn signal(self: *Self, signo: u8) !void {
    if (self.child_pid > 0) {
        _ = std.c.kill(self.child_pid, signo);
    }
}
