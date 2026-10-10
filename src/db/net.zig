//! A byte stream to a database server: TCP or Unix socket, optionally upgraded
//! to TLS after the protocol-specific negotiation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const tls = std.crypto.tls;
const TlsClient = @import("tls/Client.zig");
const conninfo = @import("../conninfo.zig");

const connect_timeout: Io.Duration = .fromSeconds(10);
const read_timeout: Io.Duration = .fromSeconds(300);

/// std.Io.Threaded (Zig 0.17) panics on `ConnectOptions.timeout`, so the
/// timeout is implemented by racing the connect against a sleep.
fn connectWithTimeout(io: Io, name: Io.net.HostName, port: u16) !Io.net.Stream {
    const Race = union(enum) {
        conn: Io.net.HostName.ConnectError!Io.net.Stream,
        timer: Io.Cancelable!void,
    };
    var buf: [2]Race = undefined;
    var race: Io.Select(Race) = .init(io, &buf);
    race.concurrent(.conn, Io.net.HostName.connect, .{ name, io, port, .{ .mode = .stream } }) catch
        return name.connect(io, port, .{ .mode = .stream });
    race.concurrent(.timer, Io.sleep, .{ io, connect_timeout, .awake }) catch {
        // No spare concurrency for the timer: wait for the connect alone.
        const first = try race.await();
        return first.conn;
    };
    const first = try race.await();
    // Stops the other task; returns its result if it finished meanwhile.
    const late = race.cancel();
    switch (first) {
        .conn => |result| return result,
        .timer => {
            // The connect may have succeeded right before it was canceled.
            if (late) |l| switch (l) {
                .conn => |result| if (result) |stream| return stream else |_| {},
                .timer => {},
            };
            return error.Timeout;
        },
    }
}

