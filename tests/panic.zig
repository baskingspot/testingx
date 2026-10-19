//! Fixture for the panic handler: one panicking test, no passing tests.

test "panic demonstration" {
    @panic("intentional panic");
}
