//! RFC 6455 client for TCP and Unix domain sockets.
pub const Connection = @import("Connection.zig");
pub const Endpoint = Connection.Endpoint;
pub const Options = Connection.Options;

test {
    _ = Connection;
}