pub const Transport = struct {
    gpa: Allocator,
    io: Io,
    stream: Io.net.Stream,
    sock_reader: Io.net.Stream.Reader,
    sock_writer: Io.net.Stream.Writer,
    sock_read_buf: []u8,
    sock_write_buf: []u8,
    read_timed_out: bool = false,
    tls_state: ?*TlsState = null,
    ca_bundle_lock: Io.RwLock = .init,
    ca_bundle: std.crypto.Certificate.Bundle = .empty,

    const TlsState = struct {
        client: TlsClient,
        read_buf: []u8,
        write_buf: []u8,
    };

    pub const ConnectError = error{ConnectFailed} || Allocator.Error;

    /// Connects to `host:port`. A host starting with '/' is a directory
    /// containing a Unix socket named by `unix_socket_name(port)`.
    pub fn connect(
        gpa: Allocator,
        io: Io,
        host: []const u8,
        port: u16,
        unix_socket_path: ?[]const u8,
        diag: *[]const u8,
    ) ConnectError!*Transport {
        const stream: Io.net.Stream = if (unix_socket_path) |path| blk: {
            const addr = Io.net.UnixAddress.init(path) catch {
                diag.* = "invalid unix socket path";
                return error.ConnectFailed;
            };
            break :blk addr.connect(io) catch |err| {
                diag.* = @errorName(err);
                return error.ConnectFailed;
            };
        } else blk: {
            const name = Io.net.HostName.init(host) catch {
                diag.* = "invalid host name";
                return error.ConnectFailed;
            };
            break :blk connectWithTimeout(io, name, port) catch |err| {
                diag.* = switch (err) {
                    error.Timeout => "timed out after 10 s (host unreachable or port filtered)",
                    else => @errorName(err),
                };
                return error.ConnectFailed;
            };
        };
        errdefer stream.close(io);

        const t = try gpa.create(Transport);
        errdefer gpa.destroy(t);
        const read_buf = try gpa.alloc(u8, TlsClient.min_buffer_len);
        errdefer gpa.free(read_buf);
        const write_buf = try gpa.alloc(u8, TlsClient.min_buffer_len);
        t.* = .{
            .gpa = gpa,
            .io = io,
            .stream = stream,
            .sock_read_buf = read_buf,
            .sock_write_buf = write_buf,
            .sock_reader = stream.reader(io, read_buf),
            .sock_writer = stream.writer(io, write_buf),
        };
        t.sock_reader.interface.vtable = &.{
            .stream = timedStream,
            .readVec = timedReadVec,
        };
        return t;
    }

    // Zig 0.17's Stream.Reader has no read deadline, so use the same vector
    // read path with an Io timeout. TLS reads through this reader too.
    fn timedStream(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try timedReadVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn timedReadVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const socket_reader: *Io.net.Stream.Reader = @alignCast(@fieldParentPtr("interface", io_r));
        const t: *Transport = @alignCast(@fieldParentPtr("sock_reader", socket_reader));
        var vectors: [8][]u8 = undefined;
        const count, const data_size = try io_r.writableVector(&vectors, data);
        const result = t.io.operateTimeout(.{ .net_read = .{
            .socket_handle = t.stream.socket.handle,
            .data = vectors[0..count],
            .control = socket_reader.control_buffer[socket_reader.control_len..],
        } }, .{ .duration = .{ .raw = read_timeout, .clock = .awake } }) catch |err| {
            if (err == error.Timeout) t.read_timed_out = true;
            if (err == error.Canceled) socket_reader.err = error.Canceled;
            return error.ReadFailed;
        };
        const received = result.net_read catch |err| {
            socket_reader.err = err;
            return error.ReadFailed;
        };
        socket_reader.control_len += received.control_len;
        socket_reader.control_truncated = socket_reader.control_truncated or received.control_truncated;
        if (received.data_len == 0) return error.EndOfStream;
        if (received.data_len > data_size) {
            io_r.end += received.data_len - data_size;
            return data_size;
        }
        return received.data_len;
    }

    pub fn reader(t: *Transport) *Io.Reader {
        if (t.tls_state) |s| return &s.client.reader;
        return &t.sock_reader.interface;
    }

    pub fn writer(t: *Transport) *Io.Writer {
        if (t.tls_state) |s| return &s.client.writer;
        return &t.sock_writer.interface;
    }

    /// Writes buffered data all the way to the socket.
    pub fn flush(t: *Transport) Io.Writer.Error!void {
        if (t.tls_state) |s| {
            try s.client.writer.flush();
        }
        try t.sock_writer.interface.flush();
    }

    /// Upgrades the connection to TLS. `require` encrypts without verifying;
    /// `verify_ca` verifies trust and `verify_full` also verifies the host.
    pub fn startTls(t: *Transport, host: []const u8, mode: conninfo.SslMode, diag: *[]const u8) error{ TlsFailed, OutOfMemory }!void {
        const state = try t.gpa.create(TlsState);
        errdefer t.gpa.destroy(state);
        state.read_buf = try t.gpa.alloc(u8, TlsClient.min_buffer_len);
        errdefer t.gpa.free(state.read_buf);
        state.write_buf = try t.gpa.alloc(u8, TlsClient.min_buffer_len);
        errdefer t.gpa.free(state.write_buf);

        var entropy: [TlsClient.Options.entropy_len]u8 = undefined;
        t.io.random(&entropy);
        state.client = TlsClient.init(&t.sock_reader.interface, &t.sock_writer.interface, .{
            .host = if (mode == .verify_full) .{ .explicit = host } else .no_verification,
            .ca = if (mode == .verify_ca or mode == .verify_full) .{ .bundle = .{
                .gpa = t.gpa,
                .io = t.io,
                .lock = &t.ca_bundle_lock,
                .bundle = &t.ca_bundle,
            } } else .no_verification,
            .read_buffer = state.read_buf,
            .write_buffer = state.write_buf,
            .entropy = &entropy,
            .realtime_now = .now(t.io, .real),
            .allow_truncation_attacks = false,
        }) catch |err| {
            diag.* = switch (err) {
                // std's TLS client cannot answer a CertificateRequest.
                error.TlsUnexpectedMessage => "the server asked for a client certificate, which is not supported yet",
                else => @errorName(err),
            };
            return error.TlsFailed;
        };
        t.tls_state = state;
    }

    pub fn isTls(t: *const Transport) bool {
        return t.tls_state != null;
    }

    pub fn close(t: *Transport) void {
        if (t.tls_state) |s| {
            s.client.end() catch {};
            t.sock_writer.interface.flush() catch {};
            t.gpa.free(s.read_buf);
            t.gpa.free(s.write_buf);
            t.gpa.destroy(s);
        }
        t.stream.close(t.io);
        t.ca_bundle.deinit(t.gpa);
        t.gpa.free(t.sock_read_buf);
        t.gpa.free(t.sock_write_buf);
        t.gpa.destroy(t);
    }
};
