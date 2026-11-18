//! Expected-fail probe for `testingx.fuzzBytes` under the built-in fuzzer.
//!
//! Run `zig build fuzz-probe --fuzz=200K`. The corpus replays "hello" and
//! passes. Mutation eventually produces an input longer than 8 bytes that does
//! not start with 'h', and the target returns
//! `error.CorpusDidNotContainThisInput`. That failure is the proof that the
//! adapter reaches the fuzzer instead of only replaying the corpus. Do not add
//! this step to `just ci`.

const testingx = @import("testingx");

const max_len = 64;

test "mutation reaches the target" {
    try testingx.fuzzBytes({}, max_len, struct {
        fn one(_: void, input: []const u8) anyerror!void {
            if (input.len > 8 and input[0] != 'h') {
                return error.CorpusDidNotContainThisInput;
            }
        }
    }.one, .{ .corpus = &.{"hello"} });
}
