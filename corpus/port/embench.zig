//! The board layer Embench expects, over port.zig: no board setup, empty timing triggers, and a
//! main that runs one benchmark once after warming, verifies it, and prints P or F followed by the
//! result in hex so the console CRC pins both, returning nonzero on failure.

const warmup_heat = 1;

extern fn console_put(c: u8) void;
extern fn initialise_benchmark() void;
extern fn warm_caches(heat: c_int) void;
extern fn benchmark() c_int;
extern fn verify_benchmark(result: c_int) c_int;

comptime {
    @export(&initialiseBoard, .{ .name = "initialise_board" });
    @export(&startTrigger, .{ .name = "start_trigger" });
    @export(&stopTrigger, .{ .name = "stop_trigger" });
}

fn initialiseBoard() callconv(.c) void {}
noinline fn startTrigger() callconv(.c) void {}
noinline fn stopTrigger() callconv(.c) void {}

fn putHex(value: u32) void {
    var i: u5 = 28;
    while (true) : (i -= 4) {
        console_put("0123456789abcdef"[(value >> i) & 15]);
        if (i == 0) break;
    }
}

export fn main() c_int {
    initialiseBoard();
    initialise_benchmark();
    warm_caches(warmup_heat);
    startTrigger();
    const result = benchmark();
    stopTrigger();
    const correct = verify_benchmark(result) != 0;
    console_put(if (correct) 'P' else 'F');
    putHex(@bitCast(result));
    return @intFromBool(!correct);
}
