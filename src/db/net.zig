//! A byte stream to a database server: TCP or Unix socket, optionally upgraded
//! to TLS after the protocol-specific negotiation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const tls = std.crypto.tls;
const TlsClient = @import("tls/Client.zig");
const conninfo = @import("../conninfo.zig");

const connect_timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } };

pub const Transport = struct {
    gpa: Allocator,
    io: Io,
    stream: Io.net.Stream,
    sock_reader: Io.net.Stream.Reader,
    sock_writer: Io.net.Stream.Writer,
    sock_read_buf: []u8,
    sock_write_buf: []u8,
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
            break :blk name.connect(io, port, .{ .mode = .stream, .timeout = connect_timeout }) catch |err| {
                diag.* = @errorName(err);
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
        return t;
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
