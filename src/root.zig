//! RFC 6455 client for TCP and Unix domain sockets.
pub const Connection = @import("Connection.zig");
pub const Endpoint = Connection.Endpoint;
pub const Options = Connection.Options;

test {
    _ = Connection;
}
pub const Kind = Connection.Kind;
pub const Message = Connection.Message;
pub const default_timeout = Connection.default_timeout;
test {
    _ = @import("wire_tests.zig");
}
